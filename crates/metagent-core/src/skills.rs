use std::collections::{BTreeMap, BTreeSet};
use std::env;
use std::ffi::OsStr;
use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_SKILL_NAME_LENGTH: usize = 64;
const MAX_SKILL_DESCRIPTION_LENGTH: usize = 1024;
const ALLOWED_SKILL_FRONTMATTER_KEYS: [&str; 5] = [
    "allowed-tools",
    "description",
    "license",
    "metadata",
    "name",
];

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
    pub output_format: OutputFormat,
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

#[derive(Debug)]
pub struct SkillsFormatOptions {
    pub roots: Vec<PathBuf>,
    pub ignore_projects: Vec<PathBuf>,
    pub max_depth: usize,
    pub apply: bool,
}

#[derive(Debug, Default)]
pub struct MetagentConfig {
    pub roots: Vec<PathBuf>,
    pub ignore_projects: Vec<PathBuf>,
    pub max_depth: Option<usize>,
    pub agents: Vec<String>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Skill {
    pub name: String,
    pub path: PathBuf,
    pub location: SkillLocation,
    pub origin: SkillOrigin,
    pub symlinked_container: bool,
    pub stats: SkillStats,
}

#[derive(Debug, Clone, Default, Eq, PartialEq)]
pub struct SkillStats {
    pub character_count: usize,
    pub word_count: usize,
    pub token_estimate: usize,
    pub skill_file_character_count: usize,
    pub skill_file_word_count: usize,
    pub skill_file_token_estimate: usize,
    pub text_file_count: usize,
    pub reference_file_count: usize,
    pub script_file_count: usize,
    pub asset_file_count: usize,
    pub other_file_count: usize,
    pub other_folder_count: usize,
    pub has_openai_yaml: bool,
    pub has_icon_small: bool,
    pub has_icon_large: bool,
    pub has_icon_and_logo: bool,
    pub icon_small: Option<String>,
    pub icon_large: Option<String>,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum SkillLocation {
    Agents,
    Codex,
    Claude,
}

impl SkillLocation {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Agents => "agents",
            Self::Codex => "codex",
            Self::Claude => "claude",
        }
    }

    fn label(&self) -> &'static str {
        match self {
            Self::Agents => ".agents",
            Self::Codex => ".codex",
            Self::Claude => ".claude",
        }
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct SkillOrigin {
    pub kind: SkillOriginKind,
    pub source: Option<String>,
    pub source_type: Option<String>,
    pub source_url: Option<String>,
    pub ref_name: Option<String>,
    pub installed_at: Option<String>,
    pub updated_at: Option<String>,
}

impl SkillOrigin {
    fn native() -> Self {
        Self {
            kind: SkillOriginKind::Native,
            source: None,
            source_type: None,
            source_url: None,
            ref_name: None,
            installed_at: None,
            updated_at: None,
        }
    }

    fn not_applicable() -> Self {
        Self {
            kind: SkillOriginKind::NotApplicable,
            source: None,
            source_type: None,
            source_url: None,
            ref_name: None,
            installed_at: None,
            updated_at: None,
        }
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub enum SkillOriginKind {
    Native,
    NpxSkills,
    NotApplicable,
}

impl SkillOriginKind {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Native => "native",
            Self::NpxSkills => "npx-skills",
            Self::NotApplicable => "not-applicable",
        }
    }
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct ProjectSkills {
    pub root: PathBuf,
    pub skills_dir: PathBuf,
    pub valid_skills: Vec<Skill>,
    pub skill_inventory: Vec<Skill>,
    pub invalid_skill_dirs: Vec<PathBuf>,
    pub hidden_skill_dirs: Vec<PathBuf>,
}

#[derive(Debug, Default)]
struct AgentsTomlSkills {
    declarations: Vec<AgentsTomlSkillDeclaration>,
}

#[derive(Debug, Default)]
struct AgentsTomlSkillDeclaration {
    name: Option<String>,
    source: Option<String>,
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
            out.push_str("],\"skills\":[");
            for (skill_index, skill) in project.skill_inventory.iter().enumerate() {
                if skill_index > 0 {
                    out.push(',');
                }
                out.push_str(&skill.to_json());
            }
            out.push_str("]}");
        }
        out.push_str("]}");
        out
    }
}

impl Skill {
    fn to_json(&self) -> String {
        let mut out = format!(
            "{{\"name\":{},\"path\":{},\"location\":{},\"location_label\":{},\"origin_kind\":{},\"folder_kind\":{},\"symlinked_container\":{},\"character_count\":{},\"word_count\":{},\"token_estimate\":{},\"skill_file_character_count\":{},\"skill_file_word_count\":{},\"skill_file_token_estimate\":{},\"text_file_count\":{},\"reference_file_count\":{},\"script_file_count\":{},\"asset_file_count\":{},\"other_file_count\":{},\"other_folder_count\":{},\"has_openai_yaml\":{},\"has_icon_small\":{},\"has_icon_large\":{},\"has_icon_and_logo\":{}",
            json_string(&self.name),
            json_string(&self.path.display().to_string()),
            json_string(self.location.as_str()),
            json_string(self.location.label()),
            json_string(self.origin.kind.as_str()),
            json_string(self.folder_kind()),
            self.symlinked_container,
            self.stats.character_count,
            self.stats.word_count,
            self.stats.token_estimate,
            self.stats.skill_file_character_count,
            self.stats.skill_file_word_count,
            self.stats.skill_file_token_estimate,
            self.stats.text_file_count,
            self.stats.reference_file_count,
            self.stats.script_file_count,
            self.stats.asset_file_count,
            self.stats.other_file_count,
            self.stats.other_folder_count,
            self.stats.has_openai_yaml,
            self.stats.has_icon_small,
            self.stats.has_icon_large,
            self.stats.has_icon_and_logo
        );

        if let Some(source) = &self.origin.source {
            write!(out, ",\"source\":{}", json_string(source)).expect("write to string");
        }
        if let Some(source_type) = &self.origin.source_type {
            write!(out, ",\"source_type\":{}", json_string(source_type)).expect("write to string");
        }
        if let Some(source_url) = &self.origin.source_url {
            write!(out, ",\"source_url\":{}", json_string(source_url)).expect("write to string");
        }
        if let Some(ref_name) = &self.origin.ref_name {
            write!(out, ",\"ref\":{}", json_string(ref_name)).expect("write to string");
        }
        if let Some(installed_at) = &self.origin.installed_at {
            write!(out, ",\"installed_at\":{}", json_string(installed_at))
                .expect("write to string");
        }
        if let Some(updated_at) = &self.origin.updated_at {
            write!(out, ",\"updated_at\":{}", json_string(updated_at)).expect("write to string");
        }
        if let Some(icon_small) = &self.stats.icon_small {
            write!(out, ",\"icon_small_path\":{}", json_string(icon_small))
                .expect("write to string");
        }
        if let Some(icon_large) = &self.stats.icon_large {
            write!(out, ",\"icon_large_path\":{}", json_string(icon_large))
                .expect("write to string");
        }

        out.push('}');
        out
    }

    fn folder_kind(&self) -> &'static str {
        if self.symlinked_container {
            return "symlinked";
        }
        if path_has_component(&self.path, ".system") {
            return "system";
        }
        match self.location {
            SkillLocation::Agents => match self.origin.kind {
                SkillOriginKind::NpxSkills => "npx-installed",
                SkillOriginKind::Native => "native",
                SkillOriginKind::NotApplicable => "agents-local",
            },
            SkillLocation::Codex => "codex-local",
            SkillLocation::Claude => "claude-local",
        }
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

    pub fn to_json(&self) -> String {
        let warning_count = self
            .projects
            .iter()
            .map(ProjectSyncReport::warning_count)
            .sum::<usize>();
        let action_count = self
            .projects
            .iter()
            .map(ProjectSyncReport::action_count)
            .sum::<usize>();
        let skipped_count = self
            .projects
            .iter()
            .map(ProjectSyncReport::skipped_count)
            .sum::<usize>();
        let dotagents_count = self
            .projects
            .iter()
            .filter(|project| project.uses_dotagents())
            .count();
        let valid_skill_count = self
            .projects
            .iter()
            .map(|project| project.valid_skill_count)
            .sum::<usize>();

        let mut out = format!(
            "{{\"apply\":{},\"mode\":{},\"summary\":{{\"project_count\":{},\"valid_skill_count\":{},\"warning_count\":{},\"action_count\":{},\"skipped_count\":{},\"dotagents_count\":{}}},\"projects\":[",
            self.apply,
            json_string(self.mode_label()),
            self.projects.len(),
            valid_skill_count,
            warning_count,
            action_count,
            skipped_count,
            dotagents_count
        );

        for (index, project) in self.projects.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            out.push_str(&project.to_json());
        }

