use std::collections::BTreeSet;
use std::env;
use std::ffi::OsStr;
use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OutputFormat {
    Text,
    Json,
}

#[derive(Debug)]
pub struct SkillsScanOptions {
    pub roots: Vec<PathBuf>,
    pub ignore_projects: Vec<PathBuf>,
    pub max_depth: usize,
    pub output_format: OutputFormat,
}

#[derive(Debug)]
pub struct SkillsSyncOptions {
    pub roots: Vec<PathBuf>,
    pub ignore_projects: Vec<PathBuf>,
    pub max_depth: usize,
    pub agents: Vec<String>,
    pub apply: bool,
    pub replace_claude_skills: bool,
    pub rewrite_agents_toml: bool,
    pub sync_only: bool,
    pub run_dotagents: bool,
}

#[derive(Debug)]
pub struct SkillsDoctorOptions {
    pub roots: Vec<PathBuf>,
    pub ignore_projects: Vec<PathBuf>,
    pub max_depth: usize,
}

#[derive(Debug, Default)]
pub struct AgentToolsConfig {
    pub roots: Vec<PathBuf>,
    pub ignore_projects: Vec<PathBuf>,
    pub max_depth: Option<usize>,
    pub agents: Vec<String>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Skill {
    pub name: String,
    pub path: PathBuf,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct ProjectSkills {
    pub root: PathBuf,
    pub skills_dir: PathBuf,
    pub valid_skills: Vec<Skill>,
    pub invalid_skill_dirs: Vec<PathBuf>,
    pub hidden_skill_dirs: Vec<PathBuf>,
}

#[derive(Debug)]
pub struct SkillsScanReport {
    pub projects: Vec<ProjectSkills>,
}

impl SkillsScanReport {
    pub fn to_json(&self) -> String {
        let mut out = String::from("{\"projects\":[");
        for (index, project) in self.projects.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            write!(
                out,
                "{{\"root\":{},\"skills_dir\":{},\"valid_skills\":[",
                json_string(&project.root.display().to_string()),
                json_string(&project.skills_dir.display().to_string())
            )
            .expect("write to string");
            for (skill_index, skill) in project.valid_skills.iter().enumerate() {
                if skill_index > 0 {
                    out.push(',');
                }
                out.push_str(&json_string(&skill.name));
            }
            out.push_str("]}");
        }
        out.push_str("]}");
        out
    }
}

#[derive(Debug)]
pub struct SkillsSyncReport {
    pub apply: bool,
    pub projects: Vec<ProjectSyncReport>,
}

impl SkillsSyncReport {
    pub fn mode_label(&self) -> &'static str {
        if self.apply { "APPLY" } else { "DRY-RUN" }
    }
}

#[derive(Debug)]
pub struct ProjectSyncReport {
    pub root: PathBuf,
    pub lines: Vec<String>,
}

#[derive(Debug)]
pub struct SkillsDoctorReport {
    pub items: Vec<DoctorItem>,
}

impl SkillsDoctorReport {
    pub fn has_errors(&self) -> bool {
        self.items
            .iter()
            .any(|item| item.level == DoctorLevel::Fail)
    }
}

#[derive(Debug)]
pub struct DoctorItem {
    pub level: DoctorLevel,
    pub message: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DoctorLevel {
    Ok,
    Warn,
    Fail,
}

impl DoctorLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ok => "OK  ",
            Self::Warn => "WARN",
            Self::Fail => "FAIL",
        }
    }
}

pub fn default_roots() -> Vec<PathBuf> {
    let home = home_dir();
    vec![
        home.join("code_projects"),
        home.join("Library/CloudStorage"),
        home.join("Documents/Codex"),
    ]
}

pub fn load_user_config() -> Result<AgentToolsConfig, String> {
    let path = home_dir().join(".config/agent-tools/config.toml");
    if !path.is_file() {
        return Ok(AgentToolsConfig::default());
    }
    let text = fs::read_to_string(&path)
        .map_err(|error| format!("failed reading {}: {error}", path.display()))?;
    parse_config(&text).map_err(|error| format!("invalid {}: {error}", path.display()))
}

