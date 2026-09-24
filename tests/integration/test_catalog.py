"""Catalog metadata against PostgreSQL's real system catalog."""

import json

from better_sql.catalog import load_catalog
from better_sql.session import Session
from support import DatabaseTestCase


class CatalogIntegrationTests(DatabaseTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.conn.execute("CREATE TYPE mood AS ENUM ('calm', 'busy')")
        cls.conn.execute('''CREATE TABLE orders (
            order_id integer NOT NULL,
            tenant_id integer NOT NULL,
            "Odd Name" text,
            tags text[],
            generated_total integer GENERATED ALWAYS AS (order_id + tenant_id) STORED,
            mood mood,
            payload jsonb,
            raw bytea,
            PRIMARY KEY (tenant_id, order_id)
        )''')
        cls.conn.execute("""CREATE TABLE allowed_types (
            id integer PRIMARY KEY, c_text text, c_varchar varchar(20),
            c_bpchar char(2), c_int2 smallint, c_int4 integer, c_int8 bigint,
            c_numeric numeric, c_float4 real, c_float8 double precision,
            c_bool boolean, c_uuid uuid, c_date date, c_time time,
            c_timetz timetz, c_timestamp timestamp, c_timestamptz timestamptz,
            c_json json, c_jsonb jsonb, c_inet inet
        )""")
        cls.conn.execute('CREATE TABLE partitioned (id integer, part integer, note text, PRIMARY KEY (id, part)) PARTITION BY RANGE (part)')
        cls.conn.execute('CREATE TABLE dropped_column (id integer PRIMARY KEY, old_value text, kept text)')
        cls.conn.execute('ALTER TABLE dropped_column DROP COLUMN old_value')
        cls.conn.execute('CREATE TABLE empty_table ()')
        cls.conn.execute('CREATE TABLE keyless (value text)')
        cls.conn.execute('CREATE VIEW order_view AS SELECT order_id, "Odd Name" FROM orders')
        cls.conn.execute('CREATE TABLE "Mixed Case" ("Key ID" uuid PRIMARY KEY, "Full Name" varchar(40))')

    def relation(self, name):
        catalog = load_catalog(self.conn)
        schema = next(s for s in catalog["schemas"] if s["name"] == self.schema)
        return next(r for r in schema["relations"] if r["name"] == name)

    def test_composite_key_and_physical_column_order(self):
        relation = self.relation("orders")
        self.assertEqual(relation["primary_key"], ["tenant_id", "order_id"])
        self.assertEqual([c["name"] for c in relation["columns"]],
                         ["order_id", "tenant_id", "Odd Name", "tags", "generated_total", "mood", "payload", "raw"])
        self.assertEqual(relation["kind"], "r")
        self.assertEqual(relation["schema"], self.schema)

    def test_column_type_and_editability(self):
        columns = {c["name"]: c for c in self.relation("orders")["columns"]}
        self.assertEqual(columns["Odd Name"], {
            "name": "Odd Name", "type_schema": "pg_catalog", "type_name": "text",
            "base_type_schema": "pg_catalog", "base_type_name": "text",
            "type_label": "text", "editable": True, "read_only_reason": None,
        })
        self.assertEqual((columns["order_id"]["editable"], columns["order_id"]["read_only_reason"]),
                         (False, "primary_key"))
        self.assertEqual((columns["generated_total"]["editable"], columns["generated_total"]["read_only_reason"]),
                         (False, "generated"))
        self.assertEqual((columns["tags"]["type_name"], columns["tags"]["editable"], columns["tags"]["read_only_reason"]),
                         ("_text", False, "unsupported_type"))
        self.assertEqual((columns["raw"]["editable"], columns["raw"]["read_only_reason"]),
                         (False, "unsupported_type"))
        self.assertEqual((columns["mood"]["type_schema"], columns["mood"]["editable"]),
                         (self.schema, True))
        self.assertTrue(columns["payload"]["editable"])

    def test_complete_type_allowlist_against_real_type_oids(self):
        columns = {c["name"]: c for c in self.relation("allowed_types")["columns"]}
        allowed = (
            "text", "varchar", "bpchar", "int2", "int4", "int8", "numeric",
            "float4", "float8", "bool", "uuid", "date", "time", "timetz",
            "timestamp", "timestamptz", "json", "jsonb",
        )
        for type_name in allowed:
            with self.subTest(type_name=type_name):
                column = columns["c_" + type_name]
                self.assertEqual((column["type_name"], column["editable"], column["read_only_reason"]),
                                 (type_name, True, None))
        self.assertEqual((columns["c_inet"]["editable"], columns["c_inet"]["read_only_reason"]),
                         (False, "unsupported_type"))

    def test_view_and_keyless_table_are_read_only(self):
        for name, kind, reason in (("order_view", "v", "view"), ("keyless", "r", "no_primary_key")):
            with self.subTest(name=name):
                relation = self.relation(name)
                self.assertEqual(relation["kind"], kind)
                self.assertEqual(relation["primary_key"], [])
                self.assertTrue(all(not c["editable"] and c["read_only_reason"] == reason
                                    for c in relation["columns"]))

    def test_dropped_columns_and_empty_relations(self):
        self.assertEqual([c["name"] for c in self.relation("dropped_column")["columns"]],
                         ["id", "kept"])
        self.assertEqual(self.relation("empty_table")["columns"], [])

    def test_partitioned_table_with_key_has_editable_non_key_column(self):
        relation = self.relation("partitioned")
        self.assertEqual(relation["kind"], "p")
        self.assertEqual(relation["primary_key"], ["id", "part"])
        self.assertEqual((relation["columns"][2]["editable"], relation["columns"][2]["read_only_reason"]),
                         (True, None))

    def test_quoted_relation_and_columns(self):
        relation = self.relation("Mixed Case")
        self.assertEqual(relation["primary_key"], ["Key ID"])
        self.assertEqual([c["name"] for c in relation["columns"]], ["Key ID", "Full Name"])
        self.assertTrue(relation["columns"][1]["editable"])
        self.assertEqual(relation["columns"][1]["type_label"], "character varying(40)")

    def test_session_returns_json_catalog_and_preserves_existing_methods(self):
        session = Session()
        try:
            self.assertEqual(session.handle("ping", {}), {"pong": True})
            session.handle("connect", {"conninfo": self.conn.info.dsn})
            catalog = session.handle("catalog.load", {})
            self.assertIn(self.schema, [s["name"] for s in catalog["schemas"]])
            self.assertEqual(json.loads(json.dumps(catalog)), catalog)
            self.assertEqual(session.handle("query.run", {"sql": "SELECT 1"})["sets"][0]["rows"][0][0]["text"], "1")
        finally:
            session.close()


if __name__ == "__main__":
    import unittest
    unittest.main()
