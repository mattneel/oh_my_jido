"""Exclusive Snakepit Eval adapter. A worker is crash separation, not a sandbox."""

import ast
import base64
import contextlib
import io
import json
import os
import reprlib
import secrets
import threading
import time
import traceback
from types import SimpleNamespace

from snakepit_bridge.base_adapter import BaseAdapter
from snakepit_bridge.serialization import TypeSerializer
from snakepit_bridge_pb2 import ExecuteElixirToolRequest

# Snakepit creates a new adapter for every request. State must belong to the
# worker module, not the ephemeral adapter object. Never recycle this worker for
# another owner: sys.stdout/sys.stderr redirection is process-global.
_SESSIONS = {}
_LOCK = threading.Lock()
_OWNER = os.environ.pop("OH_MY_JIDO_EVAL_OWNER", None)
_CONTROL_TOKEN = os.environ.pop("OH_MY_JIDO_EVAL_CONTROL_TOKEN", None)
_WORKER_TOKEN = secrets.token_hex(24)


def _clip(value, maximum):
    encoded = value.encode("utf-8", errors="replace")
    return encoded[:maximum].decode("utf-8", errors="ignore"), len(encoded) > maximum


def _kind(value):
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, int):
        return "integer"
    if isinstance(value, float):
        return "float"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "list"
    if isinstance(value, dict):
        return "map"
    return "any"


class _Bridge:
    def __init__(self, context, arguments):
        self.context = context
        self.generation = arguments["generation"]
        self.execution_id = arguments["execution_id"]
        self.deadline = time.monotonic() + arguments["timeout"] / 1000
        self.callback_timeout = arguments["callback_timeout"] / 1000
        self.output_limit = arguments["output_limit"]

    def call(self, operation, *arguments):
        remaining = min(self.deadline - time.monotonic(), self.callback_timeout)
        if remaining <= 0:
            raise TimeoutError("Eval callback deadline exceeded")
        payload = {
            "generation": self.generation,
            "execution_id": self.execution_id,
            "operation": operation,
            "arguments": list(arguments),
        }
        # JSON, not repr/str or pickle: nested containers and booleans preserve
        # their types. The convenience call_elixir_tool helper does not do so.
        encoded = json.dumps(payload, allow_nan=False).encode("utf-8")
        maximum = self.output_limit * 2 + 4096 if operation == "artifact_bytes" else self.output_limit + 4096
        if len(encoded) > maximum:
            raise ValueError("bridge_input_limit")
        parameters = {}
        for key, value in payload.items():
            message, binary = TypeSerializer.encode_any(value, _kind(value))
            if binary is not None:
                raise TypeError("binary bridge arguments are not permitted")
            parameters[key] = message
        request = ExecuteElixirToolRequest(
            session_id=self.context.session_id,
            tool_name="omj_eval",
            parameters=parameters,
        )
        response = self.context.stub.ExecuteElixirTool(request, timeout=remaining)
        if not response.success:
            raise RuntimeError(response.error_message)
        result = TypeSerializer.decode_any(response.result, response.binary_result or None)
        if isinstance(result, dict) and result.get("ok") is False:
            raise RuntimeError(result["error"])
        if isinstance(result, dict) and result.get("ok") is True:
            return result.get("result")
        return result

    def tool(self, name, parameters=None):
        if not isinstance(name, str) or not isinstance(parameters or {}, dict):
            raise TypeError("tools.call requires a name and structured parameters")
        return self.call("tool", name, parameters if parameters is not None else {})

    def artifact(self, name, media_type, data):
        if isinstance(data, bytes):
            return self.call("artifact_bytes", name, media_type, base64.b64encode(data).decode("ascii"))
        return self.call("artifact", name, media_type, data)


class _Writer(io.TextIOBase):
    def __init__(self, bridge, stream):
        self.bridge = bridge
        self.stream = stream
        self.written = 0
        self.clipped = False

    @property
    def encoding(self):
        return "utf-8"

    def writable(self):
        return True

    def write(self, value):
        if not isinstance(value, str):
            raise TypeError("write() argument must be str")
        piece, clipped = _clip(value, max(self.bridge.output_limit - self.written, 0))
        if piece or (clipped and not self.clipped):
            self.bridge.call("output", self.stream, piece, clipped)
        self.clipped = self.clipped or clipped
        self.written += len(piece.encode("utf-8"))
        return len(value)

    def flush(self):
        return None


class EvalAdapter(BaseAdapter):
    def execute_tool(self, tool_name, arguments, context):
        token = arguments.get("control_token")
        if not (_OWNER and _CONTROL_TOKEN and isinstance(token, str)
                and secrets.compare_digest(token, _CONTROL_TOKEN)
                and arguments.get("owner") == _OWNER):
            raise RuntimeError("worker_authentication_failed")
        if not _LOCK.acquire(blocking=False):
            raise RuntimeError("exclusive_worker_busy")
        try:
            session_id = context.session_id  # Never trust arguments['session_id'].
            generation = arguments["generation"]
            if tool_name == "open":
                if _SESSIONS:
                    raise RuntimeError("worker_already_owned")
                os.chdir(arguments["workspace"])
                _SESSIONS[session_id] = {
                    "generation": generation,
                    "namespace": {"__name__": "__oh_my_jido_eval__"},
                }
                return self._identity(generation)
            session = _SESSIONS.get(session_id)
            if session is None or session["generation"] != generation:
                raise RuntimeError("kernel_invalidated")
            if tool_name == "close":
                del _SESSIONS[session_id]
                return self._identity(generation)
            if tool_name != "execute":
                raise ValueError("unknown_eval_operation")
            return self._execute(session, arguments, context)
        finally:
            _LOCK.release()

    @staticmethod
    def _identity(generation):
        return {"worker_token": _WORKER_TOKEN, "generation": generation}

    def _execute(self, session, arguments, context):
        bridge = _Bridge(context, arguments)
        namespace = session["namespace"]
        namespace["tools"] = SimpleNamespace(call=bridge.tool)
        namespace["display"] = lambda value: bridge.call("display", str(value))
        namespace["artifact"] = bridge.artifact
        stdout = _Writer(bridge, "stdout")
        stderr = _Writer(bridge, "stderr")
        result = {**self._identity(session["generation"]), "status": "ok", "display": "", "diagnostics": []}
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                module = ast.parse(arguments["source"], filename="eval.py", mode="exec")
                final = module.body.pop() if module.body and isinstance(module.body[-1], ast.Expr) else None
                exec(compile(module, "eval.py", "exec"), namespace, namespace)
                value = eval(compile(ast.Expression(final.value), "eval.py", "eval"), namespace, namespace) if final else None
                renderer = reprlib.Repr()
                renderer.maxstring = arguments["output_limit"]
                renderer.maxother = arguments["output_limit"]
                text = renderer.repr(value)
                result["display"], result["truncated"] = _clip(text, arguments["output_limit"])
            except BaseException as exception:
                result["status"] = "error"
                diagnostic = traceback.TracebackException.from_exception(exception, limit=15)
                message = "".join(diagnostic.format_exception_only()) + "".join(diagnostic.stack.format())
                result["error"], result["truncated"] = _clip(message, arguments["output_limit"])
        return result

    def cleanup(self):
        # Per-request adapter cleanup must not clear the module-owned session.
        # Explicit close or Snakepit worker termination owns namespace cleanup.
        return None
