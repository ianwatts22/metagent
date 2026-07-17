#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_source="$repo_root/apps/MetagentMenuBar"
swift_helper="$app_source/.build/debug/metagent"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/metagent-clang-cache}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

cd "$repo_root"
sg scan --config "$repo_root/sgconfig.yml" --filter no-direct-hard-delete --report-style short
bash -n "$repo_root/scripts/generate-menu-bar-assets.sh"
bash -n "$repo_root/scripts/install-menu-bar-app.sh"
bash -n "$repo_root/scripts/dev-menu-bar-app.sh"
bash -n "$repo_root/scripts/install-cli.sh"
bash -n "$repo_root/scripts/build-menu-bar-app.sh"

(
  cd "$app_source"
  swift build --disable-sandbox
)

"$repo_root/scripts/build-menu-bar-app.sh" >/dev/null
plutil -lint "$repo_root/dist/MetagentMenuBar.app/Contents/Info.plist" >/dev/null
test -x "$repo_root/dist/MetagentMenuBar.app/Contents/MacOS/MetagentMenuBar"
test -x "$repo_root/dist/MetagentMenuBar.app/Contents/Helpers/metagent"
"$swift_helper" skills scan --root "$repo_root" --max-depth 3 --json >/dev/null
"$swift_helper" skills doctor --root "$repo_root" --max-depth 3 >/dev/null
"$swift_helper" skills --help >/dev/null
"$swift_helper" config show --json >/dev/null

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
  "$fixture_root/home/.config/metagent" \
  "$fixture_root/old/.agents/skills/old-skill" \
  "$fixture_root/workspace/.agents/skills/workspace-skill" \
  "$fixture_root/workspace/_archive/stale/.agents/skills/archive-skill" \
  "$fixture_root/workspace/child/.agents/skills/child-skill" \
  "$fixture_root/workspace/child/.agents/skills/directory-skill/SKILL.md" \
  "$fixture_root/workspace/child/.agents/skills/child-skill/references/example/.agents/skills/nested-skill" \
  "$fixture_root/default/.agents/skills/default-skill"
printf -- "---\nname: old-skill\ndescription: old\n---\n" >"$fixture_root/old/.agents/skills/old-skill/SKILL.md"
printf -- "---\nname: workspace-skill\ndescription: workspace\n---\n" >"$fixture_root/workspace/.agents/skills/workspace-skill/SKILL.md"
printf -- "---\nname: archive-skill\ndescription: archived\n---\n" >"$fixture_root/workspace/_archive/stale/.agents/skills/archive-skill/SKILL.md"
printf -- "---\nname: child-skill\ndescription: child\n---\n" >"$fixture_root/workspace/child/.agents/skills/child-skill/SKILL.md"
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
printf -- "---\nname: nested-skill\ndescription: nested\n---\n" >"$fixture_root/workspace/child/.agents/skills/child-skill/references/example/.agents/skills/nested-skill/SKILL.md"
printf -- "---\nname: default-skill\ndescription: default\n---\n" >"$fixture_root/default/.agents/skills/default-skill/SKILL.md"
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
grep -q "child-skill" <<<"$fixture_scan"
if grep -q "old-skill" <<<"$fixture_scan"; then
  echo "commented config roots were treated as active" >&2
  exit 1
fi
if grep -q "workspace-skill" <<<"$fixture_scan"; then
  echo "ignored parent workspace was included as a project" >&2
  exit 1
fi
if grep -q "archive-skill" <<<"$fixture_scan"; then
  echo "_archive project was included in skill discovery" >&2
  exit 1
fi
if grep -q "nested-skill" <<<"$fixture_scan"; then
  echo "nested skill fixture was treated as a project" >&2
  exit 1
fi
if grep -q "directory-skill" <<<"$fixture_scan"; then
  echo "SKILL.md directory was treated as a valid skill file" >&2
  exit 1
