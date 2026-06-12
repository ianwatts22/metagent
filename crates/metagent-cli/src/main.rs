use metagent_core::code_summary::{
    CodeSummaryGraphMode, CodeSummaryOptions, CodeSummaryView, code_summary,
};
use metagent_core::launch_agent::{LaunchAgentAction, LaunchAgentOptions, launch_agent};
use metagent_core::morph_mcp::{MorphMcpAction, MorphMcpOptions, morph_mcp};
use metagent_core::skill_usage::{
    SkillUsageOptions, default_sessions_root, default_usage_cache_path, skills_usage,
};
use metagent_core::skills::{
    OutputFormat, ProjectSkills, SkillsDoctorOptions, SkillsFormatOptions, SkillsScanOptions,
    SkillsSyncOptions, default_roots, load_user_config, skills_doctor, skills_format, skills_scan,
    skills_sync, user_config_path,
};
use std::collections::BTreeSet;
use std::env;
use std::path::PathBuf;

fn main() {
    if let Err(error) = run(env::args().skip(1).collect()) {
        eprintln!("ERROR {error}");
        std::process::exit(1);
    }
}

fn run(args: Vec<String>) -> Result<(), String> {
    if args.is_empty() {
        print_help();
        return Ok(());
    }

    match args[0].as_str() {
        "code-summary" | "ccs" => run_code_summary(&args[1..]),
        "config" => run_config(&args[1..]),
        "skills" => run_skills(&args[1..]),
        "launch-agent" => run_launch_agent(&args[1..]),
        "morph-mcp" => run_morph_mcp(&args[1..]),
        "--help" | "-h" | "help" => {
            print_help();
            Ok(())
        }
        other => Err(format!("unknown command: {other}")),
    }
}

fn scan_location_summary(project: &ProjectSkills) -> String {
    let locations = project
        .skill_inventory
        .iter()
        .filter_map(|skill| skill.path.parent())
        .map(|path| path.display().to_string())
        .collect::<BTreeSet<_>>();

    if locations.is_empty() {
        project.skills_dir.display().to_string()
    } else {
        locations.into_iter().collect::<Vec<_>>().join(",")
    }
}

fn run_code_summary(args: &[String]) -> Result<(), String> {
    let mut options = CodeSummaryOptions {
        repo_path: env::current_dir()
            .map_err(|error| format!("failed resolving current directory: {error}"))?,
        view: CodeSummaryView::Daily,
        periods: 5,
        end_date: None,
        include_tests: false,
        details: false,
        graph: CodeSummaryGraphMode::Ascii,
        has_explicit_window: false,
    };
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--repo" => {
                options.repo_path = PathBuf::from(read_value(args, index)?);
                index += 2;
            }
            "--days" => {
                options.view = CodeSummaryView::Daily;
                options.periods = read_value(args, index)?
                    .parse()
                    .map_err(|_| "invalid --days value".to_string())?;
                options.has_explicit_window = true;
                index += 2;
            }
            "--periods" => {
                options.periods = read_value(args, index)?
                    .parse()
                    .map_err(|_| "invalid --periods value".to_string())?;
                options.has_explicit_window = true;
                index += 2;
            }
            "--view" => {
                options.view = match read_value(args, index)?.as_str() {
                    "daily" => CodeSummaryView::Daily,
                    "weekly" => CodeSummaryView::Weekly,
                    "monthly" => CodeSummaryView::Monthly,
                    value => return Err(format!("invalid --view value: {value}")),
                };
                options.has_explicit_window = true;
                index += 2;
            }
            "--end-date" => {
                options.end_date = Some(read_value(args, index)?);
                index += 2;
            }
            "--include-tests" => {
                options.include_tests = true;
                index += 1;
            }
            "--details" => {
                options.details = true;
                index += 1;
            }
            "--graph" => {
                options.graph = match read_value(args, index)?.as_str() {
                    "ascii" => CodeSummaryGraphMode::Ascii,
                    "mermaid" => CodeSummaryGraphMode::Mermaid,
                    "none" => CodeSummaryGraphMode::None,
                    value => return Err(format!("invalid --graph value: {value}")),
                };
                index += 2;
            }
            "--help" | "-h" | "help" => {
                print_code_summary_help();
                return Ok(());
            }
            other => return Err(format!("unknown code-summary flag: {other}")),
        }
    }

    let report = code_summary(&options)?;
    println!("{}", report.text);
    Ok(())
}

