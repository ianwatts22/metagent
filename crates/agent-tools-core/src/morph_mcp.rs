use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const JANITOR_LABEL: &str = "com.ianwatts.agent-tools.morph-mcp-janitor";
const LEGACY_JANITOR_LABEL: &str = "com.ianwatts.codex-morphmcp-janitor";
const PROJECT_LOG_BASENAME: &str = "morph-mcp-janitor";
const LEGACY_LOG_BASENAME: &str = "codex-morphmcp-janitor";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MorphMcpAction {
    Status,
    Janitor,
    InstallLaunchAgent,
    MigrateLaunchAgent,
    RetireLegacyLaunchAgent,
    UninstallLaunchAgent,
}

#[derive(Debug, Default)]
pub struct MorphMcpOptions {
    pub program: Option<PathBuf>,
    pub dry_run: bool,
}

#[derive(Debug)]
pub struct MorphMcpReport {
    pub lines: Vec<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MorphKind {
    Node,
    Npm,
}

#[derive(Clone, Debug)]
struct ProcessInfo {
    pid: i32,
    ppid: i32,
    etime: String,
    pcpu: f32,
    command: String,
}

#[derive(Clone, Debug)]
struct Candidate {
    age_sec: u64,
    pid: i32,
    pcpu: f32,
}

#[derive(Debug)]
struct JanitorConfig {
    max_pcpu: f32,
    orphan_min_age_sec: u64,
    orphan_max_kill_per_kind: usize,
    emergency_node_keep: usize,
    emergency_npm_keep: usize,
    emergency_total_keep: usize,
    emergency_min_age_sec: u64,
    emergency_max_kill_per_kind: usize,
    state_dir: PathBuf,
    known_codex_pids_file: PathBuf,
}

impl JanitorConfig {
    fn from_env() -> Self {
        let state_dir = env_path("STATE_DIR")
            .unwrap_or_else(|| home_dir().join(".local/state/agent-tools/morph-mcp-janitor"));
        let known_codex_pids_file = env_path("KNOWN_CODEX_PIDS_FILE")
            .unwrap_or_else(|| state_dir.join("known_codex_pids.txt"));

        Self {
            max_pcpu: 1.0,
            orphan_min_age_sec: 900,
            orphan_max_kill_per_kind: 6,
            emergency_node_keep: 8,
            emergency_npm_keep: 8,
            emergency_total_keep: 16,
            emergency_min_age_sec: 1800,
            emergency_max_kill_per_kind: 4,
            state_dir,
            known_codex_pids_file,
        }
    }
}

pub fn morph_mcp(
    action: MorphMcpAction,
    options: &MorphMcpOptions,
) -> Result<MorphMcpReport, String> {
    match action {
        MorphMcpAction::Status => status(),
        MorphMcpAction::Janitor => janitor(options),
        MorphMcpAction::InstallLaunchAgent => install_launch_agent(options),
        MorphMcpAction::MigrateLaunchAgent => migrate_launch_agent(options),
        MorphMcpAction::RetireLegacyLaunchAgent => retire_legacy_launch_agent(),
        MorphMcpAction::UninstallLaunchAgent => uninstall_launch_agent(),
    }
}

fn status() -> Result<MorphMcpReport, String> {
    let mut lines = Vec::new();

    lines.push("Morph MCP Processes".to_string());
    let processes = process_snapshot()?;
    let mut node_count = 0;
    let mut npm_count = 0;
    let mut codex_owned_count = 0;
    let mut detached_count = 0;
    let mut other_parent_count = 0;
    for process in processes.values() {
        let Some(kind) = morph_kind(&process.command) else {
            continue;
        };
        match kind {
            MorphKind::Node => node_count += 1,
            MorphKind::Npm => npm_count += 1,
        }
        if has_codex_ancestor(process.pid, &processes) {
            codex_owned_count += 1;
        } else if process.ppid == 1 || !processes.contains_key(&process.ppid) {
            detached_count += 1;
        } else {
            other_parent_count += 1;
        }
    }
    lines.push(format!(
        "matching_processes={} node={} npm={}",
        node_count + npm_count,
        node_count,
        npm_count
    ));
    lines.push(format!(
        "ownership codex_owned={} detached={} other_parent={}",
        codex_owned_count, detached_count, other_parent_count
    ));

    lines.push(String::new());
    lines.push("Project LaunchAgent".to_string());
    lines.extend(installed_launch_agent_program_lines(JANITOR_LABEL));
    lines.extend(launch_agent_status_lines(JANITOR_LABEL));

    if legacy_surface_exists() {
        lines.push(String::new());
        lines.push("Legacy LaunchAgent".to_string());
        lines.extend(legacy_surface_lines());
        lines.extend(installed_launch_agent_program_lines(LEGACY_JANITOR_LABEL));
        lines.extend(launch_agent_status_lines(LEGACY_JANITOR_LABEL));
    }

    lines.push(String::new());
    lines.push("Logs".to_string());
    for log_path in status_log_paths() {
        lines.push(format!("--- {}", log_path.display()));
        if log_path.is_file() {
            match tail_lines(&log_path, 5) {
                Ok(tail) if tail.is_empty() => lines.push("(empty)".to_string()),
                Ok(tail) => lines.extend(tail),
                Err(error) => lines.push(format!("failed reading log: {error}")),
            }
        } else {
            lines.push("(missing)".to_string());
        }
    }

    Ok(MorphMcpReport { lines })
}

fn janitor(options: &MorphMcpOptions) -> Result<MorphMcpReport, String> {
    let config = JanitorConfig::from_env();
    let processes = process_snapshot()?;
    let snapshot_epoch = now_epoch();
    let mut lines = Vec::new();
    let mut all_morph_identities = BTreeSet::new();
    let mut codex_owned_identities = BTreeSet::new();
    let known = read_identity_set(&config.known_codex_pids_file)?;

    let mut node_total = 0usize;
    let mut npm_total = 0usize;
    let mut codex_node_total = 0usize;
    let mut codex_npm_total = 0usize;
    let mut orphan_node_candidates = Vec::new();
    let mut orphan_npm_candidates = Vec::new();
    let mut emergency_node_candidates = Vec::new();
    let mut emergency_npm_candidates = Vec::new();

    for process in processes.values() {
        let Some(kind) = morph_kind(&process.command) else {
            continue;
        };

        let age_sec = etime_to_sec(&process.etime);
        let start_epoch = snapshot_epoch.saturating_sub(age_sec);
        let identity = (process.pid, start_epoch);
        all_morph_identities.insert(identity);

        let codex_owned = has_codex_ancestor(process.pid, &processes);
        let detached =
            !codex_owned && (process.ppid == 1 || !processes.contains_key(&process.ppid));
        let known_match = known.contains(&identity);
        let is_idle = process.pcpu <= config.max_pcpu;

        match kind {
            MorphKind::Node => {
                node_total += 1;
                if codex_owned {
                    codex_node_total += 1;
                    codex_owned_identities.insert(identity);
                }
                if detached && known_match && age_sec >= config.orphan_min_age_sec && is_idle {
                    orphan_node_candidates.push(Candidate {
                        age_sec,
                        pid: process.pid,
                        pcpu: process.pcpu,
                    });
                }
                if codex_owned && age_sec >= config.emergency_min_age_sec && is_idle {
                    emergency_node_candidates.push(Candidate {
                        age_sec,
                        pid: process.pid,
                        pcpu: process.pcpu,
                    });
                }
            }
            MorphKind::Npm => {
                npm_total += 1;
                if codex_owned {
                    codex_npm_total += 1;
                    codex_owned_identities.insert(identity);
                }
                if detached && known_match && age_sec >= config.orphan_min_age_sec && is_idle {
                    orphan_npm_candidates.push(Candidate {
                        age_sec,
                        pid: process.pid,
                        pcpu: process.pcpu,
                    });
                }
                if codex_owned && age_sec >= config.emergency_min_age_sec && is_idle {
                    emergency_npm_candidates.push(Candidate {
                        age_sec,
                        pid: process.pid,
                        pcpu: process.pcpu,
                    });
                }
            }
        }
    }

    if node_total == 0 && npm_total == 0 {
        lines.push("no morph-mcp processes found".to_string());
        return Ok(MorphMcpReport { lines });
    }

    if options.dry_run {
        lines.push(log_line(
            "dry-run: did not refresh known Codex-owned morph process state",
        ));
    } else {
        refresh_known_identities(
            &config,
            &known,
            &all_morph_identities,
            &codex_owned_identities,
        )?;
    }

    lines.push(log_line(&format!(
        "matched morph-mcp processes: node={node_total}; npm={npm_total}; codex-owned node={codex_node_total}; npm={codex_npm_total}"
    )));

    if !orphan_node_candidates.is_empty() || !orphan_npm_candidates.is_empty() {
        lines.push(log_line(&format!(
            "orphan candidates: node={}; npm={} (minAge={}s pcpu<={})",
            orphan_node_candidates.len(),
            orphan_npm_candidates.len(),
            config.orphan_min_age_sec,
            config.max_pcpu
        )));
        kill_some(
            orphan_node_candidates.len(),
            &mut orphan_node_candidates,
            "orphan node",
            config.orphan_max_kill_per_kind,
            options.dry_run,
            &mut lines,
        );
        kill_some(
            orphan_npm_candidates.len(),
            &mut orphan_npm_candidates,
            "orphan npm",
            config.orphan_max_kill_per_kind,
            options.dry_run,
            &mut lines,
        );
    }

    let (node_need, npm_need) = emergency_trim_needs(codex_node_total, codex_npm_total, &config);
    let codex_total = codex_node_total + codex_npm_total;

    if node_need > 0 || npm_need > 0 {
        lines.push(log_line(&format!(
            "attached trim: codex-owned node={codex_node_total} (keep {}, need {node_need}); npm={codex_npm_total} (keep {}, need {npm_need}); total={codex_total} (keep {}); minAge={}s pcpu<={}",
            config.emergency_node_keep,
            config.emergency_npm_keep,
            config.emergency_total_keep,
            config.emergency_min_age_sec,
            config.max_pcpu
        )));
        kill_some(
            node_need,
            &mut emergency_node_candidates,
            "attached node",
            config.emergency_max_kill_per_kind,
            options.dry_run,
            &mut lines,
        );
        kill_some(
            npm_need,
            &mut emergency_npm_candidates,
            "attached npm",
            config.emergency_max_kill_per_kind,
            options.dry_run,
            &mut lines,
        );
    }

    if !lines
        .iter()
        .any(|line| line.contains("candidates") || line.contains("attached trim"))
    {
        lines.push(log_line("no eligible cleanup candidates"));
    }

    Ok(MorphMcpReport { lines })
}

fn install_launch_agent(options: &MorphMcpOptions) -> Result<MorphMcpReport, String> {
    let mut lines = Vec::new();
    install_project_launch_agent(options, &mut lines)?;
    Ok(MorphMcpReport { lines })
}

fn migrate_launch_agent(options: &MorphMcpOptions) -> Result<MorphMcpReport, String> {
    let mut lines = Vec::new();
    migrate_legacy_state_if_needed(&mut lines)?;
    install_project_launch_agent(options, &mut lines)?;
    retire_launch_agent(LEGACY_JANITOR_LABEL, &mut lines)?;
    Ok(MorphMcpReport { lines })
}

fn retire_legacy_launch_agent() -> Result<MorphMcpReport, String> {
    let mut lines = Vec::new();
    retire_launch_agent(LEGACY_JANITOR_LABEL, &mut lines)?;
    Ok(MorphMcpReport { lines })
}

fn install_project_launch_agent(
    options: &MorphMcpOptions,
    lines: &mut Vec<String>,
) -> Result<(), String> {
    let plist = launch_agent_plist_path(JANITOR_LABEL);
    let program = program_path(options)?;
    let launch_agents_dir = plist
        .parent()
        .ok_or_else(|| format!("invalid plist path: {}", plist.display()))?;

    fs::create_dir_all(launch_agents_dir)
        .map_err(|error| format!("failed creating {}: {error}", launch_agents_dir.display()))?;

    for log_path in project_janitor_log_paths() {
        if let Some(parent) = log_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| format!("failed creating {}: {error}", parent.display()))?;
        }
    }

    fs::write(&plist, render_launch_agent_plist(&program))
        .map_err(|error| format!("failed writing {}: {error}", plist.display()))?;

    let job = launch_agent_job(JANITOR_LABEL);
    let domain = launch_agent_domain();
    lines.push(format!("wrote {}", plist.display()));

    let _ = Command::new("launchctl").arg("bootout").arg(&job).output();
    lines.extend(run_launchctl(&[
        "bootstrap",
        &domain,
        &plist.display().to_string(),
    ]));
    lines.extend(run_launchctl(&["enable", &job]));
    lines.extend(run_launchctl(&["kickstart", "-k", &job]));
    lines.extend(launch_agent_status_lines(JANITOR_LABEL));
    Ok(())
}

