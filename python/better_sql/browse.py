"""Compose validated table filters and ordering with bound values."""

from psycopg import sql

from better_sql.protocol import ProtocolError


COMPARISONS = {"=", "!=", ">", ">=", "<", "<="}
NULL_CHECKS = {"is_null": "IS NULL", "not_null": "IS NOT NULL"}


def browse_clauses(relation, filters, sort):
    columns = {column["name"]: column for column in relation["columns"]}

    def column_for(name):
        if not isinstance(name, str) or name not in columns:
            raise ProtocolError("invalid_request", "filter and sort columns must belong to the relation")
        return columns[name]

    if filters is None:
        filters = []
    if not isinstance(filters, list):
        raise ProtocolError("invalid_request", "filters must be an array")
    conditions, values = [], []
    for condition in filters:
        if not isinstance(condition, dict):
            raise ProtocolError("invalid_request", "each filter must be an object")
        column = column_for(condition.get("column"))
        identifier = sql.Identifier(column["name"])
        operator = condition.get("operator")
        if not isinstance(operator, str) or operator not in COMPARISONS | NULL_CHECKS.keys() | {"contains"}:
            raise ProtocolError("invalid_request", "unsupported filter operator")
        if operator in NULL_CHECKS:
            conditions.append(sql.SQL("{} {}").format(identifier, sql.SQL(NULL_CHECKS[operator])))
            continue
        value = condition.get("value")
        if not isinstance(value, str):
            raise ProtocolError("invalid_request", "filter values must be strings")
        if operator == "contains":
            # Search literal text: percent, underscore and backslash are not wildcards.
            value = value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            conditions.append(sql.SQL("{}::text ILIKE %s ESCAPE E'\\\\'").format(identifier))
            values.append("%" + value + "%")
        else:
            type_id = sql.Identifier(column["type_schema"], column["type_name"])
            conditions.append(sql.SQL("{} {} CAST(%s AS {})").format(identifier, sql.SQL(operator), type_id))
            values.append(value)

    ordering = []
    sort_column = None
    if sort is not None:
        if not isinstance(sort, dict):
            raise ProtocolError("invalid_request", "sort must be an object")
        sort_column = column_for(sort.get("column"))["name"]
        direction = sort.get("direction")
        if not isinstance(direction, str) or direction not in {"asc", "desc"}:
            raise ProtocolError("invalid_request", "sort direction must be asc or desc")
        ordering.append(sql.SQL("{} {} NULLS LAST").format(
            sql.Identifier(sort_column), sql.SQL(direction.upper()),
        ))
    ordering.extend(sql.Identifier(name) for name in relation["primary_key"] if name != sort_column)
    where = sql.SQL(" WHERE ") + sql.SQL(" AND ").join(conditions) if conditions else sql.SQL("")
    order = sql.SQL(" ORDER BY ") + sql.SQL(", ").join(ordering) if ordering else sql.SQL("")
    return where, order, values