fn run_config(args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        print_config_help();
        return Ok(());
    }

    match args[0].as_str() {
        "show" => {
            let mut output_format = OutputFormat::Text;
            let mut index = 1;
            while index < args.len() {
                match args[index].as_str() {
                    "--json" => {
                        output_format = OutputFormat::Json;
                        index += 1;
                    }
                    other => return Err(format!("unknown config show flag: {other}")),
                }
            }

            let config = load_user_config()?;
            let roots = choose_roots(Vec::new(), &config.roots);
            let ignore_projects = choose_ignore_projects(Vec::new(), &config.ignore_projects);
            let max_depth = config.max_depth.unwrap_or(8);
            let agents = if config.agents.is_empty() {
                vec![
                    "claude".to_string(),
                    "codex".to_string(),
                    "cursor".to_string(),
                ]
            } else {
                config.agents
            };
            let config_path = user_config_path();

            if output_format == OutputFormat::Json {
                println!(
                    "{{\"config_path\":{},\"config_exists\":{},\"roots\":{},\"ignore_projects\":{},\"max_depth\":{},\"agents\":{}}}",
                    json_string(&config_path.display().to_string()),
                    config_path.is_file(),
                    json_array(
                        roots
                            .iter()
                            .map(|path| path.display().to_string())
                            .collect::<Vec<_>>()
                            .as_slice()
                    ),
                    json_array(
                        ignore_projects
                            .iter()
                            .map(|path| path.display().to_string())
                            .collect::<Vec<_>>()
                            .as_slice()
                    ),
                    max_depth,
                    json_array(&agents)
                );
            } else {
                println!("config: {}", config_path.display());
                println!("exists: {}", config_path.is_file());
                println!("max_depth: {max_depth}");
                println!("agents: {}", agents.join(", "));
                println!("roots:");
                for root in roots {
                    println!("  {}", root.display());
                }
                if !ignore_projects.is_empty() {
                    println!("ignore_projects:");
                    for ignored in ignore_projects {
                        println!("  {}", ignored.display());
                    }
                }
            }
            Ok(())
        }
        "--help" | "-h" | "help" => {
            print_config_help();
            Ok(())
        }
        other => Err(format!("unknown config command: {other}")),
    }
}

fn run_skills(args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        print_skills_help();
        return Ok(());
    }

    match args[0].as_str() {
        "scan" => {
            let parsed = parse_common(&args[1..])?;
            let projects = skills_scan(&SkillsScanOptions {
                roots: parsed.roots,
                ignore_projects: parsed.ignore_projects,
                max_depth: parsed.max_depth,
                output_format: parsed.output_format,
            })?;
            if parsed.output_format == OutputFormat::Json {
                println!("{}", projects.to_json());
            } else {
                for project in projects.projects {
                    println!(
                        "{}\t{} skills\t{}",
                        project.root.display(),
                        project.skill_inventory.len(),
                        scan_location_summary(&project)
                    );
                }
            }
            Ok(())
        }
        "sync" => {
            let parsed = parse_sync(&args[1..])?;
            let report = skills_sync(&parsed)?;
            if parsed.output_format == OutputFormat::Json {
                println!("{}", report.to_json());
            } else {
                print_sync_report(&report);
            }
            Ok(())
        }
        "doctor" => {
            let parsed = parse_common(&args[1..])?;
            let report = skills_doctor(&SkillsDoctorOptions {
                roots: parsed.roots,
                ignore_projects: parsed.ignore_projects,
                max_depth: parsed.max_depth,
            })?;
            for item in &report.items {
                println!("{}  {}", item.level.as_str(), item.message);
            }
            if report.has_errors() {
                return Err("doctor found errors".to_string());
            }
            Ok(())
        }
        "usage" => {
            let parsed = parse_usage(&args[1..])?;
            let report = skills_usage(&parsed)?;
            if parsed.output_format == OutputFormat::Json {
                println!("{}", report.to_json()?);
            } else {
                print!("{}", report.to_text(parsed.limit));
            }
            Ok(())
        }
        "format" => {
            let parsed = parse_format(&args[1..])?;
            let report = skills_format(&parsed)?;
            for item in &report.items {
                if item.changed || !item.errors.is_empty() {
                    let status = if item.errors.is_empty() { "OK" } else { "FAIL" };
                    println!("{status}  {}", item.path.display());
                    for error in &item.errors {
                        println!("      {error}");
                    }
                }
            }
            if report.has_errors() {
                return Err("skills format found errors".to_string());
            }
            if !report.apply && report.has_changes() {
                return Err("skills format found files that need --apply".to_string());
            }
            if report.items.is_empty() {
                println!("No skills found");
            } else if report.apply {
                println!("Formatted {} skill file(s)", report.items.len());
            } else {
                println!("All {} skill file(s) are formatted", report.items.len());
            }
            Ok(())
        }
        "--help" | "-h" | "help" => {
            print_skills_help();
            Ok(())
        }
        other => Err(format!("unknown skills command: {other}")),
    }
}

