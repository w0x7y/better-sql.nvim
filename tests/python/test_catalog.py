"""Catalog classification and session dispatch tests."""

import unittest

from better_sql.catalog import column_editability
from better_sql.protocol import ProtocolError
from better_sql.session import Session


class CatalogClassificationTests(unittest.TestCase):
    def test_supported_builtin_and_enum_types_are_editable(self):
        self.assertEqual(column_editability("r", ["id"], "value", 25, "b", False, {25}), (True, None))
        self.assertEqual(column_editability("p", ["id"], "value", 9999, "e", False, set()), (True, None))

    def test_read_only_reasons(self):
        cases = [
            (("v", [], "value", 25, "b", False, {25}), "view"),
            (("r", [], "value", 25, "b", False, {25}), "no_primary_key"),
            (("r", ["id"], "id", 23, "b", False, {23}), "primary_key"),
            (("r", ["id"], "value", 23, "b", True, {23}), "generated"),
            (("r", ["id"], "value", 1009, "b", False, {25}), "unsupported_type"),
            (("r", ["id"], "value", 17, "b", False, {25}), "unsupported_type"),
            (("r", ["id"], "value", 9999, "d", False, {25}), "unsupported_type"),
        ]
        for args, reason in cases:
            with self.subTest(reason=reason, args=args):
                self.assertEqual(column_editability(*args), (False, reason))

    def test_catalog_load_requires_connection(self):
        with self.assertRaises(ProtocolError) as raised:
            Session().handle("catalog.load", {})
        self.assertEqual(raised.exception.code, "not_connected")


if __name__ == "__main__":
    unittest.main()
