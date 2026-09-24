import os
import subprocess
import sys
import json
import pathlib

from better_sql.query import run_query
from support import DatabaseTestCase


class QueryIntegrationTests(DatabaseTestCase):
    def test_null_and_empty_are_distinct(self):
        result = run_query(self.conn, "select null::text as a, ''::text as b", 1000, 4194304)
        cells = result["sets"][0]["rows"][0]
        self.assertEqual(cells, [
            {"text": "", "is_null": True},
            {"text": "", "is_null": False},
        ])

    def test_ddl_status(self):
        result = run_query(self.conn, "create temporary table better_sql_query_test (id int)")
        self.assertEqual(result["sets"][0]["status"], "CREATE TABLE")
        self.assertEqual(result["sets"][0]["rows"], [])

    def test_multiple_result_sets(self):
        result = run_query(self.conn, "select 1 as first; select 2 as second")
        self.assertEqual(len(result["sets"]), 2)
        self.assertEqual(result["sets"][0]["columns"][0]["name"], "first")
        self.assertEqual(result["sets"][1]["rows"][0][0]["text"], "2")

    def test_caps_span_result_sets(self):
        result = run_query(self.conn, "select 1; select 2; select 3", max_rows=1)
        self.assertEqual(len(result["sets"]), 2)
        self.assertEqual(result["sets"][0]["rows"][0][0]["text"], "1")
        self.assertEqual(result["sets"][1]["rows"], [])
        self.assertTrue(result["sets"][1]["truncated"])

    def test_helper_error_has_sqlstate_and_position_without_secret(self):
        helper = pathlib.Path(__file__).resolve().parents[2] / "python" / "better_sql_helper.py"
        dsn = os.environ["BETTER_SQL_TEST_DSN"] + " password=never-print-this-secret"
        requests = [
            {"id": 1, "method": "connect", "params": {"conninfo": dsn}},
            {"id": 2, "method": "query.run", "params": {"sql": "select from", "max_rows": 1000, "max_bytes": 4194304}},
        ]
        process = subprocess.run(
            [sys.executable, str(helper)],
            input="".join(json.dumps(request) + "\n" for request in requests),
            text=True, capture_output=True, check=True,
        )
        self.assertNotIn("never-print-this-secret", process.stdout + process.stderr)
        self.assertEqual(process.stderr, "")
        replies = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertTrue(replies[0]["ok"])
        self.assertEqual(replies[0]["result"], {"database": "postgres", "user": "idan"})
        self.assertEqual(replies[1]["error"]["code"], "database_error")
        self.assertEqual(replies[1]["error"]["sqlstate"], "42601")
        self.assertIsNotNone(replies[1]["error"]["position"])

    def test_failed_connection_does_not_echo_conninfo(self):
        helper = pathlib.Path(__file__).resolve().parents[2] / "python" / "better_sql_helper.py"
        secret = "never-print-this-secret"
        request = {"id": 1, "method": "connect", "params": {
            "conninfo": "port=not-a-number password=" + secret,
        }}
        process = subprocess.run(
            [sys.executable, str(helper)], input=json.dumps(request) + "\n",
            text=True, capture_output=True, check=True,
        )
        self.assertEqual(process.stderr, "")
        self.assertNotIn(secret, process.stdout)
        response = json.loads(process.stdout)
        self.assertEqual(response["error"]["code"], "database_error")
        self.assertEqual(response["error"]["message"], "connection failed")
