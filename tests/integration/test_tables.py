"""Paged table reads against PostgreSQL."""

import datetime
import decimal
import json

from better_sql.catalog import load_catalog
from better_sql.session import Session
from better_sql.tables import TableStore
from support import DatabaseTestCase


class TableIntegrationTests(DatabaseTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.conn.execute("CREATE TABLE numbered (id integer PRIMARY KEY, label text)")
        cls.conn.execute("INSERT INTO numbered SELECT n, 'row ' || n FROM generate_series(1, 101) AS n")
        cls.conn.execute('CREATE TABLE "Odd"" Table" ("Order ID" integer NOT NULL, tenant integer NOT NULL, "Value" text, PRIMARY KEY (tenant, "Order ID"))')
        cls.conn.execute('INSERT INTO "Odd"" Table" VALUES (1, 2, NULL), (2, 1, \'\'), (1, 1, \'first\')')
        cls.conn.execute('CREATE VIEW "Odd View" AS SELECT "Order ID", "Value" FROM "Odd"" Table"')
        cls.conn.execute('CREATE TABLE keyless (value text)')
        cls.conn.execute("INSERT INTO keyless VALUES ('one')")
        cls.conn.execute('CREATE TABLE typed_values (id integer PRIMARY KEY, amount numeric, happened date, payload jsonb)')
        cls.conn.execute("INSERT INTO typed_values VALUES (7, 12.50, DATE '2024-01-02', '{\"a\": 1}'::jsonb)")

    def setUp(self):
        self.store = TableStore()
        schema = next(s for s in load_catalog(self.conn)["schemas"] if s["name"] == self.schema)
        self.relations = {relation["name"]: relation for relation in schema["relations"]}

    def test_page_size_has_more_and_order(self):
        relation = self.relations["numbered"]
        first = self.store.page(self.conn, relation, 0)
        self.assertEqual(len(first["rows"]), 100)
        self.assertTrue(first["has_more"])
        self.assertEqual(first["rows"][0]["key"], [{"text": "1", "is_null": False}])
        self.assertEqual(first["rows"][-1]["key"], [{"text": "100", "is_null": False}])
        self.assertEqual([c["name"] for c in first["columns"]], ["id", "label"])
        self.assertEqual(first["offset"], 0)
        self.assertTrue(first["editable"])
        self.assertIsNone(first["read_only_reason"])

        second = self.store.page(self.conn, relation, 100)
        self.assertEqual(len(second["rows"]), 1)
        self.assertEqual(second["rows"][0]["cells"][0]["text"], "101")
        self.assertFalse(second["has_more"])
        self.assertEqual(second["offset"], 100)

    def test_composite_key_order_quoted_identifiers_and_null_cell(self):
        page = self.store.page(self.conn, self.relations['Odd" Table'], 0)
        self.assertEqual([row["key"] for row in page["rows"]], [
            [{"text": "1", "is_null": False}, {"text": "1", "is_null": False}],
            [{"text": "1", "is_null": False}, {"text": "2", "is_null": False}],
            [{"text": "2", "is_null": False}, {"text": "1", "is_null": False}],
        ])
        self.assertEqual(page["rows"][1]["cells"][2], {"text": "", "is_null": False})
        self.assertEqual(page["rows"][2]["cells"][2], {"text": "", "is_null": True})
        self.assertEqual(json.loads(json.dumps(page)), page)

    def test_view_and_keyless_rows_have_no_editable_handles(self):
        for name in ("Odd View", "keyless"):
            with self.subTest(name=name):
                page = self.store.page(self.conn, self.relations[name], 0)
                self.assertFalse(page["editable"])
                self.assertIn("unstable", page["read_only_reason"])
                self.assertTrue(page["rows"])
                self.assertTrue(all(row["handle"] is None and row["key"] == [] for row in page["rows"]))
        self.assertEqual(self.store.handles, {})

    def test_handles_keep_typed_originals_and_prune_unpinned_rows(self):
        typed = self.store.page(self.conn, self.relations["typed_values"], 0)["rows"][0]
        original = self.store.handles[typed["handle"]]
        self.assertEqual(original.relation, (self.schema, "typed_values"))
        self.assertEqual(original.key, (7,))
        self.assertEqual(original.values["amount"], decimal.Decimal("12.50"))
        self.assertEqual(original.values["happened"], datetime.date(2024, 1, 2))
        self.assertEqual(original.values["payload"], {"a": 1})
        self.assertIsInstance(original.xmin, str)

        first = self.store.page(self.conn, self.relations["numbered"], 0,
                                retain_handles=[typed["handle"]])
        unpinned = first["rows"][0]["handle"]
        pinned = first["rows"][1]["handle"]
        self.store.page(self.conn, self.relations["numbered"], 100, retain_handles=[pinned, typed["handle"]])
        self.assertNotIn(unpinned, self.store.handles)
        self.assertIn(pinned, self.store.handles)
        self.assertIn(typed["handle"], self.store.handles)
        self.assertEqual(len(self.store.handles), 3)

    def test_session_pages_relation_and_reconnect_clears_handles(self):
        session = Session()
        try:
            session.handle("connect", {"conninfo": self.conn.info.dsn})
            page = session.handle("table.page", {
                "schema": self.schema, "table": "numbered", "offset": 100,
            })
            self.assertEqual([row["key"][0]["text"] for row in page["rows"]], ["101"])
            old_handle = page["rows"][0]["handle"]
            self.assertIn(old_handle, session.tables.handles)
            session.handle("connect", {"conninfo": self.conn.info.dsn})
            self.assertNotIn(old_handle, session.tables.handles)
            self.assertEqual(session.handle("ping", {}), {"pong": True})
            self.assertEqual(session.handle("query.run", {"sql": "SELECT 1"})["sets"][0]["rows"][0][0]["text"], "1")
        finally:
            session.close()
