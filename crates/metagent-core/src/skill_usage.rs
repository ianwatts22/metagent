use crate::skills::{
    OutputFormat, Skill, SkillLocation, SkillsScanOptions, default_roots, skills_scan,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::OsStr;
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Component, Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const CACHE_VERSION: u32 = 1;

#[derive(Debug)]
pub struct SkillUsageOptions {
    pub roots: Vec<PathBuf>,
    pub ignore_projects: Vec<PathBuf>,
    pub max_depth: usize,
    pub sessions_root: PathBuf,
    pub cache_path: PathBuf,
    pub output_format: OutputFormat,
    pub use_cache: bool,
    pub refresh_cache: bool,
    pub days: Option<u64>,
    pub limit: usize,
}

#[derive(Debug, Serialize)]
pub struct SkillUsageReport {
    pub generated_at: u64,
    pub sessions_root: String,
    pub cache_path: String,
    pub cache_enabled: bool,
    pub window_days: Option<u64>,
    pub summary: SkillUsageSummary,
    pub skills: Vec<SkillUsageRow>,
    pub unmatched: Vec<UnmatchedSkillUsageRow>,
}

#[derive(Debug, Default, Serialize)]
pub struct SkillUsageSummary {
    pub inventory_count: usize,
    pub used_count: usize,
    pub unused_count: usize,
    pub unmatched_used_count: usize,
    pub event_count: usize,
    pub read_event_count: usize,
    pub reference_event_count: usize,
    pub session_file_count: usize,
    pub parsed_session_file_count: usize,
    pub cached_session_file_count: usize,
    pub skipped_session_file_count: usize,
    pub parse_error_count: usize,
}

#[derive(Debug, Serialize)]
pub struct SkillUsageRow {
    pub name: String,
    pub skill_file: String,
    pub source: String,
    pub activation_count: usize,
    pub reference_count: usize,
    pub session_count: usize,
    pub first_used_at: Option<String>,
    pub last_used_at: Option<String>,
    pub last_session_id: Option<String>,
    pub last_cwd: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct UnmatchedSkillUsageRow {
    pub skill_file: String,
    pub inferred_name: String,
    pub activation_count: usize,
    pub reference_count: usize,
    pub session_count: usize,
    pub first_used_at: Option<String>,
    pub last_used_at: Option<String>,
    pub last_session_id: Option<String>,
    pub last_cwd: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct SkillUsageCache {
    version: u32,
    files: BTreeMap<String, CachedSessionFile>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CachedSessionFile {
    size: u64,
    modified_millis: u64,
    session_id: Option<String>,
    cwd: Option<String>,
    started_at: Option<String>,
    line_count: usize,
    parse_error_count: usize,
    events: Vec<CachedSkillUsageEvent>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CachedSkillUsageEvent {
    skill_file: String,
    timestamp: Option<String>,
    session_id: Option<String>,
    cwd: Option<String>,
    tool_name: Option<String>,
    signal: SkillUsageSignal,
}

#[derive(Debug, Clone, Copy, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum SkillUsageSignal {
    SkillRead,
    SkillReference,
}

#[derive(Debug)]
struct InventoryItem {
    name: String,
    skill_file: PathBuf,
    normalized_skill_file: String,
    source: String,
}

#[derive(Debug, Default)]
struct UsageAggregate {
    activation_count: usize,
    reference_count: usize,
    sessions: BTreeSet<String>,
    first_used_at: Option<String>,
    last_used_at: Option<String>,
    last_session_id: Option<String>,
    last_cwd: Option<String>,
}

pub fn default_sessions_root() -> PathBuf {
    codex_home().join("sessions")
}

pub fn default_usage_cache_path() -> PathBuf {
    home_dir().join(".local/state/metagent/skill-usage/cache.json")
}

pub fn skills_usage(options: &SkillUsageOptions) -> Result<SkillUsageReport, String> {
    let generated_at = unix_now();
    let inventory = build_inventory(options)?;
    let cutoff = options
        .days
        .and_then(|days| generated_at.checked_sub(days.saturating_mul(86_400)));
    let mut cache = if options.use_cache && !options.refresh_cache {
        read_cache(&options.cache_path)
    } else {
        SkillUsageCache {
            version: CACHE_VERSION,
            files: BTreeMap::new(),
        }
    };
    let mut next_cache = SkillUsageCache {
        version: CACHE_VERSION,
        files: BTreeMap::new(),
    };
    let mut summary = SkillUsageSummary {
        inventory_count: inventory.len(),
        ..SkillUsageSummary::default()
    };
    let mut report_cache_keys = Vec::new();

    let session_files = collect_session_files(&options.sessions_root)?;
    summary.session_file_count = session_files.len();

    for session_file in session_files {
        let metadata = match fs::metadata(&session_file) {
            Ok(metadata) => metadata,
            Err(_) => {
                summary.skipped_session_file_count += 1;
                continue;
            }
        };
        let cache_key = session_file.display().to_string();
        let size = metadata.len();
        let modified_millis = modified_millis(&metadata);
        let modified_secs = modified_secs(&metadata);
        if cutoff.is_some_and(|cutoff| modified_secs < cutoff) {
            if options.use_cache
                && !options.refresh_cache
                && cache.files.get(&cache_key).is_some_and(|entry| {
                    entry.size == size && entry.modified_millis == modified_millis
                })
            {
                let cached = cache.files.remove(&cache_key).expect("cache entry checked");
                next_cache.files.insert(cache_key, cached);
            }
            summary.skipped_session_file_count += 1;
            continue;
        }

        let parsed = if options.use_cache
            && !options.refresh_cache
            && cache
                .files
                .get(&cache_key)
                .is_some_and(|entry| entry.size == size && entry.modified_millis == modified_millis)
        {
            summary.cached_session_file_count += 1;
            cache.files.remove(&cache_key).expect("cache entry checked")
        } else {
            summary.parsed_session_file_count += 1;
            parse_session_file(&session_file, size, modified_millis)?
        };

        summary.parse_error_count += parsed.parse_error_count;
        report_cache_keys.push(cache_key.clone());
        next_cache.files.insert(cache_key, parsed);
    }

    if options.use_cache {
        write_cache(&options.cache_path, &next_cache)?;
    }

    let mut aggregates: BTreeMap<String, UsageAggregate> = BTreeMap::new();
    for cached_file in report_cache_keys
        .iter()
        .filter_map(|cache_key| next_cache.files.get(cache_key))
    {
        for event in &cached_file.events {
            summary.event_count += 1;
            match event.signal {
                SkillUsageSignal::SkillRead => summary.read_event_count += 1,
                SkillUsageSignal::SkillReference => summary.reference_event_count += 1,
            }
            aggregates
                .entry(event.skill_file.clone())
                .or_default()
                .add_event(event);
        }
    }

    let inventory_by_path = inventory
        .iter()
        .map(|item| (item.normalized_skill_file.clone(), item))
        .collect::<BTreeMap<_, _>>();

    let mut skills = Vec::new();
    for item in &inventory {
        let aggregate = aggregates.get(&item.normalized_skill_file);
        if aggregate.is_some_and(UsageAggregate::has_usage) {
            summary.used_count += 1;
        } else {
            summary.unused_count += 1;
        }
        skills.push(SkillUsageRow {
            name: item.name.clone(),
            skill_file: item.skill_file.display().to_string(),
            source: item.source.clone(),
            activation_count: aggregate.map_or(0, |aggregate| aggregate.activation_count),
            reference_count: aggregate.map_or(0, |aggregate| aggregate.reference_count),
            session_count: aggregate.map_or(0, |aggregate| aggregate.sessions.len()),
            first_used_at: aggregate.and_then(|aggregate| aggregate.first_used_at.clone()),
            last_used_at: aggregate.and_then(|aggregate| aggregate.last_used_at.clone()),
            last_session_id: aggregate.and_then(|aggregate| aggregate.last_session_id.clone()),
            last_cwd: aggregate.and_then(|aggregate| aggregate.last_cwd.clone()),
        });
    }

    let mut unmatched = aggregates
        .iter()
        .filter(|(skill_file, aggregate)| {
            aggregate.has_usage() && !inventory_by_path.contains_key(*skill_file)
        })
        .map(|(skill_file, aggregate)| UnmatchedSkillUsageRow {
            skill_file: skill_file.clone(),
            inferred_name: infer_skill_name(skill_file),
            activation_count: aggregate.activation_count,
            reference_count: aggregate.reference_count,
            session_count: aggregate.sessions.len(),
            first_used_at: aggregate.first_used_at.clone(),
            last_used_at: aggregate.last_used_at.clone(),
            last_session_id: aggregate.last_session_id.clone(),
            last_cwd: aggregate.last_cwd.clone(),
        })
        .collect::<Vec<_>>();
    summary.unmatched_used_count = unmatched.len();

    skills.sort_by(|left, right| {
        right
            .last_used_at
            .cmp(&left.last_used_at)
            .then_with(|| right.activation_count.cmp(&left.activation_count))
            .then_with(|| left.name.cmp(&right.name))
            .then_with(|| left.skill_file.cmp(&right.skill_file))
    });
    unmatched.sort_by(|left, right| {
        right
            .last_used_at
            .cmp(&left.last_used_at)
            .then_with(|| right.activation_count.cmp(&left.activation_count))
            .then_with(|| left.skill_file.cmp(&right.skill_file))
    });

    Ok(SkillUsageReport {
        generated_at,
        sessions_root: options.sessions_root.display().to_string(),
        cache_path: options.cache_path.display().to_string(),
        cache_enabled: options.use_cache,
        window_days: options.days,
        summary,
        skills,
        unmatched,
    })
}

impl SkillUsageReport {
    pub fn to_json(&self) -> Result<String, String> {
        serde_json::to_string(self).map_err(|error| format!("failed serializing report: {error}"))
    }

    pub fn to_text(&self, limit: usize) -> String {
        let mut out = String::new();
        out.push_str("metagent skills usage\n");
        out.push_str(&format!(
            "sessions: {}{}\n",
            self.sessions_root,
            self.window_days
                .map(|days| format!(" (last {days} day(s))"))
                .unwrap_or_else(|| " (all discovered sessions)".to_string())
        ));
        out.push_str(&format!(
            "files: {} total, {} parsed, {} cached, {} skipped, {} parse errors\n",
            self.summary.session_file_count,
            self.summary.parsed_session_file_count,
            self.summary.cached_session_file_count,
            self.summary.skipped_session_file_count,
            self.summary.parse_error_count
        ));
        out.push_str(&format!(
            "skills: {} inventory, {} used, {} unused, {} unmatched historical\n",
            self.summary.inventory_count,
            self.summary.used_count,
            self.summary.unused_count,
            self.summary.unmatched_used_count
        ));
        out.push_str(&format!(
            "events: {} skill reads, {} other SKILL.md references\n",
            self.summary.read_event_count, self.summary.reference_event_count
        ));

        let used = self
            .skills
            .iter()
            .filter(|skill| skill.activation_count > 0 || skill.reference_count > 0)
            .collect::<Vec<_>>();
        if !used.is_empty() {
            out.push_str("\nUsed skills\n");
            for skill in used.into_iter().take(limit) {
                out.push_str(&format!(
                    "  {:>4} read  {:>4} ref  {:>3} sessions  {:<28}  {}\n",
                    skill.activation_count,
                    skill.reference_count,
                    skill.session_count,
                    skill.last_used_at.as_deref().unwrap_or("-"),
                    skill.name
                ));
                out.push_str(&format!("       {}\n", skill.skill_file));
            }
        }

        let unused = self
            .skills
            .iter()
            .filter(|skill| skill.activation_count == 0 && skill.reference_count == 0)
            .collect::<Vec<_>>();
        if !unused.is_empty() {
            out.push_str("\nUnused inventory skills\n");
            for skill in unused.into_iter().take(limit) {
                out.push_str(&format!("  {:<28}  {}\n", skill.name, skill.skill_file));
            }
        }

        if !self.unmatched.is_empty() {
            out.push_str("\nUnmatched historical skill paths\n");
            for skill in self.unmatched.iter().take(limit) {
                out.push_str(&format!(
                    "  {:>4} read  {:>4} ref  {:>3} sessions  {:<28}  {}\n",
                    skill.activation_count,
                    skill.reference_count,
                    skill.session_count,
                    skill.last_used_at.as_deref().unwrap_or("-"),
                    skill.inferred_name
                ));
                out.push_str(&format!("       {}\n", skill.skill_file));
            }
        }

        out
    }
}

impl UsageAggregate {
    fn add_event(&mut self, event: &CachedSkillUsageEvent) {
        match event.signal {
            SkillUsageSignal::SkillRead => self.activation_count += 1,
            SkillUsageSignal::SkillReference => self.reference_count += 1,
        }

        if let Some(session_id) = &event.session_id {
            self.sessions.insert(session_id.clone());
        }

        if let Some(timestamp) = &event.timestamp {
            if self
                .first_used_at
                .as_ref()
                .is_none_or(|current| timestamp < current)
            {
                self.first_used_at = Some(timestamp.clone());
            }
            if self
                .last_used_at
                .as_ref()
                .is_none_or(|current| timestamp > current)
            {
                self.last_used_at = Some(timestamp.clone());
                self.last_session_id = event.session_id.clone();
                self.last_cwd = event.cwd.clone();
            }
        } else if self.last_session_id.is_none() {
            self.last_session_id = event.session_id.clone();
            self.last_cwd = event.cwd.clone();
        }
    }

    fn has_usage(&self) -> bool {
        self.activation_count > 0 || self.reference_count > 0
    }
}

fn build_inventory(options: &SkillUsageOptions) -> Result<Vec<InventoryItem>, String> {
    let mut inventory = BTreeMap::new();

    let mut roots = if options.roots.is_empty() {
        default_roots()
    } else {
        options.roots.clone()
    };
    roots.sort();
    roots.dedup();

    let project_scan = skills_scan(&SkillsScanOptions {
        roots,
        ignore_projects: options.ignore_projects.clone(),
        max_depth: options.max_depth,
        output_format: OutputFormat::Text,
    })?;
    for project in project_scan.projects {
        for skill in project.skill_inventory {
            let source = skill_source(&skill);
            insert_inventory_skill(&mut inventory, &skill, source);
        }
    }

    for skill_root in default_extra_skill_roots() {
        collect_inventory_root(&skill_root, &mut inventory)?;
    }

    Ok(inventory.into_values().collect())
}

fn insert_inventory_skill(
    inventory: &mut BTreeMap<String, InventoryItem>,
    skill: &Skill,
    source: String,
) {
    let skill_file = skill.path.join("SKILL.md");
    let normalized_skill_file = normalize_existing_path(&skill_file);
    inventory
        .entry(normalized_skill_file.clone())
        .or_insert_with(|| InventoryItem {
            name: skill.name.clone(),
            skill_file,
            normalized_skill_file,
            source,
        });
}

fn skill_source(skill: &Skill) -> String {
    match skill.location {
        SkillLocation::Agents => ".agents".to_string(),
        SkillLocation::Codex => ".codex".to_string(),
        SkillLocation::Claude => ".claude".to_string(),
    }
}

fn default_extra_skill_roots() -> Vec<PathBuf> {
    let home = home_dir();
    vec![
        home.join(".agents/skills"),
        home.join(".codex/skills"),
        home.join(".codex/plugins/cache"),
        PathBuf::from("/etc/codex/skills"),
    ]
}

fn collect_inventory_root(
    root: &Path,
    inventory: &mut BTreeMap<String, InventoryItem>,
) -> Result<(), String> {
    if !root.exists() {
        return Ok(());
    }
    collect_inventory_root_inner(root, root, 0, 12, inventory)
}

fn collect_inventory_root_inner(
    root: &Path,
    dir: &Path,
    depth: usize,
    max_depth: usize,
    inventory: &mut BTreeMap<String, InventoryItem>,
) -> Result<(), String> {
    if depth > max_depth || should_prune(dir) {
        return Ok(());
    }

    if dir.join("SKILL.md").is_file() {
        let Some(name) = dir.file_name().and_then(OsStr::to_str) else {
            return Ok(());
        };
        let skill_file = dir.join("SKILL.md");
        let normalized_skill_file = normalize_existing_path(&skill_file);
        inventory
            .entry(normalized_skill_file.clone())
            .or_insert_with(|| InventoryItem {
                name: name.to_string(),
                skill_file,
                normalized_skill_file,
                source: extra_skill_source(root),
            });
        return Ok(());
    }

    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::PermissionDenied
            ) =>
        {
            return Ok(());
        }
        Err(error) => return Err(format!("failed reading {}: {error}", dir.display())),
    };

    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => continue,
        };
        let path = entry.path();
        let file_type = match entry.file_type() {
            Ok(file_type) => file_type,
            Err(_) => continue,
        };
        if file_type.is_dir() || file_type.is_symlink() {
            collect_inventory_root_inner(root, &path, depth + 1, max_depth, inventory)?;
        }
    }

    Ok(())
}

