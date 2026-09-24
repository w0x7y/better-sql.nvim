"""Validate staged cells and commit a table's edits as one transaction."""

import psycopg
from psycopg import sql
from psycopg.pq import TransactionStatus
from psycopg.types.json import Jsonb

from better_sql.protocol import ProtocolError
from better_sql.query import cell
from better_sql.tables import RowOriginal


class EditConflict(ProtocolError):
    def __init__(self, handle):
        super().__init__(
            "edit_conflict", "Row changed or was deleted since loading; reload and review pending edits.",
            handle=handle,
        )


def _validate_edits(store, relation, edits):
    relation_key = (relation["schema"], relation["name"])
    stored = store.relations.get(relation_key)
    if stored is None:
        raise ProtocolError("invalid_request", "Load the table before saving edits.")
    if stored["kind"] not in ("r", "p") or not stored["primary_key"]:
        raise ProtocolError("invalid_request", "Table is read-only.")
    if not isinstance(edits, list):
        raise ProtocolError("invalid_request", "edits must be an array")
    columns = {column["name"]: column for column in stored["columns"]}
    seen_handles = set()
    for edit in edits:
        if not isinstance(edit, dict) or not isinstance(edit.get("handle"), str):
            raise ProtocolError("invalid_request", "Each edit must have a row handle.")
        handle = edit["handle"]
        original = store.handles.get(handle)
        if original is None or original.relation != relation_key:
            raise ProtocolError("invalid_request", "Unknown row handle; reload the table.", handle=handle)
        if handle in seen_handles:
            raise ProtocolError("invalid_request", "Duplicate row handle.", handle=handle)
        seen_handles.add(handle)
        changes = edit.get("changes")
        if not isinstance(changes, list) or not changes:
            raise ProtocolError("invalid_request", "changes must be a nonempty array", handle=handle)
        seen_columns = set()
        for change in changes:
            if not isinstance(change, dict) or not isinstance(change.get("column"), str):
                raise ProtocolError("invalid_request", "Each change must name a column.", handle=handle)
            name = change["column"]
            column = columns.get(name)
            details = {"handle": handle, "column": name}
            if column is None or name in stored["primary_key"] or not column["editable"]:
                raise ProtocolError("invalid_request", "Column is unknown or read-only.", **details)
            if name in seen_columns:
                raise ProtocolError("invalid_request", "Duplicate column change.", **details)
            seen_columns.add(name)
            if not isinstance(change.get("text"), str) or type(change.get("is_null")) is not bool:
                raise ProtocolError("invalid_request", "Each change requires text and a boolean is_null.", **details)
    return stored, columns


def _typed_predicate(column):
    return sql.SQL("{} = %s::{}").format(
        sql.Identifier(column["name"]),
        sql.Identifier(column["type_schema"], column["type_name"]),
    )


def save_edits(conn, store, relation, edits: list[dict]) -> dict:
    relation, columns = _validate_edits(store, relation, edits)
    if not edits:
        return {"rows": []}
    if not conn.autocommit or conn.info.transaction_status != TransactionStatus.IDLE:
        raise ProtocolError("invalid_request", "Finish the active SQL transaction before saving table edits.")

    keys = relation["primary_key"]
    predicate = sql.SQL(" AND ").join(_typed_predicate(columns[name]) for name in keys)
    returning = sql.SQL(", ").join(sql.Identifier(column["name"]) for column in relation["columns"])
    refreshed = {}
    rows = []
    handle = None
    changed_names = []
    try:
        with conn.transaction():
            with conn.cursor() as cursor:
                for edit in edits:
                    handle = edit["handle"]
                    original = store.handles[handle]
                    changed_names = [change["column"] for change in edit["changes"]]
                    assignments = sql.SQL(", ").join(_typed_predicate(columns[name]) for name in changed_names)
                    query = sql.SQL("UPDATE {} SET {} WHERE {} AND xmin = %s::pg_catalog.xid RETURNING {}, xmin::text").format(
                        sql.Identifier(relation["schema"], relation["name"]), assignments, predicate, returning,
                    )
                    values = [None if change["is_null"] else change["text"] for change in edit["changes"]]
                    key_values = [
                        Jsonb(value) if (columns[name]["type_schema"], columns[name]["type_name"]) == ("pg_catalog", "jsonb") else value
                        for name, value in zip(keys, original.key)
                    ]
                    cursor.execute(query, (*values, *key_values, original.xmin))
                    if cursor.rowcount == 0:
                        raise EditConflict(handle)
                    if cursor.rowcount != 1:
                        raise ProtocolError("internal_error", "Expected exactly one updated row.", handle=handle)
                    raw = cursor.fetchone()
                    new_values = dict(zip(columns, raw[:-1]))
                    key = tuple(new_values[name] for name in keys)
                    refreshed[handle] = RowOriginal(original.relation, new_values, key, raw[-1])
                    rows.append({
                        "handle": handle, "key": [cell(value) for value in key],
                        "cells": [cell(value) for value in raw[:-1]], "xmin": raw[-1],
                    })
            # A deferred constraint may fail at commit and cannot reliably identify a row.
            handle = None
            changed_names = []
    except psycopg.Error as exc:
        column = exc.diag.column_name
        if column is None and len(changed_names) == 1:
            column = changed_names[0]
        position = exc.diag.statement_position
        raise ProtocolError(
            "database_error", exc.diag.message_primary or "Table save failed; check the database connection.",
            sqlstate=exc.sqlstate, position=int(position) if position else None,
            handle=handle, column=column, columns=changed_names,
        ) from None
    store.handles.update(refreshed)
    return {"rows": rows}
