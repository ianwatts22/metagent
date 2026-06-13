#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_source="$repo_root/apps/MetagentMenuBar"
swift_helper="$app_source/.build/debug/metagent"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/private/tmp/metagent-clang-cache}"

cd "$repo_root"
sg scan --config "$repo_root/sgconfig.yml" --filter no-direct-hard-delete --report-style short
bash -n "$repo_root/scripts/generate-menu-bar-assets.sh"
bash -n "$repo_root/scripts/install-menu-bar-app.sh"
bash -n "$repo_root/scripts/install-cli.sh"
bash -n "$repo_root/scripts/build-menu-bar-app.sh"

(
  cd "$app_source"
  swift build
)

"$repo_root/scripts/build-menu-bar-app.sh" >/dev/null
plutil -lint "$repo_root/dist/MetagentMenuBar.app/Contents/Info.plist" >/dev/null
test -x "$repo_root/dist/MetagentMenuBar.app/Contents/MacOS/MetagentMenuBar"
test -x "$repo_root/dist/MetagentMenuBar.app/Contents/Helpers/metagent"
"$swift_helper" skills scan --root "$repo_root" --max-depth 3 --json >/dev/null
"$swift_helper" skills doctor --root "$repo_root" --max-depth 3 >/dev/null
"$swift_helper" skills --help >/dev/null
"$swift_helper" config show --json >/dev/null
"$swift_helper" launch-agent --help >/dev/null
"$swift_helper" launch-agent status >/dev/null

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
  "$fixture_root/workspace/child/.agents/skills/child-skill" \
  "$fixture_root/workspace/child/.agents/skills/directory-skill/SKILL.md" \
  "$fixture_root/workspace/child/.agents/skills/child-skill/references/example/.agents/skills/nested-skill" \
  "$fixture_root/default/.agents/skills/default-skill"
printf -- "---\nname: old-skill\ndescription: old\n---\n" >"$fixture_root/old/.agents/skills/old-skill/SKILL.md"
printf -- "---\nname: workspace-skill\ndescription: workspace\n---\n" >"$fixture_root/workspace/.agents/skills/workspace-skill/SKILL.md"
printf -- "---\nname: child-skill\ndescription: child\n---\n" >"$fixture_root/workspace/child/.agents/skills/child-skill/SKILL.md"
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
if grep -q "nested-skill" <<<"$fixture_scan"; then
  echo "nested skill fixture was treated as a project" >&2
  exit 1
fi
if grep -q "directory-skill" <<<"$fixture_scan"; then
  echo "SKILL.md directory was treated as a valid skill file" >&2
  exit 1
fi
grep -q '"location" : "claude"' <<<"$fixture_scan"

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
if "$swift_helper" skills sync --apply --root >"$missing_root_output" 2>&1; then
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

bad_launch_output="$fixture_root/bad-launch.out"
if "$swift_helper" launch-agent status --bogus >"$bad_launch_output" 2>&1; then
  echo "unknown launch-agent flag was accepted" >&2
  exit 1
fi
grep -q -- "unknown launch-agent flag: --bogus" "$bad_launch_output"

missing_launch_output="$fixture_root/missing-launch.out"
if "$swift_helper" launch-agent install --program >"$missing_launch_output" 2>&1; then
  echo "missing launch-agent flag value was accepted" >&2
  exit 1
fi
grep -q -- "--program requires a value" "$missing_launch_output"

negative_launch_output="$fixture_root/negative-launch.out"
if HOME="$fixture_root/negative-launch-home" "$swift_helper" launch-agent install --interval -300 >"$negative_launch_output" 2>&1; then
  echo "negative launch-agent interval was accepted" >&2
  exit 1
fi
grep -q -- "--interval must be a positive integer" "$negative_launch_output"