        out.push_str("]}");
        out
    }
}

#[derive(Debug)]
pub struct ProjectSyncReport {
    pub root: PathBuf,
    pub valid_skill_count: usize,
    pub lines: Vec<String>,
}

impl ProjectSyncReport {
    fn warning_count(&self) -> usize {
        self.lines
            .iter()
            .filter(|line| sync_line_kind(line) == "warning")
            .count()
    }

    fn action_count(&self) -> usize {
        self.lines
            .iter()
            .filter(|line| sync_line_kind(line) == "action")
            .count()
    }

    fn skipped_count(&self) -> usize {
        self.lines
            .iter()
            .filter(|line| sync_line_kind(line) == "skipped")
            .count()
    }

    fn uses_dotagents(&self) -> bool {
        self.lines.iter().any(|line| {
            line.starts_with("dotagents:") || line == "would run: npx @sentry/dotagents sync"
        })
    }

    fn to_json(&self) -> String {
        let name = self.root.file_name().and_then(OsStr::to_str).unwrap_or("");
        let mut out = format!(
            "{{\"root\":{},\"name\":{},\"valid_skill_count\":{},\"warning_count\":{},\"action_count\":{},\"skipped_count\":{},\"uses_dotagents\":{},\"lines\":[",
            json_string(&self.root.display().to_string()),
            json_string(name),
            self.valid_skill_count,
            self.warning_count(),
            self.action_count(),
            self.skipped_count(),
            self.uses_dotagents()
        );

        for (index, line) in self.lines.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            write!(
                out,
                "{{\"kind\":{},\"text\":{}}}",
                json_string(sync_line_kind(line)),
                json_string(line)
            )
            .expect("write to string");
        }

        out.push_str("]}");
        out
    }
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

#[derive(Debug)]
pub struct SkillsFormatReport {
    pub apply: bool,
    pub items: Vec<SkillsFormatItem>,
}

impl SkillsFormatReport {
    pub fn has_changes(&self) -> bool {
        self.items.iter().any(|item| item.changed)
    }

    pub fn has_errors(&self) -> bool {
        self.items.iter().any(|item| !item.errors.is_empty())
    }
}

#[derive(Debug)]
pub struct SkillsFormatItem {
    pub path: PathBuf,
    pub changed: bool,
    pub errors: Vec<String>,
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

pub fn load_user_config() -> Result<MetagentConfig, String> {
    let path = user_config_path();
    if !path.is_file() {
        return Ok(MetagentConfig::default());
    }
    let text = fs::read_to_string(&path)
        .map_err(|error| format!("failed reading {}: {error}", path.display()))?;
    parse_config(&text).map_err(|error| format!("invalid {}: {error}", path.display()))
}

pub fn user_config_path() -> PathBuf {
    home_dir().join(".config/metagent/config.toml")
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
    let ignored = expanded_paths(&options.ignore_projects);
    let mut project_roots = scan
        .projects
        .iter()
        .map(|project| project.root.clone())
        .collect::<BTreeSet<_>>();
    for root in &options.roots {
        let expanded = expand_tilde(root);
        if !expanded.is_dir() {
            continue;
        }
        discover_dotagents_config_dirs(&expanded, options.max_depth, 0, &mut project_roots)
            .map_err(|error| format!("failed scanning {}: {error}", expanded.display()))?;
    }

    let mut projects = scan.projects;
    for root in project_roots {
        if projects
            .iter()
            .any(|project| same_path(&project.root, &root))
            || ignored
                .iter()
                .any(|ignored_root| same_path(&root, ignored_root))
        {
            continue;
        }
        projects.push(read_project_skills(root)?);
    }
    projects.sort_by(|left, right| left.root.cmp(&right.root));

    let mut items = Vec::new();

    if projects.is_empty() {
        items.push(DoctorItem {
            level: DoctorLevel::Warn,
            message: "no projects with .agents/skills found".to_string(),
        });
    }

    for project in projects {
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

        check_agents_toml(&project, &mut items);
        check_competing_skill_registries(&project, &mut items);
        check_cleanup_candidates(&project, &mut items);
        check_legacy_command_prompts(&project, &mut items);

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

fn check_agents_toml(project: &ProjectSkills, items: &mut Vec<DoctorItem>) {
    let Some(agents_toml) = agents_toml_path(project) else {
        items.push(DoctorItem {
            level: DoctorLevel::Warn,
            message: format!("{} missing", expected_agents_toml_path(project).display()),
        });
        return;
    };

    items.push(DoctorItem {
        level: DoctorLevel::Ok,
        message: format!("{} exists", agents_toml.display()),
    });

    let Ok(text) = fs::read_to_string(&agents_toml) else {
        items.push(DoctorItem {
            level: DoctorLevel::Warn,
            message: format!("{} could not be read", agents_toml.display()),
        });
        return;
    };

    let declared = parse_agents_toml_skills(&text);
    if declared.declarations.is_empty() {
        items.push(DoctorItem {
            level: DoctorLevel::Warn,
            message: format!("{} declares no skills", agents_toml.display()),
        });
        return;
    }

    let actual = project
        .valid_skills
        .iter()
        .map(|skill| skill.name.clone())
        .collect::<BTreeSet<_>>();
    let declared_names = declared_skill_names(&declared);
    for (name, source_name) in declaration_name_source_mismatches(&declared) {
        items.push(DoctorItem {
            level: DoctorLevel::Warn,
            message: format!(
                "{} declares skill {} with mismatched path source basename {}",
                agents_toml.display(),
                name,
                source_name
            ),
        });
    }

    for name in actual.difference(&declared_names) {
        items.push(DoctorItem {
            level: DoctorLevel::Warn,
            message: format!(
                "{} has on-disk skill not declared in {}: {}",
                project.skills_dir.display(),
                agents_toml.display(),
                name
            ),
        });
    }

    for name in declared_names.difference(&actual) {
        items.push(DoctorItem {
            level: DoctorLevel::Warn,
            message: format!(
                "{} declares missing skill folder: {}",
                agents_toml.display(),
                name
            ),
        });
    }
}

fn check_competing_skill_registries(project: &ProjectSkills, items: &mut Vec<DoctorItem>) {
    let dotagents_config = agents_toml_path(project);
    let dotagents_lock = dotagents_lock_path(project, dotagents_config.as_deref());
    let legacy_lock = legacy_skill_lock_path(project);

    if legacy_lock.is_file() && dotagents_config.is_some() {
        items.push(DoctorItem {
            level: DoctorLevel::Warn,
            message: format!(
                "{} exists beside dotagents config; treat agents.toml/agents.lock and skills/ as source of truth",
                legacy_lock.display()
            ),
        });
    }

    if dotagents_config.is_some() && !dotagents_lock.is_file() {
        items.push(DoctorItem {
            level: DoctorLevel::Warn,
            message: format!("{} missing", dotagents_lock.display()),
        });
    }

    if is_user_agents_project(project) {
        items.push(DoctorItem {
            level: DoctorLevel::Warn,
            message: "user-space ~/.agents layout detected; validate with `npx @sentry/dotagents --user list` before sync/apply mutations".to_string(),
        });
    }
}

fn check_cleanup_candidates(project: &ProjectSkills, items: &mut Vec<DoctorItem>) {
    for root in cleanup_search_roots(project) {
        let Ok(entries) = fs::read_dir(&root) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(OsStr::to_str) else {
                continue;
            };
            if name.starts_with(".system-skills.bak-") || name.starts_with("agents.toml.bak-") {
                items.push(DoctorItem {
                    level: DoctorLevel::Warn,
                    message: format!("{} looks like a backup cleanup candidate", path.display()),
                });
            }
        }
    }
}

fn check_legacy_command_prompts(project: &ProjectSkills, items: &mut Vec<DoctorItem>) {
    for commands_dir in command_prompt_dirs(project) {
        let Ok(entries) = fs::read_dir(&commands_dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Some(name) = path.file_name().and_then(OsStr::to_str) else {
                continue;
            };
            if name.starts_with("rp-") && name.ends_with(".md") {
                items.push(DoctorItem {
                    level: DoctorLevel::Warn,
                    message: format!(
                        "{} is a RepoPrompt command prompt; verify RepoPrompt MCP is configured, loaded, and read-only verified before keeping it",
                        path.display()
                    ),
                });
            }
        }
    }
}

pub fn skills_format(options: &SkillsFormatOptions) -> Result<SkillsFormatReport, String> {
    let scan = skills_scan(&SkillsScanOptions {
        roots: options.roots.clone(),
        ignore_projects: options.ignore_projects.clone(),
        max_depth: options.max_depth,
        output_format: OutputFormat::Text,
    })?;
    let mut items = Vec::new();

    for project in scan.projects {
        for skill in project.valid_skills {
            items.extend(format_skill_dir(&skill.path, &skill.name, options.apply)?);
        }
        for skill_dir in project.invalid_skill_dirs {
            let Some(name) = skill_dir.file_name().and_then(OsStr::to_str) else {
                items.push(SkillsFormatItem {
                    path: skill_dir,
                    changed: false,
                    errors: vec!["invalid non-Unicode skill folder name".to_string()],
                });
                continue;
            };

            items.extend(format_skill_dir(&skill_dir, name, options.apply)?);
        }
    }

    Ok(SkillsFormatReport {
        apply: options.apply,
        items,
    })
}

fn format_skill_dir(
    skill_dir: &Path,
    expected_name: &str,
    apply: bool,
) -> Result<Vec<SkillsFormatItem>, String> {
    let skill_md = skill_dir.join("SKILL.md");
    let mut items = vec![format_skill_markdown(&skill_md, expected_name, apply)?];
    validate_skill_name_rules("skill folder name", expected_name, &mut items[0].errors);

    for path in skill_text_files(skill_dir)? {
        if path != skill_md {
            items.push(format_text_file(&path, apply)?);
        }
    }

    Ok(items)
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
            valid_skill_count: project.valid_skills.len(),
            lines,
        });
    }

    retire_nested_agents_toml(&project.root, options.apply, &mut lines)?;
    if !ensure_agents_toml(project, options, &mut lines)? {
        return Ok(ProjectSyncReport {
            root: project.root.clone(),
            valid_skill_count: project.valid_skills.len(),
            lines,
        });
    }
    prepare_claude_skills(&project.root, options, &mut lines)?;

    if !options.run_dotagents {
        lines.push("skipped dotagents sync due to --no-dotagents".to_string());
        return Ok(ProjectSyncReport {
            root: project.root.clone(),
            valid_skill_count: project.valid_skills.len(),
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
        valid_skill_count: project.valid_skills.len(),
        lines,
    })
}

