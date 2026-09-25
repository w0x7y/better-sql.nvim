import contextlib
import io
import json
import pathlib
import subprocess
import sys
import unittest

from better_sql.protocol import ProtocolError, encode_error, serve


class ProtocolTests(unittest.TestCase):
    def test_one_request_one_response(self):
        source = io.StringIO('{"id":7,"method":"ping","params":{}}\n')
        sink = io.StringIO()

        serve(source, sink, lambda method, params: {"pong": method == "ping"})

        self.assertEqual(json.loads(sink.getvalue()), {
            "id": 7, "ok": True, "result": {"pong": True}
        })
        self.assertEqual(sink.getvalue().count("\n"), 1)

    def test_malformed_json_has_one_error_line(self):
        self.assert_error_response('{broken\n', None, "invalid_json")

    def test_missing_method_has_one_error_line(self):
        self.assert_error_response('{"id":8,"params":{}}\n', 8, "invalid_request")

    def test_handler_exception_has_one_error_line(self):
        def fail(method, params):
            raise ValueError("handler failed")

        self.assert_error_response(
            '{"id":9,"method":"explode","params":{}}\n',
            9,
            "internal_error",
            handler=fail,
        )

    def test_protocol_error_keeps_its_code_and_message(self):
        self.assertEqual(
            encode_error(ProtocolError("unknown_method", "nope")),
            {"code": "unknown_method", "message": "nope"},
        )

    def test_entry_point_handles_ping_and_unknown_method(self):
        helper = pathlib.Path(__file__).resolve().parents[2] / "python" / "better_sql_helper.py"
        replies = []
        with subprocess.Popen(
            [sys.executable, "-u", str(helper)], stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        ) as process:
            for request in ({"id": 1, "method": "ping"}, {"id": 2, "method": "missing"}):
                process.stdin.write(json.dumps(request) + "\n")
                process.stdin.flush()
                replies.append(json.loads(process.stdout.readline()))
            process.stdin.close()
            process.wait(timeout=3)
            self.assertEqual(process.stderr.read(), "")
        self.assertEqual(replies, [
            {"id": 1, "ok": True, "result": {"pong": True}},
            {"id": 2, "ok": False,
             "error": {"code": "unknown_method", "message": "unknown helper method"}},
        ])

    def assert_error_response(self, request, request_id, code, handler=None):
        sink = io.StringIO()
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            serve(io.StringIO(request), sink, handler or (lambda method, params: {}))

        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(sink.getvalue().count("\n"), 1)
        response = json.loads(sink.getvalue())
        self.assertEqual(response["id"], request_id)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], code)
        self.assertIsInstance(response["error"]["message"], str)
        self.assertNotIn("result", response)


if __name__ == "__main__":
    unittest.main()