fn extra_skill_source(root: &Path) -> String {
    let path = root.display().to_string();
    if path.contains("/.codex/plugins/cache") {
        return "plugin-cache".to_string();
    }
    if path.ends_with("/.agents/skills") {
        return "user-agents".to_string();
    }
    if path.ends_with("/.codex/skills") {
        return "user-codex".to_string();
    }
    if path == "/etc/codex/skills" {
        return "admin".to_string();
    }
    path
}

fn collect_session_files(root: &Path) -> Result<Vec<PathBuf>, String> {
    let mut files = Vec::new();
    if !root.exists() {
        return Ok(files);
    }
    collect_session_files_inner(root, &mut files)?;
    files.sort();
    Ok(files)
}

fn collect_session_files_inner(dir: &Path, files: &mut Vec<PathBuf>) -> Result<(), String> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::PermissionDenied
            ) =>
        {
            return Ok(());
        }
        Err(error) => return Err(format!("failed reading {}: {error}", dir.display())),
    };

    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => continue,
        };
        let path = entry.path();
        let file_type = match entry.file_type() {
            Ok(file_type) => file_type,
            Err(_) => continue,
        };
        if file_type.is_dir() {
            collect_session_files_inner(&path, files)?;
        } else if path.extension() == Some(OsStr::new("jsonl")) {
            files.push(path);
        }
    }

    Ok(())
}