launch_home="$fixture_root/launch-home"
legacy_plist="$launch_home/Library/LaunchAgents/com.ianwatts.agent-tools.skills-sync.plist"
new_plist="$launch_home/Library/LaunchAgents/com.ianwatts.metagent.skills-sync.plist"
mkdir -p "$(dirname "$legacy_plist")"
printf -- "<plist/>\n" >"$legacy_plist"
fake_launchctl="$fixture_root/fake-launchctl"
cat >"$fake_launchctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${METAGENT_FAKE_LAUNCHCTL_LOG:?}"
exit 0
SH
chmod +x "$fake_launchctl"
fake_launchctl_log="$fixture_root/fake-launchctl.log"
METAGENT_FAKE_LAUNCHCTL_LOG="$fake_launchctl_log" METAGENT_LAUNCHCTL="$fake_launchctl" HOME="$launch_home" "$swift_helper" launch-agent install --interval 999 >/dev/null
grep -q -- "<integer>999</integer>" "$new_plist"
grep -q -- "<string>$swift_helper</string>" "$new_plist"
test ! -e "$legacy_plist"
launch_domain="gui/$(id -u)"
grep -Fxq -- "bootout $launch_domain/com.ianwatts.agent-tools.skills-sync" "$fake_launchctl_log"
grep -Fxq -- "bootout $launch_domain/com.ianwatts.metagent.skills-sync" "$fake_launchctl_log"
grep -Fxq -- "bootstrap $launch_domain $new_plist" "$fake_launchctl_log"
: >"$fake_launchctl_log"
METAGENT_FAKE_LAUNCHCTL_LOG="$fake_launchctl_log" METAGENT_LAUNCHCTL="$fake_launchctl" HOME="$launch_home" "$swift_helper" launch-agent uninstall >/dev/null
test ! -e "$new_plist"
grep -Fxq -- "bootout $launch_domain/com.ianwatts.metagent.skills-sync" "$fake_launchctl_log"

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

unknown_sync_output="$fixture_root/unknown-sync.out"
if HOME="$fixture_root/home" "$swift_helper" skills sync --apply --no-dotagents --rot "$fixture_root/workspace/child" >"$unknown_sync_output" 2>&1; then
  echo "unknown sync flag was accepted" >&2
  exit 1
fi
grep -q -- "unknown sync flag: --rot" "$unknown_sync_output"
test ! -f "$fixture_root/workspace/child/agents.toml"

cat >"$fixture_root/workspace/child/agents.toml" <<EOF
version = 1

[[skills]]
name = "missing-skill"
source = "path:.agents/skills/missing-skill"
EOF
doctor_output="$("$swift_helper" skills doctor --root "$fixture_root/workspace/child" --max-depth 1)"
grep -q "on-disk skill not declared" <<<"$doctor_output"
grep -q "declares missing skill folder: missing-skill" <<<"$doctor_output"

mkdir -p "$fixture_root/config-only"
cat >"$fixture_root/config-only/agents.toml" <<EOF
version = 1

[[skills]]
name = "config-only-skill"
source = "path:.agents/skills/config-only-skill"
EOF
config_only_doctor="$("$swift_helper" skills doctor --root "$fixture_root/config-only" --max-depth 0)"
grep -q "has no valid .agents skills" <<<"$config_only_doctor"
grep -q "declares missing skill folder: config-only-skill" <<<"$config_only_doctor"

mkdir -p "$fixture_root/nested-config/.agents"
cat >"$fixture_root/nested-config/.agents/agents.toml" <<EOF
version = 1

[[skills]]
name = "nested-config-skill"
source = "path:.agents/skills/nested-config-skill"
EOF
nested_config_doctor="$("$swift_helper" skills doctor --root "$fixture_root/nested-config/.agents" --max-depth 1)"
grep -q ".agents/agents.toml exists" <<<"$nested_config_doctor"
grep -q "declares missing skill folder: nested-config-skill" <<<"$nested_config_doctor"

nested_retire_project="$fixture_root/nested-retire"
mkdir -p "$nested_retire_project/.agents/skills/nested-retire-skill"
printf -- "---\nname: nested-retire-skill\ndescription: nested retire\n---\n" >"$nested_retire_project/.agents/skills/nested-retire-skill/SKILL.md"
cat >"$nested_retire_project/.agents/agents.toml" <<EOF
version = 1

