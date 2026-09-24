"""Isolated PostgreSQL fixture for integration tests."""

import os
import unittest
import uuid

import psycopg
from psycopg import sql


class DatabaseTestCase(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        dsn = os.environ.get("BETTER_SQL_TEST_DSN")
        if not dsn:
            raise unittest.SkipTest("BETTER_SQL_TEST_DSN is not set")
        cls.conn = psycopg.connect(dsn, autocommit=True)
        cls.other_conn = psycopg.connect(dsn, autocommit=True)
        cls.schema = "better_sql_test_" + uuid.uuid4().hex
        cls.conn.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(cls.schema)))
        for conn in (cls.conn, cls.other_conn):
            conn.execute(sql.SQL("SET search_path TO {}").format(sql.Identifier(cls.schema)))

    @classmethod
    def tearDownClass(cls):
        try:
            cls.conn.execute(sql.SQL("DROP SCHEMA {} CASCADE").format(sql.Identifier(cls.schema)))
        finally:
            cls.other_conn.close()
            cls.conn.close()
