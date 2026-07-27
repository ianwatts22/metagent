#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_source="$repo_root/apps/MetagentMenuBar"
swift_helper="$app_source/.build/debug/metagent"

source "$repo_root/scripts/lib.sh"
setup_swift_build_env

# Run a command that must fail, capturing its combined output to out_file,
# then assert the output contains the expected literal message. Pass an empty
# message to skip the output assertion.
# Usage: expect_failure "expected message" out_file -- cmd args...
expect_failure() {
  local expected="$1" out_file="$2"
  shift 2
  if [[ "${1:-}" == "--" ]]; then
    shift
  fi
  if "$@" >"$out_file" 2>&1; then
    echo "expected failure, but the command succeeded: $*" >&2
    exit 1
  fi
  if [[ -n "$expected" ]]; then
    grep -Fq -- "$expected" "$out_file"
  fi
}

# Write a minimal skill fixture: <dir>/SKILL.md with frontmatter only.
make_skill() {
  local dir="$1" name="$2" description="$3"
  mkdir -p "$dir"
  printf -- "---\nname: %s\ndescription: %s\n---\n" "$name" "$description" >"$dir/SKILL.md"
}

# Write a skills-lock.json with two plain github-sourced entries.
write_pair_lock() {
  local lock_path="$1" first="$2" second="$3"
  cat >"$lock_path" <<EOF
{
  "version": 1,
  "skills": {
    "$first": {"source": "example/skills", "sourceType": "github"},
    "$second": {"source": "example/skills", "sourceType": "github"}
  }
}
EOF
}

# Write the stale-lock fixture with future metadata that must be preserved.
write_stale_lock() {
  local lock_path="$1"
  cat >"$lock_path" <<'EOF'
{
  "version": 1,
  "skills": {
    "stale-lock": {
      "source": "example/skills",
      "sourceType": "github",
      "futureMetadata": {"preserve": true}
    }
  },
  "futureRootMetadata": {"preserve": true}
}
EOF
}

