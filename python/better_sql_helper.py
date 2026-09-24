"""Standard input and output bridge for the editor client."""

import sys

from better_sql.protocol import ProtocolError, serve


def handle(method: str, params: dict) -> dict:
    if method == "ping":
        return {"pong": True}
    raise ProtocolError("unknown_method", method)


if __name__ == "__main__":
    serve(sys.stdin, sys.stdout, handle)
