#!/usr/bin/env python3

import json
import os
import select
import subprocess
import sys
import time


def send_messages(process: subprocess.Popen[bytes], messages: list[dict]) -> None:
    assert process.stdin is not None
    for message in messages:
        process.stdin.write((json.dumps(message) + "\n").encode())
    process.stdin.flush()


def read_responses(
    process: subprocess.Popen[bytes],
    pending_output: bytearray,
    expected_response_ids: set[int],
    timeout: float,
) -> dict[int, dict]:
    assert process.stdout is not None
    responses = {}
    deadline = time.time() + timeout
    while time.time() < deadline and not expected_response_ids.issubset(responses):
        while b"\n" in pending_output:
            newline_index = pending_output.index(b"\n")
            line = bytes(pending_output[:newline_index]).strip()
            del pending_output[: newline_index + 1]
            if not line:
                continue
            try:
                response = json.loads(line)
            except json.JSONDecodeError as error:
                raise RuntimeError(
                    "MCP server interleaved concurrent JSON-RPC responses "
                    f"(invalid line of {len(line)} bytes)"
                ) from error
            if "id" in response:
                responses[response["id"]] = response

        if expected_response_ids.issubset(responses):
            break

        ready, _, _ = select.select([process.stdout], [], [], 0.5)
        if not ready:
            continue
        chunk = os.read(process.stdout.fileno(), 65_536)
        if not chunk:
            break
        pending_output.extend(chunk)

    missing_response_ids = expected_response_ids - responses.keys()
    if missing_response_ids:
        raise RuntimeError(
            f"MCP verifier timed out waiting for response IDs: {sorted(missing_response_ids)}"
        )
    return responses


def stress_concurrent_responses(
    process: subprocess.Popen[bytes], pending_output: bytearray
) -> None:
    requests_per_round = 64
    for round_index in range(3):
        first_id = 1_000 + round_index * requests_per_round
        expected_ids = set(range(first_id, first_id + requests_per_round))
        send_messages(
            process,
            [
                {
                    "jsonrpc": "2.0",
                    "id": request_id,
                    "method": "tools/list",
                    "params": {},
                }
                for request_id in sorted(expected_ids)
            ],
        )

        # Let concurrent handlers fill the stdout pipe before reading. This
        # forces the transport through partial writes and EAGAIN instead of
        # accidentally testing only the single-write fast path.
        time.sleep(0.1)
        responses = read_responses(
            process,
            pending_output,
            expected_ids,
            timeout=30,
        )
        for request_id, response in responses.items():
            if "result" not in response or "tools" not in response["result"]:
                raise RuntimeError(
                    f"MCP stress response {request_id} was not a tools/list result"
                )


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit("usage: verify-mcp-stdio.py METAGENT PROJECT_ROOT")

    process = subprocess.Popen(
        [sys.argv[1], "mcp", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
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
    send_messages(process, messages)
    pending_output = bytearray()
    try:
        expected_response_ids = {1, 2, 3, 4, 5, 6, 7}
        responses = read_responses(
            process,
            pending_output,
            expected_response_ids,
            timeout=30,
        )

        tools = {tool["name"] for tool in responses[2]["result"]["tools"]}
        required = {
            "analyze_project",
            "get_project_analysis_details",
            "list_skills",
            "list_projects",
            "find_duplicate_skills",
            "get_skill",
            "remove_skills",
            "doctor_project",
        }
        missing_tools = required - tools
        if missing_tools:
            raise RuntimeError(f"missing MCP tools: {sorted(missing_tools)}")

        payload = json.loads(responses[3]["result"]["content"][0]["text"])
        if not payload.get("items"):
            raise RuntimeError("MCP list_skills returned no skill records")
        if payload.get("total_count") is None:
            raise RuntimeError("MCP list_skills did not report a total count")
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

        stress_concurrent_responses(process, pending_output)

        assert process.stdin is not None
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