fn run_launch_agent(args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        print_launch_agent_help();
        return Ok(());
    }

    let action = match args[0].as_str() {
        "install" => LaunchAgentAction::Install,
        "uninstall" => LaunchAgentAction::Uninstall,
        "status" => LaunchAgentAction::Status,
        "--help" | "-h" | "help" => {
            print_launch_agent_help();
            return Ok(());
        }
        other => return Err(format!("unknown launch-agent command: {other}")),
    };

    let mut options = LaunchAgentOptions::default();
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--label" => {
                options.label = Some(read_value(args, index)?);
                index += 2;
            }
            "--program" => {
                options.program = Some(PathBuf::from(read_value(args, index)?));
                index += 2;
            }
            "--interval" => {
                options.interval_seconds = read_value(args, index)?
                    .parse()
                    .map_err(|_| "invalid --interval value".to_string())?;
                index += 2;
            }
            other => return Err(format!("unknown launch-agent flag: {other}")),
        }
    }

    let report = launch_agent(action, &options)?;
    for line in report.lines {
        println!("{line}");
    }
    Ok(())
}

fn run_morph_mcp(args: &[String]) -> Result<(), String> {
    if args.is_empty() {
        print_morph_mcp_help();
        return Ok(());
    }

    let action = match args[0].as_str() {
        "status" => MorphMcpAction::Status,
        "janitor" => MorphMcpAction::Janitor,
        "install-launch-agent" => MorphMcpAction::InstallLaunchAgent,
        "migrate-launch-agent" => MorphMcpAction::MigrateLaunchAgent,
        "retire-legacy-launch-agent" => MorphMcpAction::RetireLegacyLaunchAgent,
        "uninstall-launch-agent" => MorphMcpAction::UninstallLaunchAgent,
        "--help" | "-h" | "help" => {
            print_morph_mcp_help();
            return Ok(());
        }
        other => return Err(format!("unknown morph-mcp command: {other}")),
    };

    let mut options = MorphMcpOptions::default();
    let mut index = 1;
    while index < args.len() {
        match args[index].as_str() {
            "--program" => {
                options.program = Some(PathBuf::from(read_value(args, index)?));
                index += 2;
            }
            "--dry-run" => {
                options.dry_run = true;
                index += 1;
            }
            other => return Err(format!("unknown morph-mcp flag: {other}")),
        }
    }

    if options.dry_run && action != MorphMcpAction::Janitor {
        return Err("--dry-run is only supported for morph-mcp janitor".to_string());
    }

    let report = morph_mcp(action, &options)?;
    for line in report.lines {
        println!("{line}");
    }
    Ok(())
}

struct CommonArgs {
    roots: Vec<PathBuf>,
    ignore_projects: Vec<PathBuf>,
    max_depth: usize,
    output_format: OutputFormat,
}

