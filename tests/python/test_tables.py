"""Table page request validation without a database connection."""

import unittest

from better_sql.protocol import ProtocolError
from better_sql.session import Session


class TablePageSessionTests(unittest.TestCase):
    def test_page_requires_connection(self):
        with self.assertRaises(ProtocolError) as raised:
            Session().handle("table.page", {"schema": "public", "table": "users", "offset": 0})
        self.assertEqual(raised.exception.code, "not_connected")


if __name__ == "__main__":
    unittest.main()
