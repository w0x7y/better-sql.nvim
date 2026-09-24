"""Own the active PostgreSQL connection and dispatch helper requests."""

import psycopg

from better_sql.protocol import ProtocolError
from better_sql.query import run_query


class Session:
    def __init__(self):
        self.conn = None

    def close(self):
        if self.conn is not None:
            self.conn.close()
            self.conn = None

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
            if old is not None:
                old.close()
            return {"database": conn.info.dbname, "user": conn.info.user}
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
        raise ProtocolError("unknown_method", method)