fn parse_common(args: &[String]) -> Result<CommonArgs, String> {
    let mut roots = Vec::new();
    let mut ignore_projects = Vec::new();
    let mut max_depth = None;
    let mut output_format = OutputFormat::Text;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--root" => {
                roots.push(PathBuf::from(read_value(args, index)?));
                index += 2;
            }
            "--max-depth" => {
                max_depth = Some(
                    read_value(args, index)?
                        .parse()
                        .map_err(|_| "invalid --max-depth value".to_string())?,
                );
                index += 2;
            }
            "--ignore-project" => {
                ignore_projects.push(PathBuf::from(read_value(args, index)?));
                index += 2;
            }
            "--json" => {
                output_format = OutputFormat::Json;
                index += 1;
            }
            other => return Err(format!("unknown flag: {other}")),
        }
    }

    let config = load_user_config()?;
    let roots = choose_roots(roots, &config.roots);
    let ignore_projects = choose_ignore_projects(ignore_projects, &config.ignore_projects);
    let max_depth = max_depth.or(config.max_depth).unwrap_or(8);

    Ok(CommonArgs {
        roots,
        ignore_projects,
        max_depth,
        output_format,
    })
}

fn parse_sync(args: &[String]) -> Result<SkillsSyncOptions, String> {
    let mut common = CommonArgs {
        roots: Vec::new(),
        ignore_projects: Vec::new(),
        max_depth: 0,
        output_format: OutputFormat::Text,
    };
    let mut apply = false;
    let mut replace_claude_skills = false;
    let mut rewrite_agents_toml = false;
    let mut sync_only = false;
    let mut run_dotagents = true;
    let mut agents = Vec::new();
    let mut max_depth = None;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--root" => {
                common.roots.push(PathBuf::from(read_value(args, index)?));
                index += 2;
            }
            "--max-depth" => {
                max_depth = Some(
                    read_value(args, index)?
                        .parse()
                        .map_err(|_| "invalid --max-depth value".to_string())?,
                );
                index += 2;
            }
            "--ignore-project" => {
                common
                    .ignore_projects
                    .push(PathBuf::from(read_value(args, index)?));
                index += 2;
            }
            "--agents" => {
                agents = read_value(args, index)?
                    .split(',')
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .map(ToOwned::to_owned)
                    .collect();
                index += 2;
            }
            "--apply" => {
                apply = true;
                index += 1;
            }
            "--replace-claude-skills" => {
                replace_claude_skills = true;
                index += 1;
            }
            "--rewrite-agents-toml" => {
                rewrite_agents_toml = true;
                index += 1;
            }
            "--sync-only" => {
                sync_only = true;
                index += 1;
            }
            "--no-dotagents" => {
                run_dotagents = false;
                index += 1;
            }
            "--json" => {
                common.output_format = OutputFormat::Json;
                index += 1;
            }
            other => return Err(format!("unknown sync flag: {other}")),
        }
    }

    let config = load_user_config()?;
    common.roots = choose_roots(common.roots, &config.roots);
    common.ignore_projects =
        choose_ignore_projects(common.ignore_projects, &config.ignore_projects);
    common.max_depth = max_depth.or(config.max_depth).unwrap_or(8);
    if agents.is_empty() {
        agents = if config.agents.is_empty() {
            vec![
                "claude".to_string(),
                "codex".to_string(),
                "cursor".to_string(),
            ]
        } else {
            config.agents
        };
    }

    Ok(SkillsSyncOptions {
        roots: common.roots,
        ignore_projects: common.ignore_projects,
        max_depth: common.max_depth,
        output_format: common.output_format,
        agents,
        apply,
        replace_claude_skills,
        rewrite_agents_toml,
        sync_only,
        run_dotagents,
    })
}

