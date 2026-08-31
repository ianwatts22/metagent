#!/usr/bin/env python3

import json
import os
import select
import subprocess
import sys
import tempfile
import time


MAX_RESPONSE_BYTES = 2_000_000
MAX_TOOL_CONTENT_BYTES = 1_000_000


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
            if len(line) > MAX_RESPONSE_BYTES:
                raise RuntimeError(
                    f"MCP response exceeded {MAX_RESPONSE_BYTES} bytes: {len(line)}"
                )
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

    isolated_home = tempfile.TemporaryDirectory(prefix="metagent-mcp-home-")
    environment = os.environ.copy()
    environment["HOME"] = isolated_home.name
    process = subprocess.Popen(
        [sys.argv[1], "mcp", "--stdio"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
        env=environment,
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
            "id": 8,
            "method": "tools/call",
            "params": {"name": "list_projects", "arguments": {"kind": "all", "limit": 1}},
        },
        {
            "jsonrpc": "2.0",
            "id": 9,
            "method": "tools/call",
            "params": {
                "name": "find_duplicate_skills",
                "arguments": {"root": sys.argv[2], "scope": "project"},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": {
                "name": "get_skill",
                "arguments": {
                    "path": os.path.join(sys.argv[2], ".agents/skills/metagent"),
                    "include_body": False,
                },
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 11,
            "method": "tools/call",
            "params": {
                "name": "remove_skills",
                "arguments": {
                    "root": sys.argv[2],
                    "skill_names": ["metagent"],
                    "apply": False,
                },
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 12,
            "method": "tools/call",
            "params": {
                "name": "archive_skills",
                "arguments": {
                    "root": sys.argv[2],
                    "skill_names": ["metagent"],
                    "apply": False,
                },
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 13,
            "method": "tools/call",
            "params": {
                "name": "restore_skill",
                "arguments": {"skill_name": "missing-fixture", "apply": False},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 14,
            "method": "tools/call",
            "params": {"name": "list_archived_skills", "arguments": {}},
        },
        {
            "jsonrpc": "2.0",
            "id": 15,
            "method": "tools/call",
            "params": {
                "name": "doctor_project",
                "arguments": {"root": sys.argv[2], "scope": "project"},
            },
        },
        {
            "jsonrpc": "2.0",
            "id": 16,
            "method": "tools/call",
            "params": {
                "name": "measure_codebase_size",
                "arguments": {"root": sys.argv[2]},
            },
        },
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
    pending_output = bytearray()
    try:
        send_messages(process, messages)
        expected_response_ids = set(range(1, 17))
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
            "archive_skills",
            "restore_skill",
            "list_archived_skills",
            "doctor_project",
            "measure_codebase_size",
        }
        if tools != required:
            raise RuntimeError(
                "MCP tool surface changed: "
                f"missing={sorted(required - tools)}, unexpected={sorted(tools - required)}"
            )
        for request_id in range(3, 17):
            content = responses[request_id]["result"]["content"][0]["text"].encode()
            if len(content) > MAX_TOOL_CONTENT_BYTES:
                raise RuntimeError(
                    f"MCP tool response {request_id} exceeded the content rail: {len(content)}"
                )

        payload = json.loads(responses[3]["result"]["content"][0]["text"])
        if not payload.get("items"):
            raise RuntimeError("MCP list_skills returned no skill records")
        if payload.get("total_count") is None:
            raise RuntimeError("MCP list_skills did not report a total count")
        analysis = json.loads(responses[4]["result"]["content"][0]["text"])
        if analysis.get("schema_version") != 3:
            raise RuntimeError("MCP analyze_project did not return schema version 3")
        if analysis.get("scope") != "project_only":
            raise RuntimeError("MCP analyze_project was not project-only")
        if "plugin_skills" in analysis:
            raise RuntimeError("MCP analyze_project included global plugin inventory")
        details = json.loads(responses[5]["result"]["content"][0]["text"])
        if details.get("section") != "skills" or len(details.get("items", [])) > 1:
            raise RuntimeError("MCP project details did not honor the requested page")
        accepted_sections = "instructions, skills, doctor, mcp, usage"
        missing_section = responses[6]["result"]
        missing_section_payload = json.loads(missing_section["content"][0]["text"])
        missing_section_text = missing_section_payload["error"]["message"]
        if not missing_section.get("isError") or missing_section_text != (
            f"section is required; accepted values: {accepted_sections}"
        ) or missing_section_payload.get("tool") != "get_project_analysis_details":
            raise RuntimeError(
                f"MCP project details returned an unclear missing-section error: {missing_section_text}"
            )
        invalid_section = responses[7]["result"]
        invalid_section_payload = json.loads(invalid_section["content"][0]["text"])
        invalid_section_text = invalid_section_payload["error"]["message"]
        if not invalid_section.get("isError") or invalid_section_text != (
            f'invalid section "unknown"; accepted values: {accepted_sections}'
        ):
            raise RuntimeError(
                f"MCP project details returned an unclear invalid-section error: {invalid_section_text}"
            )

        projects = json.loads(responses[8]["result"]["content"][0]["text"])
        if projects.get("schema_version") != 2 or projects.get("returned_count", 0) > 1:
            raise RuntimeError("MCP list_projects did not return a bounded schema-v2 page")
        duplicates = json.loads(responses[9]["result"]["content"][0]["text"])
        if "groups" not in duplicates:
            raise RuntimeError("MCP find_duplicate_skills returned no groups contract")
        skill = json.loads(responses[10]["result"]["content"][0]["text"])
        if skill.get("name") != "metagent" or skill.get("body") is not None:
            raise RuntimeError("MCP get_skill did not honor the bounded no-body request")
        removal = json.loads(responses[11]["result"]["content"][0]["text"])
        archive = json.loads(responses[12]["result"]["content"][0]["text"])
        if removal.get("apply") is not False or archive.get("apply") is not False:
            raise RuntimeError("MCP mutation previews did not stay dry-run only")
        restore = responses[13]["result"]
        restore_error = json.loads(restore["content"][0]["text"])
        if not restore.get("isError") or restore_error.get("tool") != "restore_skill":
            raise RuntimeError("MCP restore_skill did not return a structured expected error")
        archived = json.loads(responses[14]["result"]["content"][0]["text"])
        if archived != []:
            raise RuntimeError("MCP verifier's isolated archive was not empty")
        doctor = json.loads(responses[15]["result"]["content"][0]["text"])
        if doctor.get("canonical_skill_count") != analysis["counts"]["project_skills"]:
            raise RuntimeError("MCP Doctor and analysis canonical counts disagree")
        codebase = json.loads(responses[16]["result"]["content"][0]["text"])
        if not codebase.get("is_git_repository"):
            raise RuntimeError("MCP measure_codebase_size did not inspect the fixture repository")

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
        isolated_home.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