fn uninstall_launch_agent() -> Result<MorphMcpReport, String> {
    let mut lines = Vec::new();
    retire_launch_agent(JANITOR_LABEL, &mut lines)?;
    Ok(MorphMcpReport { lines })
}

fn process_snapshot() -> Result<BTreeMap<i32, ProcessInfo>, String> {
    let output = Command::new("ps")
        .args(["-axo", "pid=,ppid=,etime=,pcpu=,command="])
        .output()
        .map_err(|error| format!("failed running ps: {error}"))?;

    if !output.status.success() {
        return Err(format!(
            "ps failed: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ));
    }

    Ok(parse_processes(&String::from_utf8_lossy(&output.stdout)))
}

fn retire_launch_agent(label: &str, lines: &mut Vec<String>) -> Result<(), String> {
    let plist = launch_agent_plist_path(label);
    let job = launch_agent_job(label);

    lines.extend(run_launchctl(&["bootout", &job]));

    if plist.exists() {
        trash_path(&plist)?;
        lines.push(format!("moved {} to Trash", plist.display()));
    } else {
        lines.push(format!("not installed: {}", plist.display()));
    }

    Ok(())
}

fn migrate_legacy_state_if_needed(lines: &mut Vec<String>) -> Result<(), String> {
    let old_state = legacy_known_codex_pids_file();
    let new_config = JanitorConfig::from_env();
    let new_state = new_config.known_codex_pids_file;

    if !old_state.is_file() {
        lines.push(format!("legacy state missing: {}", old_state.display()));
        return Ok(());
    }

    if let Some(parent) = new_state.parent() {
        fs::create_dir_all(parent)
            .map_err(|error| format!("failed creating {}: {error}", parent.display()))?;
    }

    let mut merged = read_identity_set(&new_state)?;
    let original_len = merged.len();
    let legacy = read_identity_set(&old_state)?;
    merged.extend(legacy);
    let added = merged.len().saturating_sub(original_len);
    write_identity_set(&new_state, merged)?;

    lines.push(format!(
        "merged legacy state {} into {} (added {})",
        old_state.display(),
        new_state.display(),
        added
    ));

    Ok(())
}

fn parse_processes(text: &str) -> BTreeMap<i32, ProcessInfo> {
    let mut processes = BTreeMap::new();
    for line in text.lines() {
        if let Some(process) = parse_process_line(line) {
            processes.insert(process.pid, process);
        }
    }
    processes
}

fn parse_process_line(line: &str) -> Option<ProcessInfo> {
    let (pid, rest) = take_token(line.trim_start())?;
    let (ppid, rest) = take_token(rest)?;
    let (etime, rest) = take_token(rest)?;
    let (pcpu, command) = take_token(rest)?;

    Some(ProcessInfo {
        pid: pid.parse().ok()?,
        ppid: ppid.parse().ok()?,
        etime: etime.to_string(),
        pcpu: pcpu.parse().ok()?,
        command: command.trim_start().to_string(),
    })
}

fn take_token(input: &str) -> Option<(&str, &str)> {
    let trimmed = input.trim_start();
    if trimmed.is_empty() {
        return None;
    }
    let end = trimmed.find(char::is_whitespace).unwrap_or(trimmed.len());
    Some((&trimmed[..end], &trimmed[end..]))
}

fn morph_kind(command: &str) -> Option<MorphKind> {
    let command = command.trim();
    if command_starts_with_executable(command, "node")
        && (command.ends_with("morph-mcp")
            || command.contains("/morph-mcp ")
            || command.contains("/morph-mcp\t"))
    {
        return Some(MorphKind::Node);
    }
    if command_starts_with_executable(command, "npm")
        && command_remainder(command).starts_with("exec @morphllm/morphmcp")
    {
        return Some(MorphKind::Npm);
    }
    None
}

fn command_starts_with_executable(command: &str, executable: &str) -> bool {
    let Some((first, _)) = split_command(command) else {
        return false;
    };
    Path::new(first)
        .file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| name == executable)
}

fn command_remainder(command: &str) -> &str {
    split_command(command).map(|(_, rest)| rest).unwrap_or("")
}

fn split_command(command: &str) -> Option<(&str, &str)> {
    let trimmed = command.trim_start();
    if trimmed.is_empty() {
        return None;
    }
    let end = trimmed.find(char::is_whitespace).unwrap_or(trimmed.len());
    Some((&trimmed[..end], trimmed[end..].trim_start()))
}

fn emergency_trim_needs(
    codex_node_total: usize,
    codex_npm_total: usize,
    config: &JanitorConfig,
) -> (usize, usize) {
    let mut node_need = codex_node_total.saturating_sub(config.emergency_node_keep);
    let mut npm_need = codex_npm_total.saturating_sub(config.emergency_npm_keep);
    let total_need =
        (codex_node_total + codex_npm_total).saturating_sub(config.emergency_total_keep);
    let additional_total_need = total_need.saturating_sub(node_need + npm_need);

    if additional_total_need > 0 {
        let node_slack = codex_node_total as isize - config.emergency_node_keep as isize;
        let npm_slack = codex_npm_total as isize - config.emergency_npm_keep as isize;
        if node_slack >= npm_slack {
            node_need += additional_total_need;
        } else {
            npm_need += additional_total_need;
        }
    }

    (node_need, npm_need)
}

fn has_codex_ancestor(pid: i32, processes: &BTreeMap<i32, ProcessInfo>) -> bool {
    let mut current = pid;
    let mut guard = 0;
    while let Some(process) = processes.get(&current) {
        if is_codex_command(&process.command) {
            return true;
        }
        if process.ppid == 1 || !processes.contains_key(&process.ppid) {
            return false;
        }
        current = process.ppid;
        guard += 1;
        if guard > 200 {
            return false;
        }
    }
    false
}

fn is_codex_command(command: &str) -> bool {
    command.contains("Codex.app/Contents/MacOS/Codex")
        || command.contains("Codex.app/Contents/Resources/codex app-server")
}

fn etime_to_sec(etime: &str) -> u64 {
    let mut days = 0u64;
    let mut rest = etime.trim();
    if let Some((left, right)) = rest.split_once('-') {
        days = left.parse().unwrap_or(0);
        rest = right;
    }

    let parts: Vec<u64> = rest
        .split(':')
        .map(|part| part.parse().unwrap_or(0))
        .collect();
    let seconds = match parts.as_slice() {
        [hours, minutes, seconds] => hours * 3600 + minutes * 60 + seconds,
        [minutes, seconds] => minutes * 60 + seconds,
        [seconds] => *seconds,
        _ => 0,
    };
    days * 86_400 + seconds
}

fn read_identity_set(path: &Path) -> Result<BTreeSet<(i32, u64)>, String> {
    let mut identities = BTreeSet::new();
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(identities),
        Err(error) => return Err(format!("failed reading {}: {error}", path.display())),
    };

    for line in text.lines() {
        let mut parts = line.split_whitespace();
        let Some(pid) = parts.next().and_then(|value| value.parse().ok()) else {
            continue;
        };
        let Some(start_epoch) = parts.next().and_then(|value| value.parse().ok()) else {
            continue;
        };
        identities.insert((pid, start_epoch));
    }
    Ok(identities)
}