fn parse_session_file(
    path: &Path,
    size: u64,
    modified_millis: u64,
) -> Result<CachedSessionFile, String> {
    let file = fs::File::open(path)
        .map_err(|error| format!("failed opening {}: {error}", path.display()))?;
    let reader = BufReader::new(file);
    let mut cached = CachedSessionFile {
        size,
        modified_millis,
        session_id: None,
        cwd: None,
        started_at: None,
        line_count: 0,
        parse_error_count: 0,
        events: Vec::new(),
    };

    for line in reader.lines() {
        let line = match line {
            Ok(line) => line,
            Err(_) => {
                cached.parse_error_count += 1;
                continue;
            }
        };
        cached.line_count += 1;

        let is_session_meta = line.contains("\"type\":\"session_meta\"");
        if !is_session_meta && !line.contains("SKILL.md") {
            continue;
        }

        let value = match serde_json::from_str::<Value>(&line) {
            Ok(value) => value,
            Err(_) => {
                cached.parse_error_count += 1;
                continue;
            }
        };

        if is_session_meta {
            read_session_meta(&value, &mut cached);
            continue;
        }

        if value.get("type").and_then(Value::as_str) != Some("response_item") {
            continue;
        }

        let Some(payload) = value.get("payload") else {
            continue;
        };
        let payload_type = payload.get("type").and_then(Value::as_str);
        if !matches!(payload_type, Some("function_call" | "local_shell_call")) {
            continue;
        }

        let timestamp = value
            .get("timestamp")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        cached.events.extend(events_from_tool_call(
            payload,
            timestamp,
            cached.session_id.clone(),
            cached.cwd.clone(),
        ));
    }

    Ok(cached)
}