fn parse_format(args: &[String]) -> Result<SkillsFormatOptions, String> {
    let mut common = CommonArgs {
        roots: Vec::new(),
        ignore_projects: Vec::new(),
        max_depth: 0,
        output_format: OutputFormat::Text,
    };
    let mut max_depth = None;
    let mut apply = false;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--root" => {
                common.roots.push(PathBuf::from(read_value(args, index)?));
                index += 2;
            }
            "--max-depth" => {
                max_depth = Some(
                    read_value(args, index)?
                        .parse()
                        .map_err(|_| "invalid --max-depth value".to_string())?,
                );
                index += 2;
            }
            "--ignore-project" => {
                common
                    .ignore_projects
                    .push(PathBuf::from(read_value(args, index)?));
                index += 2;
            }
            "--apply" => {
                apply = true;
                index += 1;
            }
            other => return Err(format!("unknown format flag: {other}")),
        }
    }

    let config = load_user_config()?;
    common.roots = choose_roots(common.roots, &config.roots);
    common.ignore_projects =
        choose_ignore_projects(common.ignore_projects, &config.ignore_projects);
    common.max_depth = max_depth.or(config.max_depth).unwrap_or(8);

    Ok(SkillsFormatOptions {
        roots: common.roots,
        ignore_projects: common.ignore_projects,
        max_depth: common.max_depth,
        apply,
    })
}

fn parse_usage(args: &[String]) -> Result<SkillUsageOptions, String> {
    let mut common = CommonArgs {
        roots: Vec::new(),
        ignore_projects: Vec::new(),
        max_depth: 0,
        output_format: OutputFormat::Text,
    };
    let mut max_depth = None;
    let mut sessions_root = default_sessions_root();
    let mut cache_path = default_usage_cache_path();
    let mut use_cache = true;
    let mut refresh_cache = false;
    let mut days = None;
    let mut limit = 80usize;
    let mut index = 0;

    while index < args.len() {
        match args[index].as_str() {
            "--root" => {
                common.roots.push(PathBuf::from(read_value(args, index)?));
                index += 2;
            }
            "--max-depth" => {
                max_depth = Some(
                    read_value(args, index)?
                        .parse()
                        .map_err(|_| "invalid --max-depth value".to_string())?,
                );
                index += 2;
            }
            "--ignore-project" => {
                common
                    .ignore_projects
                    .push(PathBuf::from(read_value(args, index)?));
                index += 2;
            }
            "--sessions" => {
                sessions_root = PathBuf::from(read_value(args, index)?);
                index += 2;
            }
            "--cache" => {
                cache_path = PathBuf::from(read_value(args, index)?);
                index += 2;
            }
            "--no-cache" => {
                use_cache = false;
                index += 1;
            }
            "--refresh-cache" => {
                refresh_cache = true;
                index += 1;
            }
            "--days" => {
                days = Some(
                    read_value(args, index)?
                        .parse()
                        .map_err(|_| "invalid --days value".to_string())?,
                );
                index += 2;
            }
            "--all" => {
                days = None;
                index += 1;
            }
            "--limit" => {
                limit = read_value(args, index)?
                    .parse()
                    .map_err(|_| "invalid --limit value".to_string())?;
                index += 2;
            }
            "--json" => {
                common.output_format = OutputFormat::Json;
                index += 1;
            }
            other => return Err(format!("unknown usage flag: {other}")),
        }
    }

    let config = load_user_config()?;
    common.roots = choose_roots(common.roots, &config.roots);
    common.ignore_projects =
        choose_ignore_projects(common.ignore_projects, &config.ignore_projects);
    common.max_depth = max_depth.or(config.max_depth).unwrap_or(8);

    Ok(SkillUsageOptions {
        roots: common.roots,
        ignore_projects: common.ignore_projects,
        max_depth: common.max_depth,
        sessions_root,
        cache_path,
        output_format: common.output_format,
        use_cache,
        refresh_cache,
        days,
        limit,
    })
}

fn choose_roots(cli_roots: Vec<PathBuf>, config_roots: &[PathBuf]) -> Vec<PathBuf> {
    if !cli_roots.is_empty() {
        return cli_roots;
    }
    if !config_roots.is_empty() {
        return config_roots.to_vec();
    }
    default_roots()
}

