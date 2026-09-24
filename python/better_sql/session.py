"""Own the active PostgreSQL connection and dispatch helper requests."""

import psycopg

from better_sql.catalog import load_catalog
from better_sql.edits import save_edits
from better_sql.protocol import ProtocolError
from better_sql.query import run_query
from better_sql.tables import TableStore


class Session:
    def __init__(self):
        self.conn = None
        self.tables = TableStore()

    def close(self):
        if self.conn is not None:
            self.conn.close()
            self.conn = None
        self.tables = TableStore()

    def handle(self, method: str, params: dict) -> dict:
        if method == "ping":
            return {"pong": True}
        if method == "connect":
            conninfo = params.get("conninfo")
            if not isinstance(conninfo, str) or not conninfo:
                raise ProtocolError("invalid_request", "conninfo must be a nonempty string")
            try:
                conn = psycopg.connect(conninfo, autocommit=True)
            except psycopg.Error as exc:
                raise ProtocolError(
                    "database_error", "connection failed", sqlstate=exc.sqlstate, position=None
                ) from None
            old = self.conn
            self.conn = conn
            self.tables = TableStore()
            if old is not None:
                old.close()
            return {"database": conn.info.dbname, "user": conn.info.user}
        if method == "catalog.load":
            if self.conn is None:
                raise ProtocolError("not_connected", "connect to a database first")
            try:
                return load_catalog(self.conn)
            except psycopg.Error as exc:
                raise ProtocolError(
                    "database_error", exc.diag.message_primary or "database error",
                    sqlstate=exc.sqlstate, position=None,
                ) from None
        if method == "query.run":
            if self.conn is None:
                raise ProtocolError("not_connected", "connect to a database first")
            sql_text = params.get("sql")
            max_rows = params.get("max_rows", 1000)
            max_bytes = params.get("max_bytes", 4194304)
            if not isinstance(sql_text, str) or not sql_text:
                raise ProtocolError("invalid_request", "sql must be a nonempty string")
            if any(type(value) is not int or value < 0 for value in (max_rows, max_bytes)):
                raise ProtocolError("invalid_request", "result caps must be nonnegative integers")
            try:
                return run_query(self.conn, sql_text, max_rows, max_bytes)
            except psycopg.Error as exc:
                position = exc.diag.statement_position
                raise ProtocolError(
                    "database_error", exc.diag.message_primary or "database error",
                    sqlstate=exc.sqlstate,
                    position=int(position) if position else None,
                ) from None
        if method == "table.save":
            if self.conn is None:
                raise ProtocolError("not_connected", "connect to a database first")
            schema = params.get("schema")
            table = params.get("table")
            if not isinstance(schema, str) or not schema or not isinstance(table, str) or not table:
                raise ProtocolError("invalid_request", "schema and table must be nonempty strings")
            return save_edits(self.conn, self.tables, {"schema": schema, "name": table}, params.get("edits"))
        if method == "table.page":
            if self.conn is None:
                raise ProtocolError("not_connected", "connect to a database first")
            schema = params.get("schema")
            table = params.get("table")
            if not isinstance(schema, str) or not schema or not isinstance(table, str) or not table:
                raise ProtocolError("invalid_request", "schema and table must be nonempty strings")
            offset = params.get("offset", 0)
            retain_handles = params.get("retain_handles")
            if type(offset) is not int or offset < 0:
                raise ProtocolError("invalid_request", "offset must be a nonnegative integer")
            if retain_handles is not None and (
                not isinstance(retain_handles, list)
                or any(not isinstance(handle, str) for handle in retain_handles)
            ):
                raise ProtocolError("invalid_request", "retain_handles must be an array of strings")
            try:
                catalog = load_catalog(self.conn)
                relation = next((
                    relation
                    for entry in catalog["schemas"] if entry["name"] == schema
                    for relation in entry["relations"] if relation["name"] == table
                ), None)
                if relation is None:
                    raise ProtocolError("invalid_request", "relation not found")
                return self.tables.page(self.conn, relation, offset, retain_handles=retain_handles)
            except psycopg.Error as exc:
                raise ProtocolError(
                    "database_error", exc.diag.message_primary or "database error",
                    sqlstate=exc.sqlstate, position=None,
                ) from None
        raise ProtocolError("unknown_method", method)