fn sync_line_kind(line: &str) -> &'static str {
    if line.starts_with("warning:") || line.starts_with("dotagents stderr:") {
        return "warning";
    }
    if line.starts_with("skipped") {
        return "skipped";
    }
    if line.starts_with("would ")
        || line.starts_with("backed up ")
        || line.starts_with("created ")
        || line.starts_with("moved ")
        || line.starts_with("updated ")
        || line.starts_with("replaced ")
        || line.starts_with("retired ")
        || line.starts_with("wrote ")
        || line.starts_with("linked ")
        || line.starts_with("dotagents:")
    {
        return "action";
    }
    "info"
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

fn agents_toml_path(project: &ProjectSkills) -> Option<PathBuf> {
    let primary = project.root.join("agents.toml");
    if primary.is_file() {
        return Some(primary);
    }

    let user_space = project.root.join(".agents/agents.toml");
    if user_space.is_file() {
        return Some(user_space);
    }

    None
}

fn expected_agents_toml_path(project: &ProjectSkills) -> PathBuf {
    project.root.join("agents.toml")
}

fn dotagents_lock_path(project: &ProjectSkills, agents_toml: Option<&Path>) -> PathBuf {
    if agents_toml.is_some_and(|path| same_path(path, &project.root.join(".agents/agents.toml"))) {
        project.root.join(".agents/agents.lock")
    } else {
        project.root.join("agents.lock")
    }
}

fn legacy_skill_lock_path(project: &ProjectSkills) -> PathBuf {
    if is_user_agents_project(project) {
        project.root.join(".agents/.skill-lock.json")
    } else {
        project.root.join(".agents/.skill-lock.json")
    }
}

fn is_user_agents_project(project: &ProjectSkills) -> bool {
    same_path(&project.skills_dir, &project.root.join(".agents/skills"))
        && same_path(&project.root, &home_dir())
}

fn cleanup_search_roots(project: &ProjectSkills) -> Vec<PathBuf> {
    let mut roots = vec![project.root.clone()];
    let agents_root = project.skills_dir.parent().unwrap_or(&project.root);
    if !same_path(agents_root, &project.root) {
        roots.push(agents_root.to_path_buf());
    }
    roots
}

fn command_prompt_dirs(project: &ProjectSkills) -> Vec<PathBuf> {
    let mut dirs = vec![
        project.root.join("commands"),
        project.root.join(".codex/prompts"),
        project.root.join(".claude/commands"),
    ];
    if let Some(agents_root) = project.skills_dir.parent() {
        dirs.push(agents_root.join("commands"));
    }
    dirs
}

fn read_project_skills(root: PathBuf) -> Result<ProjectSkills, String> {
    let skills_dir = root.join(".agents/skills");
    let skill_lock = read_skill_lock(&root.join(".agents/.skill-lock.json"));
    let mut valid_skills = Vec::new();
    let mut skill_inventory = Vec::new();
    let mut invalid_skill_dirs = Vec::new();
    let mut hidden_skill_dirs = Vec::new();

    read_agents_skill_dir(
        &skills_dir,
        &skill_lock,
        &mut valid_skills,
        &mut skill_inventory,
        &mut invalid_skill_dirs,
        &mut hidden_skill_dirs,
    )?;
    read_inventory_skill_dir(
        &root.join(".codex/skills"),
        SkillLocation::Codex,
        &mut skill_inventory,
    )?;
    read_inventory_skill_dir(
        &root.join(".claude/skills"),
        SkillLocation::Claude,
        &mut skill_inventory,
    )?;

    valid_skills.sort_by(|left, right| left.name.cmp(&right.name));
    skill_inventory.sort_by(|left, right| {
        left.location
            .as_str()
            .cmp(right.location.as_str())
            .then_with(|| left.name.cmp(&right.name))
            .then_with(|| left.path.cmp(&right.path))
    });
    invalid_skill_dirs.sort();
    hidden_skill_dirs.sort();

    Ok(ProjectSkills {
        root,
        skills_dir,
        valid_skills,
        skill_inventory,
        invalid_skill_dirs,
        hidden_skill_dirs,
    })
}

fn read_agents_skill_dir(
    skills_dir: &Path,
    skill_lock: &BTreeMap<String, SkillOrigin>,
    valid_skills: &mut Vec<Skill>,
    skill_inventory: &mut Vec<Skill>,
    invalid_skill_dirs: &mut Vec<PathBuf>,
    hidden_skill_dirs: &mut Vec<PathBuf>,
) -> Result<(), String> {
    if !skills_dir.exists() {
        return Ok(());
    }

    for entry in fs::read_dir(skills_dir)
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
            let skill = Skill {
                name: name.to_string(),
                path: path.clone(),
                location: SkillLocation::Agents,
                origin: skill_lock
                    .get(name)
                    .cloned()
                    .unwrap_or_else(SkillOrigin::native),
                symlinked_container: is_symlink(skills_dir),
                stats: skill_stats(&path),
            };
            valid_skills.push(skill.clone());
            skill_inventory.push(skill);
        } else {
            invalid_skill_dirs.push(path);
        }
    }

    Ok(())
}

fn read_inventory_skill_dir(
    skills_dir: &Path,
    location: SkillLocation,
    skill_inventory: &mut Vec<Skill>,
) -> Result<(), String> {
    if !skills_dir.exists() {
        return Ok(());
    }

    collect_inventory_skills(
        skills_dir,
        &location,
        0,
        2,
        is_symlink(skills_dir),
        skill_inventory,
    )
}