fn refresh_known_identities(
    config: &JanitorConfig,
    known: &BTreeSet<(i32, u64)>,
    all_morph_identities: &BTreeSet<(i32, u64)>,
    codex_owned_identities: &BTreeSet<(i32, u64)>,
) -> Result<(), String> {
    fs::create_dir_all(&config.state_dir)
        .map_err(|error| format!("failed creating {}: {error}", config.state_dir.display()))?;

    let mut refreshed = BTreeSet::new();
    for identity in codex_owned_identities {
        refreshed.insert(*identity);
    }
    for identity in known {
        if all_morph_identities.contains(identity) {
            refreshed.insert(*identity);
        }
    }

    write_identity_set(&config.known_codex_pids_file, refreshed)
}

fn write_identity_set(path: &Path, identities: BTreeSet<(i32, u64)>) -> Result<(), String> {
    let mut text = String::new();
    for (pid, start_epoch) in identities {
        text.push_str(&format!("{pid} {start_epoch}\n"));
    }
    fs::write(path, text).map_err(|error| format!("failed writing {}: {error}", path.display()))
}

fn kill_some(
    need: usize,
    candidates: &mut [Candidate],
    label: &str,
    max_kills: usize,
    dry_run: bool,
    lines: &mut Vec<String>,
) {
    if need == 0 {
        return;
    }
    if candidates.is_empty() {
        lines.push(log_line(&format!("no eligible {label} candidates")));
        return;
    }

    let kill_count = need.min(max_kills).min(candidates.len());
    candidates.sort_by(|left, right| {
        right
            .age_sec
            .cmp(&left.age_sec)
            .then_with(|| left.pcpu.total_cmp(&right.pcpu))
    });
    let pids: Vec<i32> = candidates
        .iter()
        .take(kill_count)
        .map(|item| item.pid)
        .collect();
    let verb = if dry_run { "would kill" } else { "killing" };
    lines.push(log_line(&format!(
        "{verb} {label} pids: {}",
        join_pids(&pids)
    )));

    if dry_run {
        return;
    }

    let pid_args: Vec<String> = pids.iter().map(ToString::to_string).collect();
    let _ = Command::new("kill")
        .arg("-TERM")
        .arg("--")
        .args(&pid_args)
        .output();
    thread::sleep(Duration::from_millis(250));

    for pid in pids {
        if process_exists(pid) {
            let _ = Command::new("kill")
                .arg("-KILL")
                .arg(pid.to_string())
                .output();
        }
    }
}

