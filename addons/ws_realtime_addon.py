"""mitmproxy addon: write every WebSocket frame to a JSONL file the moment it arrives.

Why: `mitmdump -w flows.mitm` only serializes a WebSocket flow when the socket closes, so
chat/push frames are invisible on disk while the connection is open. The `websocket_message`
hook fires per frame; here each frame is appended and flushed immediately.

Usage:
    WS_REALTIME_LOG=captures/ws.jsonl mitmdump -s addons/ws_realtime_addon.py -w flows.mitm
    tail -f captures/ws.jsonl | jq .

Each line:
    {"ts": 1700000000.12, "event": "message", "host": "...", "url": "...",
     "direction": "c2s"|"s2c", "type": "text"|"binary", "length": 42, "payload": "..."}
Binary frames are hex-encoded in `payload` (truncated to MAX_BINARY bytes).
"""
import json
import os
import time

from mitmproxy import http

OUT = os.environ.get("WS_REALTIME_LOG", os.path.join(os.getcwd(), "ws_realtime.jsonl"))
MAX_BINARY = int(os.environ.get("WS_MAX_BINARY", "4096"))


def _write(record: dict) -> None:
    record["ts"] = round(time.time(), 3)
    with open(OUT, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(record, ensure_ascii=False) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def websocket_start(flow: http.HTTPFlow) -> None:
    _write({"event": "open", "host": flow.request.pretty_host, "url": flow.request.pretty_url})


def websocket_message(flow: http.HTTPFlow) -> None:
    assert flow.websocket is not None
    msg = flow.websocket.messages[-1]  # the frame that just arrived
    if msg.is_text:
        kind, payload = "text", msg.text
    else:
        kind, payload = "binary", msg.content[:MAX_BINARY].hex()
    _write({
        "event": "message",
        "host": flow.request.pretty_host,
        "url": flow.request.pretty_url,
        "direction": "c2s" if msg.from_client else "s2c",
        "type": kind,
        "length": len(msg.content),
        "payload": payload,
    })


def websocket_end(flow: http.HTTPFlow) -> None:
    _write({"event": "close", "host": flow.request.pretty_host, "url": flow.request.pretty_url})
