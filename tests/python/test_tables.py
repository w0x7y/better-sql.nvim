"""Table page request validation without a database connection."""

import unittest

from better_sql.protocol import ProtocolError
from better_sql.session import Session
from better_sql.tables import TableStore


class TablePageSessionTests(unittest.TestCase):
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