pub fn skills_scan(options: &SkillsScanOptions) -> Result<SkillsScanReport, String> {
    let mut project_roots = BTreeSet::new();

    for root in &options.roots {
        let expanded = expand_tilde(root);
        if !expanded.is_dir() {
            continue;
        }
        discover_skill_dirs(&expanded, options.max_depth, 0, &mut project_roots)
            .map_err(|error| format!("failed scanning {}: {error}", expanded.display()))?;
    }

    let ignored = expanded_paths(&options.ignore_projects);
    let mut projects = Vec::new();
    for root in project_roots {
        if ignored
            .iter()
            .any(|ignored_root| same_path(&root, ignored_root))
        {
            continue;
        }
        projects.push(read_project_skills(root)?);
    }

    Ok(SkillsScanReport { projects })
}

pub fn skills_sync(options: &SkillsSyncOptions) -> Result<SkillsSyncReport, String> {
    let scan = skills_scan(&SkillsScanOptions {
        roots: options.roots.clone(),
        ignore_projects: options.ignore_projects.clone(),
        max_depth: options.max_depth,
        output_format: OutputFormat::Text,
    })?;

    let mut projects = Vec::new();
    for project in scan.projects {
        projects.push(sync_project(&project, options)?);
    }

    Ok(SkillsSyncReport {
        apply: options.apply,
        projects,
    })
}

pub fn skills_doctor(options: &SkillsDoctorOptions) -> Result<SkillsDoctorReport, String> {
    let scan = skills_scan(&SkillsScanOptions {
        roots: options.roots.clone(),
        ignore_projects: options.ignore_projects.clone(),
        max_depth: options.max_depth,
        output_format: OutputFormat::Text,
    })?;
    let mut items = Vec::new();

    if scan.projects.is_empty() {
        items.push(DoctorItem {
            level: DoctorLevel::Warn,
            message: "no projects with .agents/skills found".to_string(),
        });
    }

    for project in scan.projects {
        if project.valid_skills.is_empty() {
            items.push(DoctorItem {
                level: DoctorLevel::Warn,
                message: format!("{} has no valid skills", project.root.display()),
            });
        } else {
            items.push(DoctorItem {
                level: DoctorLevel::Ok,
                message: format!(
                    "{} has {} valid skill(s)",
                    project.root.display(),
                    project.valid_skills.len()
                ),
            });
        }

        for invalid in &project.invalid_skill_dirs {
            items.push(DoctorItem {
                level: DoctorLevel::Warn,
                message: format!("{} has invalid dotagents skill name", invalid.display()),
            });
        }

        let agents_toml = project.root.join("agents.toml");
        if agents_toml.is_file() {
            items.push(DoctorItem {
                level: DoctorLevel::Ok,
                message: format!("{} exists", agents_toml.display()),
            });
        } else {
            items.push(DoctorItem {
                level: DoctorLevel::Warn,
                message: format!("{} missing", agents_toml.display()),
            });
        }

        let claude_skills = project.root.join(".claude/skills");
        if is_symlink(&claude_skills) {
            items.push(DoctorItem {
                level: DoctorLevel::Ok,
                message: format!("{} is a symlink", claude_skills.display()),
            });
        } else if claude_skills.exists() {
            items.push(DoctorItem {
                level: DoctorLevel::Warn,
                message: format!("{} exists but is not a symlink", claude_skills.display()),
            });
        } else {
            items.push(DoctorItem {
                level: DoctorLevel::Warn,
                message: format!("{} missing", claude_skills.display()),
            });
        }
    }

    Ok(SkillsDoctorReport { items })
}

