#!/usr/bin/env python3

import json
import select
import subprocess
import sys
import time


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify-mcp-stdio.py METAGENT PROJECT_ROOT")

    process = subprocess.Popen(
        [sys.argv[1], "mcp", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    messages = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "metagent-verifier", "version": "1"},
            },
        },
        {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        {
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {"name": "list_skills", "arguments": {"root": sys.argv[2]}},
        },
    ]
    assert process.stdin is not None
    assert process.stdout is not None
    for message in messages:
        process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()

    responses = {}
    try:
        deadline = time.time() + 15
        while time.time() < deadline and not {1, 2, 3}.issubset(responses):
            ready, _, _ = select.select([process.stdout], [], [], 0.5)
            if not ready:
                continue
            line = process.stdout.readline().strip()
            if not line:
                continue
            response = json.loads(line)
            if "id" in response:
                responses[response["id"]] = response

        tools = [tool["name"] for tool in responses[2]["result"]["tools"]]
        expected = ["analyze_project", "list_skills", "doctor_project"]
        if tools != expected:
            raise RuntimeError(f"unexpected MCP tools: {tools}")

        payload = json.loads(responses[3]["result"]["content"][0]["text"])
        if not payload.get("projects"):
            raise RuntimeError("MCP list_skills returned no project inventory")
        process.stdin.close()
        process.wait(timeout=5)
        if process.returncode != 0:
            raise RuntimeError(
                f"MCP server exited with {process.returncode} after stdin closed"
            )
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