[[skills]]
name = "legacy-nested-skill"
source = "path:.agents/skills/legacy-nested-skill"
EOF
nested_retire_dry_run="$("$swift_helper" skills sync --root "$nested_retire_project" --max-depth 0 --no-dotagents)"
grep -q "would move ignored nested config to" <<<"$nested_retire_dry_run"
test -f "$nested_retire_project/.agents/agents.toml"
nested_retire_apply="$("$swift_helper" skills sync --root "$nested_retire_project" --max-depth 0 --apply --no-dotagents)"
grep -q "moved ignored nested config to" <<<"$nested_retire_apply"
test ! -f "$nested_retire_project/.agents/agents.toml"
nested_retire_backup="$(find "$nested_retire_project/.agents" -maxdepth 1 -name 'agents.toml.bak-metagent-*' -print -quit)"
test -n "$nested_retire_backup"
grep -q "legacy-nested-skill" "$nested_retire_backup"
grep -q 'name = "nested-retire-skill"' "$nested_retire_project/agents.toml"

mkdir -p "$fixture_root/rewrite-project/.agents/skills/rewrite-skill"
printf -- "---\nname: rewrite-skill\ndescription: rewrite\n---\n" >"$fixture_root/rewrite-project/.agents/skills/rewrite-skill/SKILL.md"
printf -- "custom config\n" >"$fixture_root/rewrite-project/agents.toml"
rewrite_output="$(HOME="$fixture_root/no-config-home" "$swift_helper" skills sync --root "$fixture_root/rewrite-project" --max-depth 0 --apply --rewrite-agents-toml --no-dotagents)"
grep -q "backed up existing agents.toml" <<<"$rewrite_output"
backup_file="$(find "$fixture_root/rewrite-project" -maxdepth 1 -name 'agents.toml.bak-metagent-*' -print -quit)"
test -n "$backup_file"
grep -q "custom config" "$backup_file"
grep -q 'name = "rewrite-skill"' "$fixture_root/rewrite-project/agents.toml"

mkdir -p "$fixture_root/dotagents-project/.agents/skills/dotagents-skill" "$fixture_root/fake-bin"
printf -- "---\nname: dotagents-skill\ndescription: dotagents\n---\n" >"$fixture_root/dotagents-project/.agents/skills/dotagents-skill/SKILL.md"
cat >"$fixture_root/fake-bin/npx" <<'SH'
#!/usr/bin/env bash
printf 'dotagents stdout\n'
printf 'dotagents stderr\n' >&2
exit 0
SH
chmod +x "$fixture_root/fake-bin/npx"
dotagents_output="$(PATH="$fixture_root/fake-bin:$PATH" HOME="$fixture_root/no-config-home" "$swift_helper" skills sync --root "$fixture_root/dotagents-project" --max-depth 0 --apply)"
grep -q "dotagents: synced" <<<"$dotagents_output"
grep -q "dotagents: dotagents stdout" <<<"$dotagents_output"
grep -q "warning: dotagents: dotagents stderr" <<<"$dotagents_output"

cat >"$fixture_root/home/.config/metagent/config.toml" <<EOF
roots = ["$fixture_root/default"
EOF
bad_config_output="$fixture_root/bad-config.out"
if HOME="$fixture_root/home" "$swift_helper" skills sync --apply --no-dotagents >"$bad_config_output" 2>&1; then
  echo "malformed config was accepted" >&2
  exit 1
fi
grep -q -- "roots must be a TOML string array" "$bad_config_output"
test ! -f "$fixture_root/default/agents.toml"

cat >"$fixture_root/home/.config/metagent/config.toml" <<EOF
roots = [$fixture_root/default]
EOF
bare_array_output="$fixture_root/bare-array.out"
if HOME="$fixture_root/home" "$swift_helper" skills sync --apply --no-dotagents >"$bare_array_output" 2>&1; then
  echo "bare config array value was accepted" >&2
  exit 1
fi
grep -q -- "roots must be a TOML string array" "$bare_array_output"
test ! -f "$fixture_root/default/agents.toml"

echo "metagent verification passed"
