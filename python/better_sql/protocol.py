"""Newline-delimited JSON request and response framing."""

import json
import threading


class ProtocolError(Exception):
    def __init__(self, code: str, message: str, **details):
        super().__init__(message)
        self.code = code
        self.message = message
        self.details = details


def encode_error(exc: Exception) -> dict:
    if isinstance(exc, ProtocolError):
        return {"code": exc.code, "message": exc.message, **exc.details}
    if isinstance(exc, json.JSONDecodeError):
        return {"code": "invalid_json", "message": str(exc)}
    return {"code": "internal_error", "message": "helper failed while processing the request"}


def reply(writer, request_id, result=None, error=None):
    message = {"id": request_id, "ok": error is None}
    message["result" if error is None else "error"] = result if error is None else error
    writer.write(json.dumps(message, ensure_ascii=False) + "\n")
    writer.flush()


def serve(reader, writer, handler, *, session=None) -> None:
    """Keep stdin available while a single worker owns the database connection.

    The session lock covers request identity and cancellation delivery, so a late
    cancellation cannot spill into the next database operation.
    """
    state_lock = session.request_lock if session else threading.RLock()
    write_lock = threading.Lock()
    active = False
    worker = None

    def respond(request_id, result=None, error=None):
        if error is not None and session:
            error = {**error, "message": session.redact(error["message"])}
        with write_lock:
            reply(writer, request_id, result, error)

    def execute(request_id, method, params):
        nonlocal active
        result, error = None, None
        try:
            result = handler(method, params)
        except Exception as exc:
            error = encode_error(exc)
        finally:
            with state_lock:
                active = False
                if session:
                    session.active_request_id = None
                respond(request_id, result=result, error=error)

    try:
        for line in reader:
            request_id = None
            try:
                request = json.loads(line)
                if not isinstance(request, dict):
                    raise ProtocolError("invalid_request", "request must be an object")
                request_id = request.get("id")
                method = request.get("method")
                if not isinstance(method, str) or not method:
                    raise ProtocolError("invalid_request", "method must be a nonempty string")
                params = request.get("params", {})
                if not isinstance(params, dict):
                    raise ProtocolError("invalid_request", "params must be an object")
                with state_lock:
                    if method == "query.cancel" and session:
                        target = params.get("target_id")
                        if type(target) is not int:
                            raise ProtocolError("invalid_request", "target_id must be an integer")
                        respond(request_id, result=session.cancel(target))
                    elif active:
                        raise ProtocolError("busy", "a database request is running; cancel it or wait")
                    else:
                        active = True
                        if session:
                            session.active_request_id = request_id
                        worker = threading.Thread(target=execute, args=(request_id, method, params))
                        worker.start()
            except Exception as exc:
                respond(request_id, error=encode_error(exc))
    finally:
        if worker:
            worker.join()
