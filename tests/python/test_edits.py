"""Reject invalid save requests before touching the database."""

import unittest
from unittest.mock import MagicMock

from better_sql.protocol import ProtocolError
from better_sql.session import Session
from better_sql.tables import TableStore


class EditValidationTests(unittest.TestCase):
    def setUp(self):
        self.relation = {
            "schema": "public", "name": "users", "kind": "r", "primary_key": ["id"],
            "columns": [
                {"name": "id", "type_schema": "pg_catalog", "type_name": "int4", "editable": False},
                {"name": "name", "type_schema": "pg_catalog", "type_name": "text", "editable": True},
                {"name": "computed", "type_schema": "pg_catalog", "type_name": "text", "editable": False},
            ],
        }
        self.store = TableStore()
        # Replace only PostgreSQL reads; loading and validation use the real store.
        connection = MagicMock()
        connection.cursor.return_value.__enter__.return_value.fetchall.return_value = [(1, "old", "computed", "10")]
        self.handle = self.store.page(connection, self.relation, 0)["rows"][0]["handle"]

    def test_save_requires_connection(self):
        with self.assertRaises(ProtocolError) as raised:
            Session().handle("table.save", {"schema": "public", "table": "users", "edits": []})
        self.assertEqual(raised.exception.code, "not_connected")

    def test_invalid_requests_are_rejected_before_database_access(self):
        change = {"column": "name", "text": "new", "is_null": False}
        cases = [None, {}, [None], [{"handle": "missing", "changes": [change]}],
                 [{"handle": [], "changes": [change]}], [{"handle": self.handle, "changes": []}],
                 [{"handle": self.handle, "changes": [None]}]]
        for column in ("id", "computed", "unknown", []):
            cases.append([{"handle": self.handle, "changes": [{**change, "column": column}]}])
        for override in ({"text": 1}, {"is_null": "false"}, {"is_null": 0}):
            cases.append([{"handle": self.handle, "changes": [{**change, **override}]}])
        cases.extend([
            [{"handle": self.handle, "changes": [change, change]}],
            [{"handle": self.handle, "changes": [change]}] * 2,
        ])
        for edits in cases:
            with self.subTest(edits=edits), self.assertRaises(ProtocolError) as raised:
                self.store.save(None, "public", "users", edits)
            self.assertEqual(raised.exception.code, "invalid_request")

    def test_handle_must_belong_to_requested_relation(self):
        other = {**self.relation, "name": "other"}
        connection = MagicMock()
        connection.cursor.return_value.__enter__.return_value.fetchall.return_value = []
        self.store.page(connection, other, 0, retain_handles=[self.handle])
        with self.assertRaises(ProtocolError):
            self.store.save(None, "public", "other", [{"handle": self.handle, "changes": [
                {"column": "name", "text": "new", "is_null": False},
            ]}])

    def test_unloaded_relation_cannot_be_saved(self):
        self.store = TableStore()
        with self.assertRaises(ProtocolError):
            self.store.save(None, "public", "users", [])

    def test_empty_save_is_a_noop(self):
        self.assertEqual(self.store.save(None, "public", "users", []), {"rows": []})