verify_shell_syntax() {
for shell_script in "$repo_root"/scripts/*.sh; do
  bash -n "$shell_script"
done
}

verify_swift_build() (
  cd "$app_source"
  swift build --disable-sandbox
)

verify_swift_tests() (
  cd "$app_source"
  if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    swift test --disable-sandbox
  else
    echo "Full Xcode not found; skipping XCTest while retaining build and integration verification" >&2
  fi
)

verify_release_bundle() {
"$repo_root/scripts/build-app.sh" >/dev/null
plutil -lint "$repo_root/dist/MetagentMenuBar.app/Contents/Info.plist" >/dev/null
test -x "$repo_root/dist/MetagentMenuBar.app/Contents/MacOS/MetagentMenuBar"
test -x "$repo_root/dist/MetagentMenuBar.app/Contents/Helpers/metagent"
test -f "$repo_root/dist/MetagentMenuBar.app/Contents/Resources/Lucide-LICENSE.txt"
test -f "$repo_root/dist/MetagentMenuBar.app/Contents/Resources/Lucide-sprite.svg"
test -f "$repo_root/dist/MetagentMenuBar.app/Contents/Resources/Lucide-tags.json"
test -f "$repo_root/dist/MetagentMenuBar.app/Contents/Resources/Lucide-VERSION.txt"
}

verify_update_archive() (
  update_fixture="$(mktemp -d /private/tmp/metagent-update-verify.XXXXXX)"
  update_archive="$update_fixture/Metagent.zip"
  update_verification="$update_fixture/unpacked"
  trap 'rm -rf "$update_fixture"' EXIT
  mkdir -p "$update_verification"
  "$repo_root/scripts/package-update.sh" "$update_archive" >/dev/null
  /usr/bin/ditto -x -k "$update_archive" "$update_verification"
  test -d "$update_verification/Metagent.app"
  test ! -e "$update_verification/MetagentMenuBar.app"
)

verify_helper_smoke() {
"$swift_helper" skills scan --root "$repo_root" --max-depth 3 --json >/dev/null
"$swift_helper" skills doctor --root "$repo_root" --max-depth 3 >/dev/null
"$swift_helper" skills --help >/dev/null
"$swift_helper" usage --help >/dev/null
"$swift_helper" config show --json >/dev/null
"$swift_helper" analyze --root "$repo_root" --json \
  | jq -e '
      .schema_version == 2 and
      .scope == "project_only" and
      .counts.project_skills > 0 and
      .detail_tool == "get_project_analysis_details"
    ' >/dev/null
"$swift_helper" analyze --root "$repo_root" --json --details \
  | jq -e '.schema_version == 1 and (.skills.projects | length) > 0' >/dev/null
}

verify_mcp_protocol() {
python3 "$repo_root/scripts/verify-mcp-stdio.py" "$swift_helper" "$repo_root"
}

verify_manager_fixtures() (
fixture_root="$(mktemp -d /private/tmp/metagent-verify.XXXXXX)"
normalized_fixture_root="${fixture_root/#\/private\/tmp/\/tmp}"
cleanup_fixture() {
  if command -v trash >/dev/null 2>&1; then
    trash "$fixture_root" >/dev/null 2>&1 || true
  else
    rm -rf "$fixture_root"
  fi
}
trap cleanup_fixture EXIT

mkdir -p \
  "$fixture_root/dotagents-safe/.agents/skills/demo" \
  "$fixture_root/dotagents-commented/.agents/skills/demo" \
  "$fixture_root/dotagents-empty/.agents/skills" \
  "$fixture_root/dotagents-invalid-name/.agents/skills" \
  "$fixture_root/dotagents-missing/.agents/skills" \
  "$fixture_root/dotagents-no-newline/.agents/skills/demo" \
  "$fixture_root/dotagents-reordered/.agents/skills/demo" \
  "$fixture_root/dotagents-unsafe/.agents/skills/demo" \
  "$fixture_root/dotagents-unsafe/.agents/skills/other"
cat >"$fixture_root/dotagents-safe/agents.toml" <<'EOF'
version = 1
[[skills]]
name = "demo"
source = "path:.agents/skills/demo"
EOF
cat >"$fixture_root/dotagents-commented/agents.toml" <<'EOF'
version = 1
[[skills]] # valid TOML comment
name = "demo"
source = "path:.agents/skills/demo"
EOF
cat >"$fixture_root/dotagents-empty/agents.toml" <<'EOF'
version = 1
agents = ["claude", "codex"]
EOF
cat >"$fixture_root/dotagents-reordered/agents.toml" <<'EOF'
version = 1
[[skills]]
source = "path:.agents/skills/demo"
name = "demo"
EOF
cat >"$fixture_root/dotagents-invalid-name/agents.toml" <<'EOF'
version = 1
[[skills]]
name = "../external"
source = "path:.agents/skills/../external"
EOF
cat >"$fixture_root/dotagents-missing/agents.toml" <<'EOF'
version = 1
[[skills]]
name = "missing"
source = "path:.agents/skills/missing"
EOF
printf '%s' 'version = 1
[[skills]]
name = "demo"
source = "path:.agents/skills/demo"' >"$fixture_root/dotagents-no-newline/agents.toml"
cat >"$fixture_root/dotagents-unsafe/agents.toml" <<'EOF'
version = 1
[[skills]]
name = "demo"
source = "path:.agents/skills/other"
EOF
"$repo_root/scripts/retire-dotagents-state.sh" "$fixture_root/dotagents-safe" >/dev/null
"$repo_root/scripts/retire-dotagents-state.sh" "$fixture_root/dotagents-commented" >/dev/null
no_newline_output="$fixture_root/dotagents-no-newline.out"
"$repo_root/scripts/retire-dotagents-state.sh" "$fixture_root/dotagents-no-newline" >"$no_newline_output"
grep -Fq "would trash: $fixture_root/dotagents-no-newline/agents.toml" "$no_newline_output"
test -f "$fixture_root/dotagents-no-newline/agents.toml"
"$repo_root/scripts/retire-dotagents-state.sh" "$fixture_root/dotagents-reordered" >/dev/null
empty_output="$fixture_root/dotagents-empty.out"
expect_failure "no skill declarations were found" "$empty_output" -- \
  "$repo_root/scripts/retire-dotagents-state.sh" "$fixture_root/dotagents-empty"
test -f "$fixture_root/dotagents-empty/agents.toml"
invalid_name_output="$fixture_root/dotagents-invalid-name.out"
expect_failure "invalid skill name ../external" "$invalid_name_output" -- \
  "$repo_root/scripts/retire-dotagents-state.sh" "$fixture_root/dotagents-invalid-name"
test -f "$fixture_root/dotagents-invalid-name/agents.toml"
missing_output="$fixture_root/dotagents-missing.out"
expect_failure "missing's skill directory is missing on disk" "$missing_output" -- \
  "$repo_root/scripts/retire-dotagents-state.sh" "$fixture_root/dotagents-missing"
test -f "$fixture_root/dotagents-missing/agents.toml"
unsafe_output="$fixture_root/dotagents-unsafe.out"
expect_failure "demo uses independent source path:.agents/skills/other" "$unsafe_output" -- \
  "$repo_root/scripts/retire-dotagents-state.sh" "$fixture_root/dotagents-unsafe"
test -f "$fixture_root/dotagents-unsafe/agents.toml"

mkdir -p \
  "$fixture_root/home/.config/metagent" \
  "$fixture_root/old/.agents/skills/old-skill" \
  "$fixture_root/workspace/.agents/skills/workspace-skill" \
  "$fixture_root/workspace/_archive/stale/.agents/skills/archive-skill" \
  "$fixture_root/workspace/child/.agents/skills/child-skill" \
  "$fixture_root/workspace/child/.agents/skills/directory-skill/SKILL.md" \
  "$fixture_root/workspace/child/.agents/skills/child-skill/references/example/.agents/skills/nested-skill" \
  "$fixture_root/default/.agents/skills/default-skill"
make_skill "$fixture_root/old/.agents/skills/old-skill" "old-skill" "old"
make_skill "$fixture_root/workspace/.agents/skills/workspace-skill" "workspace-skill" "workspace"
make_skill "$fixture_root/workspace/_archive/stale/.agents/skills/archive-skill" "archive-skill" "archived"
make_skill "$fixture_root/workspace/child/.agents/skills/child-skill" "child-skill" "child"
cat >"$fixture_root/workspace/child/skills-lock.json" <<'EOF'
{
  "version": 1,
  "skills": {
    "child-skill": {
      "source": "example/skills",
      "sourceType": "github",
      "skillPath": "skills/child-skill",
      "computedHash": "fixture-hash"
    }
  }
}
EOF
make_skill "$fixture_root/workspace/child/.agents/skills/child-skill/references/example/.agents/skills/nested-skill" "nested-skill" "nested"
make_skill "$fixture_root/default/.agents/skills/default-skill" "default-skill" "default"
mkdir -p "$fixture_root/workspace/child/.claude"
ln -s ../.agents/skills "$fixture_root/workspace/child/.claude/skills"
ln -s .. "$fixture_root/workspace/child/.agents/skills/child-skill/references/loop"
ln -s "$fixture_root/workspace" "$fixture_root/workspace-link"
cat >"$fixture_root/home/.config/metagent/config.toml" <<EOF
# roots = ["$fixture_root/old"]
# max_depth = 0
roots = ["$fixture_root/workspace"]
max_depth = 3
ignore_projects = ["$fixture_root/workspace"]
EOF

fixture_scan="$(HOME="$fixture_root/home" "$swift_helper" skills scan --json)"
printf '%s\n' "$fixture_scan" | grep -F "child-skill" >/dev/null
if printf '%s\n' "$fixture_scan" | grep -F "old-skill" >/dev/null; then
  echo "commented config roots were treated as active" >&2
  exit 1
fi
if printf '%s\n' "$fixture_scan" | grep -F "workspace-skill" >/dev/null; then
  echo "ignored parent workspace was included as a project" >&2
  exit 1
fi
if printf '%s\n' "$fixture_scan" | grep -F "archive-skill" >/dev/null; then
  echo "_archive project was included in skill discovery" >&2
  exit 1
fi
if printf '%s\n' "$fixture_scan" | grep -F "nested-skill" >/dev/null; then
  echo "nested skill fixture was treated as a project" >&2
  exit 1
fi
if printf '%s\n' "$fixture_scan" | grep -F "directory-skill" >/dev/null; then
  echo "SKILL.md directory was treated as a valid skill file" >&2
  exit 1
fi
printf '%s\n' "$fixture_scan" | grep -F '"location" : "claude"' >/dev/null
printf '%s\n' "$fixture_scan" | grep -F '"origin_kind" : "npx-skills"' >/dev/null
printf '%s\n' "$fixture_scan" | grep -F '"manager" : "skills-cli"' >/dev/null
printf '%s\n' "$fixture_scan" | grep -F '"mutability" : "managed-read-only"' >/dev/null
printf '%s\n' "$fixture_scan" | grep -F '"representation" : "projection"' >/dev/null
printf '%s\n' "$fixture_scan" | grep -F '"source" : "example' >/dev/null

legacy_lock_root="$fixture_root/legacy-lock-project"
mkdir -p "$legacy_lock_root/.agents/skills/root-managed" "$legacy_lock_root/.agents/skills/nested-only"
make_skill "$legacy_lock_root/.agents/skills/root-managed" "root-managed" "root lock"
make_skill "$legacy_lock_root/.agents/skills/nested-only" "nested-only" "nested legacy lock"
cat >"$legacy_lock_root/skills-lock.json" <<'EOF'
{"version":1,"skills":{"root-managed":{"source":"root/source","sourceType":"github","computedHash":"fixture"}}}
EOF
cat >"$legacy_lock_root/.agents/.skill-lock.json" <<'EOF'
{"version":3,"skills":{"nested-only":{"source":"legacy/source","sourceType":"github","skillFolderHash":"fixture"}}}
EOF
legacy_lock_scan="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills scan --root "$legacy_lock_root" --max-depth 0 --json)"
test "$(printf '%s\n' "$legacy_lock_scan" | jq -r '.projects[].skills[] | select(.name=="root-managed" and .location=="agents") | .manager')" = "skills-cli"
test "$(printf '%s\n' "$legacy_lock_scan" | jq -r '.projects[].skills[] | select(.name=="nested-only" and .location=="agents") | .manager')" = "local"
legacy_lock_doctor="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills doctor --root "$legacy_lock_root" --max-depth 0 --json)"
printf '%s\n' "$legacy_lock_doctor" | grep -F 'Legacy skills lock ignored' >/dev/null

plugin_home="$fixture_root/plugin-home"
plugin_root="$plugin_home/.codex/plugins/cache/test-market/demo/1.2.3"
mkdir -p "$plugin_root/skills/demo-skill"
make_skill "$plugin_root/skills/demo-skill" "demo-skill" "plugin fixture"
codex_stub="$fixture_root/codex-stub"
cat >"$codex_stub" <<EOF
#!/usr/bin/env bash
set -euo pipefail
dd if=/dev/zero bs=131072 count=1 2>/dev/null | tr '\0' x >&2
printf '%s\n' '{"installed":[{"pluginId":"demo@test-market","name":"demo","marketplaceName":"test-market","version":"1.2.3","installed":true,"enabled":true,"source":{"path":"$plugin_root"}}]}'
EOF
chmod +x "$codex_stub"
plugin_scan="$(HOME="$plugin_home" METAGENT_CODEX="$codex_stub" "$swift_helper" inventory --json)"
test "$(printf '%s\n' "$plugin_scan" | jq -r '.projects[].skills[] | select(.name=="demo-skill") | [.manager,.mutability,.representation] | @tsv')" = $'codex-plugin\tmanaged-read-only\tversioned-cache'

plugin_collision_root="$fixture_root/plugin-collision"
mkdir -p "$plugin_collision_root/.agents/skills/local-skill" "$plugin_collision_root/skills/plugin-skill"
make_skill "$plugin_collision_root/.agents/skills/local-skill" "local-skill" "local"
make_skill "$plugin_collision_root/skills/plugin-skill" "plugin-skill" "plugin"
cat >"$codex_stub" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"installed":[{"pluginId":"collision@test-market","name":"collision","marketplaceName":"test-market","version":"1.2.3","installed":true,"enabled":true,"source":{"path":"$plugin_collision_root"}}]}'
EOF
mkdir -p "$plugin_home/.config/metagent"
cat >"$plugin_home/.config/metagent/config.toml" <<EOF
roots = ["$plugin_collision_root"]
max_depth = 0
EOF
plugin_collision_scan="$(HOME="$plugin_home" METAGENT_CODEX="$codex_stub" "$swift_helper" inventory --json)"
printf '%s\n' "$plugin_collision_scan" | jq -e '
  (.projects | length) == 1 and
  ([.projects[0].skills[].name] | sort | join(",")) == "local-skill,plugin-skill"
' >/dev/null

fixture_doctor="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills doctor --root "$fixture_root/workspace" --max-depth 4 --json)"
if printf '%s\n' "$fixture_doctor" | grep -F "archive-skill" >/dev/null; then
  echo "_archive project was included in Doctor findings" >&2
  exit 1
fi
printf '%s\n' "$fixture_doctor" | grep -F '"repair_action" : "repair_projection"' >/dev/null

symlink_ignore_scan="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills scan --root "$fixture_root/workspace" --ignore-project "$fixture_root/workspace-link" --max-depth 0 --json)"
if printf '%s\n' "$symlink_ignore_scan" | grep -F "workspace-skill" >/dev/null; then
  echo "symlinked ignore project path was not honored" >&2
  exit 1
fi

agents_root_scan="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills scan --root "$fixture_root/workspace/.agents" --max-depth 0 --json)"
printf '%s\n' "$agents_root_scan" | grep -F "workspace-skill" >/dev/null

skills_root_scan="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills scan --root "$fixture_root/workspace/.agents/skills" --max-depth 0 --json)"
printf '%s\n' "$skills_root_scan" | grep -F "workspace-skill" >/dev/null

mkdir -p \
  "$fixture_root/home/code_projects/.agents/skills/home-parent" \
  "$fixture_root/home/code_projects/home-child/.agents/skills/home-child"
make_skill "$fixture_root/home/code_projects/.agents/skills/home-parent" "home-parent" "home parent"
make_skill "$fixture_root/home/code_projects/home-child/.agents/skills/home-child" "home-child" "home child"
cat >"$fixture_root/home/.config/metagent/config.toml" <<EOF
roots = ["$fixture_root/home/code_projects"]
max_depth = 3
ignore_projects = ["$fixture_root/home/code_projects"]
EOF
home_probe="$fixture_root/scan-home-probe.swift"
cat >"$home_probe" <<'SWIFT'
import Foundation

@main
struct Probe {
    static func main() throws {
        let report = try MetagentCore.scanHomeSkills(maxDepth: 2)
        for project in report.projects {
            print(project.root)
        }
    }
}
SWIFT
swiftc "$app_source"/Sources/MetagentCore/*.swift "$home_probe" -lsqlite3 -o "$fixture_root/scan-home-probe"
home_scan="$(HOME="$fixture_root/home" "$fixture_root/scan-home-probe")"
printf '%s\n' "$home_scan" | grep -F -- "$normalized_fixture_root/home/code_projects/home-child" >/dev/null
if printf '%s\n' "$home_scan" | grep -Fx -- "$normalized_fixture_root/home/code_projects" >/dev/null; then
  echo "ignored home parent was included in scanHomeSkills" >&2
  exit 1
fi
nested_scan="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills scan --root "$fixture_root/home/code_projects" --max-depth 3 --json)"
printf '%s\n' "$nested_scan" | grep -F "home-parent" >/dev/null
printf '%s\n' "$nested_scan" | grep -F "home-child" >/dev/null

cache_home="$fixture_root/cache-home"
mkdir -p \
  "$cache_home/.config/metagent" \
  "$cache_home/full/.agents/skills/cache-full" \
  "$cache_home/scoped/.agents/skills/cache-scoped"
make_skill "$cache_home/full/.agents/skills/cache-full" "cache-full" "full"
make_skill "$cache_home/scoped/.agents/skills/cache-scoped" "cache-scoped" "scoped"
cat >"$cache_home/.config/metagent/config.toml" <<EOF
roots = ["$cache_home/full"]
max_depth = 0
EOF
HOME="$cache_home" "$swift_helper" skills scan --json >/dev/null
HOME="$cache_home" "$swift_helper" skills scan --root "$cache_home/scoped" --max-depth 0 --json >/dev/null
cache_db="$cache_home/Library/Application Support/Metagent/inventory.sqlite"
cache_json="$(sqlite3 "$cache_db" "SELECT json FROM inventory_snapshots WHERE id = 1;")"
printf '%s\n' "$cache_json" | grep -F "cache-full" >/dev/null
if printf '%s\n' "$cache_json" | grep -F "cache-scoped" >/dev/null; then
  echo "scoped scan replaced the shared inventory cache" >&2
  exit 1
fi

uninstall_root="$fixture_root/uninstall-project"
mkdir -p \
  "$uninstall_root/.agents/skills/remove-me" \
  "$uninstall_root/.agents/skills/keep-me" \
  "$uninstall_root/.codex/skills/remove-me" \
  "$uninstall_root/.claude"
make_skill "$uninstall_root/.agents/skills/remove-me" "remove-me" "remove"
make_skill "$uninstall_root/.agents/skills/keep-me" "keep-me" "keep"
make_skill "$uninstall_root/.codex/skills/remove-me" "remove-me" "independent codex copy"
ln -s ../.agents/skills "$uninstall_root/.claude/skills"
cat >"$uninstall_root/skills-lock.json" <<'EOF'
{
  "version": 1,
  "customTopLevel": "preserve-me",
  "skills": {
    "remove-me": {
      "source": "example/skills",
      "sourceType": "github",
      "computedHash": "remove-hash",
      "customEntryField": "preserve-if-present"
    },
    "keep-me": {
      "source": "example/skills",
      "sourceType": "github",
      "computedHash": "keep-hash"
    }
  }
}
EOF
uninstall_probe="$fixture_root/uninstall-probe.swift"
cp "$repo_root/scripts/fixtures/uninstall-probe.swift" "$uninstall_probe"
swiftc "$app_source"/Sources/MetagentCore/*.swift "$uninstall_probe" -lsqlite3 -o "$fixture_root/uninstall-probe"
managed_uninstall_output="$fixture_root/managed-uninstall.out"
expect_failure 'npx --yes skills remove remove-me --yes' "$managed_uninstall_output" -- \
  env HOME="$fixture_root/home" "$fixture_root/uninstall-probe" "$uninstall_root" remove-me refuse
env HOME="$fixture_root/home" "$fixture_root/uninstall-probe" "$uninstall_root" remove-me plan \
  >"$fixture_root/managed-uninstall-plan.out" 2>&1
grep -Fq -- 'would remove remove-me through the canonical path managed by skills-cli' \
  "$fixture_root/managed-uninstall-plan.out"
test -f "$uninstall_root/.agents/skills/remove-me/SKILL.md"
test -f "$uninstall_root/.agents/skills/keep-me/SKILL.md"
test -f "$uninstall_root/.codex/skills/remove-me/SKILL.md"
test -L "$uninstall_root/.claude/skills"
grep -q '"remove-me"' "$uninstall_root/skills-lock.json"

npx_stub="$fixture_root/npx-stub"
cp "$repo_root/scripts/fixtures/npx-remove-stub.sh" "$npx_stub"
chmod +x "$npx_stub"
HOME="$fixture_root/home" METAGENT_NPX="$npx_stub" "$fixture_root/uninstall-probe" "$uninstall_root" remove-me apply >/dev/null
test ! -e "$uninstall_root/.agents/skills/remove-me"
test -f "$uninstall_root/.agents/skills/keep-me/SKILL.md"
test -f "$uninstall_root/.codex/skills/remove-me/SKILL.md"
if grep -q '"remove-me"' "$uninstall_root/skills-lock.json"; then
  echo "managed removal left its project lock entry" >&2
  exit 1
fi

batch_root="$fixture_root/batch-uninstall-project"
mkdir -p "$batch_root/.agents/skills/batch-one" "$batch_root/.agents/skills/batch-two"
make_skill "$batch_root/.agents/skills/batch-one" "batch-one" "first"
make_skill "$batch_root/.agents/skills/batch-two" "batch-two" "second"
write_pair_lock "$batch_root/skills-lock.json" batch-one batch-two
batch_npx_log="$fixture_root/batch-npx.log"
HOME="$fixture_root/home" METAGENT_NPX="$npx_stub" METAGENT_NPX_LOG="$batch_npx_log" \
  "$fixture_root/uninstall-probe" "$batch_root" batch-one,batch-two apply >/dev/null
test ! -e "$batch_root/.agents/skills/batch-one"
test ! -e "$batch_root/.agents/skills/batch-two"
jq -e '.skills == {}' "$batch_root/skills-lock.json" >/dev/null
test "$(wc -l <"$batch_npx_log" | tr -d ' ')" = "1"
grep -q 'skills remove batch-one batch-two --yes' "$batch_npx_log"

stale_lock_root="$fixture_root/stale-lock-uninstall-project"
mkdir -p "$stale_lock_root/.agents/skills/stale-lock"
make_skill "$stale_lock_root/.agents/skills/stale-lock" "stale-lock" "stale lock fixture"
write_stale_lock "$stale_lock_root/skills-lock.json"
stale_lock_output="$fixture_root/stale-lock.out"
HOME="$fixture_root/home" METAGENT_NPX="$npx_stub" METAGENT_NPX_LEAVE_LOCK=1 \
  "$fixture_root/uninstall-probe" "$stale_lock_root" stale-lock apply >"$stale_lock_output"
test ! -e "$stale_lock_root/.agents/skills/stale-lock"
jq -e '.skills == {} and .futureRootMetadata.preserve == true' "$stale_lock_root/skills-lock.json" >/dev/null
grep -q 'removed a stale project lock entry left by skills-cli' "$stale_lock_output"

write_stale_lock "$stale_lock_root/skills-lock.json"
mkdir -p "$stale_lock_root/.codex/skills"
ln -s ../../.agents/skills/stale-lock "$stale_lock_root/.codex/skills/stale-lock"
mkdir -p "$stale_lock_root/.claude/shared-skills"
ln -s ../../.agents/skills/stale-lock "$stale_lock_root/.claude/shared-skills/stale-lock"
ln -s shared-skills "$stale_lock_root/.claude/skills"
stale_lock_retry_output="$fixture_root/stale-lock-retry.out"
HOME="$fixture_root/home" METAGENT_NPX="$npx_stub" \
  "$fixture_root/uninstall-probe" "$stale_lock_root" stale-lock apply >"$stale_lock_retry_output"
jq -e '.skills == {} and .futureRootMetadata.preserve == true' "$stale_lock_root/skills-lock.json" >/dev/null
test ! -L "$stale_lock_root/.codex/skills/stale-lock"
test -L "$stale_lock_root/.claude/shared-skills/stale-lock"
grep -q 'removed a stale project lock entry for an already-absent Skills CLI bundle' "$stale_lock_retry_output"
grep -q 'removed 1 dangling per-skill projection link' "$stale_lock_retry_output"

partial_root="$fixture_root/partial-batch-uninstall-project"
mkdir -p "$partial_root/.agents/skills/partial-one" "$partial_root/.agents/skills/partial-two"
make_skill "$partial_root/.agents/skills/partial-one" "partial-one" "first"
make_skill "$partial_root/.agents/skills/partial-two" "partial-two" "second"
write_pair_lock "$partial_root/skills-lock.json" partial-one partial-two
partial_output="$fixture_root/partial-batch.out"
expect_failure 'partial-one' "$partial_output" -- \
  env HOME="$fixture_root/home" METAGENT_NPX="$npx_stub" METAGENT_NPX_FAIL_AFTER_FIRST=1 \
  "$fixture_root/uninstall-probe" "$partial_root" partial-one,partial-two apply
test ! -e "$partial_root/.agents/skills/partial-one"
test -f "$partial_root/.agents/skills/partial-two/SKILL.md"
jq -e '.skills["partial-one"] == null and .skills["partial-two"] != null' "$partial_root/skills-lock.json" >/dev/null
partial_recovery_metadata="$(rg -l '^skill=partial-one$' "$fixture_root/home/Library/Application Support/Metagent/Removed Skills" -g REMOVAL.txt | head -1)"
test -f "$(dirname "$partial_recovery_metadata")/after.json"

corrupt_root="$fixture_root/corrupt-batch-uninstall-project"
mkdir -p "$corrupt_root/.agents/skills/corrupt-one" "$corrupt_root/.agents/skills/corrupt-two"
make_skill "$corrupt_root/.agents/skills/corrupt-one" "corrupt-one" "first"
make_skill "$corrupt_root/.agents/skills/corrupt-two" "corrupt-two" "second"
write_pair_lock "$corrupt_root/skills-lock.json" corrupt-one corrupt-two
corrupt_output="$fixture_root/corrupt-batch.out"
expect_failure 'Could not verify Skills CLI lock state' "$corrupt_output" -- \
  env HOME="$fixture_root/home" METAGENT_NPX="$npx_stub" METAGENT_NPX_CORRUPT_AFTER_FIRST=1 \
  "$fixture_root/uninstall-probe" "$corrupt_root" corrupt-one,corrupt-two apply
grep -q 'Recovery state:' "$corrupt_output"
test ! -e "$corrupt_root/.agents/skills/corrupt-one"
test -f "$corrupt_root/.agents/skills/corrupt-two/SKILL.md"
corrupt_recovery_metadata="$(rg -l '^skill=corrupt-one$' "$fixture_root/home/Library/Application Support/Metagent/Removed Skills" -g REMOVAL.txt | head -1)"
test -f "$(dirname "$corrupt_recovery_metadata")/after.json"

partial_success_root="$fixture_root/partial-success-corrupt-lock-project"
mkdir -p "$partial_success_root/.agents/skills/partial-success-one" "$partial_success_root/.agents/skills/partial-success-two"
make_skill "$partial_success_root/.agents/skills/partial-success-one" "partial-success-one" "first"
make_skill "$partial_success_root/.agents/skills/partial-success-two" "partial-success-two" "second"
write_pair_lock "$partial_success_root/skills-lock.json" partial-success-one partial-success-two
partial_success_output="$fixture_root/partial-success-corrupt-lock.out"
expect_failure 'partial-success-one' "$partial_success_output" -- \
  env HOME="$fixture_root/home" METAGENT_NPX="$npx_stub" METAGENT_NPX_PARTIAL_SUCCESS_CORRUPT=1 \
  "$fixture_root/uninstall-probe" "$partial_success_root" partial-success-one,partial-success-two apply
test ! -e "$partial_success_root/.agents/skills/partial-success-one"
test -f "$partial_success_root/.agents/skills/partial-success-two/SKILL.md"
grep -q 'partial-success-two' "$partial_success_output"

native_root="$fixture_root/native-uninstall-project"
mkdir -p \
  "$native_root/.agents/skills/native-remove" \
  "$native_root/.claude/skills" \
  "$native_root/.codex/skills/native-remove"
make_skill "$native_root/.agents/skills/native-remove" "native-remove" "native"
make_skill "$native_root/.codex/skills/native-remove" "native-remove" "independent"
ln -s ../../.agents/skills/native-remove "$native_root/.claude/skills/native-remove"
HOME="$fixture_root/home" "$fixture_root/uninstall-probe" "$native_root" native-remove apply >/dev/null
test ! -e "$native_root/.agents/skills/native-remove"
test ! -L "$native_root/.claude/skills/native-remove"
test -f "$native_root/.codex/skills/native-remove/SKILL.md"
native_recovery_metadata="$(rg -l '^skill=native-remove$' "$fixture_root/home/Library/Application Support/Metagent/Removed Skills" -g REMOVAL.txt | head -1)"
test -n "$native_recovery_metadata"
native_recovery_root="$(dirname "$native_recovery_metadata")"
test -f "$native_recovery_root/native-remove/SKILL.md"

rollback_root="$fixture_root/native-uninstall-rollback"
mkdir -p "$rollback_root/.agents/skills/native-rollback" "$rollback_root/.claude/skills"
make_skill "$rollback_root/.agents/skills/native-rollback" "native-rollback" "rollback"
ln -s ../../.agents/skills/native-rollback "$rollback_root/.claude/skills/native-rollback"
chmod 555 "$rollback_root/.claude/skills"
rollback_output="$fixture_root/native-rollback.out"
expect_failure "" "$rollback_output" -- \
  env HOME="$fixture_root/home" "$fixture_root/uninstall-probe" "$rollback_root" native-rollback apply
test -f "$rollback_root/.agents/skills/native-rollback/SKILL.md"
test -L "$rollback_root/.claude/skills/native-rollback"
chmod 755 "$rollback_root/.claude/skills"

global_home="$fixture_root/global-home"
global_xdg="$fixture_root/global-xdg"
mkdir -p "$global_home/.agents/skills/global-managed" "$global_xdg/skills"
make_skill "$global_home/.agents/skills/global-managed" "global-managed" "global"
cat >"$global_xdg/skills/.skill-lock.json" <<'EOF'
{
  "version": 3,
  "skills": {
    "global-managed": {
      "source": "example/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/example/skills.git",
      "skillFolderHash": "global-hash",
      "pluginName": "example"
    }
  }
}
EOF
global_scan="$(HOME="$global_home" XDG_STATE_HOME="$global_xdg" "$swift_helper" skills scan --root "$global_home" --max-depth 0 --json)"
printf '%s\n' "$global_scan" | grep -F '"name" : "global-managed"' >/dev/null
printf '%s\n' "$global_scan" | grep -F '"origin_kind" : "npx-skills"' >/dev/null
global_doctor="$(HOME="$global_home" XDG_STATE_HOME="$global_xdg" "$swift_helper" skills doctor --json)"
printf '%s\n' "$global_doctor" | jq -e '([.issues[] | select(.severity != "OK")] | length) == 0' >/dev/null
global_uninstall_output="$fixture_root/global-uninstall.out"
expect_failure 'npx --yes skills remove global-managed --yes --global' "$global_uninstall_output" -- \
  env HOME="$global_home" XDG_STATE_HOME="$global_xdg" \
  "$fixture_root/uninstall-probe" "$global_home" global-managed refuse
env HOME="$global_home" XDG_STATE_HOME="$global_xdg" \
  "$fixture_root/uninstall-probe" "$global_home" global-managed plan \
  >"$fixture_root/global-uninstall-plan.out" 2>&1
grep -Fq -- 'would remove global-managed through the canonical path managed by skills-cli' \
  "$fixture_root/global-uninstall-plan.out"
test -f "$global_home/.agents/skills/global-managed/SKILL.md"
grep -q '"global-managed"' "$global_xdg/skills/.skill-lock.json"
HOME="$global_home" XDG_STATE_HOME="$global_xdg" METAGENT_NPX="$npx_stub" "$fixture_root/uninstall-probe" "$global_home" global-managed apply >/dev/null
test ! -e "$global_home/.agents/skills/global-managed"
if grep -q '"global-managed"' "$global_xdg/skills/.skill-lock.json"; then
  echo "managed removal left its global lock entry" >&2
  exit 1
fi

mkdir -p \
  "$fixture_root/prune-root/app/.agents/skills/app-skill" \
  "$fixture_root/prune-root/build/generated/.agents/skills/built" \
  "$fixture_root/prune-root/vendor/dependency/.agents/skills/vendored"
make_skill "$fixture_root/prune-root/app/.agents/skills/app-skill" "app-skill" "app"
make_skill "$fixture_root/prune-root/build/generated/.agents/skills/built" "built" "built"
make_skill "$fixture_root/prune-root/vendor/dependency/.agents/skills/vendored" "vendored" "vendored"
prune_scan="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills scan --root "$fixture_root/prune-root" --max-depth 4 --json)"
printf '%s\n' "$prune_scan" | grep -F "app-skill" >/dev/null
if printf '%s\n' "$prune_scan" | grep -F "built" >/dev/null; then
  echo "build skill fixture was treated as a project" >&2
  exit 1
fi
if printf '%s\n' "$prune_scan" | grep -F "vendored" >/dev/null; then
  echo "vendor skill fixture was treated as a project" >&2
  exit 1
fi

missing_root_output="$fixture_root/missing-root.out"
expect_failure "--root requires a value" "$missing_root_output" -- \
  "$swift_helper" skills repair --apply --root

bad_config_flag_output="$fixture_root/bad-config-flag.out"
expect_failure "unknown config show flag: --bogus" "$bad_config_flag_output" -- \
  "$swift_helper" config show --bogus

bad_config_command_output="$fixture_root/bad-config-command.out"
expect_failure "unknown config command: bogus" "$bad_config_command_output" -- \
  "$swift_helper" config bogus

bad_max_depth_home="$fixture_root/bad-max-depth-home"
mkdir -p "$bad_max_depth_home/.config/metagent"
cat >"$bad_max_depth_home/.config/metagent/config.toml" <<EOF
roots = ["$fixture_root/workspace"]
max_depth = 3.5
EOF
bad_max_depth_output="$fixture_root/bad-max-depth.out"
expect_failure "max_depth must be an integer" "$bad_max_depth_output" -- \
  env HOME="$bad_max_depth_home" "$swift_helper" config show --json

install_home="$fixture_root/install-home"
mkdir -p "$install_home/.cargo/bin"
printf -- "#!/usr/bin/env bash\nexit 42\n" >"$install_home/.cargo/bin/metagent"
chmod +x "$install_home/.cargo/bin/metagent"
install_output="$(HOME="$install_home" PATH="$install_home/.cargo/bin:$PATH" "$repo_root/scripts/install-cli.sh")"
printf '%s\n' "$install_output" | grep -F -- "Installed metagent to $install_home/.cargo/bin/metagent" >/dev/null
HOME="$install_home" "$install_home/.cargo/bin/metagent" --help >/dev/null

unreadable_config_home="$fixture_root/unreadable-config-home"
mkdir -p "$unreadable_config_home/.config/metagent/config.toml"
unreadable_config_output="$fixture_root/unreadable-config.out"
expect_failure "failed reading" "$unreadable_config_output" -- \
  env HOME="$unreadable_config_home" "$swift_helper" config show --json

unknown_repair_output="$fixture_root/unknown-repair.out"
expect_failure "unknown repair flag: --rot" "$unknown_repair_output" -- \
  env HOME="$fixture_root/home" "$swift_helper" skills repair --apply --rot "$fixture_root/workspace/child"

repair_project="$fixture_root/repair-project"
mkdir -p "$repair_project/.agents/skills/native-skill"
make_skill "$repair_project/.agents/skills/native-skill" "native-skill" "native"
repair_preview="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills repair --root "$repair_project" --max-depth 0)"
printf '%s\n' "$repair_preview" | grep -F "would create .claude/skills symlink" >/dev/null
test ! -e "$repair_project/.claude/skills"
repair_apply="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills repair --root "$repair_project" --max-depth 0 --apply)"
printf '%s\n' "$repair_apply" | grep -F "repaired: .claude/skills -> ../.agents/skills" >/dev/null
test -L "$repair_project/.claude/skills"
test "$(readlink "$repair_project/.claude/skills")" = "../.agents/skills"
test -f "$repair_project/.claude/skills/native-skill/SKILL.md"
test ! -e "$repair_project/agents.toml"
test ! -e "$repair_project/agents.lock"

repair_home="$fixture_root/repair-home"
mkdir -p "$repair_home/.agents/skills/global-only"
make_skill "$repair_home/.agents/skills/global-only" "global-only" "global"
HOME="$repair_home" "$swift_helper" skills repair --root "$repair_home" --max-depth 0 --apply >/dev/null
test ! -e "$repair_home/.claude/skills"

shared_claude_project="$fixture_root/shared-claude-project"
shared_claude_target="$fixture_root/shared-claude-target"
mkdir -p "$shared_claude_project/.agents/skills/shared-test" "$shared_claude_target"
make_skill "$shared_claude_project/.agents/skills/shared-test" "shared-test" "shared"
ln -s "$shared_claude_target" "$shared_claude_project/.claude"
shared_claude_output="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills repair --root "$shared_claude_project" --max-depth 0 --apply)"
printf '%s\n' "$shared_claude_output" | grep -F "refusing to modify its shared target" >/dev/null
test ! -e "$shared_claude_target/skills"

wrong_link_project="$fixture_root/wrong-link-project"
mkdir -p "$wrong_link_project/.agents/skills/wrong-link-skill" "$wrong_link_project/.claude"
make_skill "$wrong_link_project/.agents/skills/wrong-link-skill" "wrong-link-skill" "wrong link"
ln -s ../somewhere-else "$wrong_link_project/.claude/skills"
wrong_link_preview="$("$swift_helper" skills repair --root "$wrong_link_project" --max-depth 0)"
printf '%s\n' "$wrong_link_preview" | grep -F "would replace wrong .claude/skills symlink" >/dev/null
wrong_link_apply="$("$swift_helper" skills repair --root "$wrong_link_project" --max-depth 0 --apply)"
printf '%s\n' "$wrong_link_apply" | grep -F "repaired: .claude/skills -> ../.agents/skills" >/dev/null
test "$(readlink "$wrong_link_project/.claude/skills")" = "../.agents/skills"

conflict_project="$fixture_root/conflict-project"
mkdir -p "$conflict_project/.agents/skills/canonical-skill" "$conflict_project/.claude/skills/claude-only"
make_skill "$conflict_project/.agents/skills/canonical-skill" "canonical-skill" "canonical"
printf -- "keep me\n" >"$conflict_project/.claude/skills/claude-only/SKILL.md"
conflict_output="$("$swift_helper" skills repair --root "$conflict_project" --max-depth 0 --apply)"
printf '%s\n' "$conflict_output" | grep -F "moved 1 skill(s) into .agents/skills: claude-only" >/dev/null
printf '%s\n' "$conflict_output" | grep -F "repaired: .claude/skills -> ../.agents/skills" >/dev/null
test -L "$conflict_project/.claude/skills"
test "$(readlink "$conflict_project/.claude/skills")" = "../.agents/skills"
test -f "$conflict_project/.agents/skills/claude-only/SKILL.md"
test -f "$conflict_project/.claude/skills/claude-only/SKILL.md"

cat >"$fixture_root/home/.config/metagent/config.toml" <<EOF
roots = ["$fixture_root/default"
EOF
bad_config_output="$fixture_root/bad-config.out"
expect_failure "roots must be a TOML string array" "$bad_config_output" -- \
  env HOME="$fixture_root/home" "$swift_helper" skills repair --apply
test ! -e "$fixture_root/default/.claude/skills"

cat >"$fixture_root/home/.config/metagent/config.toml" <<EOF
roots = [$fixture_root/default]
EOF
bare_array_output="$fixture_root/bare-array.out"
expect_failure "roots must be a TOML string array" "$bare_array_output" -- \
  env HOME="$fixture_root/home" "$swift_helper" skills repair --apply
test ! -e "$fixture_root/default/.claude/skills"

)

usage() {
  cat <<'EOF'
Usage: scripts/verify.sh [--fast|--integration|--release]

Without a lane, runs the complete release gate.
  --fast         Shell syntax, Swift build, and Swift tests
  --integration  Helper smoke checks, MCP stress, and disposable manager fixtures
  --release      App bundle, resources, signatures, and Sparkle archive
EOF
}

lane="all"
case "${1:-}" in
  "")
    ;;
  --fast)
    lane="fast"
    ;;
  --integration)
    lane="integration"
    ;;
  --release)
    lane="release"
    ;;
  --help|-h)
    usage
    exit 0
    ;;
  *)
    echo "Unknown verification lane: $1" >&2
    usage >&2
    exit 2
    ;;
esac

if (( $# > 1 )); then
  echo "Only one verification lane may be selected" >&2
  usage >&2
  exit 2
fi

log_root="${METAGENT_VERIFY_LOG_DIR:-$(mktemp -d /private/tmp/metagent-verify-logs.XXXXXX)}"
keep_logs="${METAGENT_VERIFY_KEEP_LOGS:-0}"
mkdir -p "$log_root"
stage_number=0
swift_built=false

run_stage() {
  local label="$1" timeout_hint="$2"
  shift 2
  local started_at=$SECONDS
  local slug log_file
  stage_number=$((stage_number + 1))
  slug="$(printf '%s' "$label" | tr '[:upper:] ' '[:lower:]-' | tr -cd '[:alnum:]-')"
  log_file="$log_root/$(printf '%02d' "$stage_number")-$slug.log"

  printf '▶ %s' "$label"
  if [[ -n "$timeout_hint" ]]; then
    printf ' · expected %s' "$timeout_hint"
  fi
  printf '\n'

  set +e
  (
    set -e
    "$@"
  ) >"$log_file" 2>&1
  local status=$?
  set -e

  if (( status == 0 )); then
    local warnings
    warnings="$(
      grep -Ei \
        '(^|[[:space:]:])(warning|warnings|skipping|skipped|unsigned)([[:space:]:.]|$)|not suitable for local installation' \
        "$log_file" \
        || true
    )"
    if [[ -n "$warnings" ]]; then
      local warning_count
      warning_count="$(awk 'END { print NR }' <<<"$warnings")"
      printf '⚠ %s · %ss · completed with warnings\n' "$label" "$((SECONDS - started_at))"
      awk 'NR <= 5' <<<"$warnings"
      if (( warning_count > 5 )); then
        printf '… %s more warning(s); rerun with METAGENT_VERIFY_KEEP_LOGS=1 for the full log\n' \
          "$((warning_count - 5))"
      fi
    else
      printf '✓ %s · %ss\n' "$label" "$((SECONDS - started_at))"
    fi
    return
  fi

  printf '✗ %s · failed after %ss\n' "$label" "$((SECONDS - started_at))" >&2
  tail -80 "$log_file" >&2
  printf 'Full log: %s\n' "$log_file" >&2
  return "$status"
}

run_fast_lane() {
  run_stage "Shell syntax" "<5s" verify_shell_syntax
  run_stage "Swift build" "<10s incremental" verify_swift_build
  swift_built=true
  run_stage "Swift tests" "<30s" verify_swift_tests
}

ensure_swift_build() {
  if [[ "$swift_built" == false ]]; then
    run_stage "Swift build prerequisite" "<10s incremental" verify_swift_build
    swift_built=true
  fi
}

run_integration_lane() {
  ensure_swift_build
  run_stage "CLI and analysis smoke checks" "<15s" verify_helper_smoke
  run_stage "MCP protocol and concurrency stress" "<2m" verify_mcp_protocol
  run_stage "Disposable manager fixtures" "<45s" verify_manager_fixtures
}

run_release_lane() {
  run_stage "App bundle and signatures" "<30s incremental" verify_release_bundle
  run_stage "Sparkle update archive" "<15s" verify_update_archive
}

cd "$repo_root"
case "$lane" in
  fast)
    run_fast_lane
    ;;
  integration)
    run_integration_lane
    ;;
  release)
    run_release_lane
    ;;
  all)
    run_fast_lane
    run_integration_lane
    run_release_lane
    ;;
esac

if [[ "$keep_logs" == "1" ]]; then
  printf 'Verification logs: %s\n' "$log_root"
elif [[ -z "${METAGENT_VERIFY_LOG_DIR:-}" ]]; then
  rm -rf "$log_root"
fi

printf 'metagent verification passed (%s lane)\n' "$lane"