fn process_exists(pid: i32) -> bool {
    Command::new("ps")
        .arg("-p")
        .arg(pid.to_string())
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn trash_path(path: &Path) -> Result<(), String> {
    let output = Command::new("/usr/bin/trash")
        .arg(path)
        .output()
        .map_err(|error| format!("failed launching trash for {}: {error}", path.display()))?;
    if output.status.success() {
        return Ok(());
    }
    Err(format!(
        "trash failed for {}: {}{}",
        path.display(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    ))
}

fn join_pids(pids: &[i32]) -> String {
    pids.iter()
        .map(ToString::to_string)
        .collect::<Vec<_>>()
        .join(" ")
}

fn render_launch_agent_plist(program: &Path) -> String {
    let logs = project_janitor_log_paths();
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{program}</string>
    <string>morph-mcp</string>
    <string>janitor</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>1800</integer>
  <key>StandardOutPath</key>
  <string>{stdout}</string>
  <key>StandardErrorPath</key>
  <string>{stderr}</string>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LimitLoadToSessionType</key>
  <array>
    <string>Aqua</string>
  </array>
</dict>
</plist>
"#,
        label = xml_escape(JANITOR_LABEL),
        program = xml_escape(&program.display().to_string()),
        stdout = xml_escape(&logs[0].display().to_string()),
        stderr = xml_escape(&logs[1].display().to_string())
    )
}

fn launch_agent_status_lines(label: &str) -> Vec<String> {
    let job = launch_agent_job(label);
    let output = Command::new("launchctl").arg("print").arg(&job).output();
    match output {
        Ok(output) if output.status.success() => {
            let text = String::from_utf8_lossy(&output.stdout);
            let mut lines = vec![format!("loaded: {job}")];
            for line in text.lines() {
                let trimmed = line.trim();
                if trimmed.contains("path =")
                    || trimmed.contains("state =")
                    || trimmed.contains("last exit code =")
                    || trimmed.contains("runs =")
                    || trimmed.contains("stdout path =")
                    || trimmed.contains("stderr path =")
                {
                    lines.push(trimmed.to_string());
                }
                if lines.len() >= 16 {
                    break;
                }
            }
            lines
        }
        Ok(output) => vec![
            format!(
                "not loaded: {job}; {}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            )
            .trim()
            .to_string(),
        ],
        Err(error) => vec![format!("launchctl unavailable for {job}: {error}")],
    }
}

fn installed_launch_agent_program_lines(label: &str) -> Vec<String> {
    let plist = launch_agent_plist_path(label);
    let Ok(text) = fs::read_to_string(&plist) else {
        return vec![format!("plist missing: {}", plist.display())];
    };
    if text.contains("<string>morph-mcp</string>") && text.contains("<string>janitor</string>") {
        return vec!["program: agent-tools morph-mcp janitor".to_string()];
    }
    if text.contains("codex-morphmcp-janitor") {
        return vec!["program: legacy codex-morphmcp-janitor script".to_string()];
    }
    vec!["program: unknown janitor command".to_string()]
}

fn legacy_surface_exists() -> bool {
    launch_agent_plist_path(LEGACY_JANITOR_LABEL).exists()
        || legacy_entrypoint_path().exists()
        || legacy_known_codex_pids_file().exists()
        || legacy_janitor_log_paths().iter().any(|path| path.exists())
        || launch_agent_loaded(LEGACY_JANITOR_LABEL)
}

fn legacy_surface_lines() -> Vec<String> {
    let mut lines = Vec::new();
    let entrypoint = legacy_entrypoint_path();
    if entrypoint.exists() {
        if is_symlink(&entrypoint) {
            match fs::read_link(&entrypoint) {
                Ok(target) => lines.push(format!(
                    "legacy entrypoint: {} -> {}",
                    entrypoint.display(),
                    target.display()
                )),
                Err(error) => lines.push(format!(
                    "legacy entrypoint target unreadable: {}: {error}",
                    entrypoint.display()
                )),
            }
        } else {
            lines.push(format!("legacy entrypoint: {}", entrypoint.display()));
        }
    }
    lines
}

fn launch_agent_loaded(label: &str) -> bool {
    Command::new("launchctl")
        .arg("print")
        .arg(launch_agent_job(label))
        .output()
        .map(|output| output.status.success())
        .unwrap_or(false)
}

fn run_launchctl(args: &[&str]) -> Vec<String> {
    let output = Command::new("launchctl").args(args).output();
    let command = format!("launchctl {}", args.join(" "));
    match output {
        Ok(output) if output.status.success() => vec![format!("{command}: ok")],
        Ok(output) => vec![
            format!(
                "{command}: {}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            )
            .trim()
            .to_string(),
        ],
        Err(error) => vec![format!("{command}: {error}")],
    }
}

fn tail_lines(path: &Path, count: usize) -> Result<Vec<String>, String> {
    let text = fs::read_to_string(path)
        .map_err(|error| format!("failed reading {}: {error}", path.display()))?;
    let mut lines: Vec<String> = text
        .lines()
        .rev()
        .take(count)
        .map(ToOwned::to_owned)
        .collect();
    lines.reverse();
    Ok(lines)
}

fn status_log_paths() -> Vec<PathBuf> {
    let mut paths = Vec::new();
    paths.extend(project_janitor_log_paths());
    paths.extend(
        legacy_janitor_log_paths()
            .into_iter()
            .filter(|path| path.exists()),
    );
    paths
}

fn project_janitor_log_paths() -> [PathBuf; 2] {
    let logs_dir = home_dir().join("Library/Logs/agent-tools");
    [
        logs_dir.join(format!("{PROJECT_LOG_BASENAME}.out.log")),
        logs_dir.join(format!("{PROJECT_LOG_BASENAME}.err.log")),
    ]
}

fn legacy_janitor_log_paths() -> [PathBuf; 2] {
    [
        home_dir().join(format!("Library/Logs/{LEGACY_LOG_BASENAME}.log")),
        home_dir().join(format!("Library/Logs/{LEGACY_LOG_BASENAME}.err.log")),
    ]
}

fn launch_agent_plist_path(label: &str) -> PathBuf {
    home_dir()
        .join("Library/LaunchAgents")
        .join(format!("{label}.plist"))
}

fn launch_agent_domain() -> String {
    format!("gui/{}", unsafe { libc_getuid() })
}

fn launch_agent_job(label: &str) -> String {
    format!("{}/{}", launch_agent_domain(), label)
}

fn legacy_known_codex_pids_file() -> PathBuf {
    home_dir().join(".local/state/codex-morphmcp-janitor/known_codex_pids.txt")
}

fn legacy_entrypoint_path() -> PathBuf {
    home_dir().join(".local/bin/codex-morphmcp-janitor")
}

fn program_path(options: &MorphMcpOptions) -> Result<PathBuf, String> {
    if let Some(program) = &options.program {
        return Ok(expand_tilde(program));
    }
    env::current_exe().map_err(|error| format!("failed resolving current executable: {error}"))
}

fn expand_tilde(path: &Path) -> PathBuf {
    let Some(path_str) = path.to_str() else {
        return path.to_path_buf();
    };
    if path_str == "~" {
        return home_dir();
    }
    if let Some(rest) = path_str.strip_prefix("~/") {
        return home_dir().join(rest);
    }
    path.to_path_buf()
}

fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn env_path(name: &str) -> Option<PathBuf> {
    env::var_os(name).map(PathBuf::from)
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
}

fn log_line(message: &str) -> String {
    format!("[{}] {message}", timestamp())
}

fn timestamp() -> String {
    let output = Command::new("date").arg("+%Y-%m-%d %H:%M:%S%z").output();
    if let Ok(output) = output
        && output.status.success()
    {
        return String::from_utf8_lossy(&output.stdout).trim().to_string();
    }
    now_epoch().to_string()
}

fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

unsafe fn libc_getuid() -> u32 {
    unsafe extern "C" {
        fn getuid() -> u32;
    }
    unsafe { getuid() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_ps_elapsed_time() {
        assert_eq!(etime_to_sec("01:02"), 62);
        assert_eq!(etime_to_sec("03:04:05"), 11_045);
        assert_eq!(etime_to_sec("2-03:04:05"), 183_845);
    }

    #[test]
    fn detects_morph_process_kinds() {
        assert_eq!(
            morph_kind("node /private/tmp/x/node_modules/.bin/morph-mcp"),
            Some(MorphKind::Node)
        );
        assert_eq!(
            morph_kind("npm exec @morphllm/morphmcp -- --stdio"),
            Some(MorphKind::Npm)
        );
        assert_eq!(
            morph_kind("/opt/homebrew/bin/node /tmp/node_modules/.bin/morph-mcp"),
            Some(MorphKind::Node)
        );
        assert_eq!(
            morph_kind("/opt/homebrew/bin/npm exec @morphllm/morphmcp"),
            Some(MorphKind::Npm)
        );
        assert_eq!(morph_kind("node /tmp/not-morph"), None);
    }

    #[test]
    fn parses_process_line_with_command_spaces() {
        let process =
            parse_process_line("  123  45 01:02  0.0 node /tmp/some dir/morph-mcp --flag")
                .expect("process");
        assert_eq!(process.pid, 123);
        assert_eq!(process.ppid, 45);
        assert_eq!(process.etime, "01:02");
        assert_eq!(process.command, "node /tmp/some dir/morph-mcp --flag");
    }

    #[test]
    fn detects_codex_ancestry() {
        let processes = parse_processes(
            "1 0 01:00 0.0 launchd\n\
             10 1 01:00 0.0 /Applications/Codex.app/Contents/Resources/codex app-server\n\
             20 10 01:00 0.0 npm exec @morphllm/morphmcp\n",
        );
        assert!(has_codex_ancestor(20, &processes));
    }

    #[test]
    fn launch_agent_plist_calls_morph_janitor_command() {
        let plist = render_launch_agent_plist(Path::new("/Users/ianwatts/.cargo/bin/agent-tools"));
        assert!(plist.contains("<string>/Users/ianwatts/.cargo/bin/agent-tools</string>"));
        assert!(plist.contains("<string>morph-mcp</string>"));
        assert!(plist.contains("<string>janitor</string>"));
        assert!(plist.contains(JANITOR_LABEL));
        assert!(!plist.contains("EMERGENCY_NODE_KEEP"));
        assert!(!plist.contains("ORPHAN_MIN_AGE_SEC"));
    }

    #[test]
    fn emergency_trim_needs_do_not_double_count_total_threshold() {
        let config = JanitorConfig {
            max_pcpu: 1.0,
            orphan_min_age_sec: 900,
            orphan_max_kill_per_kind: 6,
            emergency_node_keep: 8,
            emergency_npm_keep: 8,
            emergency_total_keep: 16,
            emergency_min_age_sec: 1800,
            emergency_max_kill_per_kind: 4,
            state_dir: PathBuf::from("/tmp/state"),
            known_codex_pids_file: PathBuf::from("/tmp/state/known.txt"),
        };

        assert_eq!(emergency_trim_needs(20, 8, &config), (12, 0));
        assert_eq!(emergency_trim_needs(9, 9, &config), (1, 1));
        assert_eq!(emergency_trim_needs(8, 20, &config), (0, 12));
    }
}