fn sync_project(
    project: &ProjectSkills,
    options: &SkillsSyncOptions,
) -> Result<ProjectSyncReport, String> {
    let mut lines = Vec::new();

    lines.push(format!(
        "valid local skills: {}",
        project.valid_skills.len()
    ));
    if !project.hidden_skill_dirs.is_empty() {
        lines.push(format!(
            "warning: {} hidden skill dir(s) ignored",
            project.hidden_skill_dirs.len()
        ));
    }
    for invalid in &project.invalid_skill_dirs {
        lines.push(format!(
            "warning: skipped invalid skill name: {}",
            invalid.display()
        ));
    }

    if project.valid_skills.is_empty() {
        lines.push("skipped: no valid SKILL.md folders".to_string());
        return Ok(ProjectSyncReport {
            root: project.root.clone(),
            lines,
        });
    }

    retire_nested_agents_toml(&project.root, options.apply, &mut lines)?;
    if !ensure_agents_toml(project, options, &mut lines)? {
        return Ok(ProjectSyncReport {
            root: project.root.clone(),
            lines,
        });
    }
    prepare_claude_skills(&project.root, options, &mut lines)?;

    if !options.run_dotagents {
        lines.push("skipped dotagents sync due to --no-dotagents".to_string());
        return Ok(ProjectSyncReport {
            root: project.root.clone(),
            lines,
        });
    }

    if options.apply {
        let npx = resolve_executable(
            "npx",
            &[
                "/opt/homebrew/bin/npx",
                "/usr/local/bin/npx",
                "/usr/bin/npx",
            ],
        )
        .ok_or_else(|| "could not find npx; install Node.js or add npx to PATH".to_string())?;
        let output = Command::new(&npx)
            .arg("@sentry/dotagents")
            .arg("sync")
            .current_dir(&project.root)
            .env("PATH", augmented_path())
            .output()
            .map_err(|error| {
                format!(
                    "failed to run dotagents sync in {} using {}: {error}",
                    project.root.display(),
                    npx.display()
                )
            })?;

        if !output.status.success() {
            return Err(format!(
                "dotagents sync failed in {}\nstdout:\n{}\nstderr:\n{}",
                project.root.display(),
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            ));
        }

        for line in String::from_utf8_lossy(&output.stdout).lines() {
            lines.push(format!("dotagents: {line}"));
        }
        for line in String::from_utf8_lossy(&output.stderr).lines() {
            lines.push(format!("dotagents stderr: {line}"));
        }
    } else {
        lines.push("would run: npx @sentry/dotagents sync".to_string());
    }

    Ok(ProjectSyncReport {
        root: project.root.clone(),
        lines,
    })
}

fn ensure_agents_toml(
    project: &ProjectSkills,
    options: &SkillsSyncOptions,
    lines: &mut Vec<String>,
) -> Result<bool, String> {
    let agents_toml = project.root.join("agents.toml");

    if agents_toml.is_file() && !options.rewrite_agents_toml {
        lines.push(format!("kept existing {}", agents_toml.display()));
        return Ok(true);
    }

    if options.sync_only && !agents_toml.is_file() {
        lines.push(format!(
            "skipped: {} missing and --sync-only is set",
            agents_toml.display()
        ));
        return Ok(false);
    }

    let content = render_agents_toml(project, &options.agents);

    if !options.apply {
        if agents_toml.is_file() {
            lines.push(format!("would rewrite {}", agents_toml.display()));
        } else {
            lines.push(format!("would create {}", agents_toml.display()));
        }
        return Ok(true);
    }

    if agents_toml.is_file() {
        let backup = timestamped_backup_path(&agents_toml);
        fs::copy(&agents_toml, &backup)
            .map_err(|error| format!("failed backing up {}: {error}", agents_toml.display()))?;
        lines.push(format!("backed up existing config to {}", backup.display()));
    }

    fs::write(&agents_toml, content)
        .map_err(|error| format!("failed writing {}: {error}", agents_toml.display()))?;
    lines.push(format!("wrote {}", agents_toml.display()));
    Ok(true)
}

fn render_agents_toml(project: &ProjectSkills, agents: &[String]) -> String {
    let mut out = String::new();
    out.push_str("version = 1\n");
    out.push_str("agents = [");
    for (index, agent) in agents.iter().enumerate() {
        if index > 0 {
            out.push_str(", ");
        }
        out.push_str(&toml_string(agent));
    }
    out.push_str("]\n\n");
    out.push_str("[trust]\nallow_all = true\n");

    for skill in &project.valid_skills {
        out.push_str("\n[[skills]]\n");
        writeln!(out, "name = {}", toml_string(&skill.name)).expect("write to string");
        writeln!(
            out,
            "source = {}",
            toml_string(&format!("path:.agents/skills/{}", skill.name))
        )
        .expect("write to string");
    }

    out
}