fn read_session_meta(value: &Value, cached: &mut CachedSessionFile) {
    let Some(payload) = value.get("payload") else {
        return;
    };

    if cached.session_id.is_none() {
        cached.session_id = payload
            .get("id")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
    }
    if cached.cwd.is_none() {
        cached.cwd = payload
            .get("cwd")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
    }
    if cached.started_at.is_none() {
        cached.started_at = payload
            .get("timestamp")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
    }
}

fn events_from_tool_call(
    payload: &Value,
    timestamp: Option<String>,
    session_id: Option<String>,
    session_cwd: Option<String>,
) -> Vec<CachedSkillUsageEvent> {
    let tool_name = payload
        .get("name")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);
    let arguments_value = payload
        .get("arguments")
        .and_then(Value::as_str)
        .and_then(|arguments| serde_json::from_str::<Value>(arguments).ok());
    let call_workdir = arguments_value
        .as_ref()
        .and_then(|arguments| arguments.get("workdir"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| session_cwd.clone());
    let command_text = arguments_value
        .as_ref()
        .and_then(|arguments| arguments.get("cmd"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned);

    let mut strings = Vec::new();
    collect_json_strings(payload, &mut strings);
    if let Some(arguments_value) = &arguments_value {
        collect_json_strings(arguments_value, &mut strings);
    }

    let signal = classify_signal(tool_name.as_deref(), command_text.as_deref());
    let mut skill_paths = BTreeSet::new();
    for text in strings {
        for skill_path in extract_skill_paths(&text, call_workdir.as_deref()) {
            skill_paths.insert(skill_path);
        }
    }

    skill_paths
        .into_iter()
        .map(|skill_file| CachedSkillUsageEvent {
            skill_file,
            timestamp: timestamp.clone(),
            session_id: session_id.clone(),
            cwd: session_cwd.clone(),
            tool_name: tool_name.clone(),
            signal,
        })
        .collect()
}

fn collect_json_strings(value: &Value, strings: &mut Vec<String>) {
    match value {
        Value::String(value) => strings.push(value.clone()),
        Value::Array(values) => {
            for value in values {
                collect_json_strings(value, strings);
            }
        }
        Value::Object(values) => {
            for value in values.values() {
                collect_json_strings(value, strings);
            }
        }
        _ => {}
    }
}

fn classify_signal(tool_name: Option<&str>, command_text: Option<&str>) -> SkillUsageSignal {
    if tool_name.is_some_and(|name| name.contains("exec_command")) {
        if let Some(command) = command_text {
            let command = command.trim_start();
            if command.starts_with("cat ")
                || command.starts_with("sed ")
                || command.starts_with("nl ")
                || command.starts_with("head ")
                || command.starts_with("tail ")
                || command.starts_with("rg ")
                || command.starts_with("grep ")
                || command.starts_with("less ")
                || command.contains(" sed -n ")
                || command.contains(" cat ")
            {
                return SkillUsageSignal::SkillRead;
            }
        }
    }

    SkillUsageSignal::SkillReference
}

fn extract_skill_paths(text: &str, base_dir: Option<&str>) -> Vec<String> {
    let text = text.replace("\\/", "/");
    let mut paths = Vec::new();
    let mut seen = BTreeSet::new();
    let mut search_start = 0;
    while let Some(relative_index) = text[search_start..].find("SKILL.md") {
        let end = search_start + relative_index + "SKILL.md".len();
        let candidate =
            quoted_skill_candidate(&text, end).or_else(|| unquoted_skill_candidate(&text, end));

        if let Some(candidate) = candidate {
            if let Some(normalized) = normalize_extracted_skill_path(&candidate, base_dir) {
                if seen.insert(normalized.clone()) {
                    paths.push(normalized);
                }
            }
        }

        search_start = end;
    }
    paths
}

fn quoted_skill_candidate(text: &str, end: usize) -> Option<String> {
    for quote in ['"', '\'', '`'] {
        let Some(start) = text[..end].rfind(quote) else {
            continue;
        };
        let start = start + quote.len_utf8();
        if let Some(candidate) = clean_skill_candidate(&text[start..end]) {
            return Some(candidate);
        }
    }
    None
}

fn unquoted_skill_candidate(text: &str, end: usize) -> Option<String> {
    let bytes = text.as_bytes();
    let mut start = end;
    while start > 0 {
        let previous = bytes[start - 1];
        if previous.is_ascii_whitespace() || is_path_boundary(previous) {
            break;
        }
        start -= 1;
    }

    let candidate = text[start..end].trim();
    clean_skill_candidate(candidate)
}

fn clean_skill_candidate(candidate: &str) -> Option<String> {
    let mut candidate = candidate.trim();
    for marker in [
        " /",
        " ~/",
        " ./",
        " ../",
        " .agents/",
        " .claude/",
        " .codex/",
        " skills/",
        " $HOME",
        " ${HOME}",
        " $CODEX_HOME",
        " ${CODEX_HOME}",
    ] {
        if let Some(index) = candidate.rfind(marker) {
            candidate = &candidate[index + 1..];
        }
    }

    if candidate.contains('"') || candidate.contains('\'') || candidate.contains('`') {
        return None;
    }

    if looks_like_skill_path(candidate) {
        return Some(candidate.to_string());
    }

    None
}

fn is_path_boundary(byte: u8) -> bool {
    matches!(
        byte,
        b'"' | b'\'' | b'`' | b'<' | b'>' | b'(' | b')' | b'[' | b']' | b'{' | b'}' | b',' | b';'
    )
}

fn looks_like_skill_path(candidate: &str) -> bool {
    let candidate = candidate.trim();
    candidate.ends_with("/SKILL.md")
        && (candidate.starts_with('/')
            || candidate.starts_with("~/")
            || candidate.starts_with("./")
            || candidate.starts_with("../")
            || candidate.starts_with(".agents/")
            || candidate.starts_with(".claude/")
            || candidate.starts_with(".codex/")
            || candidate.starts_with("skills/")
            || candidate.starts_with("$HOME")
            || candidate.starts_with("${HOME}")
            || candidate.starts_with("$CODEX_HOME")
            || candidate.starts_with("${CODEX_HOME}"))
}

fn normalize_extracted_skill_path(raw: &str, base_dir: Option<&str>) -> Option<String> {
    let cleaned = raw
        .trim()
        .trim_matches('"')
        .trim_matches('\'')
        .trim_matches('`')
        .replace("\\ ", " ")
        .replace("\\/", "/");
    if !cleaned.ends_with("SKILL.md") {
        return None;
    }

    let expanded = expand_path_vars(&cleaned);
    let path = PathBuf::from(&expanded);
    let absolute = if path.is_absolute() {
        path
    } else {
        PathBuf::from(base_dir?).join(path)
    };
    Some(normalize_existing_path(&absolute))
}

fn expand_path_vars(path: &str) -> String {
    let home = home_dir().display().to_string();
    let codex_home = codex_home().display().to_string();

    if let Some(rest) = path.strip_prefix("~/") {
        return format!("{home}/{rest}");
    }
    if let Some(rest) = path.strip_prefix("${HOME}/") {
        return format!("{home}/{rest}");
    }
    if let Some(rest) = path.strip_prefix("$HOME/") {
        return format!("{home}/{rest}");
    }
    if let Some(rest) = path.strip_prefix("${CODEX_HOME}/") {
        return format!("{codex_home}/{rest}");
    }
    if let Some(rest) = path.strip_prefix("$CODEX_HOME/") {
        return format!("{codex_home}/{rest}");
    }

    path.to_string()
}

fn normalize_existing_path(path: &Path) -> String {
    fs::canonicalize(path)
        .unwrap_or_else(|_| normalize_path(path))
        .display()
        .to_string()
}

fn normalize_path(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            _ => normalized.push(component.as_os_str()),
        }
    }
    normalized
}

