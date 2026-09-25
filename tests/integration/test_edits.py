"""Atomic saves, typed input, and stale handles against PostgreSQL."""

import copy
import decimal

from psycopg import sql
from psycopg.pq import TransactionStatus

from better_sql.catalog import load_catalog
from better_sql.edits import EditConflict, save_edits
from better_sql.protocol import ProtocolError, encode_error
from better_sql.session import Session
from better_sql.tables import TableStore
from support import DatabaseTestCase


class EditIntegrationTests(DatabaseTestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.conn.execute("CREATE TABLE users (id integer PRIMARY KEY, username text NOT NULL UNIQUE, amount numeric CHECK (amount >= 0), doubled numeric GENERATED ALWAYS AS (amount * 2) STORED, tags text[])")
        cls.conn.execute("CREATE TABLE keyless (username text)")
        cls.conn.execute("CREATE VIEW user_view AS SELECT * FROM users")
        cls.conn.execute('CREATE TYPE "Odd"" Type" AS ENUM (\'one\', \'two\', \'three\')')
        cls.conn.execute('CREATE TABLE "Odd"" Table" ("Key" "Odd"" Type", tenant integer, "Value" "Odd"" Type", "Text" text, PRIMARY KEY ("Key", tenant))')

    def setUp(self):
        self.conn.execute("TRUNCATE users")
        self.conn.execute("INSERT INTO users (id, username, amount) VALUES (1, 'first', 10), (2, 'second', 20)")
        self.store = TableStore()
        schema = next(s for s in load_catalog(self.conn)["schemas"] if s["name"] == self.schema)
        self.relations = {r["name"]: r for r in schema["relations"]}
        self.table = self.relations["users"]
        self.rows = self.store.page(self.conn, self.table, 0)["rows"]

    def edit(self, index, column, text="", is_null=False):
        return {"handle": self.rows[index]["handle"], "changes": [
            {"column": column, "text": text, "is_null": is_null},
        ]}

    def values(self):
        return self.other_conn.execute("SELECT username, amount FROM users ORDER BY id").fetchall()

    def test_two_rows_commit_and_refresh_originals_for_next_save(self):
        old_xmin = self.store.handles[self.rows[0]["handle"]].xmin
        result = save_edits(self.conn, self.store, self.table, [
            self.edit(0, "username", "changed"), self.edit(1, "amount", "3.50"),
        ])
        self.assertEqual(self.values(), [("changed", decimal.Decimal("10")), ("second", decimal.Decimal("3.50"))])
        self.assertEqual([r["handle"] for r in result["rows"]], [r["handle"] for r in self.rows])
        self.assertEqual(result["rows"][1]["cells"][3]["text"], "7.00")
        original = self.store.handles[self.rows[0]["handle"]]
        self.assertEqual(original.values["username"], "changed")
        self.assertNotEqual(original.xmin, old_xmin)
        self.assertEqual(result["rows"][0]["xmin"], original.xmin)
        save_edits(self.conn, self.store, self.table, [self.edit(0, "username", "again")])
        self.assertEqual(self.values()[0][0], "again")

    def assert_failed_batch(self, second, code, sqlstate=None):
        originals = copy.deepcopy(self.store.handles)
        with self.assertRaises(ProtocolError) as raised:
            save_edits(self.conn, self.store, self.table, [self.edit(0, "username", "changed"), second])
        error = encode_error(raised.exception)
        self.assertEqual(error["code"], code)
        self.assertEqual(error["handle"], self.rows[1]["handle"])
        if sqlstate:
            self.assertEqual(error["sqlstate"], sqlstate)
        self.assertEqual(self.store.handles, originals)
        self.assertEqual(self.values()[0][0], "first")
        self.assertEqual(self.conn.info.transaction_status, TransactionStatus.IDLE)
        return raised.exception

    def test_invalid_numeric_rolls_back_first_row_and_reports_column(self):
        error = self.assert_failed_batch(self.edit(1, "amount", "bad numeric"), "database_error", "22P02")
        self.assertEqual(error.details["column"], "amount")

    def test_constraint_error_rolls_back_first_row(self):
        self.assert_failed_batch(self.edit(1, "amount", "-1"), "database_error", "23514")

    def test_concurrent_update_rolls_back_first_row(self):
        self.other_conn.execute("UPDATE users SET username = 'other' WHERE id = 2")
        error = self.assert_failed_batch(self.edit(1, "username", "mine"), "edit_conflict")
        self.assertIsInstance(error, EditConflict)
        self.assertEqual(self.values()[1][0], "other")

    def test_deleted_row_rolls_back_first_row(self):
        self.other_conn.execute("DELETE FROM users WHERE id = 2")
        self.assert_failed_batch(self.edit(1, "username", "mine"), "edit_conflict")
        self.assertEqual(len(self.values()), 1)

    def test_null_and_empty_string_remain_distinct(self):
        result = save_edits(self.conn, self.store, self.table, [self.edit(0, "amount", "ignored", True), self.edit(1, "username", "")])
        self.assertEqual(result["rows"][0]["cells"][2], {"text": "", "is_null": True})
        self.assertEqual(result["rows"][1]["cells"][1], {"text": "", "is_null": False})
        self.assertEqual(self.values(), [("first", None), ("", decimal.Decimal("20"))])

    def test_quoted_names_enum_keys_and_bound_values(self):
        relation = self.relations['Odd" Table']
        self.conn.execute('TRUNCATE "Odd"" Table"')
        self.conn.execute('INSERT INTO "Odd"" Table" VALUES (\'one\', 1, \'two\', \'original\'), (\'one\', 2, \'two\', \'other tenant\')')
        row = self.store.page(self.conn, relation, 0)["rows"][0]
        text = "'); DROP TABLE users; --"
        result = save_edits(self.conn, self.store, relation, [{"handle": row["handle"], "changes": [
            {"column": "Value", "text": "three", "is_null": False},
            {"column": "Text", "text": text, "is_null": False},
        ]}])
        self.assertEqual(result["rows"][0]["cells"][2]["text"], "three")
        self.assertEqual(self.conn.execute('SELECT "Text" FROM "Odd"" Table" ORDER BY tenant').fetchall(), [(text,), ("other tenant",)])
        self.assertEqual(len(self.values()), 2)

    def test_quoted_schema(self):
        name = self.schema + '" odd'
        self.conn.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(name)))
        try:
            self.conn.execute(sql.SQL("CREATE TABLE {} (id int PRIMARY KEY, value text)").format(sql.Identifier(name, "table")))
            self.conn.execute(sql.SQL("INSERT INTO {} VALUES (1, 'old')").format(sql.Identifier(name, "table")))
            relation = next(s for s in load_catalog(self.conn)["schemas"] if s["name"] == name)["relations"][0]
            row = self.store.page(self.conn, relation, 0)["rows"][0]
            result = save_edits(self.conn, self.store, relation, [{"handle": row["handle"], "changes": [{"column": "value", "text": "new", "is_null": False}]}])
            self.assertEqual(result["rows"][0]["cells"][1]["text"], "new")
        finally:
            self.conn.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(name)))

    def test_read_only_columns_and_relations_rejected(self):
        for column in ("id", "doubled", "tags", "unknown"):
            with self.subTest(column=column), self.assertRaises(ProtocolError):
                save_edits(self.conn, self.store, self.table, [self.edit(0, column, "42")])
        for name in ("keyless", "user_view"):
            relation = self.relations[name]
            self.store.page(self.conn, relation, 0)
            with self.subTest(relation=name), self.assertRaises(ProtocolError):
                save_edits(self.conn, self.store, relation, [self.edit(0, "username", "changed")])
        self.assertEqual(self.values()[0][0], "first")

    def test_supplied_metadata_cannot_override_stored_editability(self):
        forged = copy.deepcopy(self.table)
        forged["columns"][0]["editable"] = True
        with self.assertRaises(ProtocolError):
            save_edits(self.conn, self.store, forged, [self.edit(0, "id", "42")])
        self.assertEqual(self.values()[0][0], "first")

    def test_active_user_transaction_is_rejected_without_consuming_it(self):
        self.conn.execute("BEGIN")
        try:
            with self.assertRaises(ProtocolError):
                save_edits(self.conn, self.store, self.table, [self.edit(0, "username", "changed")])
            self.assertEqual(self.conn.info.transaction_status, TransactionStatus.INTRANS)
            self.assertEqual(self.values()[0][0], "first")
        finally:
            self.conn.execute("ROLLBACK")

    def test_session_dispatches_save_and_reports_database_errors(self):
        session = Session()
        try:
            session.handle("connect", {"conninfo": self.conn.info.dsn})
            params = {"schema": self.schema, "table": "users"}
            self.rows = session.handle("table.page", params)["rows"]
            result = session.handle("table.save", {**params, "edits": [self.edit(0, "username", "saved")]})
            self.assertEqual(result["rows"][0]["cells"][1]["text"], "saved")
            with self.assertRaises(ProtocolError) as raised:
                session.handle("table.save", {**params, "edits": [self.edit(1, "amount", "invalid")]})
            self.assertEqual(raised.exception.details["sqlstate"], "22P02")
            self.assertNotIn("host=", str(raised.exception))
        finally:
            session.close()

    def test_deferred_constraint_failure_preserves_originals(self):
        self.conn.execute("CREATE TABLE deferred_unique (id int PRIMARY KEY, value text UNIQUE DEFERRABLE INITIALLY DEFERRED)")
        try:
            self.conn.execute("INSERT INTO deferred_unique VALUES (1, 'first'), (2, 'second')")
            relation = next(r for s in load_catalog(self.conn)["schemas"] if s["name"] == self.schema
                            for r in s["relations"] if r["name"] == "deferred_unique")
            rows = self.store.page(self.conn, relation, 0)["rows"]
            originals = copy.deepcopy(self.store.handles)
            with self.assertRaises(ProtocolError) as raised:
                save_edits(self.conn, self.store, relation, [{"handle": row["handle"], "changes": [
                    {"column": "value", "text": "duplicate", "is_null": False},
                ]} for row in rows])
            self.assertEqual(raised.exception.details["sqlstate"], "23505")
            self.assertIsNone(raised.exception.details["handle"])
            self.assertEqual(self.store.handles, originals)
            self.assertEqual(self.other_conn.execute("SELECT value FROM deferred_unique ORDER BY id").fetchall(), [("first",), ("second",)])
        finally:
            self.conn.execute("DROP TABLE deferred_unique")

    def test_multiple_matching_inherited_rows_are_an_internal_error(self):
        self.conn.execute("CREATE TABLE parent (id int PRIMARY KEY, value text)")
        try:
            self.conn.execute("CREATE TABLE child () INHERITS (parent)")
            with self.conn.transaction():
                self.conn.execute("INSERT INTO parent VALUES (1, 'parent')")
                self.conn.execute("INSERT INTO child VALUES (1, 'child')")
            relation = next(r for s in load_catalog(self.conn)["schemas"] if s["name"] == self.schema
                            for r in s["relations"] if r["name"] == "parent")
            row = self.store.page(self.conn, relation, 0)["rows"][0]
            originals = copy.deepcopy(self.store.handles)
            with self.assertRaises(ProtocolError) as raised:
                save_edits(self.conn, self.store, relation, [{"handle": row["handle"], "changes": [
                    {"column": "value", "text": "changed", "is_null": False},
                ]}])
            self.assertEqual(raised.exception.code, "internal_error")
            self.assertEqual(self.store.handles, originals)
            self.assertEqual(self.other_conn.execute("SELECT value FROM parent ORDER BY value").fetchall(), [("child",), ("parent",)])
        finally:
            self.conn.execute("DROP TABLE parent CASCADE")

    def test_jsonb_primary_key_is_bound_as_json(self):
        self.conn.execute("CREATE TABLE json_key (id jsonb PRIMARY KEY, value text)")
        try:
            self.conn.execute('INSERT INTO json_key VALUES (\'{"tenant": 1}\', \'old\')')
            relation = next(r for s in load_catalog(self.conn)["schemas"] if s["name"] == self.schema
                            for r in s["relations"] if r["name"] == "json_key")
            row = self.store.page(self.conn, relation, 0)["rows"][0]
            result = save_edits(self.conn, self.store, relation, [{"handle": row["handle"], "changes": [
                {"column": "value", "text": "new", "is_null": False},
            ]}])
            self.assertEqual(result["rows"][0]["cells"][1]["text"], "new")
            self.assertEqual(self.other_conn.execute("SELECT value FROM json_key").fetchone(), ("new",))
        finally:
            self.conn.execute("DROP TABLE json_key")

    def test_jsonb_domain_and_domain_chain_primary_keys(self):
        self.conn.execute("CREATE DOMAIN json_key_domain AS jsonb CHECK (jsonb_typeof(VALUE) = 'object')")
        self.conn.execute("CREATE DOMAIN json_key_chain AS json_key_domain")
        try:
            for type_name in ("json_key_domain", "json_key_chain"):
                with self.subTest(type_name=type_name):
                    self.conn.execute(sql.SQL("CREATE TABLE domain_key (id {} PRIMARY KEY, value text)").format(sql.Identifier(type_name)))
                    try:
                        self.conn.execute('INSERT INTO domain_key VALUES (\'{"tenant": 1}\', \'old\')')
                        relation = next(r for s in load_catalog(self.conn)["schemas"] if s["name"] == self.schema
                                        for r in s["relations"] if r["name"] == "domain_key")
                        row = self.store.page(self.conn, relation, 0)["rows"][0]
                        self.assertEqual(self.store.handles[row["handle"]].key, ({"tenant": 1},))
                        result = save_edits(self.conn, self.store, relation, [{"handle": row["handle"], "changes": [
                            {"column": "value", "text": "new", "is_null": False},
                        ]}])
                        self.assertEqual(result["rows"][0]["cells"][1]["text"], "new")
                        self.assertEqual(self.other_conn.execute("SELECT value FROM domain_key").fetchone(), ("new",))
                        column = relation["columns"][0]
                        self.assertEqual((column["type_schema"], column["type_name"]), (self.schema, type_name))
                        self.assertEqual((column["base_type_schema"], column["base_type_name"]), ("pg_catalog", "jsonb"))
                        # Existing rows survive NOT VALID; casting the old key must still check the domain.
                        self.conn.execute(sql.SQL("ALTER DOMAIN {} ADD CONSTRAINT reject_old_key CHECK (VALUE <> '{{\"tenant\": 1}}'::jsonb) NOT VALID").format(sql.Identifier(type_name)))
                        try:
                            with self.assertRaises(ProtocolError) as raised:
                                save_edits(self.conn, self.store, relation, [{"handle": row["handle"], "changes": [
                                    {"column": "value", "text": "must not save", "is_null": False},
                                ]}])
                            self.assertEqual(raised.exception.details["sqlstate"], "23514")
                            self.assertEqual(self.other_conn.execute("SELECT value FROM domain_key").fetchone(), ("new",))
                        finally:
                            self.conn.execute(sql.SQL("ALTER DOMAIN {} DROP CONSTRAINT reject_old_key").format(sql.Identifier(type_name)))
                    finally:
                        self.conn.execute("DROP TABLE domain_key")
        finally:
            self.conn.execute("DROP DOMAIN json_key_domain CASCADE")
