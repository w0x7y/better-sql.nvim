import io
import json
import unittest

from better_sql.query import cell, read_result_set
from better_sql.session import Session
from better_sql.protocol import serve


class Cursor:
    def __init__(self, rows, description, statusmessage="SELECT 2"):
        self.rows = iter(rows)
        self.description = description
        self.statusmessage = statusmessage

    def fetchmany(self, size=1):
        rows = []
        for _ in range(size):
            try:
                rows.append(next(self.rows))
            except StopIteration:
                break
        return rows


class QueryTests(unittest.TestCase):
    def test_cell_preserves_null_empty_json_and_bytes(self):
        self.assertEqual(cell(None), {"text": "", "is_null": True})
        self.assertEqual(cell(""), {"text": "", "is_null": False})
        self.assertEqual(cell({"é": [1]}), {"text": '{"é": [1]}', "is_null": False})
        self.assertEqual(cell(b"\x00\xff"), {"text": "\\x00ff", "is_null": False})

    def test_command_has_status_and_consumes_no_rows(self):
        result, rows, size = read_result_set(Cursor([], None, "CREATE TABLE"), 5, 1000, cell)
        self.assertEqual(result, {"columns": [], "rows": [], "status": "CREATE TABLE", "truncated": False})
        self.assertEqual((rows, size), (0, 0))

    def test_row_cap_detects_another_row(self):
        cursor = Cursor([(1,), (2,), (3,)], [("n", 23)])
        result, rows, size = read_result_set(cursor, 2, 1000, cell)
        self.assertEqual([row[0]["text"] for row in result["rows"]], ["1", "2"])
        self.assertTrue(result["truncated"])
        self.assertEqual(rows, 2)
        self.assertGreater(size, 0)

    def test_exact_row_cap_is_not_truncated(self):
        result, rows, _ = read_result_set(Cursor([(1,)], [("n", 23)]), 1, 1000, cell)
        self.assertEqual(rows, 1)
        self.assertFalse(result["truncated"])

    def test_byte_cap_does_not_return_partial_row(self):
        row = [cell("é")]
        row_bytes = len(json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        result, rows, size = read_result_set(Cursor([("é",), ("hello",)], [("v", 25)]), 10, row_bytes, cell)
        self.assertEqual(result["rows"], [row])
        self.assertTrue(result["truncated"])
        self.assertEqual((rows, size), (1, row_bytes))

    def test_unknown_method_and_ping_remain_operational(self):
        sink = io.StringIO()
        serve(io.StringIO('{"id":1,"method":"ping"}\n{"id":2,"method":"missing"}\n'), sink, Session().handle)
        responses = [json.loads(line) for line in sink.getvalue().splitlines()]
        self.assertEqual(responses[0]["result"], {"pong": True})
        self.assertEqual(responses[1]["error"]["code"], "unknown_method")


if __name__ == "__main__":
    unittest.main()
