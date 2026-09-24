"""Newline-delimited JSON request and response framing."""

import json


class ProtocolError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


def encode_error(exc: Exception) -> dict:
    if isinstance(exc, ProtocolError):
        return {"code": exc.code, "message": exc.message}
    if isinstance(exc, json.JSONDecodeError):
        return {"code": "invalid_json", "message": str(exc)}
    return {"code": "internal_error", "message": str(exc)}


def reply(writer, request_id, result=None, error=None):
    message = {"id": request_id, "ok": error is None}
    message["result" if error is None else "error"] = result if error is None else error
    writer.write(json.dumps(message, ensure_ascii=False) + "\n")
    writer.flush()


def serve(reader, writer, handler) -> None:
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
            result = handler(method, params)
        except Exception as exc:
            reply(writer, request_id, error=encode_error(exc))
        else:
            reply(writer, request_id, result=result)