fn prepare_claude_skills(
    project: &Path,
    options: &SkillsSyncOptions,
    lines: &mut Vec<String>,
) -> Result<(), String> {
    let claude_skills = project.join(".claude/skills");

    if is_symlink(&claude_skills) || !claude_skills.exists() {
        return Ok(());
    }

    if !options.replace_claude_skills {
        lines.push(format!(
            "skipped: {} exists and is not a symlink; pass --replace-claude-skills",
            claude_skills.display()
        ));
        return Ok(());
    }

    let backup = timestamped_backup_path(&claude_skills);
    if options.apply {
        fs::rename(&claude_skills, &backup)
            .map_err(|error| format!("failed moving {}: {error}", claude_skills.display()))?;
        lines.push(format!(
            "moved existing .claude/skills to {}",
            backup.display()
        ));
    } else {
        lines.push(format!(
            "would move existing .claude/skills to {}",
            backup.display()
        ));
    }
    Ok(())
}

fn retire_nested_agents_toml(
    project: &Path,
    apply: bool,
    lines: &mut Vec<String>,
) -> Result<(), String> {
    let nested = project.join(".agents/agents.toml");
    if !nested.is_file() {
        return Ok(());
    }

    let backup = timestamped_backup_path(&nested);
    if apply {
        fs::rename(&nested, &backup)
            .map_err(|error| format!("failed moving {}: {error}", nested.display()))?;
        lines.push(format!(
            "moved ignored nested config to {}",
            backup.display()
        ));
    } else {
        lines.push(format!(
            "would move ignored nested config to {}",
            backup.display()
        ));
    }
    Ok(())
}

fn read_project_skills(root: PathBuf) -> Result<ProjectSkills, String> {
    let skills_dir = root.join(".agents/skills");
    let mut valid_skills = Vec::new();
    let mut invalid_skill_dirs = Vec::new();
    let mut hidden_skill_dirs = Vec::new();

    for entry in fs::read_dir(&skills_dir)
        .map_err(|error| format!("failed reading {}: {error}", skills_dir.display()))?
    {
        let entry = entry.map_err(|error| format!("failed reading dir entry: {error}"))?;
        let path = entry.path();
        let file_type = entry
            .file_type()
            .map_err(|error| format!("failed reading file type for {}: {error}", path.display()))?;
        if !file_type.is_dir() && !file_type.is_symlink() {
            continue;
        }
        if !path.join("SKILL.md").is_file() {
            continue;
        }
        let Some(name) = path.file_name().and_then(OsStr::to_str) else {
            invalid_skill_dirs.push(path);
            continue;
        };
        if name.starts_with('.') {
            hidden_skill_dirs.push(path.clone());
        }
        if is_valid_skill_name(name) {
            valid_skills.push(Skill {
                name: name.to_string(),
                path,
            });
        } else {
            invalid_skill_dirs.push(path);
        }
    }

    valid_skills.sort_by(|left, right| left.name.cmp(&right.name));
    invalid_skill_dirs.sort();
    hidden_skill_dirs.sort();

    Ok(ProjectSkills {
        root,
        skills_dir,
        valid_skills,
        invalid_skill_dirs,
        hidden_skill_dirs,
    })
}

fn discover_skill_dirs(
    dir: &Path,
    max_depth: usize,
    depth: usize,
    projects: &mut BTreeSet<PathBuf>,
) -> io::Result<()> {
    if depth > max_depth {
        return Ok(());
    }

    if should_prune(dir) && depth > 0 {
        return Ok(());
    }

    if dir.file_name() == Some(OsStr::new("skills"))
        && dir.parent().and_then(Path::file_name) == Some(OsStr::new(".agents"))
    {
        if let Some(project_root) = dir.parent().and_then(Path::parent) {
            projects.insert(project_root.to_path_buf());
        }
        return Ok(());
    }

    if depth == max_depth {
        return Ok(());
    }

    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if is_permission_error(&error) => return Ok(()),
        Err(error) => return Err(error),
    };

    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) if is_permission_error(&error) => continue,
            Err(error) => return Err(error),
        };
        let file_type = match entry.file_type() {
            Ok(file_type) => file_type,
            Err(error) if is_permission_error(&error) => continue,
            Err(error) => return Err(error),
        };
        if file_type.is_dir() {
            discover_skill_dirs(&entry.path(), max_depth, depth + 1, projects)?;
        }
    }

    Ok(())
}