fi
grep -q '"location" : "claude"' <<<"$fixture_scan"
grep -q '"origin_kind" : "npx-skills"' <<<"$fixture_scan"
grep -q '"source" : "example' <<<"$fixture_scan"

fixture_doctor="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills doctor --root "$fixture_root/workspace" --max-depth 4 --json)"
if grep -q "archive-skill" <<<"$fixture_doctor"; then
  echo "_archive project was included in Doctor findings" >&2
  exit 1
fi
grep -q '"repair_action" : "repair_projection"' <<<"$fixture_doctor"

symlink_ignore_scan="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills scan --root "$fixture_root/workspace" --ignore-project "$fixture_root/workspace-link" --max-depth 0 --json)"
if grep -q "workspace-skill" <<<"$symlink_ignore_scan"; then
  echo "symlinked ignore project path was not honored" >&2
  exit 1
fi

agents_root_scan="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills scan --root "$fixture_root/workspace/.agents" --max-depth 0 --json)"
grep -q "workspace-skill" <<<"$agents_root_scan"

skills_root_scan="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills scan --root "$fixture_root/workspace/.agents/skills" --max-depth 0 --json)"
grep -q "workspace-skill" <<<"$skills_root_scan"

mkdir -p \
  "$fixture_root/home/code_projects/.agents/skills/home-parent" \
  "$fixture_root/home/code_projects/home-child/.agents/skills/home-child"
printf -- "---\nname: home-parent\ndescription: home parent\n---\n" >"$fixture_root/home/code_projects/.agents/skills/home-parent/SKILL.md"
printf -- "---\nname: home-child\ndescription: home child\n---\n" >"$fixture_root/home/code_projects/home-child/.agents/skills/home-child/SKILL.md"
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
swiftc "$app_source/Sources/MetagentCore/MetagentCore.swift" "$home_probe" -lsqlite3 -o "$fixture_root/scan-home-probe"
home_scan="$(HOME="$fixture_root/home" "$fixture_root/scan-home-probe")"
grep -q -- "$normalized_fixture_root/home/code_projects/home-child" <<<"$home_scan"
if grep -qx -- "$normalized_fixture_root/home/code_projects" <<<"$home_scan"; then
  echo "ignored home parent was included in scanHomeSkills" >&2
  exit 1
fi
nested_scan="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills scan --root "$fixture_root/home/code_projects" --max-depth 3 --json)"
grep -q "home-parent" <<<"$nested_scan"
grep -q "home-child" <<<"$nested_scan"

cache_home="$fixture_root/cache-home"
mkdir -p \
  "$cache_home/.config/metagent" \
  "$cache_home/full/.agents/skills/cache-full" \
  "$cache_home/scoped/.agents/skills/cache-scoped"
printf -- "---\nname: cache-full\ndescription: full\n---\n" >"$cache_home/full/.agents/skills/cache-full/SKILL.md"
printf -- "---\nname: cache-scoped\ndescription: scoped\n---\n" >"$cache_home/scoped/.agents/skills/cache-scoped/SKILL.md"
cat >"$cache_home/.config/metagent/config.toml" <<EOF
roots = ["$cache_home/full"]
max_depth = 0
EOF
HOME="$cache_home" "$swift_helper" skills scan --json >/dev/null
HOME="$cache_home" "$swift_helper" skills scan --root "$cache_home/scoped" --max-depth 0 --json >/dev/null
cache_db="$cache_home/Library/Application Support/Metagent/inventory.sqlite"
cache_json="$(sqlite3 "$cache_db" "SELECT json FROM inventory_snapshots WHERE id = 1;")"
grep -q "cache-full" <<<"$cache_json"
if grep -q "cache-scoped" <<<"$cache_json"; then
  echo "scoped scan replaced the shared inventory cache" >&2
  exit 1
fi

