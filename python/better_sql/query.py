"""Execute SQL and turn PostgreSQL results into bounded display data."""

import json


def cell(value):
    if value is None:
        return {"text": "", "is_null": True}
    if isinstance(value, (dict, list)):
        return {"text": json.dumps(value, ensure_ascii=False, default=lambda item: cell(item)["text"]), "is_null": False}
    if isinstance(value, bytes):
        return {"text": "\\x" + value.hex(), "is_null": False}
    return {"text": str(value), "is_null": False}


def read_result_set(cursor, rows_left, bytes_left, cell_encoder):
    description = cursor.description
    columns = [] if description is None else [
        {"name": column.name, "type_oid": column.type_code}
        if hasattr(column, "name") else {"name": column[0], "type_oid": column[1]}
        for column in description
    ]
    result = {
        "columns": columns,
        "rows": [],
        "status": cursor.statusmessage or "",
        "truncated": False,
    }
    if description is None:
        return result, 0, 0

    used_bytes = 0
    while batch := cursor.fetchmany(1):
        if len(result["rows"]) >= rows_left:
            result["truncated"] = True
            break
        row = [cell_encoder(value) for value in batch[0]]
        row_bytes = len(json.dumps(row, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))
        if used_bytes + row_bytes > bytes_left:
            result["truncated"] = True
            break
        result["rows"].append(row)
        used_bytes += row_bytes
    return result, len(result["rows"]), used_bytes


def run_query(conn, sql_text, max_rows=1000, max_bytes=4194304):
    with conn.cursor() as cursor:
        cursor.execute(sql_text)
        sets = []
        rows_left, bytes_left = max_rows, max_bytes
        while True:
            result, used_rows, used_bytes = read_result_set(cursor, rows_left, bytes_left, cell)
            sets.append(result)
            rows_left -= used_rows
            bytes_left -= used_bytes
            if result["truncated"] or not cursor.nextset():
                return {"sets": sets}