fn should_prune(path: &Path) -> bool {
    matches!(
        path.file_name().and_then(OsStr::to_str),
        Some(
            ".git"
                | ".hg"
                | ".svn"
                | "node_modules"
                | ".next"
                | "dist"
                | "build"
                | "vendor"
                | "target"
        )
    )
}

fn is_permission_error(error: &io::Error) -> bool {
    matches!(error.kind(), io::ErrorKind::PermissionDenied)
}

fn is_valid_skill_name(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !first.is_ascii_alphanumeric() {
        return false;
    }
    chars.all(|char| char.is_ascii_alphanumeric() || matches!(char, '.' | '_' | '-'))
}

fn expand_tilde(path: &Path) -> PathBuf {
    let Some(raw) = path.to_str() else {
        return path.to_path_buf();
    };
    if raw == "~" {
        return home_dir();
    }
    if let Some(rest) = raw.strip_prefix("~/") {
        return home_dir().join(rest);
    }
    path.to_path_buf()
}

fn expanded_paths(paths: &[PathBuf]) -> Vec<PathBuf> {
    paths.iter().map(|path| expand_tilde(path)).collect()
}

fn same_path(left: &Path, right: &Path) -> bool {
    let left = fs::canonicalize(left).unwrap_or_else(|_| left.to_path_buf());
    let right = fs::canonicalize(right).unwrap_or_else(|_| right.to_path_buf());
    left == right
}

fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn is_symlink(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
}

fn resolve_executable(name: &str, candidates: &[&str]) -> Option<PathBuf> {
    if let Some(path) = env::var_os("PATH") {
        for dir in env::split_paths(&path) {
            let candidate = dir.join(name);
            if is_executable(&candidate) {
                return Some(candidate);
            }
        }
    }

    candidates
        .iter()
        .map(PathBuf::from)
        .find(|candidate| is_executable(candidate))
}

fn augmented_path() -> String {
    let mut parts = vec![
        "/opt/homebrew/bin".to_string(),
        "/usr/local/bin".to_string(),
        "/usr/bin".to_string(),
        "/bin".to_string(),
        "/usr/sbin".to_string(),
        "/sbin".to_string(),
    ];

    if let Some(path) = env::var_os("PATH") {
        for dir in env::split_paths(&path) {
            let value = dir.display().to_string();
            if !parts.iter().any(|existing| existing == &value) {
                parts.push(value);
            }
        }
    }

    parts.join(":")
}

fn is_executable(path: &Path) -> bool {
    path.is_file()
}

fn timestamped_backup_path(path: &Path) -> PathBuf {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    let file_name = path.file_name().and_then(OsStr::to_str).unwrap_or("backup");
    path.with_file_name(format!("{file_name}.bak-agent-tools-{timestamp}"))
}

fn toml_string(value: &str) -> String {
    json_string(value)
}

fn json_string(value: &str) -> String {
    let mut out = String::from("\"");
    for char in value.chars() {
        match char {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            char if char.is_control() => write!(out, "\\u{:04x}", char as u32).expect("write"),
            char => out.push(char),
        }
    }
    out.push('"');
    out
}

fn parse_config(text: &str) -> Result<AgentToolsConfig, String> {
    let mut config = AgentToolsConfig::default();

    for line in logical_config_lines(text)? {
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let value = value.trim();

        match key {
            "roots" => {
                config.roots = parse_string_array(value)?
                    .into_iter()
                    .map(PathBuf::from)
                    .collect();
            }
            "ignore_projects" => {
                config.ignore_projects = parse_string_array(value)?
                    .into_iter()
                    .map(PathBuf::from)
                    .collect();
            }
            "max_depth" => {
                config.max_depth = Some(
                    value
                        .parse()
                        .map_err(|_| format!("max_depth must be a number, got {value}"))?,
                );
            }
            "agents" => {
                config.agents = parse_string_array(value)?;
            }
            _ => {}
        }
    }

    Ok(config)
}

fn logical_config_lines(text: &str) -> Result<Vec<String>, String> {
    let mut lines = Vec::new();
    let mut pending: Option<String> = None;

    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }

        if let Some(current) = &mut pending {
            current.push(' ');
            current.push_str(line);
            if line.contains(']') {
                lines.push(pending.take().expect("pending exists"));
            }
            continue;
        }

        if let Some((_, value)) = line.split_once('=') {
            let value = value.trim();
            if value.starts_with('[') && !value.contains(']') {
                pending = Some(line.to_string());
                continue;
            }
        }

        lines.push(line.to_string());
    }

    if let Some(line) = pending {
        return Err(format!("unterminated array: {line}"));
    }

    Ok(lines)
}

