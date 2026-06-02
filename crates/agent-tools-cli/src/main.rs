use agent_tools_core::launch_agent::{LaunchAgentAction, LaunchAgentOptions, launch_agent};
use agent_tools_core::skills::{
    OutputFormat, SkillsDoctorOptions, SkillsScanOptions, SkillsSyncOptions, default_roots,
    load_user_config, skills_doctor, skills_scan, skills_sync,
};
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
        "skills" => run_skills(&args[1..]),
        "launch-agent" => run_launch_agent(&args[1..]),
        "--help" | "-h" | "help" => {
            print_help();
            Ok(())
        }
        other => Err(format!("unknown command: {other}")),
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
                        project.valid_skills.len(),
                        project.skills_dir.display()
                    );
                }
            }
            Ok(())
        }
        "sync" => {
            let parsed = parse_sync(&args[1..])?;
            let report = skills_sync(&parsed)?;
            print_sync_report(&report);
            Ok(())
        }
        "doctor" => {
            let parsed = parse_common(&args[1..])?;
            let report = skills_doctor(&SkillsDoctorOptions {
                roots: parsed.roots,
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

struct CommonArgs {
    roots: Vec<PathBuf>,
    max_depth: usize,
    output_format: OutputFormat,
}

fn parse_common(args: &[String]) -> Result<CommonArgs, String> {
    let mut roots = Vec::new();
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
            "--json" => {
                output_format = OutputFormat::Json;
                index += 1;
            }
            other => return Err(format!("unknown flag: {other}")),
        }
    }

    let config = load_user_config()?;
    let roots = choose_roots(roots, &config.roots);
    let max_depth = max_depth.or(config.max_depth).unwrap_or(8);

    Ok(CommonArgs {
        roots,
        max_depth,
        output_format,
    })
}

fn parse_sync(args: &[String]) -> Result<SkillsSyncOptions, String> {
    let mut common = CommonArgs {
        roots: Vec::new(),
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
            other => return Err(format!("unknown sync flag: {other}")),
        }
    }

    let config = load_user_config()?;
    common.roots = choose_roots(common.roots, &config.roots);
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
        max_depth: common.max_depth,
        agents,
        apply,
        replace_claude_skills,
        rewrite_agents_toml,
        sync_only,
        run_dotagents,
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

fn read_value(args: &[String], index: usize) -> Result<String, String> {
    let Some(value) = args.get(index + 1) else {
        return Err(format!("missing value for {}", args[index]));
    };
    if value.starts_with("--") {
        return Err(format!("missing value for {}", args[index]));
    }
    Ok(value.clone())
}

fn print_sync_report(report: &agent_tools_core::skills::SkillsSyncReport) {
    println!("agent-tools skills sync: {}", report.mode_label());
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
        "agent-tools\n\nUsage:\n  agent-tools skills <scan|sync|doctor> [flags]\n  agent-tools launch-agent <install|uninstall|status> [flags]\n"
    );
}

fn print_skills_help() {
    println!(
        "agent-tools skills\n\nUsage:\n  agent-tools skills scan [--root PATH] [--max-depth N] [--json]\n  agent-tools skills sync [--apply] [--replace-claude-skills] [--root PATH] [--max-depth N]\n  agent-tools skills doctor [--root PATH] [--max-depth N]\n"
    );
}

fn print_launch_agent_help() {
    println!(
        "agent-tools launch-agent\n\nUsage:\n  agent-tools launch-agent install [--program PATH] [--interval SECONDS]\n  agent-tools launch-agent status\n  agent-tools launch-agent uninstall\n"
    );
}
