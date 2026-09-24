"""Read table pages and retain originals for later row edits."""

import secrets
from dataclasses import dataclass
from typing import Any

from psycopg import sql

from better_sql.protocol import ProtocolError
from better_sql.query import cell


@dataclass
class RowOriginal:
    relation: tuple[str, str]
    values: dict[str, Any]
    key: tuple[Any, ...]
    xmin: str


class TableStore:
    def __init__(self):
        self.handles: dict[str, RowOriginal] = {}

    def page(self, conn, relation, offset: int, limit: int = 100,
             retain_handles: list[str] | None = None) -> dict:
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
        if editable:
            order = sql.SQL(", ").join(sql.Identifier(name) for name in relation["primary_key"])
            query = sql.SQL("SELECT *, xmin::text FROM {} ORDER BY {} LIMIT %s OFFSET %s").format(
                relation_id, order,
            )
            read_only_reason = None
        else:
            query = sql.SQL("SELECT * FROM {} LIMIT %s OFFSET %s").format(relation_id)
            if relation["kind"] == "v":
                read_only_reason = "View is read-only; paging order is unstable."
            else:
                read_only_reason = "Table has no primary key; paging order is unstable."

        with conn.cursor() as cursor:
            cursor.execute(query, (limit + 1, offset))
            fetched = cursor.fetchall()

        columns = relation["columns"]
        column_names = [column["name"] for column in columns]
        kept = {handle: self.handles[handle] for handle in retain_handles if handle in self.handles}
        rows = []
        for raw_row in fetched[:limit]:
            values = dict(zip(column_names, raw_row[:len(column_names)]))
            key = tuple(values[name] for name in relation["primary_key"]) if editable else ()
            handle = None
            if editable:
                handle = secrets.token_urlsafe(24)
                kept[handle] = RowOriginal(
                    relation=(relation["schema"], relation["name"]),
                    values=values, key=key, xmin=raw_row[-1],
                )
            rows.append({
                "handle": handle,
                "key": [cell(value) for value in key],
                "cells": [cell(value) for value in raw_row[:len(column_names)]],
            })
        self.handles = kept
        return {
            "columns": columns, "rows": rows, "offset": offset,
            "has_more": len(fetched) > limit, "editable": editable,
            "read_only_reason": read_only_reason,
        }