fn choose_ignore_projects(cli_ignored: Vec<PathBuf>, config_ignored: &[PathBuf]) -> Vec<PathBuf> {
    if !cli_ignored.is_empty() {
        return cli_ignored;
    }
    config_ignored.to_vec()
}

fn read_value(args: &[String], index: usize) -> Result<String, String> {
    let Some(value) = args.get(index + 1) else {
        return Err(format!("missing value for {}", args[index]));
    };
    if value.starts_with("--") {
        return Err(format!("missing value for {}", args[index]));
    }
    Ok(value.clone())
}

fn json_array(values: &[String]) -> String {
    format!(
        "[{}]",
        values
            .iter()
            .map(|value| json_string(value))
            .collect::<Vec<_>>()
            .join(",")
    )
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
            char if char.is_control() => out.push_str(&format!("\\u{:04x}", char as u32)),
            char => out.push(char),
        }
    }
    out.push('"');
    out
}

fn print_sync_report(report: &metagent_core::skills::SkillsSyncReport) {
    println!("metagent skills sync: {}", report.mode_label());
    for project in &report.projects {
        println!();
        println!("Project: {}", project.root.display());
        for line in &project.lines {
            println!("  {line}");
        }
    }
}

fn print_help() {
    println!(
        "metagent\n\nUsage:\n  metagent code-summary [flags]\n  metagent config show [--json]\n  metagent skills <scan|sync|doctor|usage|format> [flags]\n  metagent launch-agent <install|uninstall|status> [flags]\n  metagent morph-mcp <status|janitor|install-launch-agent|migrate-launch-agent|retire-legacy-launch-agent|uninstall-launch-agent> [flags]\n"
    );
}

fn print_code_summary_help() {
    println!(
        "metagent code-summary\n\nUsage:\n  metagent code-summary\n  metagent code-summary --repo /path/to/repo --days 14\n  metagent code-summary --repo /path/to/repo --view weekly --periods 8\n  metagent code-summary --repo /path/to/repo --view monthly --periods 6 --graph mermaid\n\nFlags:\n  --view <mode>         daily | weekly | monthly. Default: overview when omitted\n  --periods <n>         Number of periods to show for --view\n  --days <n>            Alias for --view daily --periods <n>\n  --end-date <date>     Inclusive end date in YYYY-MM-DD. Default: today\n  --include-tests       Include *.test.ts(x), *.spec.ts(x), and tests/\n  --details             Show add/delete counts in addition to net values\n  --graph <mode>        ascii | mermaid | none. Default: ascii\n  --repo <path>         Repo path. Default: current working directory\n"
    );
}

fn print_config_help() {
    println!("metagent config\n\nUsage:\n  metagent config show [--json]\n");
}

fn print_skills_help() {
    println!(
        "metagent skills\n\nUsage:\n  metagent skills scan [--root PATH] [--ignore-project PATH] [--max-depth N] [--json]\n  metagent skills sync [--apply] [--replace-claude-skills] [--root PATH] [--ignore-project PATH] [--max-depth N] [--json]\n  metagent skills doctor [--root PATH] [--ignore-project PATH] [--max-depth N]\n  metagent skills usage [--sessions PATH] [--cache PATH] [--days N|--all] [--no-cache] [--refresh-cache] [--limit N] [--json]\n  metagent skills format [--apply] [--root PATH] [--ignore-project PATH] [--max-depth N]\n"
    );
}

fn print_launch_agent_help() {
    println!(
        "metagent launch-agent\n\nUsage:\n  metagent launch-agent install [--program PATH] [--interval SECONDS]\n  metagent launch-agent status\n  metagent launch-agent uninstall\n"
    );
}

fn print_morph_mcp_help() {
    println!(
        "metagent morph-mcp\n\nUsage:\n  metagent morph-mcp status\n  metagent morph-mcp janitor [--dry-run]\n  metagent morph-mcp install-launch-agent [--program PATH]\n  metagent morph-mcp migrate-launch-agent [--program PATH]\n  metagent morph-mcp retire-legacy-launch-agent\n  metagent morph-mcp uninstall-launch-agent\n"
    );
}
