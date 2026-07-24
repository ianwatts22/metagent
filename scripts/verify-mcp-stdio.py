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
        {
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {"name": "analyze_project", "arguments": {"root": sys.argv[2]}},
        },
        {
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": {
                "name": "get_project_analysis_details",
                "arguments": {
                    "root": sys.argv[2],
                    "section": "skills",
                    "limit": 1,
                },
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 6,
            "method": "tools/call",
            "params": {
                "name": "get_project_analysis_details",
                "arguments": {"root": sys.argv[2]},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": {
                "name": "get_project_analysis_details",
                "arguments": {"root": sys.argv[2], "section": "unknown"},
            },
        },
    ]
    assert process.stdin is not None
    assert process.stdout is not None
    for message in messages:
        process.stdin.write(json.dumps(message) + "\n")
    process.stdin.flush()

    responses = {}
    try:
        expected_response_ids = {1, 2, 3, 4, 5, 6, 7}
        deadline = time.time() + 30
        while time.time() < deadline and not expected_response_ids.issubset(responses):
            ready, _, _ = select.select([process.stdout], [], [], 0.5)
            if not ready:
                continue
            line = process.stdout.readline().strip()
            if not line:
                continue
            response = json.loads(line)
            if "id" in response:
                responses[response["id"]] = response

        missing_response_ids = expected_response_ids - responses.keys()
        if missing_response_ids:
            raise RuntimeError(
                f"MCP verifier timed out waiting for response IDs: {sorted(missing_response_ids)}"
            )

        tools = [tool["name"] for tool in responses[2]["result"]["tools"]]
        expected = [
            "analyze_project",
            "get_project_analysis_details",
            "list_skills",
            "doctor_project",
        ]
        if tools != expected:
            raise RuntimeError(f"unexpected MCP tools: {tools}")

        payload = json.loads(responses[3]["result"]["content"][0]["text"])
        if not payload.get("projects"):
            raise RuntimeError("MCP list_skills returned no project inventory")
        analysis = json.loads(responses[4]["result"]["content"][0]["text"])
        if analysis.get("schema_version") != 2:
            raise RuntimeError("MCP analyze_project did not return schema version 2")
        if analysis.get("scope") != "project_only":
            raise RuntimeError("MCP analyze_project was not project-only")
        if "plugin_skills" in analysis:
            raise RuntimeError("MCP analyze_project included global plugin inventory")
        details = json.loads(responses[5]["result"]["content"][0]["text"])
        if details.get("section") != "skills" or len(details.get("items", [])) > 1:
            raise RuntimeError("MCP project details did not honor the requested page")
        accepted_sections = "instructions, skills, doctor, mcp, usage"
        missing_section = responses[6]["result"]
        missing_section_text = missing_section["content"][0]["text"]
        if not missing_section.get("isError") or missing_section_text != (
            f"section is required; accepted values: {accepted_sections}"
        ):
            raise RuntimeError(
                f"MCP project details returned an unclear missing-section error: {missing_section_text}"
            )
        invalid_section = responses[7]["result"]
        invalid_section_text = invalid_section["content"][0]["text"]
        if not invalid_section.get("isError") or invalid_section_text != (
            f'invalid section "unknown"; accepted values: {accepted_sections}'
        ):
            raise RuntimeError(
                f"MCP project details returned an unclear invalid-section error: {invalid_section_text}"
            )
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