fn collect_inventory_skills(
    dir: &Path,
    location: &SkillLocation,
    depth: usize,
    max_depth: usize,
    symlinked_container: bool,
    skill_inventory: &mut Vec<Skill>,
) -> Result<(), String> {
    if depth > max_depth {
        return Ok(());
    }

    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::PermissionDenied
            ) =>
        {
            return Ok(());
        }
        Err(error) => return Err(format!("failed reading {}: {error}", dir.display())),
    };

    for entry in entries {
        let entry = entry.map_err(|error| format!("failed reading dir entry: {error}"))?;
        let path = entry.path();
        let file_type = entry
            .file_type()
            .map_err(|error| format!("failed reading file type for {}: {error}", path.display()))?;

        if !file_type.is_dir() && !file_type.is_symlink() {
            continue;
        }
        if file_type.is_symlink() && !path.exists() {
            continue;
        }

        if path.join("SKILL.md").is_file() {
            if let Some(name) = path.file_name().and_then(OsStr::to_str) {
                if is_valid_skill_name(name) {
                    skill_inventory.push(Skill {
                        name: name.to_string(),
                        path: path.clone(),
                        location: location.clone(),
                        origin: SkillOrigin::not_applicable(),
                        symlinked_container,
                        stats: skill_stats(&path),
                    });
                }
            }
            continue;
        }

        if depth < max_depth && !should_prune(&path) {
            collect_inventory_skills(
                &path,
                location,
                depth + 1,
                max_depth,
                symlinked_container,
                skill_inventory,
            )?;
        }
    }

    Ok(())
}

fn skill_stats(skill_dir: &Path) -> SkillStats {
    let mut stats = SkillStats::default();
    let mut other_folders = BTreeSet::new();

    read_openai_yaml(skill_dir, &mut stats);
    collect_skill_stats(skill_dir, skill_dir, &mut stats, &mut other_folders);
    stats.token_estimate = estimate_tokens(stats.character_count);
    stats.skill_file_token_estimate = estimate_tokens(stats.skill_file_character_count);
    stats.other_folder_count = other_folders.len();
    stats.has_icon_and_logo = stats.has_icon_small && stats.has_icon_large;
    stats
}

fn collect_skill_stats(
    root: &Path,
    dir: &Path,
    stats: &mut SkillStats,
    other_folders: &mut BTreeSet<String>,
) {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let file_type = match entry.file_type() {
            Ok(file_type) => file_type,
            Err(_) => continue,
        };

        if file_type.is_dir() {
            if should_prune(&path) {
                continue;
            }
            collect_skill_stats(root, &path, stats, other_folders);
            continue;
        }

        if file_type.is_symlink() && !path.exists() {
            continue;
        }
        if !file_type.is_file() {
            continue;
        }

        categorize_skill_file(root, &path, stats, other_folders);
        if is_skill_text_file(&path) {
            stats.text_file_count += 1;
            if let Ok(text) = fs::read_to_string(&path) {
                let character_count = text.chars().count();
                let word_count = text.split_whitespace().count();
                stats.character_count += character_count;
                stats.word_count += word_count;

                if path.file_name() == Some(OsStr::new("SKILL.md")) {
                    stats.skill_file_character_count += character_count;
                    stats.skill_file_word_count += word_count;
                }
            }
        }
    }
}

fn categorize_skill_file(
    root: &Path,
    path: &Path,
    stats: &mut SkillStats,
    other_folders: &mut BTreeSet<String>,
) {
    let Some(top_level) = top_level_component(root, path) else {
        return;
    };

    match top_level.as_str() {
        "SKILL.md" => {}
        "references" => stats.reference_file_count += 1,
        "scripts" => stats.script_file_count += 1,
        "assets" => stats.asset_file_count += 1,
        "agents" if path.file_name() == Some(OsStr::new("openai.yaml")) => {}
        _ => {
            stats.other_file_count += 1;
            if top_level != "agents" && path.parent() != Some(root) {
                other_folders.insert(top_level);
            }
        }
    }
}

fn top_level_component(root: &Path, path: &Path) -> Option<String> {
    let relative = path.strip_prefix(root).ok()?;
    let component = relative.components().next()?;
    let normal = component.as_os_str().to_str()?;
    Some(normal.to_string())
}

fn read_openai_yaml(skill_dir: &Path, stats: &mut SkillStats) {
    let path = skill_dir.join("agents/openai.yaml");
    if !path.is_file() {
        return;
    }

    stats.has_openai_yaml = true;
    let Ok(text) = fs::read_to_string(&path) else {
        return;
    };

    stats.icon_small = yaml_string_value(&text, "icon_small");
    stats.icon_large = yaml_string_value(&text, "icon_large");
    stats.has_icon_small = stats.icon_small.is_some();
    stats.has_icon_large = stats.icon_large.is_some();
}

fn yaml_string_value(text: &str, key: &str) -> Option<String> {
    let prefix = format!("{key}:");
    for line in text.lines() {
        let trimmed = line.trim_start();
        let Some(value) = trimmed.strip_prefix(&prefix) else {
            continue;
        };
        let value = value
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .to_string();
        if !value.is_empty() {
            return Some(value);
        }
    }
    None
}

fn estimate_tokens(character_count: usize) -> usize {
    (character_count + 3) / 4
}

fn path_has_component(path: &Path, expected: &str) -> bool {
    path.components()
        .any(|component| component.as_os_str() == OsStr::new(expected))
}

fn skill_text_files(skill_dir: &Path) -> Result<Vec<PathBuf>, String> {
    let mut paths = Vec::new();
    collect_skill_text_files(skill_dir, &mut paths)?;
    paths.sort();
    Ok(paths)
}

fn collect_skill_text_files(dir: &Path, paths: &mut Vec<PathBuf>) -> Result<(), String> {
    let entries =
        fs::read_dir(dir).map_err(|error| format!("failed reading {}: {error}", dir.display()))?;

    for entry in entries {
        let entry = entry.map_err(|error| format!("failed reading dir entry: {error}"))?;
        let path = entry.path();
        let file_type = entry
            .file_type()
            .map_err(|error| format!("failed reading file type for {}: {error}", path.display()))?;

        if file_type.is_dir() {
            if should_prune(&path) {
                continue;
            }
            collect_skill_text_files(&path, paths)?;
            continue;
        }

        if file_type.is_file() && is_skill_text_file(&path) {
            paths.push(path);
        }
    }

    Ok(())
}

fn is_skill_text_file(path: &Path) -> bool {
    matches!(
        path.extension().and_then(OsStr::to_str),
        Some(
            "md" | "markdown"
                | "txt"
                | "toml"
                | "yaml"
                | "yml"
                | "json"
                | "sh"
                | "py"
                | "js"
                | "ts"
                | "tsx"
                | "css"
                | "html"
        )
    )
}

fn format_skill_markdown(
    path: &Path,
    expected_name: &str,
    apply: bool,
) -> Result<SkillsFormatItem, String> {
    let raw = fs::read_to_string(path)
        .map_err(|error| format!("failed reading {}: {error}", path.display()))?;
    let formatted = normalize_text_file(&raw);
    let mut errors = validate_skill_markdown(&formatted, expected_name);
    let changed = raw != formatted;

    if apply && changed {
        fs::write(path, formatted)
            .map_err(|error| format!("failed writing {}: {error}", path.display()))?;
    } else if !apply && changed {
        errors.push("needs whitespace normalization; rerun with --apply".to_string());
    }

    Ok(SkillsFormatItem {
        path: path.to_path_buf(),
        changed,
        errors,
    })
}

fn format_text_file(path: &Path, apply: bool) -> Result<SkillsFormatItem, String> {
    let raw = fs::read_to_string(path)
        .map_err(|error| format!("failed reading {}: {error}", path.display()))?;
    let formatted = normalize_text_file(&raw);
    let changed = raw != formatted;
    let mut errors = Vec::new();

    if apply && changed {
        fs::write(path, formatted)
            .map_err(|error| format!("failed writing {}: {error}", path.display()))?;
    } else if !apply && changed {
        errors.push("needs whitespace normalization; rerun with --apply".to_string());
    }

    Ok(SkillsFormatItem {
        path: path.to_path_buf(),
        changed,
        errors,
    })
}

fn normalize_text_file(text: &str) -> String {
    let mut out = String::new();
    let mut blank_count = 0;

    for raw_line in text.replace("\r\n", "\n").replace('\r', "\n").lines() {
        let line = raw_line.trim_end_matches([' ', '\t']);
        if line.is_empty() {
            blank_count += 1;
            if blank_count <= 2 {
                out.push('\n');
            }
            continue;
        }

        blank_count = 0;
        out.push_str(line);
        out.push('\n');
    }

    while out.starts_with('\n') {
        out.remove(0);
    }
    while out.ends_with("\n\n") {
        out.pop();
    }
    if !out.ends_with('\n') {
        out.push('\n');
    }
    out
}