fn infer_skill_name(skill_file: &str) -> String {
    Path::new(skill_file)
        .parent()
        .and_then(Path::file_name)
        .and_then(OsStr::to_str)
        .unwrap_or("unknown")
        .to_string()
}

fn read_cache(path: &Path) -> SkillUsageCache {
    let Ok(text) = fs::read_to_string(path) else {
        return empty_cache();
    };
    let Ok(cache) = serde_json::from_str::<SkillUsageCache>(&text) else {
        return empty_cache();
    };
    if cache.version == CACHE_VERSION {
        cache
    } else {
        empty_cache()
    }
}

fn empty_cache() -> SkillUsageCache {
    SkillUsageCache {
        version: CACHE_VERSION,
        files: BTreeMap::new(),
    }
}

fn write_cache(path: &Path, cache: &SkillUsageCache) -> Result<(), String> {
    let Some(parent) = path.parent() else {
        return Err(format!("cache path has no parent: {}", path.display()));
    };
    fs::create_dir_all(parent)
        .map_err(|error| format!("failed creating {}: {error}", parent.display()))?;
    let temp = path.with_extension("json.tmp");
    let text = serde_json::to_string(cache)
        .map_err(|error| format!("failed serializing cache: {error}"))?;
    fs::write(&temp, text)
        .map_err(|error| format!("failed writing {}: {error}", temp.display()))?;
    fs::rename(&temp, path).map_err(|error| {
        format!(
            "failed moving {} to {}: {error}",
            temp.display(),
            path.display()
        )
    })
}

