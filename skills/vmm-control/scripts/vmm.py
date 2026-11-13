#!/usr/bin/env python3
"""VMM MCP client and batch helper (Python standard library only; no HTTP API)."""
import argparse
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time

DEFAULT_CONNECTION = Path.home() / "Library/Application Support/VMM/mcp-connection.json"

class Client:
    def __init__(self, helper, connection, timeout=30):
        self.timeout = timeout
        self.sequence = 0
        self.process = subprocess.Popen([str(helper), "--connection", str(connection)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        try:
            result = self.rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}, "clientInfo": {"name": "vmm-control", "version": "2.0"}})
            if result.get("protocolVersion") not in ("2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"):
                raise RuntimeError("Unsupported MCP protocol version")
            self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        except Exception:
            self.close()
            raise

    def send(self, message):
        payload = json.dumps(message, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
        if len(payload) > 1048576:
            raise RuntimeError("MCP request exceeds 1 MiB")
        self.process.stdin.write(payload)
        self.process.stdin.flush()

    def rpc(self, method, params):
        self.sequence += 1
        request_id = self.sequence
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params})
        deadline = time.monotonic() + self.timeout
        while True:
            if b"\n" not in self.buffer:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not self.selector.select(remaining):
                    raise RuntimeError("MCP timed out; the operation may still be running. Inspect state/job before retrying.")
                data = os.read(self.process.stdout.fileno(), 65536)
                if not data:
                    raise RuntimeError("VMM MCP disconnected. Enable MCP in VMM and check the connection/helper paths.")
                self.buffer += data
                if len(self.buffer) > 33554432:
                    raise RuntimeError("MCP response exceeds 32 MiB")
                continue
            line, self.buffer = self.buffer.split(b"\n", 1)
            message = json.loads(line)
            if message.get("id") != request_id:
                continue
            if "error" in message:
                raise RuntimeError(message["error"].get("message", "MCP error"))
            return message["result"]

    def tool(self, name, arguments=None):
        result = self.rpc("tools/call", {"name": name if name.startswith("vmm.") else "vmm." + name, "arguments": arguments or {}})
        value = result.get("structuredContent")
        if value is None:
            value = json.loads(next(item["text"] for item in result["content"] if item["type"] == "text"))
        if result.get("isError"):
            raise RuntimeError(value.get("error", "VMM operation failed"))
        return value

    def close(self):
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.selector.close()
        self.process.stdout.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--helper", default=os.environ.get("VMM_MCP_HELPER"), help="Absolute path to VMMMCPBridge in the VMM app's Contents/Helpers")
    parser.add_argument("--connection", type=Path, default=Path(os.environ.get("VMM_MCP_CONNECTION", DEFAULT_CONNECTION)))
    parser.add_argument("--timeout", type=float, default=30)
    sub = parser.add_subparsers(dest="action", required=True)
    for name in ("state", "capabilities", "catalog", "settings", "tools"):
        sub.add_parser(name)
    command = sub.add_parser("command", help="Editor operation JSON file, or - for stdin")
    command.add_argument("file")
    call = sub.add_parser("call", help="MCP tool name and JSON arguments file")
    call.add_argument("name")
    call.add_argument("file", nargs="?", default=None)
    script = sub.add_parser("script")
    script.add_argument("file", type=Path)
    script.add_argument("--track", type=int)
    script.add_argument("--start", type=float)
    job = sub.add_parser("job")
    job.add_argument("id")
    job.add_argument("--wait", action="store_true")
    job.add_argument("--wait-timeout", type=float, default=300)
    args = parser.parse_args()
    if not args.helper:
        parser.error("Set --helper or VMM_MCP_HELPER to the VMMMCPBridge path shown by VMM's MCP connection settings.")
    def read_json(path):
        return json.load(sys.stdin) if path == "-" else json.loads(Path(path).read_text(encoding="utf-8"))
    client = Client(Path(args.helper), args.connection, args.timeout)
    try:
        if args.action == "tools":
            value = client.rpc("tools/list", {})
        elif args.action == "command":
            request = read_json(args.file)
            name = request.pop("command")
            value = client.tool(name, request)
        elif args.action == "call":
            value = client.tool(args.name, read_json(args.file) if args.file else {})
        elif args.action == "script":
            request = {"text": args.file.read_text(encoding="utf-8")}
            if args.track is not None:
                request["track"] = args.track
            if args.start is not None:
                request["start"] = args.start
            value = client.tool("script.import", request)
        elif args.action == "job":
            deadline = time.monotonic() + args.wait_timeout
            while True:
                value = client.tool("job", {"jobID": args.id})
                if not args.wait or value["state"] != "running":
                    break
                if time.monotonic() >= deadline:
                    raise RuntimeError("Job wait timed out; do not resubmit. Inspect the existing jobID.")
                time.sleep(0.25)
            if value["state"] == "failed":
                raise RuntimeError(value.get("error", "Job failed"))
        else:
            value = client.tool(args.action)
        print(json.dumps(value, ensure_ascii=False, indent=2))
    finally:
        client.close()

if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, KeyError, BrokenPipeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