fn validate_skill_markdown(text: &str, expected_name: &str) -> Vec<String> {
    let mut errors = Vec::new();

    if !text.starts_with("---\n") {
        errors.push("SKILL.md must start with YAML frontmatter".to_string());
        return errors;
    }

    let Some(rest) = text.strip_prefix("---\n") else {
        return errors;
    };
    let Some((frontmatter, body)) = rest.split_once("\n---\n") else {
        errors.push("SKILL.md frontmatter must close with ---".to_string());
        return errors;
    };

    match parse_skill_frontmatter(frontmatter) {
        Ok(mapping) => validate_skill_frontmatter(&mapping, expected_name, &mut errors),
        Err(error) => errors.push(error),
    }

    if body.trim().is_empty() {
        errors.push("SKILL.md body must not be empty".to_string());
    }

    errors
}

fn parse_skill_frontmatter(frontmatter: &str) -> Result<serde_norway::Mapping, String> {
    let value = serde_norway::from_str::<serde_norway::Value>(frontmatter)
        .map_err(|error| format!("invalid YAML in frontmatter: {error}"))?;

    match value {
        serde_norway::Value::Mapping(mapping) => Ok(mapping),
        _ => Err("frontmatter must be a YAML dictionary".to_string()),
    }
}

fn validate_skill_frontmatter(
    mapping: &serde_norway::Mapping,
    expected_name: &str,
    errors: &mut Vec<String>,
) {
    validate_frontmatter_keys(mapping, errors);

    match frontmatter_string(mapping, "name") {
        FrontmatterFieldValue::String(value) => {
            validate_skill_name_value(value, expected_name, errors)
        }
        FrontmatterFieldValue::Missing => errors.push("frontmatter must include name".to_string()),
        FrontmatterFieldValue::WrongType => {
            errors.push("frontmatter name must be a string".to_string())
        }
    }

    match frontmatter_string(mapping, "description") {
        FrontmatterFieldValue::String(value) => validate_skill_description_value(value, errors),
        FrontmatterFieldValue::Missing => {
            errors.push("frontmatter must include description".to_string())
        }
        FrontmatterFieldValue::WrongType => {
            errors.push("frontmatter description must be a string".to_string())
        }
    }
}

fn validate_frontmatter_keys(mapping: &serde_norway::Mapping, errors: &mut Vec<String>) {
    for key in mapping.keys() {
        let Some(key) = key.as_str() else {
            errors.push("frontmatter keys must be strings".to_string());
            continue;
        };
        if !ALLOWED_SKILL_FRONTMATTER_KEYS.contains(&key) {
            errors.push(format!(
                "unexpected frontmatter key {key}; allowed keys are allowed-tools, description, license, metadata, name"
            ));
        }
    }
}

enum FrontmatterFieldValue<'a> {
    Missing,
    WrongType,
    String(&'a str),
}

fn frontmatter_string<'a>(
    mapping: &'a serde_norway::Mapping,
    key: &str,
) -> FrontmatterFieldValue<'a> {
    match mapping.get(key) {
        None => FrontmatterFieldValue::Missing,
        Some(serde_norway::Value::String(value)) => FrontmatterFieldValue::String(value.trim()),
        Some(_) => FrontmatterFieldValue::WrongType,
    }
}

fn validate_skill_name_value(value: &str, expected_name: &str, errors: &mut Vec<String>) {
    if value != expected_name {
        errors.push(format!(
            "frontmatter name must match folder name ({expected_name}), got {value}"
        ));
    }
    validate_skill_name_rules("frontmatter name", value, errors);
}

fn validate_skill_name_rules(label: &str, value: &str, errors: &mut Vec<String>) {
    if value.is_empty() {
        errors.push(format!("{label} must not be empty"));
        return;
    }
    if !is_openai_skill_name(value) {
        errors.push(format!(
            "{label} {value} should be hyphen-case lowercase letters, digits, and hyphens only"
        ));
    }
    if value.starts_with('-') || value.ends_with('-') || value.contains("--") {
        errors.push(format!(
            "{label} {value} cannot start/end with hyphen or contain consecutive hyphens"
        ));
    }
    if value.len() > MAX_SKILL_NAME_LENGTH {
        errors.push(format!(
            "{label} is too long ({} characters); maximum is {MAX_SKILL_NAME_LENGTH}",
            value.len()
        ));
    }
}

fn validate_skill_description_value(value: &str, errors: &mut Vec<String>) {
    if value.is_empty() {
        errors.push("frontmatter description must not be empty".to_string());
        return;
    }
    if value.contains('<') || value.contains('>') {
        errors.push("frontmatter description cannot contain angle brackets".to_string());
    }
    if value.len() > MAX_SKILL_DESCRIPTION_LENGTH {
        errors.push(format!(
            "frontmatter description is too long ({} characters); maximum is {MAX_SKILL_DESCRIPTION_LENGTH}",
            value.len()
        ));
    }
}

fn is_openai_skill_name(name: &str) -> bool {
    name.chars()
        .all(|char| char.is_ascii_lowercase() || char.is_ascii_digit() || char == '-')
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

    if is_known_skills_dir(dir) {
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
        let path = entry.path();
        if is_known_skills_dir(&path) {
            if let Some(project_root) = path.parent().and_then(Path::parent) {
                projects.insert(project_root.to_path_buf());
            }
            continue;
        }
        let file_type = match entry.file_type() {
            Ok(file_type) => file_type,
            Err(error) if is_permission_error(&error) => continue,
            Err(error) => return Err(error),
        };
        if file_type.is_dir() {
            discover_skill_dirs(&path, max_depth, depth + 1, projects)?;
        }
    }

    Ok(())
}

fn discover_dotagents_config_dirs(
    dir: &Path,
    max_depth: usize,
    depth: usize,
    projects: &mut BTreeSet<PathBuf>,
) -> io::Result<()> {
    if dir.file_name() == Some(OsStr::new(".agents")) {
        if depth == 0 && dir.join("agents.toml").is_file() {
            if let Some(parent) = dir.parent() {
                projects.insert(parent.to_path_buf());
            }
        }
        return Ok(());
    }

    if depth > max_depth {
        return Ok(());
    }

    if should_prune(dir) && depth > 0 {
        return Ok(());
    }

    if dir.join("agents.toml").is_file() || dir.join(".agents/agents.toml").is_file() {
        projects.insert(dir.to_path_buf());
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
            discover_dotagents_config_dirs(&entry.path(), max_depth, depth + 1, projects)?;
        }
    }

    Ok(())
}

fn is_known_skills_dir(path: &Path) -> bool {
    if path.file_name() != Some(OsStr::new("skills")) {
        return false;
    }

    matches!(
        path.parent().and_then(Path::file_name),
        Some(parent)
            if parent == OsStr::new(".agents")
                || parent == OsStr::new(".codex")
                || parent == OsStr::new(".claude")
    )
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
    path.with_file_name(format!("{file_name}.bak-metagent-{timestamp}"))
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

fn parse_agents_toml_skills(text: &str) -> AgentsTomlSkills {
    let mut declared = AgentsTomlSkills::default();
    let mut current: Option<AgentsTomlSkillDeclaration> = None;

    for raw_line in text.lines() {
        let line = raw_line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if is_skills_array_header(line) {
            push_skill_declaration(&mut declared, current.take());
            current = Some(AgentsTomlSkillDeclaration::default());
            continue;
        }
        if line.starts_with('[') {
            push_skill_declaration(&mut declared, current.take());
            continue;
        }
        let Some(declaration) = &mut current else {
            continue;
        };

        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let Some(value) = parse_quoted_value(value.trim()) else {
            continue;
        };

        match key.trim() {
            "name" => {
                declaration.name = Some(value);
            }
            "source" => {
                declaration.source = Some(value);
            }
            _ => {}
        }
    }

    push_skill_declaration(&mut declared, current);
    declared
}

fn is_skills_array_header(line: &str) -> bool {
    let Some(inner) = line
        .strip_prefix("[[")
        .and_then(|line| line.strip_suffix("]]"))
    else {
        return false;
    };
    inner.trim() == "skills"
}

fn push_skill_declaration(
    declared: &mut AgentsTomlSkills,
    declaration: Option<AgentsTomlSkillDeclaration>,
) {
    let Some(declaration) = declaration else {
        return;
    };
    if declaration.name.is_some() || declaration.source.is_some() {
        declared.declarations.push(declaration);
    }
}

fn declared_skill_names(declared: &AgentsTomlSkills) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    for declaration in &declared.declarations {
        match (&declaration.name, &declaration.source) {
            (Some(name), _) => {
                names.insert(name.clone());
            }
            (None, Some(source)) => {
                if let Some(name) = skill_name_from_source(source) {
                    names.insert(name);
                }
            }
            (None, None) => {}
        };
    }
    names
}