fn should_prune(path: &Path) -> bool {
    matches!(
        path.file_name().and_then(OsStr::to_str),
        Some(
            ".git"
                | ".hg"
                | ".svn"
                | "node_modules"
                | "target"
                | ".next"
                | ".turbo"
                | ".build"
                | "DerivedData"
        )
    )
}

fn modified_millis(metadata: &fs::Metadata) -> u64 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_millis().min(u128::from(u64::MAX)) as u64)
        .unwrap_or(0)
}

fn modified_secs(metadata: &fs::Metadata) -> u64 {
    metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn codex_home() -> PathBuf {
    env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home_dir().join(".codex"))
}

fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usage_extracts_skill_reads_and_ignores_prompt_inventory() {
        let temp = temp_dir("skill-usage-read");
        let project = temp.join("repo");
        let sessions = temp.join("sessions");
        let cache = temp.join("cache.json");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(
            project.join(".agents/skills/alpha/SKILL.md"),
            "---\nname: alpha\ndescription: Alpha\n---\nBody\n",
        )
        .unwrap();
        fs::create_dir_all(&sessions).unwrap();
        let skill_file = project.join(".agents/skills/alpha/SKILL.md");
        let arguments = serde_json::to_string(&format!(
            r#"{{"cmd":"sed -n '1,80p' {}","workdir":"/tmp/repo"}}"#,
            skill_file.display()
        ))
        .unwrap();
        fs::write(
            sessions.join("rollout.jsonl"),
            format!(
                "{}\n{}\n{}\n",
                r#"{"timestamp":"2026-06-10T00:00:00Z","type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/repo","timestamp":"2026-06-10T00:00:00Z"}}"#,
                r#"{"timestamp":"2026-06-10T00:00:01Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"alpha path /tmp/noise/SKILL.md"}]}}"#,
                format!(
                    r#"{{"timestamp":"2026-06-10T00:00:02Z","type":"response_item","payload":{{"type":"function_call","name":"exec_command","arguments":{arguments}}}}}"#
                )
            ),
        )
        .unwrap();

        let report = skills_usage(&SkillUsageOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            sessions_root: sessions,
            cache_path: cache,
            output_format: OutputFormat::Json,
            use_cache: true,
            refresh_cache: false,
            days: None,
            limit: 50,
        })
        .unwrap();

        let alpha = report
            .skills
            .iter()
            .find(|skill| skill.name == "alpha")
            .unwrap();
        assert_eq!(alpha.activation_count, 1);
        assert_eq!(alpha.reference_count, 0);
        assert_eq!(report.summary.read_event_count, 1);
        assert!(report.unmatched.is_empty());
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn usage_cache_reuses_unchanged_session_files() {
        let temp = temp_dir("skill-usage-cache");
        let project = temp.join("repo");
        let sessions = temp.join("sessions");
        let cache = temp.join("cache.json");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(project.join(".agents/skills/alpha/SKILL.md"), "---\n").unwrap();
        fs::create_dir_all(&sessions).unwrap();
        let skill_file = project.join(".agents/skills/alpha/SKILL.md");
        let arguments = serde_json::to_string(&format!(
            r#"{{"cmd":"cat {}","workdir":"/tmp/repo"}}"#,
            skill_file.display()
        ))
        .unwrap();
        fs::write(
            sessions.join("rollout.jsonl"),
            format!(
                "{}\n{}\n",
                r#"{"timestamp":"2026-06-10T00:00:00Z","type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/repo"}}"#,
                format!(
                    r#"{{"timestamp":"2026-06-10T00:00:02Z","type":"response_item","payload":{{"type":"function_call","name":"exec_command","arguments":{arguments}}}}}"#
                )
            ),
        )
        .unwrap();

        let options = SkillUsageOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            sessions_root: sessions,
            cache_path: cache,
            output_format: OutputFormat::Json,
            use_cache: true,
            refresh_cache: false,
            days: None,
            limit: 50,
        };

        let first = skills_usage(&options).unwrap();
        let second = skills_usage(&options).unwrap();

        assert_eq!(first.summary.parsed_session_file_count, 1);
        assert_eq!(second.summary.parsed_session_file_count, 0);
        assert_eq!(second.summary.cached_session_file_count, 1);
        assert_eq!(second.summary.read_event_count, 1);
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn usage_days_filter_preserves_valid_skipped_cache_entries() {
        let temp = temp_dir("skill-usage-days-cache");
        let project = temp.join("repo");
        let sessions = temp.join("sessions");
        let cache = temp.join("cache.json");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(project.join(".agents/skills/alpha/SKILL.md"), "---\n").unwrap();
        fs::create_dir_all(&sessions).unwrap();
        let skill_file = project.join(".agents/skills/alpha/SKILL.md");
        let arguments = serde_json::to_string(&format!(
            r#"{{"cmd":"cat {}","workdir":"/tmp/repo"}}"#,
            skill_file.display()
        ))
        .unwrap();
        fs::write(
            sessions.join("rollout.jsonl"),
            format!(
                "{}\n{}\n",
                r#"{"timestamp":"2026-06-10T00:00:00Z","type":"session_meta","payload":{"id":"session-1","cwd":"/tmp/repo"}}"#,
                format!(
                    r#"{{"timestamp":"2026-06-10T00:00:02Z","type":"response_item","payload":{{"type":"function_call","name":"exec_command","arguments":{arguments}}}}}"#
                )
            ),
        )
        .unwrap();

        let all_options = SkillUsageOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            sessions_root: sessions.clone(),
            cache_path: cache.clone(),
            output_format: OutputFormat::Json,
            use_cache: true,
            refresh_cache: false,
            days: None,
            limit: 50,
        };
        let first = skills_usage(&all_options).unwrap();
        assert_eq!(first.summary.parsed_session_file_count, 1);

        std::thread::sleep(std::time::Duration::from_millis(1100));

        let window_options = SkillUsageOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            sessions_root: sessions,
            cache_path: cache,
            output_format: OutputFormat::Json,
            use_cache: true,
            refresh_cache: false,
            days: Some(0),
            limit: 50,
        };
        let windowed = skills_usage(&window_options).unwrap();
        assert_eq!(windowed.summary.skipped_session_file_count, 1);
        assert_eq!(windowed.summary.read_event_count, 0);

        let all_again = skills_usage(&all_options).unwrap();
        assert_eq!(all_again.summary.parsed_session_file_count, 0);
        assert_eq!(all_again.summary.cached_session_file_count, 1);
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn extract_skill_paths_resolves_relative_paths() {
        let paths = extract_skill_paths(
            "sed -n '1,20p' .agents/skills/example/SKILL.md",
            Some("/Users/example/repo"),
        );

        assert_eq!(
            paths,
            vec!["/Users/example/repo/.agents/skills/example/SKILL.md"]
        );
    }

    fn temp_dir(name: &str) -> PathBuf {
        let path = env::temp_dir().join(format!(
            "metagent-{name}-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&path).unwrap();
        path
    }
}