fn parse_string_array(value: &str) -> Result<Vec<String>, String> {
    let trimmed = value.trim();
    if !trimmed.starts_with('[') || !trimmed.ends_with(']') {
        return Err(format!("expected array, got {value}"));
    }

    let inner = &trimmed[1..trimmed.len() - 1];
    let mut values = Vec::new();

    for part in inner.split(',') {
        let part = part.trim();
        if part.is_empty() {
            continue;
        }
        if !part.starts_with('"') || !part.ends_with('"') || part.len() < 2 {
            return Err(format!("expected quoted string in array, got {part}"));
        }
        values.push(
            part[1..part.len() - 1]
                .replace("\\\"", "\"")
                .replace("\\\\", "\\"),
        );
    }

    Ok(values)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    #[test]
    fn skill_name_validation_matches_dotagents_shape() {
        assert!(is_valid_skill_name("abc"));
        assert!(is_valid_skill_name("a.b_c-d"));
        assert!(is_valid_skill_name("A1"));
        assert!(!is_valid_skill_name(".system"));
        assert!(!is_valid_skill_name("-bad"));
        assert!(!is_valid_skill_name("bad name"));
    }

    #[test]
    fn scan_finds_project_skills_and_ignores_hidden_invalid_skill() {
        let temp = temp_dir("scan");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/good")).unwrap();
        fs::write(project.join(".agents/skills/good/SKILL.md"), "---\n").unwrap();
        fs::create_dir_all(project.join(".agents/skills/.system")).unwrap();
        fs::write(project.join(".agents/skills/.system/SKILL.md"), "---\n").unwrap();

        let report = skills_scan(&SkillsScanOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            output_format: OutputFormat::Text,
        })
        .unwrap();

        assert_eq!(report.projects.len(), 1);
        assert_eq!(report.projects[0].valid_skills[0].name, "good");
        assert_eq!(report.projects[0].hidden_skill_dirs.len(), 1);
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn sync_dry_run_writes_project_root_agents_toml_plan() {
        let temp = temp_dir("sync");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(project.join(".agents/skills/alpha/SKILL.md"), "---\n").unwrap();

        let report = skills_sync(&SkillsSyncOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            agents: vec!["claude".to_string()],
            apply: false,
            replace_claude_skills: false,
            rewrite_agents_toml: false,
            sync_only: false,
            run_dotagents: false,
        })
        .unwrap();

        assert!(
            report.projects[0]
                .lines
                .iter()
                .any(|line| { line.contains("would create") && line.contains("agents.toml") })
        );
        assert!(!project.join("agents.toml").exists());
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn parses_simple_user_config() {
        let config = parse_config(
            r#"
roots = ["~/code_projects", "~/Documents/Codex"]
max_depth = 6
ignore_projects = ["~/code_projects"]
agents = ["claude", "codex"]
"#,
        )
        .unwrap();

        assert_eq!(config.roots.len(), 2);
        assert_eq!(config.ignore_projects.len(), 1);
        assert_eq!(config.max_depth, Some(6));
        assert_eq!(config.agents, vec!["claude", "codex"]);
    }

    #[test]
    fn parses_multiline_user_config_arrays() {
        let config = parse_config(
            r#"
roots = [
  "~/code_projects",
  "~/Library/CloudStorage",
]
max_depth = 6
ignore_projects = [
  "~/code_projects",
]
agents = ["claude", "codex", "cursor"]
"#,
        )
        .unwrap();

        assert_eq!(config.roots.len(), 2);
        assert_eq!(config.ignore_projects.len(), 1);
        assert_eq!(config.max_depth, Some(6));
        assert_eq!(config.agents.len(), 3);
    }

    fn temp_dir(label: &str) -> PathBuf {
        let id = COUNTER.fetch_add(1, Ordering::SeqCst);
        env::temp_dir().join(format!("agent-tools-{label}-{}-{id}", std::process::id()))
    }
}