fn declaration_name_source_mismatches(declared: &AgentsTomlSkills) -> Vec<(String, String)> {
    declared
        .declarations
        .iter()
        .filter_map(|declaration| {
            let name = declaration.name.as_ref()?;
            let source_name = skill_name_from_source(declaration.source.as_ref()?)?;
            if name == &source_name {
                None
            } else {
                Some((name.clone(), source_name))
            }
        })
        .collect()
}

fn skill_name_from_source(source: &str) -> Option<String> {
    let path = source.strip_prefix("path:")?;
    let name = path
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("")
        .trim();
    if name.is_empty() {
        None
    } else {
        Some(name.to_string())
    }
}

fn parse_quoted_value(value: &str) -> Option<String> {
    if value.starts_with('"') {
        return parse_json_string(value, 0).map(|(parsed, _)| parsed);
    }

    parse_toml_literal_string(value)
}

fn parse_toml_literal_string(value: &str) -> Option<String> {
    let rest = value.strip_prefix('\'')?;
    let end = rest.find('\'')?;
    Some(rest[..end].to_string())
}

fn parse_config(text: &str) -> Result<MetagentConfig, String> {
    let mut config = MetagentConfig::default();

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

fn read_skill_lock(path: &Path) -> BTreeMap<String, SkillOrigin> {
    if !path.is_file() {
        return BTreeMap::new();
    }

    let Ok(text) = fs::read_to_string(path) else {
        return BTreeMap::new();
    };

    parse_skill_lock(&text).unwrap_or_default()
}

fn parse_skill_lock(text: &str) -> Result<BTreeMap<String, SkillOrigin>, String> {
    let Some(skills_object) = json_object_for_key(text, "skills") else {
        return Ok(BTreeMap::new());
    };
    let mut lock = BTreeMap::new();

    for (name, value) in parse_json_object_entries(skills_object)? {
        if !value.trim_start().starts_with('{') {
            continue;
        }
        let fields = parse_json_string_fields(&value)?;
        lock.insert(
            name,
            SkillOrigin {
                kind: SkillOriginKind::NpxSkills,
                source: fields.get("source").cloned(),
                source_type: fields.get("sourceType").cloned(),
                source_url: fields.get("sourceUrl").cloned(),
                ref_name: fields.get("ref").cloned(),
                installed_at: fields.get("installedAt").cloned(),
                updated_at: fields.get("updatedAt").cloned(),
            },
        );
    }

    Ok(lock)
}

fn parse_json_string_fields(text: &str) -> Result<BTreeMap<String, String>, String> {
    let mut fields = BTreeMap::new();
    for (key, value) in parse_json_object_entries(text)? {
        let value = value.trim_start();
        if !value.starts_with('"') {
            continue;
        }
        if let Some((parsed, _)) = parse_json_string(value, 0) {
            fields.insert(key, parsed);
        }
    }
    Ok(fields)
}

fn json_object_for_key<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    let bytes = text.as_bytes();
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] != b'"' {
            index += 1;
            continue;
        }

        let Some((parsed_key, after_key)) = parse_json_string(text, index) else {
            return None;
        };
        index = skip_json_ws(text, after_key);
        if parsed_key != key || bytes.get(index) != Some(&b':') {
            continue;
        }
        index = skip_json_ws(text, index + 1);
        if bytes.get(index) != Some(&b'{') {
            return None;
        }
        let Some((object, _)) = json_object_slice_at(text, index) else {
            return None;
        };
        return Some(object);
    }

    None
}

fn parse_json_object_entries(text: &str) -> Result<Vec<(String, String)>, String> {
    let bytes = text.as_bytes();
    if bytes.first() != Some(&b'{') {
        return Err("expected JSON object".to_string());
    }

    let mut entries = Vec::new();
    let mut index = 1;

    loop {
        index = skip_json_ws_and_commas(text, index);
        match bytes.get(index) {
            Some(b'}') => return Ok(entries),
            Some(b'"') => {}
            Some(_) => return Err("expected JSON object key".to_string()),
            None => return Err("unterminated JSON object".to_string()),
        }

        let Some((key, after_key)) = parse_json_string(text, index) else {
            return Err("invalid JSON object key".to_string());
        };
        index = skip_json_ws(text, after_key);
        if bytes.get(index) != Some(&b':') {
            return Err("expected ':' after JSON object key".to_string());
        }
        index = skip_json_ws(text, index + 1);
        let Some((value, after_value)) = json_value_slice_at(text, index) else {
            return Err("invalid JSON object value".to_string());
        };
        entries.push((key, value.to_string()));
        index = after_value;
    }
}

fn json_value_slice_at(text: &str, index: usize) -> Option<(&str, usize)> {
    let bytes = text.as_bytes();
    match bytes.get(index) {
        Some(b'{') => json_object_slice_at(text, index),
        Some(b'"') => {
            let (_, after_string) = parse_json_string(text, index)?;
            Some((&text[index..after_string], after_string))
        }
        Some(_) => {
            let mut end = index;
            while end < bytes.len() && bytes[end] != b',' && bytes[end] != b'}' {
                end += 1;
            }
            Some((&text[index..end], end))
        }
        None => None,
    }
}

fn json_object_slice_at(text: &str, index: usize) -> Option<(&str, usize)> {
    let bytes = text.as_bytes();
    if bytes.get(index) != Some(&b'{') {
        return None;
    }

    let mut depth = 0usize;
    let mut in_string = false;
    let mut escaped = false;
    let mut cursor = index;

    while cursor < bytes.len() {
        let byte = bytes[cursor];

        if in_string {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                in_string = false;
            }
            cursor += 1;
            continue;
        }

        match byte {
            b'"' => in_string = true,
            b'{' => depth += 1,
            b'}' => {
                depth = depth.checked_sub(1)?;
                if depth == 0 {
                    return Some((&text[index..=cursor], cursor + 1));
                }
            }
            _ => {}
        }
        cursor += 1;
    }

    None
}

fn parse_json_string(text: &str, index: usize) -> Option<(String, usize)> {
    let bytes = text.as_bytes();
    if bytes.get(index) != Some(&b'"') {
        return None;
    }

    let mut out = String::new();
    let mut cursor = index + 1;
    while cursor < bytes.len() {
        match bytes[cursor] {
            b'"' => return Some((out, cursor + 1)),
            b'\\' => {
                cursor += 1;
                match bytes.get(cursor)? {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{0008}'),
                    b'f' => out.push('\u{000c}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => {
                        if cursor + 4 >= bytes.len() {
                            return None;
                        }
                        cursor += 4;
                    }
                    other => out.push(*other as char),
                }
                cursor += 1;
            }
            _ => {
                let char = text[cursor..].chars().next()?;
                out.push(char);
                cursor += char.len_utf8();
            }
        }
    }

    None
}

fn skip_json_ws(text: &str, mut index: usize) -> usize {
    let bytes = text.as_bytes();
    while index < bytes.len() && matches!(bytes[index], b' ' | b'\n' | b'\r' | b'\t') {
        index += 1;
    }
    index
}

