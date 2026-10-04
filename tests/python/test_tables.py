"""Table page request validation without a database connection."""

import unittest
from unittest.mock import MagicMock

from better_sql.protocol import ProtocolError
from better_sql.session import Session
from better_sql.tables import TableStore


class TablePageSessionTests(unittest.TestCase):
    def test_page_reports_requested_size_and_terminal_next_offset(self):
        relation = {"schema": "public", "name": "items", "kind": "r",
                    "primary_key": ["id"], "columns": [
                        {"name": "id", "type_schema": "pg_catalog", "type_name": "int4"},
                    ]}
        conn = MagicMock()
        cursor = conn.cursor.return_value.__enter__.return_value
        store = TableStore()
        cursor.fetchall.return_value = [(n, "1") for n in (5, 6, 7, 8)]
        first = store.page(conn, relation, 4, limit=3)
        self.assertEqual(len(first["rows"]), 3)
        self.assertEqual(first["page_size"], 3)
        self.assertEqual(first["next_offset"], 7)
        cursor.fetchall.return_value = [(8, "1")]
        last = store.page(conn, relation, first["next_offset"], limit=3)
        self.assertEqual(last["page_size"], 3)
        self.assertIsNone(last["next_offset"])
        cursor.fetchall.return_value = []
        empty = store.page(conn, relation, 10, limit=3)
        self.assertEqual(empty["page_size"], 3)
        self.assertIsNone(empty["next_offset"])

    def test_page_requires_connection(self):
        with self.assertRaises(ProtocolError) as raised:
            Session().handle("table.page", {"schema": "public", "table": "users", "offset": 0})
        self.assertEqual(raised.exception.code, "not_connected")

    def test_invalid_browse_options_are_rejected_before_database_access(self):
        relation = {"schema": "public", "name": "items", "kind": "r",
                    "primary_key": ["id"], "columns": [
                        {"name": "id", "type_schema": "pg_catalog", "type_name": "int4"},
                    ]}
        cases = [
            {"filters": {}}, {"filters": [None]},
            {"filters": [{"column": [], "operator": "=", "value": "1"}]},
            {"filters": [{"column": "missing", "operator": "=", "value": "1"}]},
            {"filters": [{"column": "id", "operator": "OR true", "value": "1"}]},
            {"filters": [{"column": "id", "operator": [], "value": "1"}]},
            {"filters": [{"column": "id", "operator": "=", "value": 1}]},
            {"filters": [{"column": "id", "operator": "="}]},
            {"sort": []}, {"sort": {"column": "missing", "direction": "asc"}},
            {"sort": {"column": "id", "direction": "desc; DELETE FROM items"}},
            {"sort": {"column": "id", "direction": []}},
        ]
        for options in cases:
            with self.subTest(options=options):
                with self.assertRaises(ProtocolError) as raised:
                    TableStore().page(None, relation, 0, **options)
                self.assertEqual(raised.exception.code, "invalid_request")


if __name__ == "__main__":
    unittest.main()
