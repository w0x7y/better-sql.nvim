"""Paged table reads against PostgreSQL."""

import json

from better_sql.catalog import load_catalog
from better_sql.protocol import ProtocolError
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
        cls.conn.execute("CREATE TABLE browsing (id integer PRIMARY KEY, score integer, note text)")
        cls.conn.execute("INSERT INTO browsing SELECT n, n % 2, 'same' FROM generate_series(1, 205) AS n")

    def test_session_filters_and_sorts_before_paging(self):
        session = Session()
        try:
            session.handle("connect", {"conninfo": self.conn.info.dsn})
            options = {"schema": self.schema, "table": "numbered",
                       "filters": [{"column": "id", "operator": ">=", "value": "2"}],
                       "sort": {"column": "id", "direction": "desc"}}
            page = session.handle("table.page", {**options, "offset": 0})
            self.assertEqual(len(page["rows"]), 100)
            self.assertFalse(page["has_more"])
            self.assertEqual(page["rows"][0]["cells"][0]["text"], "101")
            self.assertEqual(page["rows"][-1]["cells"][0]["text"], "2")
            self.assertEqual(session.handle("table.page", {**options, "offset": 100})["rows"], [])
        finally:
            session.close()

    def test_sort_ties_use_primary_key_across_pages(self):
        ids = []
        for offset in (0, 100, 200):
            page = self.store.page(self.conn, self.relations["browsing"], offset,
                                   sort={"column": "score", "direction": "desc"})
            ids.extend(int(row["cells"][0]["text"]) for row in page["rows"])
        self.assertEqual(ids[:3], [1, 3, 5])
        self.assertEqual(ids[100:106], [201, 203, 205, 2, 4, 6])
        self.assertEqual(ids[-3:], [200, 202, 204])
        self.assertEqual(len(set(ids)), 205)

    def test_multiple_typed_filters_and_literal_search(self):
        page = self.store.page(self.conn, self.relations["typed_values"], 0, filters=[
            {"column": "amount", "operator": ">", "value": "12.49"},
            {"column": "happened", "operator": "<=", "value": "2024-01-02"},
        ])
        self.assertEqual([row["cells"][0]["text"] for row in page["rows"]], ["7"])
        for value in ("%", "_", "\\", "' OR true --"):
            with self.subTest(value=value):
                page = self.store.page(self.conn, self.relations["numbered"], 0,
                                       filters=[{"column": "label", "operator": "contains", "value": value}])
                self.assertEqual(page["rows"], [])
        page = self.store.page(self.conn, self.relations["numbered"], 0,
                               filters=[{"column": "label", "operator": "contains", "value": "ROW 101"}])
        self.assertEqual(page["rows"][0]["cells"][0]["text"], "101")

    def test_null_empty_and_quoted_columns_on_views(self):
        relation = self.relations["Odd View"]
        for operator, value, expected in (("is_null", None, "1"), ("=", "", "2"),
                                           ("not_null", None, "1")):
            with self.subTest(operator=operator):
                condition = {"column": "Value", "operator": operator}
                if value is not None:
                    condition["value"] = value
                page = self.store.page(self.conn, relation, 0, filters=[condition],
                                       sort={"column": "Order ID", "direction": "asc"})
                self.assertEqual(page["rows"][0]["cells"][0]["text"], expected)
                self.assertFalse(page["editable"])
        page = self.store.page(self.conn, self.relations['Odd" Table'], 0,
                               sort={"column": "Value", "direction": "desc"})
        self.assertTrue(page["rows"][-1]["cells"][2]["is_null"])

    def test_filtered_out_pending_handle_remains_saveable(self):
        relation = self.relations["numbered"]
        original = self.store.page(self.conn, relation, 0)["rows"][0]
        try:
            hidden = self.store.page(self.conn, relation, 0,
                                     retain_handles=[original["handle"]],
                                     filters=[{"column": "id", "operator": "=", "value": "101"}])
            self.assertEqual(len(hidden["rows"]), 1)
            self.store.save(self.conn, relation["schema"], relation["name"], [{"handle": original["handle"], "changes": [
                {"column": "label", "text": "hidden edit", "is_null": False},
            ]}])
            self.assertEqual(self.conn.execute("SELECT label FROM numbered WHERE id=1").fetchone()[0], "hidden edit")
        finally:
            self.conn.execute("UPDATE numbered SET label='row 1' WHERE id=1")

    def test_session_invalid_options_and_conversion_preserve_handles(self):
        session = Session()
        try:
            session.handle("connect", {"conninfo": self.conn.info.dsn})
            params = {"schema": self.schema, "table": "numbered"}
            page = session.handle("table.page", params)
            original_handle = page["rows"][0]["handle"]
            with self.assertRaises(ProtocolError) as raised:
                session.handle("table.page", {**params, "sort": {"column": "id", "direction": "DROP"}})
            self.assertEqual(raised.exception.code, "invalid_request")
            with self.assertRaises(ProtocolError) as raised:
                session.handle("table.page", {**params, "filters": [
                    {"column": "id", "operator": "=", "value": "invalid integer"},
                ]})
            self.assertEqual(raised.exception.details["sqlstate"], "22P02")
            result = session.handle("table.save", {**params, "edits": [{"handle": original_handle, "changes": [
                {"column": "label", "text": "row 1", "is_null": False},
            ]}]})
            self.assertEqual(result["rows"][0]["cells"][1]["text"], "row 1")
        finally:
            session.close()

    def setUp(self):
        self.store = TableStore()
        schema = next(s for s in load_catalog(self.conn)["schemas"] if s["name"] == self.schema)
        self.relations = {relation["name"]: relation for relation in schema["relations"]}

    def test_session_pages_typed_arrays_as_read_only_cells(self):
        self.conn.execute("CREATE TABLE arrays (id integer PRIMARY KEY, amounts numeric[], dates date[], ids uuid[])")
        self.conn.execute("""INSERT INTO arrays VALUES (1, ARRAY[12.50, NULL]::numeric[],
            ARRAY[DATE '2024-01-02'], ARRAY['12345678-1234-1234-1234-123456789abc'::uuid])""")
        session = Session()
        try:
            session.handle("connect", {"conninfo": self.conn.info.dsn})
            page = session.handle("table.page", {"schema": self.schema, "table": "arrays", "offset": 0})
            self.assertEqual([json.loads(value["text"]) for value in page["rows"][0]["cells"][1:]], [
                ["12.50", None], ["2024-01-02"], ["12345678-1234-1234-1234-123456789abc"],
            ])
            for column in page["columns"][1:]:
                self.assertFalse(column["editable"])
                self.assertEqual(column["read_only_reason"], "unsupported_type")
        finally:
            session.close()

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
        old_handle = self.store.page(self.conn, self.relations["numbered"], 0)["rows"][0]["handle"]
        for name in ("Odd View", "keyless"):
            with self.subTest(name=name):
                page = self.store.page(self.conn, self.relations[name], 0)
                self.assertFalse(page["editable"])
                self.assertIn("unstable", page["read_only_reason"])
                self.assertTrue(page["rows"])
                self.assertTrue(all(row["handle"] is None and row["key"] == [] for row in page["rows"]))
        with self.assertRaises(ProtocolError) as raised:
            self.store.save(self.conn, self.schema, "numbered", [{"handle": old_handle, "changes": [
                {"column": "label", "text": "must not save", "is_null": False},
            ]}])
        self.assertEqual(raised.exception.code, "invalid_request")

    def test_retained_handles_remain_saveable_and_unpinned_handles_expire(self):
        typed = self.store.page(self.conn, self.relations["typed_values"], 0)["rows"][0]
        self.assertEqual([value["text"] for value in typed["cells"]], ["7", "12.50", "2024-01-02", '{"a": 1}'])
        first = self.store.page(self.conn, self.relations["numbered"], 0,
                                retain_handles=[typed["handle"]])
        unpinned = first["rows"][0]["handle"]
        pinned = first["rows"][1]["handle"]
        self.store.page(self.conn, self.relations["numbered"], 100, retain_handles=[pinned, typed["handle"], "unknown"])
        change = {"column": "label", "text": "row 2", "is_null": False}
        with self.assertRaises(ProtocolError) as raised:
            self.store.save(self.conn, self.schema, "numbered", [{"handle": unpinned, "changes": [change]}])
        self.assertEqual(raised.exception.code, "invalid_request")
        self.store.page(self.conn, self.relations["numbered"], 100,
                        retain_handles=[unpinned, pinned, typed["handle"]])
        with self.assertRaises(ProtocolError) as raised:
            self.store.save(self.conn, self.schema, "numbered", [{"handle": unpinned, "changes": [change]}])
        self.assertEqual(raised.exception.code, "invalid_request")
        saved = self.store.save(self.conn, self.schema, "numbered", [{"handle": pinned, "changes": [change]}])
        self.assertEqual(saved["rows"][0]["key"], [{"text": "2", "is_null": False}])
        saved = self.store.save(self.conn, self.schema, "typed_values", [{"handle": typed["handle"], "changes": [
            {"column": "amount", "text": "12.50", "is_null": False},
        ]}])
        self.assertEqual(saved["rows"][0]["cells"], typed["cells"])

    def test_session_pages_relation_and_reconnect_clears_handles(self):
        session = Session()
        try:
            session.handle("connect", {"conninfo": self.conn.info.dsn})
            page = session.handle("table.page", {
                "schema": self.schema, "table": "numbered", "offset": 100,
            })
            self.assertEqual([row["key"][0]["text"] for row in page["rows"]], ["101"])
            old_handle = page["rows"][0]["handle"]
            params = {"schema": self.schema, "table": "numbered", "edits": [{"handle": old_handle, "changes": [
                {"column": "label", "text": "row 101", "is_null": False},
            ]}]}
            session.handle("connect", {"conninfo": self.conn.info.dsn})
            session.handle("table.page", {"schema": self.schema, "table": "numbered", "offset": 100})
            with self.assertRaises(ProtocolError) as raised:
                session.handle("table.save", params)
            self.assertEqual(raised.exception.code, "invalid_request")
            self.assertEqual(session.handle("ping", {}), {"pong": True})
            self.assertEqual(session.handle("query.run", {"sql": "SELECT 1"})["sets"][0]["rows"][0][0]["text"], "1")
        finally:
            session.close()
