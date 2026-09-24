import json
import os
import pathlib
import queue
import subprocess
import sys
import threading
import time
import unittest

import psycopg


@unittest.skipUnless(os.environ.get("BETTER_SQL_TEST_DSN"), "BETTER_SQL_TEST_DSN is not set")
class CancelIntegrationTests(unittest.TestCase):
    def setUp(self):
        helper = pathlib.Path(__file__).resolve().parents[2] / "python/better_sql_helper.py"
        self.process = subprocess.Popen([sys.executable, "-u", str(helper)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.close_helper)
        self.replies = queue.Queue()
        self.output = []
        def read():
            for line in self.process.stdout:
                self.output.append(line)
                self.replies.put(json.loads(line))
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        self.dsn = os.environ["BETTER_SQL_TEST_DSN"] + " password='cancel secret 13'"
        self.send(1, "connect", {"conninfo": self.dsn})
        self.assertTrue(self.receive()["ok"])
        self.send(2, "query.run", {"sql": "select pg_backend_pid()"})
        self.pid = int(self.receive()["result"]["sets"][0]["rows"][0][0]["text"])

    def close_helper(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=3)
        self.reader.join(timeout=3)
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()

    def send(self, ident, method, params):
        self.process.stdin.write(json.dumps({"id": ident, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()

    def receive(self):
        try:
            return self.replies.get(timeout=3)
        except queue.Empty:
            self.fail("helper failed to respond while SQL was running")

    def wait_sleep(self):
        with psycopg.connect(self.dsn, autocommit=True) as observer:
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                row = observer.execute("select wait_event from pg_stat_activity where pid=%s", (self.pid,)).fetchone()
                if row and row[0] == "PgSleep": return
                time.sleep(.01)
        self.fail("query did not reach pg_sleep")

    def test_cancel_keeps_session_usable_and_rejects_other_work(self):
        self.send(3, "query.run", {"sql": "select pg_sleep(10)"})
        self.wait_sleep()
        self.send(4, "query.run", {"sql": "select 2"})
        self.assertEqual(self.receive()["error"]["code"], "busy")
        self.send(5, "query.cancel", {"target_id": 999})
        self.assertFalse(self.receive()["result"]["cancel_requested"])
        self.send(6, "query.cancel", {"target_id": 3})
        replies = {r["id"]: r for r in [self.receive(), self.receive()]}
        self.assertTrue(replies[6]["result"]["cancel_requested"])
        self.assertEqual(replies[3]["error"]["code"], "cancelled")
        self.assertEqual(replies[3]["error"]["sqlstate"], "57014")
        self.send(7, "query.run", {"sql": "select 1, pg_backend_pid()"})
        cells = self.receive()["result"]["sets"][0]["rows"][0]
        self.assertEqual(cells[0]["text"], "1")
        self.assertEqual(int(cells[1]["text"]), self.pid)

    def test_cancel_in_explicit_transaction_recovers(self):
        self.send(3, "query.run", {"sql": "begin; select pg_sleep(10)"})
        self.wait_sleep()
        self.send(4, "query.cancel", {"target_id": 3})
        replies = {r["id"]: r for r in [self.receive(), self.receive()]}
        self.assertEqual(replies[3]["error"]["sqlstate"], "57014")
        self.send(5, "query.run", {"sql": "select 1"})
        self.assertEqual(self.receive()["result"]["sets"][0]["rows"][0][0]["text"], "1")

    def test_server_error_redacts_configured_password(self):
        self.send(3, "query.run", {"sql": "do $$ begin raise exception 'cancel secret 13'; end $$"})
        self.assertEqual(self.receive()["error"]["sqlstate"], "P0001")
        self.process.stdin.close()
        self.process.wait(timeout=3)
        self.reader.join(timeout=3)
        stderr = self.process.stderr.read()
        self.assertNotIn("cancel secret 13", "".join(self.output) + stderr)
        self.assertEqual(stderr, "")

    def test_broken_connection_reconnects_before_next_query(self):
        with psycopg.connect(self.dsn, autocommit=True) as observer:
            observer.execute("select pg_terminate_backend(%s)", (self.pid,))
        self.send(3, "query.run", {"sql": "select 1"})
        self.assertFalse(self.receive()["ok"])
        self.send(4, "query.run", {"sql": "select 1, pg_backend_pid()"})
        cells = self.receive()["result"]["sets"][0]["rows"][0]
        self.assertEqual(cells[0]["text"], "1")
        self.assertNotEqual(int(cells[1]["text"]), self.pid)

    def test_password_from_environment_is_redacted(self):
        from unittest.mock import patch
        from better_sql.session import Session
        from better_sql.protocol import ProtocolError
        session = Session()
        self.addCleanup(session.close)
        with patch.dict(os.environ, {"PGPASSWORD": "environment password 13"}):
            session.handle("connect", {"conninfo": os.environ["BETTER_SQL_TEST_DSN"]})
        with self.assertRaises(ProtocolError) as caught:
            session.handle("query.run", {"sql": "do $$ begin raise exception 'environment password 13'; end $$"})
        self.assertNotIn("environment password 13", str(caught.exception))
