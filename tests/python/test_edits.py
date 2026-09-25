"""Reject invalid save requests before touching the database."""

import unittest

from better_sql.edits import save_edits
from better_sql.protocol import ProtocolError
from better_sql.session import Session
from better_sql.tables import RowOriginal, TableStore


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
        self.store.relations[("public", "users")] = self.relation
        self.store.handles["row"] = RowOriginal(("public", "users"), {"id": 1, "name": "old"}, (1,), "10")

    def test_save_requires_connection(self):
        with self.assertRaises(ProtocolError) as raised:
            Session().handle("table.save", {"schema": "public", "table": "users", "edits": []})
        self.assertEqual(raised.exception.code, "not_connected")

    def test_invalid_requests_are_rejected_before_database_access(self):
        change = {"column": "name", "text": "new", "is_null": False}
        cases = [None, {}, [None], [{"handle": "missing", "changes": [change]}],
                 [{"handle": [], "changes": [change]}], [{"handle": "row", "changes": []}],
                 [{"handle": "row", "changes": [None]}]]
        for column in ("id", "computed", "unknown", []):
            cases.append([{"handle": "row", "changes": [{**change, "column": column}]}])
        for override in ({"text": 1}, {"is_null": "false"}, {"is_null": 0}):
            cases.append([{"handle": "row", "changes": [{**change, **override}]}])
        cases.extend([
            [{"handle": "row", "changes": [change, change]}],
            [{"handle": "row", "changes": [change]}] * 2,
        ])
        for edits in cases:
            with self.subTest(edits=edits), self.assertRaises(ProtocolError) as raised:
                save_edits(None, self.store, self.relation, edits)
            self.assertEqual(raised.exception.code, "invalid_request")

    def test_handle_must_belong_to_requested_relation(self):
        self.store.handles["row"].relation = ("public", "other")
        with self.assertRaises(ProtocolError):
            save_edits(None, self.store, self.relation, [{"handle": "row", "changes": [
                {"column": "name", "text": "new", "is_null": False},
            ]}])

    def test_unloaded_relation_cannot_be_saved(self):
        self.store.relations.clear()
        with self.assertRaises(ProtocolError):
            save_edits(None, self.store, self.relation, [])

    def test_empty_save_is_a_noop(self):
        self.assertEqual(save_edits(None, self.store, self.relation, []), {"rows": []})
