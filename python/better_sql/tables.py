"""Own table paging, retained row handles, and atomic optimistic saves."""

import secrets
from copy import deepcopy
from dataclasses import dataclass
from typing import Any

import psycopg
from psycopg import sql
from psycopg.pq import TransactionStatus
from psycopg.types.json import Jsonb

from better_sql.browse import browse_clauses
from better_sql.protocol import ProtocolError
from better_sql.query import cell


@dataclass(frozen=True)
class _RowOriginal:
    relation: tuple[str, str]
    key: tuple[Any, ...]
    xmin: str


def _typed_predicate(column):
    return sql.SQL("{} = %s::{}").format(
        sql.Identifier(column["name"]),
        sql.Identifier(column["type_schema"], column["type_name"]),
    )


class TableStore:
    def __init__(self):
        self._originals: dict[str, _RowOriginal] = {}
        self._relations: dict[tuple[str, str], dict] = {}

    def page(self, conn, relation, offset: int, limit: int = 100,
             retain_handles: list[str] | None = None, filters: list[dict] | None = None,
             sort: dict | None = None) -> dict:
        if type(offset) is not int or offset < 0:
            raise ProtocolError("invalid_request", "offset must be a nonnegative integer")
        if type(limit) is not int or not 1 <= limit <= 100:
            raise ProtocolError("invalid_request", "limit must be an integer from 1 to 100")
        if retain_handles is None:
            retain_handles = []
        if not isinstance(retain_handles, list) or any(not isinstance(h, str) for h in retain_handles):
            raise ProtocolError("invalid_request", "retain_handles must be an array of strings")

        editable = relation["kind"] in ("r", "p") and bool(relation["primary_key"])
        relation_id = sql.Identifier(relation["schema"], relation["name"])
        where, order, values = browse_clauses(relation, filters, sort)
        projection = sql.SQL("*, xmin::text") if editable else sql.SQL("*")
        query = sql.SQL("SELECT {} FROM {}{}{} LIMIT %s OFFSET %s").format(
            projection, relation_id, where, order,
        )
        if editable:
            read_only_reason = None
        else:
            if relation["kind"] == "v":
                read_only_reason = "View is read-only; paging order is unstable."
            else:
                read_only_reason = "Table has no primary key; paging order is unstable."

        with conn.cursor() as cursor:
            cursor.execute(query, (*values, limit + 1, offset))
            fetched = cursor.fetchall()

        columns = relation["columns"]
        column_names = [column["name"] for column in columns]
        kept = {handle: self._originals[handle] for handle in retain_handles if handle in self._originals}
        rows = []
        for raw_row in fetched[:limit]:
            values = dict(zip(column_names, raw_row[:len(column_names)]))
            key = tuple(values[name] for name in relation["primary_key"]) if editable else ()
            handle = None
            if editable:
                handle = secrets.token_urlsafe(24)
                kept[handle] = _RowOriginal(
                    relation=(relation["schema"], relation["name"]),
                    key=key, xmin=raw_row[-1],
                )
            rows.append({
                "handle": handle,
                "key": [cell(value) for value in key],
                "cells": [cell(value) for value in raw_row[:len(column_names)]],
            })
        self._originals = kept
        self._relations[(relation["schema"], relation["name"])] = deepcopy(relation)
        return {
            "columns": columns, "rows": rows, "offset": offset,
            "page_size": limit, "next_offset": offset + limit if len(fetched) > limit else None,
            "has_more": len(fetched) > limit, "editable": editable,
            "read_only_reason": read_only_reason,
        }

    def save(self, conn, schema: str, table: str, edits: list[dict]) -> dict:
        relation, columns = self._validate_edits(schema, table, edits)
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
                        original = self._originals[handle]
                        changed_names = [change["column"] for change in edit["changes"]]
                        assignments = sql.SQL(", ").join(_typed_predicate(columns[name]) for name in changed_names)
                        query = sql.SQL("UPDATE {} SET {} WHERE {} AND xmin = %s::pg_catalog.xid RETURNING {}, xmin::text").format(
                            sql.Identifier(relation["schema"], relation["name"]), assignments, predicate, returning,
                        )
                        values = [None if change["is_null"] else change["text"] for change in edit["changes"]]
                        key_values = [
                            Jsonb(value) if (columns[name]["base_type_schema"], columns[name]["base_type_name"]) == ("pg_catalog", "jsonb") else value
                            for name, value in zip(keys, original.key)
                        ]
                        cursor.execute(query, (*values, *key_values, original.xmin))
                        if cursor.rowcount == 0:
                            raise ProtocolError(
                                "edit_conflict", "Row changed or was deleted since loading; reload and review pending edits.",
                                handle=handle,
                            )
                        if cursor.rowcount != 1:
                            raise ProtocolError("internal_error", "Expected exactly one updated row.", handle=handle)
                        raw = cursor.fetchone()
                        new_values = dict(zip(columns, raw[:-1]))
                        key = tuple(new_values[name] for name in keys)
                        refreshed[handle] = _RowOriginal(original.relation, key, raw[-1])
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
        self._originals.update(refreshed)
        return {"rows": rows}

    def _validate_edits(self, schema, table, edits):
        relation_key = (schema, table)
        stored = self._relations.get(relation_key)
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
            original = self._originals.get(handle)
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