uninstall_root="$fixture_root/uninstall-project"
mkdir -p \
  "$uninstall_root/.agents/skills/remove-me" \
  "$uninstall_root/.agents/skills/keep-me" \
  "$uninstall_root/.codex/skills/remove-me" \
  "$uninstall_root/.claude"
printf -- "---\nname: remove-me\ndescription: remove\n---\n" >"$uninstall_root/.agents/skills/remove-me/SKILL.md"
printf -- "---\nname: keep-me\ndescription: keep\n---\n" >"$uninstall_root/.agents/skills/keep-me/SKILL.md"
printf -- "---\nname: remove-me\ndescription: independent codex copy\n---\n" >"$uninstall_root/.codex/skills/remove-me/SKILL.md"
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
cat >"$uninstall_probe" <<'SWIFT'
import Darwin
import Foundation

@main
struct Probe {
    static func main() {
        do {
            let report = try MetagentCore.uninstallSkill(
                projectRoot: CommandLine.arguments[1],
                skillName: CommandLine.arguments[2]
            )
            print(report.lines.joined(separator: "\n"))
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
SWIFT
swiftc "$app_source/Sources/MetagentCore/MetagentCore.swift" "$uninstall_probe" -lsqlite3 -o "$fixture_root/uninstall-probe"
managed_uninstall_output="$fixture_root/managed-uninstall.out"
if HOME="$fixture_root/home" "$fixture_root/uninstall-probe" "$uninstall_root" remove-me >"$managed_uninstall_output" 2>&1; then
  echo "Metagent removed an npx-managed skill directly" >&2
  exit 1
fi
grep -q 'npx skills remove remove-me --yes' "$managed_uninstall_output"
test -f "$uninstall_root/.agents/skills/remove-me/SKILL.md"
test -f "$uninstall_root/.agents/skills/keep-me/SKILL.md"
test -f "$uninstall_root/.codex/skills/remove-me/SKILL.md"
test -L "$uninstall_root/.claude/skills"
grep -q '"remove-me"' "$uninstall_root/skills-lock.json"

native_root="$fixture_root/native-uninstall-project"
mkdir -p \
  "$native_root/.agents/skills/native-remove" \
  "$native_root/.claude/skills" \
  "$native_root/.codex/skills/native-remove"
printf -- "---\nname: native-remove\ndescription: native\n---\n" >"$native_root/.agents/skills/native-remove/SKILL.md"
printf -- "---\nname: native-remove\ndescription: independent\n---\n" >"$native_root/.codex/skills/native-remove/SKILL.md"
ln -s ../../.agents/skills/native-remove "$native_root/.claude/skills/native-remove"
HOME="$fixture_root/home" "$fixture_root/uninstall-probe" "$native_root" native-remove >/dev/null
test ! -e "$native_root/.agents/skills/native-remove"
test ! -L "$native_root/.claude/skills/native-remove"
test -f "$native_root/.codex/skills/native-remove/SKILL.md"
native_recovery_metadata="$(find "$fixture_root/home/Library/Application Support/Metagent/Removed Skills" -name REMOVAL.txt -print -quit)"
test -n "$native_recovery_metadata"
native_recovery_root="$(dirname "$native_recovery_metadata")"
test -f "$native_recovery_root/native-remove/SKILL.md"

rollback_root="$fixture_root/native-uninstall-rollback"
mkdir -p "$rollback_root/.agents/skills/native-rollback" "$rollback_root/.claude/skills"
printf -- "---\nname: native-rollback\ndescription: rollback\n---\n" >"$rollback_root/.agents/skills/native-rollback/SKILL.md"
ln -s ../../.agents/skills/native-rollback "$rollback_root/.claude/skills/native-rollback"
chmod 555 "$rollback_root/.claude/skills"
rollback_output="$fixture_root/native-rollback.out"
if HOME="$fixture_root/home" "$fixture_root/uninstall-probe" "$rollback_root" native-rollback >"$rollback_output" 2>&1; then
  echo "native uninstall unexpectedly wrote through a read-only projection directory" >&2
  exit 1
fi
test -f "$rollback_root/.agents/skills/native-rollback/SKILL.md"
test -L "$rollback_root/.claude/skills/native-rollback"
chmod 755 "$rollback_root/.claude/skills"

global_home="$fixture_root/global-home"
global_xdg="$fixture_root/global-xdg"
mkdir -p "$global_home/.agents/skills/global-managed" "$global_xdg/skills"
printf -- "---\nname: global-managed\ndescription: global\n---\n" >"$global_home/.agents/skills/global-managed/SKILL.md"
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
grep -q '"name" : "global-managed"' <<<"$global_scan"
grep -q '"origin_kind" : "npx-skills"' <<<"$global_scan"
global_uninstall_output="$fixture_root/global-uninstall.out"
if HOME="$global_home" XDG_STATE_HOME="$global_xdg" "$fixture_root/uninstall-probe" "$global_home" global-managed >"$global_uninstall_output" 2>&1; then
  echo "Metagent removed a global npx-managed skill directly" >&2
  exit 1
fi
grep -q 'npx skills remove global-managed --yes --global' "$global_uninstall_output"
test -f "$global_home/.agents/skills/global-managed/SKILL.md"
grep -q '"global-managed"' "$global_xdg/skills/.skill-lock.json"

mkdir -p \
  "$fixture_root/prune-root/app/.agents/skills/app-skill" \
  "$fixture_root/prune-root/build/generated/.agents/skills/built" \
  "$fixture_root/prune-root/vendor/dependency/.agents/skills/vendored"
printf -- "---\nname: app-skill\ndescription: app\n---\n" >"$fixture_root/prune-root/app/.agents/skills/app-skill/SKILL.md"
printf -- "---\nname: built\ndescription: built\n---\n" >"$fixture_root/prune-root/build/generated/.agents/skills/built/SKILL.md"
printf -- "---\nname: vendored\ndescription: vendored\n---\n" >"$fixture_root/prune-root/vendor/dependency/.agents/skills/vendored/SKILL.md"
prune_scan="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills scan --root "$fixture_root/prune-root" --max-depth 4 --json)"
grep -q "app-skill" <<<"$prune_scan"
if grep -q "built" <<<"$prune_scan"; then
  echo "build skill fixture was treated as a project" >&2
  exit 1
fi
if grep -q "vendored" <<<"$prune_scan"; then
  echo "vendor skill fixture was treated as a project" >&2
  exit 1
fi

cat >"$fixture_root/home/.config/metagent/config.toml" <<EOF
roots = ["$fixture_root/workspace"]
max_depth = 3
ignore_projects = ["$fixture_root/workspace"]
EOF

missing_root_output="$fixture_root/missing-root.out"
if "$swift_helper" skills repair --apply --root >"$missing_root_output" 2>&1; then
  echo "missing --root value was accepted" >&2
  exit 1
fi
grep -q -- "--root requires a value" "$missing_root_output"

bad_config_flag_output="$fixture_root/bad-config-flag.out"
if "$swift_helper" config show --bogus >"$bad_config_flag_output" 2>&1; then
  echo "unknown config show flag was accepted" >&2
  exit 1
fi
grep -q -- "unknown config show flag: --bogus" "$bad_config_flag_output"

bad_config_command_output="$fixture_root/bad-config-command.out"
if "$swift_helper" config bogus >"$bad_config_command_output" 2>&1; then
  echo "unknown config command was accepted" >&2
  exit 1
fi
grep -q -- "unknown config command: bogus" "$bad_config_command_output"

bad_morph_command_output="$fixture_root/bad-morph-command.out"
if "$swift_helper" morph-mcp janitor >"$bad_morph_command_output" 2>&1; then
  echo "unknown morph-mcp command was accepted" >&2
  exit 1
fi
grep -q -- "unknown morph-mcp command: janitor" "$bad_morph_command_output"

bad_morph_flag_output="$fixture_root/bad-morph-flag.out"
if "$swift_helper" morph-mcp status --bogus >"$bad_morph_flag_output" 2>&1; then
  echo "unknown morph-mcp status flag was accepted" >&2
  exit 1
fi
grep -q -- "unknown morph-mcp status flag: --bogus" "$bad_morph_flag_output"

fake_ps="$fixture_root/fake-ps"
cat >"$fake_ps" <<'SH'
#!/usr/bin/env bash
echo "ps blocked" >&2
exit 42
SH
chmod +x "$fake_ps"
bad_morph_ps_output="$fixture_root/bad-morph-ps.out"
if METAGENT_PS="$fake_ps" "$swift_helper" morph-mcp status >"$bad_morph_ps_output" 2>&1; then
  echo "failed morph-mcp process inspection exited successfully" >&2
  exit 1
fi
grep -q -- "failed to inspect processes" "$bad_morph_ps_output"
grep -q -- "ps blocked" "$bad_morph_ps_output"

bad_max_depth_home="$fixture_root/bad-max-depth-home"
mkdir -p "$bad_max_depth_home/.config/metagent"
cat >"$bad_max_depth_home/.config/metagent/config.toml" <<EOF
roots = ["$fixture_root/workspace"]
max_depth = 3.5
EOF
bad_max_depth_output="$fixture_root/bad-max-depth.out"
if HOME="$bad_max_depth_home" "$swift_helper" config show --json >"$bad_max_depth_output" 2>&1; then
  echo "malformed max_depth was accepted" >&2
  exit 1
fi
grep -q -- "max_depth must be an integer" "$bad_max_depth_output"

install_home="$fixture_root/install-home"
mkdir -p "$install_home/.cargo/bin"
printf -- "#!/usr/bin/env bash\nexit 42\n" >"$install_home/.cargo/bin/metagent"
chmod +x "$install_home/.cargo/bin/metagent"
install_output="$(HOME="$install_home" PATH="$install_home/.cargo/bin:$PATH" "$repo_root/scripts/install-cli.sh")"
grep -q -- "Installed metagent to $install_home/.cargo/bin/metagent" <<<"$install_output"
HOME="$install_home" "$install_home/.cargo/bin/metagent" --help >/dev/null

unreadable_config_home="$fixture_root/unreadable-config-home"
mkdir -p "$unreadable_config_home/.config/metagent/config.toml"
unreadable_config_output="$fixture_root/unreadable-config.out"
if HOME="$unreadable_config_home" "$swift_helper" config show --json >"$unreadable_config_output" 2>&1; then
  echo "unreadable config was treated as default config" >&2
  exit 1
fi
grep -q -- "failed reading" "$unreadable_config_output"

unknown_repair_output="$fixture_root/unknown-repair.out"
if HOME="$fixture_root/home" "$swift_helper" skills repair --apply --rot "$fixture_root/workspace/child" >"$unknown_repair_output" 2>&1; then
  echo "unknown repair flag was accepted" >&2
  exit 1
fi
grep -q -- "unknown repair flag: --rot" "$unknown_repair_output"

repair_project="$fixture_root/repair-project"
mkdir -p "$repair_project/.agents/skills/native-skill"
printf -- "---\nname: native-skill\ndescription: native\n---\n" >"$repair_project/.agents/skills/native-skill/SKILL.md"
repair_preview="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills repair --root "$repair_project" --max-depth 0)"
grep -q "would create .claude/skills symlink" <<<"$repair_preview"
test ! -e "$repair_project/.claude/skills"
repair_apply="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills repair --root "$repair_project" --max-depth 0 --apply)"
grep -q "repaired: .claude/skills -> ../.agents/skills" <<<"$repair_apply"
test -L "$repair_project/.claude/skills"
test "$(readlink "$repair_project/.claude/skills")" = "../.agents/skills"
test -f "$repair_project/.claude/skills/native-skill/SKILL.md"
test ! -e "$repair_project/agents.toml"
test ! -e "$repair_project/agents.lock"

repair_home="$fixture_root/repair-home"
mkdir -p "$repair_home/.agents/skills/global-only"
printf -- "---\nname: global-only\ndescription: global\n---\n" >"$repair_home/.agents/skills/global-only/SKILL.md"
HOME="$repair_home" "$swift_helper" skills repair --root "$repair_home" --max-depth 0 --apply >/dev/null
test ! -e "$repair_home/.claude/skills"

shared_claude_project="$fixture_root/shared-claude-project"
shared_claude_target="$fixture_root/shared-claude-target"
mkdir -p "$shared_claude_project/.agents/skills/shared-test" "$shared_claude_target"
printf -- "---\nname: shared-test\ndescription: shared\n---\n" >"$shared_claude_project/.agents/skills/shared-test/SKILL.md"
ln -s "$shared_claude_target" "$shared_claude_project/.claude"
shared_claude_output="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills repair --root "$shared_claude_project" --max-depth 0 --apply)"
grep -q "refusing to modify its shared target" <<<"$shared_claude_output"
test ! -e "$shared_claude_target/skills"

wrong_link_project="$fixture_root/wrong-link-project"
mkdir -p "$wrong_link_project/.agents/skills/wrong-link-skill" "$wrong_link_project/.claude"
printf -- "---\nname: wrong-link-skill\ndescription: wrong link\n---\n" >"$wrong_link_project/.agents/skills/wrong-link-skill/SKILL.md"
ln -s ../somewhere-else "$wrong_link_project/.claude/skills"
wrong_link_preview="$("$swift_helper" skills repair --root "$wrong_link_project" --max-depth 0)"
grep -q "would replace wrong .claude/skills symlink" <<<"$wrong_link_preview"
wrong_link_apply="$("$swift_helper" skills repair --root "$wrong_link_project" --max-depth 0 --apply)"
grep -q "repaired: .claude/skills -> ../.agents/skills" <<<"$wrong_link_apply"
test "$(readlink "$wrong_link_project/.claude/skills")" = "../.agents/skills"

conflict_project="$fixture_root/conflict-project"
mkdir -p "$conflict_project/.agents/skills/canonical-skill" "$conflict_project/.claude/skills/claude-only"
printf -- "---\nname: canonical-skill\ndescription: canonical\n---\n" >"$conflict_project/.agents/skills/canonical-skill/SKILL.md"
printf -- "keep me\n" >"$conflict_project/.claude/skills/claude-only/SKILL.md"
conflict_output="$("$swift_helper" skills repair --root "$conflict_project" --max-depth 0 --apply)"
grep -q "manual review: .claude/skills exists and is not a symlink" <<<"$conflict_output"
test ! -L "$conflict_project/.claude/skills"
test -f "$conflict_project/.claude/skills/claude-only/SKILL.md"

cat >"$fixture_root/home/.config/metagent/config.toml" <<EOF
roots = ["$fixture_root/default"
EOF
bad_config_output="$fixture_root/bad-config.out"
if HOME="$fixture_root/home" "$swift_helper" skills repair --apply >"$bad_config_output" 2>&1; then
  echo "malformed config was accepted" >&2
  exit 1
fi
grep -q -- "roots must be a TOML string array" "$bad_config_output"
test ! -e "$fixture_root/default/.claude/skills"

cat >"$fixture_root/home/.config/metagent/config.toml" <<EOF
roots = [$fixture_root/default]
EOF
bare_array_output="$fixture_root/bare-array.out"
if HOME="$fixture_root/home" "$swift_helper" skills repair --apply >"$bare_array_output" 2>&1; then
  echo "bare config array value was accepted" >&2
  exit 1
fi
grep -q -- "roots must be a TOML string array" "$bare_array_output"
test ! -e "$fixture_root/default/.claude/skills"

echo "metagent verification passed"
