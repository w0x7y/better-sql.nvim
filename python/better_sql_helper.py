"""Standard input and output bridge for the editor client."""

import sys

from better_sql.protocol import serve
from better_sql.session import Session


if __name__ == "__main__":
    session = Session()
    try:
        serve(sys.stdin, sys.stdout, session.handle)
    finally:
        session.close()
