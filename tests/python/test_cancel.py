import io
import json
import threading
import unittest
from unittest.mock import patch

import psycopg

from better_sql.protocol import ProtocolError, encode_error, serve
from better_sql.session import Session


class CancelTests(unittest.TestCase):
    def test_reader_handles_cancel_and_busy_while_worker_runs(self):
        entered = threading.Event()
        released = threading.Event()
        session = Session()

        def handle(method, params):
            if method == "query.run":
                entered.set()
                self.assertTrue(released.wait(2), "reader blocked behind query")
            return {"done": True}

        def cancel(target):
            self.assertEqual(target, 1)
            released.set()
            return {"cancel_requested": True}

        def requests():
            yield '{"id":1,"method":"query.run"}\n'
            self.assertTrue(entered.wait(1))
            yield '{"id":2,"method":"ping"}\n'
            yield '{"id":3,"method":"query.cancel","params":{"target_id":1}}\n'

        sink = io.StringIO()
        with patch.object(session, "cancel", side_effect=cancel):
            serve(requests(), sink, handle, session=session)
        replies = {reply["id"]: reply for reply in map(json.loads, sink.getvalue().splitlines())}
        self.assertEqual(replies[2]["error"]["code"], "busy")
        self.assertTrue(replies[3]["result"]["cancel_requested"])
        self.assertTrue(replies[1]["ok"])

    def test_cancel_targets_only_active_request_and_supports_old_psycopg(self):
        session = Session()
        calls = []
        class Connection:
            closed = False
            def cancel(self): calls.append("cancel")
        session.conn = Connection()
        session.active_request_id = 7
        self.assertEqual(session.cancel(8), {"cancel_requested": False})
        self.assertEqual(session.cancel(7), {"cancel_requested": True})
        self.assertEqual(calls, ["cancel"])

    def test_unknown_exception_does_not_echo_credentials(self):
        error = encode_error(ValueError("password=super-secret host=private"))
        self.assertNotIn("super-secret", json.dumps(error))
        self.assertNotIn("host=private", json.dumps(error))

    def test_known_password_and_conninfo_redacted_in_database_errors(self):
        session = Session()
        dsn = "host=localhost password='secret with spaces'"
        with patch("better_sql.session.psycopg.connect", side_effect=psycopg.OperationalError("failed")):
            with self.assertRaises(ProtocolError):
                session.handle("connect", {"conninfo": dsn})
        message = session.redact("rejected secret with spaces; connection " + dsn)
        self.assertNotIn("secret with spaces", message)
        self.assertNotIn("host=localhost", message)

    def test_cancel_prefers_cancel_safe(self):
        session = Session()
        calls = []
        class Connection:
            closed = False
            def cancel_safe(self): calls.append("safe")
            def cancel(self): raise AssertionError("old cancel used")
        session.conn = Connection()
        session.active_request_id = 1
        self.assertTrue(session.cancel(1)["cancel_requested"])
        self.assertEqual(calls, ["safe"])

    def test_direct_session_errors_redact_password_in_exception_text(self):
        session = Session()
        session._secrets.add("private-secret")
        with patch.object(session, "_handle", side_effect=ProtocolError("database_error", "invalid private-secret")):
            with self.assertRaises(ProtocolError) as caught:
                session.handle("query.run", {"sql": "select 1"})
        self.assertNotIn("private-secret", str(caught.exception))

    def test_cancel_with_broken_connection_recovers_before_next_request(self):
        session = Session()
        session._conninfo = "dbname=test"
        class Connection:
            closed = True
            broken = True
            def rollback(self): raise psycopg.OperationalError("connection lost")
        session.conn = Connection()
        with patch.object(session, "_handle", side_effect=ProtocolError("database_error", "cancelled", sqlstate="57014")):
            with self.assertRaises(ProtocolError) as caught:
                session.handle("query.run", {"sql": "select pg_sleep(10)"})
        self.assertEqual(caught.exception.code, "cancelled")
        calls = []
        def dispatch(method, params):
            calls.append(method)
            return {"done": True}
        with patch.object(session, "_handle", side_effect=dispatch):
            self.assertEqual(session.handle("query.run", {"sql": "select 1"}), {"done": True})
        self.assertEqual(calls, ["connect", "query.run"])

    def test_redaction_preserves_error_codes_and_sqlstate(self):
        session = Session()
        session._secrets.update({"e", "7"})
        sink = io.StringIO()
        def fail(method, params):
            raise ProtocolError("database_error", "e secret", sqlstate="57014")
        serve(io.StringIO('{"id":1,"method":"query.run"}\n'), sink, fail, session=session)
        error = json.loads(sink.getvalue())["error"]
        self.assertEqual(error["code"], "database_error")
        self.assertEqual(error["sqlstate"], "57014")
