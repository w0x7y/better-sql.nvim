"""Read PostgreSQL relation metadata for browsing and completion."""

SUPPORTED_TYPE_NAMES = (
    "text", "varchar", "bpchar", "int2", "int4", "int8", "numeric",
    "float4", "float8", "bool", "uuid", "date", "time", "timetz",
    "timestamp", "timestamptz", "json", "jsonb",
)


def column_editability(kind, primary_key, name, type_oid, typtype, generated, allowed_oids):
    """Return whether a table cell can be edited, with a stable reason if not."""
    if kind == "v":
        return False, "view"
    if kind not in ("r", "p") or not primary_key:
        return False, "no_primary_key"
    if name in primary_key:
        return False, "primary_key"
    if generated:
        return False, "generated"
    if type_oid not in allowed_oids and typtype != "e":
        return False, "unsupported_type"
    return True, None


def load_catalog(conn):
    """Return all non-system schemas with ordered relations and columns."""
    with conn.cursor() as cursor:
        cursor.execute("""
            SELECT n.nspname
            FROM pg_catalog.pg_namespace AS n
            WHERE n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
            ORDER BY n.nspname
        """)
        schemas = [{"name": name, "relations": []} for (name,) in cursor.fetchall()]
        schemas_by_name = {schema["name"]: schema for schema in schemas}
        for relation in _load_relations(conn, cursor):
            schemas_by_name[relation["schema"]]["relations"].append(relation)
    return {"schemas": schemas}


def load_relation(conn, schema, name):
    """Return one non-system relation with its columns, or None."""
    with conn.cursor() as cursor:
        found = _load_relations(conn, cursor, "AND n.nspname = %s AND c.relname = %s", (schema, name))
    return found[0] if found else None


def _load_relations(conn, cursor, where="", params=None):
    cursor.execute("""
        SELECT t.oid
        FROM pg_catalog.pg_type AS t
        JOIN pg_catalog.pg_namespace AS n ON n.oid = t.typnamespace
        WHERE n.nspname = 'pg_catalog' AND t.typname = ANY(%s)
          AND t.typtype = 'b'
    """, (list(SUPPORTED_TYPE_NAMES),))
    allowed_oids = {row[0] for row in cursor.fetchall()}

    cursor.execute(f"""
        SELECT c.oid, n.nspname, c.relname, c.relkind
        FROM pg_catalog.pg_class AS c
        JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('r', 'p', 'v')
          AND n.nspname <> 'information_schema' AND n.nspname !~ '^pg_' {where}
        ORDER BY n.nspname, c.relname
    """, params)
    relations_by_oid = {
        oid: {"schema": schema_name, "name": name, "kind": kind, "primary_key": [], "columns": []}
        for oid, schema_name, name, kind in cursor.fetchall()
    }

    cursor.execute("""
        SELECT con.conrelid, a.attname
        FROM pg_catalog.pg_constraint AS con
        JOIN LATERAL unnest(con.conkey) WITH ORDINALITY AS key(attnum, position)
          ON true
        JOIN pg_catalog.pg_attribute AS a
          ON a.attrelid = con.conrelid AND a.attnum = key.attnum
        WHERE con.contype = 'p' AND con.conrelid = ANY(%s)
        ORDER BY con.conrelid, key.position
    """, (list(relations_by_oid),))
    for oid, name in cursor.fetchall():
        relations_by_oid[oid]["primary_key"].append(name)

    generated_expression = "a.attgenerated <> ''" if conn.info.server_version >= 120000 else "false"
    # Seed base-type resolution from the column types only: a CTE over all of
    # pg_type gets a huge row estimate and a plan ~20x slower on large schemas.
    cursor.execute(f"""
        WITH RECURSIVE columns AS (
            SELECT a.attrelid, a.attnum, a.attname, a.atttypid, a.atttypmod,
                   {generated_expression} AS generated
            FROM pg_catalog.pg_attribute AS a
            WHERE a.attrelid = ANY(%s) AND a.attnum > 0 AND NOT a.attisdropped
        ), type_bases AS (
            SELECT t.oid, t.oid AS base_oid, t.typbasetype
            FROM pg_catalog.pg_type AS t
            WHERE t.oid IN (SELECT atttypid FROM columns)
            UNION ALL
            SELECT base.oid, parent.oid, parent.typbasetype
            FROM type_bases AS base
            JOIN pg_catalog.pg_type AS parent ON parent.oid = base.typbasetype
        )
        SELECT c.attrelid, c.attname, t.oid, tn.nspname, t.typname,
               pg_catalog.format_type(c.atttypid, c.atttypmod),
               t.typtype, c.generated, bn.nspname, bt.typname
        FROM columns AS c
        JOIN pg_catalog.pg_type AS t ON t.oid = c.atttypid
        JOIN pg_catalog.pg_namespace AS tn ON tn.oid = t.typnamespace
        JOIN type_bases AS base ON base.oid = t.oid AND base.typbasetype = 0
        JOIN pg_catalog.pg_type AS bt ON bt.oid = base.base_oid
        JOIN pg_catalog.pg_namespace AS bn ON bn.oid = bt.typnamespace
        ORDER BY c.attrelid, c.attnum
    """, (list(relations_by_oid),))
    for oid, name, type_oid, type_schema, type_name, type_label, typtype, generated, base_schema, base_name in cursor.fetchall():
        relation = relations_by_oid[oid]
        editable, reason = column_editability(
            relation["kind"], relation["primary_key"], name,
            type_oid, typtype, generated, allowed_oids,
        )
        relation["columns"].append({
            "name": name, "type_schema": type_schema, "type_name": type_name,
            "base_type_schema": base_schema, "base_type_name": base_name,
            "type_label": type_label, "editable": editable,
            "read_only_reason": reason,
        })
    return list(relations_by_oid.values())