fn skip_json_ws_and_commas(text: &str, mut index: usize) -> usize {
    let bytes = text.as_bytes();
    while index < bytes.len() && matches!(bytes[index], b' ' | b'\n' | b'\r' | b'\t' | b',') {
        index += 1;
    }
    index
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
        assert_eq!(
            report.projects[0].skill_inventory[0].location,
            SkillLocation::Agents
        );
        assert_eq!(report.projects[0].hidden_skill_dirs.len(), 1);
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn scan_reports_codex_and_claude_skill_locations() {
        let temp = temp_dir("scan-locations");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".codex/skills/.system/skill-creator")).unwrap();
        fs::write(
            project.join(".codex/skills/.system/skill-creator/SKILL.md"),
            "---\n",
        )
        .unwrap();
        fs::create_dir_all(project.join(".claude/skills/refactor-cleanup")).unwrap();
        fs::write(
            project.join(".claude/skills/refactor-cleanup/SKILL.md"),
            "---\n",
        )
        .unwrap();

        let report = skills_scan(&SkillsScanOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            output_format: OutputFormat::Text,
        })
        .unwrap();
        let skills = &report.projects[0].skill_inventory;

        assert!(skills.iter().any(|skill| {
            skill.name == "skill-creator" && skill.location == SkillLocation::Codex
        }));
        assert!(skills.iter().any(|skill| {
            skill.name == "refactor-cleanup" && skill.location == SkillLocation::Claude
        }));
        assert!(report.to_json().contains("\"location\":\"codex\""));
        assert!(report.to_json().contains("\"location\":\"claude\""));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn scan_marks_agents_skills_from_skill_lock_as_npx_installed() {
        let temp = temp_dir("scan-origin");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/installed")).unwrap();
        fs::write(project.join(".agents/skills/installed/SKILL.md"), "---\n").unwrap();
        fs::create_dir_all(project.join(".agents/skills/native")).unwrap();
        fs::write(project.join(".agents/skills/native/SKILL.md"), "---\n").unwrap();
        fs::write(
            project.join(".agents/.skill-lock.json"),
            r#"{
  "version": 3,
  "skills": {
    "installed": {
      "source": "openai/skills",
      "sourceType": "github",
      "sourceUrl": "https://github.com/openai/skills.git",
      "ref": "main",
      "installedAt": "2026-01-01T00:00:00.000Z",
      "updatedAt": "2026-01-02T00:00:00.000Z"
    }
  }
}
"#,
        )
        .unwrap();

        let report = skills_scan(&SkillsScanOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            output_format: OutputFormat::Text,
        })
        .unwrap();
        let installed = report.projects[0]
            .skill_inventory
            .iter()
            .find(|skill| skill.name == "installed")
            .unwrap();
        let native = report.projects[0]
            .skill_inventory
            .iter()
            .find(|skill| skill.name == "native")
            .unwrap();

        assert_eq!(installed.origin.kind, SkillOriginKind::NpxSkills);
        assert_eq!(installed.origin.source.as_deref(), Some("openai/skills"));
        assert_eq!(native.origin.kind, SkillOriginKind::Native);
        assert!(report.to_json().contains("\"origin_kind\":\"npx-skills\""));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn scan_reports_skill_inventory_stats() {
        let temp = temp_dir("scan-stats");
        let project = temp.join("repo");
        let skill_dir = project.join(".agents/skills/with-meta");
        fs::create_dir_all(skill_dir.join("references")).unwrap();
        fs::create_dir_all(skill_dir.join("scripts")).unwrap();
        fs::create_dir_all(skill_dir.join("assets")).unwrap();
        fs::create_dir_all(skill_dir.join("examples")).unwrap();
        fs::create_dir_all(skill_dir.join("agents")).unwrap();
        fs::write(
            skill_dir.join("SKILL.md"),
            "---\nname: with-meta\ndescription: Count metadata\n---\nBody words here\n",
        )
        .unwrap();
        fs::write(skill_dir.join("references/guide.md"), "Reference words\n").unwrap();
        fs::write(skill_dir.join("scripts/run.sh"), "#!/bin/sh\necho run\n").unwrap();
        fs::write(skill_dir.join("assets/large-logo.svg"), "<svg></svg>\n").unwrap();
        fs::write(skill_dir.join("examples/example.txt"), "Example words\n").unwrap();
        fs::write(
            skill_dir.join("agents/openai.yaml"),
            r#"interface:
  icon_small: "./assets/small-400px.png"
  icon_large: "./assets/large-logo.svg"
"#,
        )
        .unwrap();

        let report = skills_scan(&SkillsScanOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            output_format: OutputFormat::Text,
        })
        .unwrap();
        let skill = report.projects[0]
            .skill_inventory
            .iter()
            .find(|skill| skill.name == "with-meta")
            .unwrap();

        assert_eq!(skill.folder_kind(), "native");
        assert!(skill.stats.character_count > 0);
        assert!(skill.stats.word_count > 0);
        assert!(skill.stats.token_estimate > 0);
        assert!(skill.stats.skill_file_token_estimate > 0);
        assert_eq!(skill.stats.reference_file_count, 1);
        assert_eq!(skill.stats.script_file_count, 1);
        assert_eq!(skill.stats.asset_file_count, 1);
        assert_eq!(skill.stats.other_file_count, 1);
        assert_eq!(skill.stats.other_folder_count, 1);
        assert!(skill.stats.has_openai_yaml);
        assert!(skill.stats.has_icon_small);
        assert!(skill.stats.has_icon_large);
        assert!(skill.stats.has_icon_and_logo);
        assert!(report.to_json().contains("\"folder_kind\":\"native\""));
        assert!(report.to_json().contains("\"has_icon_and_logo\":true"));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn format_check_flags_invalid_skill_frontmatter() {
        let temp = temp_dir("format-check");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(
            project.join(".agents/skills/alpha/SKILL.md"),
            "---\nname: wrong\n---\nBody\n",
        )
        .unwrap();

        let report = skills_format(&SkillsFormatOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            apply: false,
        })
        .unwrap();

        assert!(report.has_errors());
        assert!(report.items[0].errors.iter().any(|error| {
            error.contains("frontmatter name must match folder name")
                || error.contains("frontmatter must include description")
        }));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn format_check_covers_openai_frontmatter_rules() {
        let temp = temp_dir("format-openai");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/Bad_Name")).unwrap();
        fs::write(
            project.join(".agents/skills/Bad_Name/SKILL.md"),
            "---\nname: Bad_Name\ndescription: Has <angle>\nextra: nope\n---\nBody\n",
        )
        .unwrap();
        fs::create_dir_all(project.join(".agents/skills/number-name")).unwrap();
        fs::write(
            project.join(".agents/skills/number-name/SKILL.md"),
            "---\nname: 123\ndescription: true\n---\nBody\n",
        )
        .unwrap();
        fs::create_dir_all(project.join(".agents/skills/bad-yaml")).unwrap();
        fs::write(
            project.join(".agents/skills/bad-yaml/SKILL.md"),
            "---\nname: bad-yaml\ndescription: [unfinished\n---\nBody\n",
        )
        .unwrap();

        let report = skills_format(&SkillsFormatOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            apply: false,
        })
        .unwrap();
        let errors = report
            .items
            .iter()
            .flat_map(|item| item.errors.iter())
            .cloned()
            .collect::<Vec<_>>()
            .join("\n");

        assert!(errors.contains("unexpected frontmatter key extra"));
        assert!(errors.contains("should be hyphen-case lowercase"));
        assert!(errors.contains("cannot contain angle brackets"));
        assert!(errors.contains("frontmatter name must be a string"));
        assert!(errors.contains("frontmatter description must be a string"));
        assert!(errors.contains("invalid YAML in frontmatter"));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn format_check_reports_invalid_skill_folder_names() {
        let temp = temp_dir("format-invalid-folder");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/.system")).unwrap();
        fs::write(
            project.join(".agents/skills/.system/SKILL.md"),
            "---\nname: system\ndescription: Hidden system skill\n---\nBody\n",
        )
        .unwrap();

        let report = skills_format(&SkillsFormatOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            apply: false,
        })
        .unwrap();
        let errors = report
            .items
            .iter()
            .flat_map(|item| item.errors.iter())
            .cloned()
            .collect::<Vec<_>>()
            .join("\n");

        assert!(errors.contains("skill folder name .system should be hyphen-case"));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn format_apply_normalizes_skill_text_files() {
        let temp = temp_dir("format-apply");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/alpha/references")).unwrap();
        fs::write(
            project.join(".agents/skills/alpha/SKILL.md"),
            "---\r\nname: alpha   \r\ndescription: Test skill   \r\n---\r\n\r\nBody   \r\n\r\n\r\n",
        )
        .unwrap();
        fs::write(
            project.join(".agents/skills/alpha/references/example.md"),
            "Example   \r\n\r\n\r\n",
        )
        .unwrap();

        let report = skills_format(&SkillsFormatOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
            apply: true,
        })
        .unwrap();

        assert!(!report.has_errors());
        assert!(report.has_changes());
        assert_eq!(
            fs::read_to_string(project.join(".agents/skills/alpha/SKILL.md")).unwrap(),
            "---\nname: alpha\ndescription: Test skill\n---\n\nBody\n"
        );
        assert_eq!(
            fs::read_to_string(project.join(".agents/skills/alpha/references/example.md")).unwrap(),
            "Example\n"
        );
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
            output_format: OutputFormat::Text,
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
        assert!(report.to_json().contains("\"mode\":\"DRY-RUN\""));
        assert!(report.to_json().contains("\"valid_skill_count\":1"));
        assert!(!project.join("agents.toml").exists());
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn doctor_flags_agents_toml_skill_drift_and_legacy_lock() {
        let temp = temp_dir("doctor-drift");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(project.join(".agents/skills/alpha/SKILL.md"), "---\n").unwrap();
        fs::create_dir_all(project.join(".agents/skills/beta")).unwrap();
        fs::write(project.join(".agents/skills/beta/SKILL.md"), "---\n").unwrap();
        fs::write(
            project.join("agents.toml"),
            r#"version = 1

[[skills]]
name = "alpha"
source = "path:.agents/skills/alpha"

[[skills]]
name = "missing"
source = "path:.agents/skills/missing"
"#,
        )
        .unwrap();
        fs::write(project.join("agents.lock"), "").unwrap();
        fs::write(project.join(".agents/.skill-lock.json"), r#"{"skills":{}}"#).unwrap();

        let report = skills_doctor(&SkillsDoctorOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
        })
        .unwrap();
        let messages = report
            .items
            .iter()
            .map(|item| item.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(messages.contains("on-disk skill not declared"));
        assert!(messages.contains("beta"));
        assert!(messages.contains("declares missing skill folder"));
        assert!(messages.contains("missing"));
        assert!(messages.contains("exists beside dotagents config"));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn doctor_uses_skill_name_for_non_path_sources() {
        let temp = temp_dir("doctor-remote-source");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(project.join(".agents/skills/alpha/SKILL.md"), "---\n").unwrap();
        fs::write(
            project.join("agents.toml"),
            r#"[[skills]]
name = "alpha"
source = "github:org/repo"
"#,
        )
        .unwrap();
        fs::write(project.join("agents.lock"), "").unwrap();

        let report = skills_doctor(&SkillsDoctorOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
        })
        .unwrap();
        let messages = report
            .items
            .iter()
            .map(|item| item.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(!messages.contains("declares missing skill folder: repo"));
        assert!(!messages.contains("declares missing skill folder"));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn doctor_accepts_toml_literal_string_skill_declarations() {
        let temp = temp_dir("doctor-literal-strings");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(project.join(".agents/skills/alpha/SKILL.md"), "---\n").unwrap();
        fs::write(
            project.join("agents.toml"),
            r#"[[skills]]
name = 'alpha'
source = 'path:.agents/skills/alpha'
"#,
        )
        .unwrap();
        fs::write(project.join("agents.lock"), "").unwrap();

        let report = skills_doctor(&SkillsDoctorOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
        })
        .unwrap();
        let messages = report
            .items
            .iter()
            .map(|item| item.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(!messages.contains("declares no skills"));
        assert!(!messages.contains("declares missing skill folder"));
        assert!(!messages.contains("on-disk skill not declared"));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn doctor_accepts_whitespace_in_toml_skill_table_header() {
        let temp = temp_dir("doctor-spaced-table");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(project.join(".agents/skills/alpha/SKILL.md"), "---\n").unwrap();
        fs::write(
            project.join("agents.toml"),
            r#"[[ skills ]]
name = "alpha"
source = "path:.agents/skills/alpha"
"#,
        )
        .unwrap();
        fs::write(project.join("agents.lock"), "").unwrap();

        let report = skills_doctor(&SkillsDoctorOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
        })
        .unwrap();
        let messages = report
            .items
            .iter()
            .map(|item| item.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(!messages.contains("declares no skills"));
        assert!(!messages.contains("declares missing skill folder"));
        assert!(!messages.contains("on-disk skill not declared"));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn doctor_checks_config_only_projects_for_missing_skill_folders() {
        let temp = temp_dir("doctor-config-only");
        let project = temp.join("repo");
        fs::create_dir_all(&project).unwrap();
        fs::write(
            project.join("agents.toml"),
            r#"[[skills]]
name = "alpha"
source = "path:.agents/skills/alpha"
"#,
        )
        .unwrap();
        fs::write(project.join("agents.lock"), "").unwrap();

        let report = skills_doctor(&SkillsDoctorOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
        })
        .unwrap();
        let messages = report
            .items
            .iter()
            .map(|item| item.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(!messages.contains("no projects with .agents/skills found"));
        assert!(messages.contains("has no valid skills"));
        assert!(messages.contains("declares missing skill folder: alpha"));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn doctor_does_not_treat_dotagents_directory_as_project_root() {
        let temp = temp_dir("doctor-dotagents-root");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(project.join(".agents/skills/alpha/SKILL.md"), "---\n").unwrap();
        fs::write(
            project.join(".agents/agents.toml"),
            r#"[[skills]]
name = "alpha"
source = "path:.agents/skills/alpha"
"#,
        )
        .unwrap();

        let report = skills_doctor(&SkillsDoctorOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
        })
        .unwrap();
        let messages = report
            .items
            .iter()
            .map(|item| item.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(!messages.contains(".agents/.agents/skills"));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn doctor_maps_direct_dotagents_root_to_parent_project() {
        let temp = temp_dir("doctor-direct-dotagents-root");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents")).unwrap();
        fs::write(
            project.join(".agents/agents.toml"),
            r#"[[skills]]
name = "alpha"
source = "path:.agents/skills/alpha"
"#,
        )
        .unwrap();

        let report = skills_doctor(&SkillsDoctorOptions {
            roots: vec![project.join(".agents")],
            ignore_projects: Vec::new(),
            max_depth: 4,
        })
        .unwrap();
        let messages = report
            .items
            .iter()
            .map(|item| item.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(!messages.contains("no projects with .agents/skills found"));
        assert!(messages.contains(".agents/agents.toml exists"));
        assert!(messages.contains("declares missing skill folder: alpha"));
        assert!(!messages.contains(".agents/.agents/skills"));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn doctor_flags_mismatched_name_and_path_source() {
        let temp = temp_dir("doctor-mismatched-source");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(project.join(".agents/skills/alpha/SKILL.md"), "---\n").unwrap();
        fs::create_dir_all(project.join(".agents/skills/beta")).unwrap();
        fs::write(project.join(".agents/skills/beta/SKILL.md"), "---\n").unwrap();
        fs::write(
            project.join("agents.toml"),
            r#"[[skills]]
name = "alpha"
source = "path:.agents/skills/beta"
"#,
        )
        .unwrap();
        fs::write(project.join("agents.lock"), "").unwrap();

        let report = skills_doctor(&SkillsDoctorOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
        })
        .unwrap();
        let messages = report
            .items
            .iter()
            .map(|item| item.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(messages.contains("mismatched path source basename beta"));
        assert!(messages.contains("on-disk skill not declared"));
        assert!(messages.contains("beta"));
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn dotagents_lock_path_follows_selected_nested_agents_toml() {
        let temp = temp_dir("nested-lock");
        let project = ProjectSkills {
            root: temp.clone(),
            skills_dir: temp.join(".agents/skills"),
            valid_skills: Vec::new(),
            skill_inventory: Vec::new(),
            invalid_skill_dirs: Vec::new(),
            hidden_skill_dirs: Vec::new(),
        };

        assert_eq!(
            dotagents_lock_path(&project, Some(&temp.join(".agents/agents.toml"))),
            temp.join(".agents/agents.lock")
        );
        assert_eq!(
            dotagents_lock_path(&project, Some(&temp.join("agents.toml"))),
            temp.join("agents.lock")
        );
    }

    #[test]
    fn doctor_flags_backup_and_repoprompt_command_candidates() {
        let temp = temp_dir("doctor-candidates");
        let project = temp.join("repo");
        fs::create_dir_all(project.join(".agents/skills/alpha")).unwrap();
        fs::write(project.join(".agents/skills/alpha/SKILL.md"), "---\n").unwrap();
        fs::write(
            project.join("agents.toml"),
            r#"[[skills]]
name = "alpha"
source = "path:.agents/skills/alpha"
"#,
        )
        .unwrap();
        fs::write(project.join("agents.lock"), "").unwrap();
        fs::create_dir_all(project.join(".system-skills.bak-before-dotagents")).unwrap();
        fs::create_dir_all(project.join("commands")).unwrap();
        fs::write(project.join("commands/rp-build.md"), "RepoPrompt\n").unwrap();

        let report = skills_doctor(&SkillsDoctorOptions {
            roots: vec![temp.clone()],
            ignore_projects: Vec::new(),
            max_depth: 4,
        })
        .unwrap();
        let messages = report
            .items
            .iter()
            .map(|item| item.message.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        assert!(messages.contains("backup cleanup candidate"));
        assert!(messages.contains("RepoPrompt command prompt"));
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
        env::temp_dir().join(format!("metagent-{label}-{}-{id}", std::process::id()))
    }
}
