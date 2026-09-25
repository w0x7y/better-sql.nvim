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
            SELECT t.oid
            FROM pg_catalog.pg_type AS t
            JOIN pg_catalog.pg_namespace AS n ON n.oid = t.typnamespace
            WHERE n.nspname = 'pg_catalog' AND t.typname = ANY(%s)
              AND t.typtype = 'b'
        """, (list(SUPPORTED_TYPE_NAMES),))
        allowed_oids = {row[0] for row in cursor.fetchall()}

        cursor.execute("""
            SELECT n.oid, n.nspname
            FROM pg_catalog.pg_namespace AS n
            WHERE n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
            ORDER BY n.nspname
        """)
        schemas = [{"name": name, "relations": []} for _, name in cursor.fetchall()]
        schemas_by_name = {schema["name"]: schema for schema in schemas}

        cursor.execute("""
            SELECT c.oid, n.nspname, c.relname, c.relkind
            FROM pg_catalog.pg_class AS c
            JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
            WHERE c.relkind IN ('r', 'p', 'v')
              AND n.nspname <> 'information_schema' AND n.nspname !~ '^pg_'
            ORDER BY n.nspname, c.relname
        """)
        relations_by_oid = {}
        for oid, schema_name, name, kind in cursor.fetchall():
            relation = {
                "schema": schema_name, "name": name, "kind": kind,
                "primary_key": [], "columns": [],
            }
            schemas_by_name[schema_name]["relations"].append(relation)
            relations_by_oid[oid] = relation

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
        cursor.execute(f"""
            WITH RECURSIVE type_bases AS (
                SELECT oid, oid AS base_oid
                FROM pg_catalog.pg_type
                WHERE typbasetype = 0
                UNION ALL
                SELECT domain.oid, base.base_oid
                FROM pg_catalog.pg_type AS domain
                JOIN type_bases AS base ON base.oid = domain.typbasetype
            )
            SELECT a.attrelid, a.attname, t.oid, tn.nspname, t.typname,
                   pg_catalog.format_type(a.atttypid, a.atttypmod),
                   t.typtype, {generated_expression}, bn.nspname, bt.typname
            FROM pg_catalog.pg_attribute AS a
            JOIN pg_catalog.pg_type AS t ON t.oid = a.atttypid
            JOIN pg_catalog.pg_namespace AS tn ON tn.oid = t.typnamespace
            JOIN type_bases AS base ON base.oid = t.oid
            JOIN pg_catalog.pg_type AS bt ON bt.oid = base.base_oid
            JOIN pg_catalog.pg_namespace AS bn ON bn.oid = bt.typnamespace
            WHERE a.attrelid = ANY(%s) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attrelid, a.attnum
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
    return {"schemas": schemas}
