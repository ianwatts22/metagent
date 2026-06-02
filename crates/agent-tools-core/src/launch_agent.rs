use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Debug)]
pub enum LaunchAgentAction {
    Install,
    Uninstall,
    Status,
}

#[derive(Debug)]
pub struct LaunchAgentOptions {
    pub label: Option<String>,
    pub program: Option<PathBuf>,
    pub interval_seconds: u64,
}

impl Default for LaunchAgentOptions {
    fn default() -> Self {
        Self {
            label: None,
            program: None,
            interval_seconds: 300,
        }
    }
}

#[derive(Debug)]
pub struct LaunchAgentReport {
    pub lines: Vec<String>,
}

pub fn launch_agent(
    action: LaunchAgentAction,
    options: &LaunchAgentOptions,
) -> Result<LaunchAgentReport, String> {
    match action {
        LaunchAgentAction::Install => install(options),
        LaunchAgentAction::Uninstall => uninstall(options),
        LaunchAgentAction::Status => status(options),
    }
}

fn install(options: &LaunchAgentOptions) -> Result<LaunchAgentReport, String> {
    let label = label(options);
    let plist = plist_path(&label);
    let program = program_path(options)?;
    let logs_dir = home_dir().join("Library/Logs/agent-tools");
    fs::create_dir_all(&logs_dir)
        .map_err(|error| format!("failed creating {}: {error}", logs_dir.display()))?;
    fs::create_dir_all(plist.parent().expect("plist has parent"))
        .map_err(|error| format!("failed creating LaunchAgents dir: {error}"))?;

    let content = render_plist(&label, &program, options.interval_seconds, &logs_dir);
    fs::write(&plist, content)
        .map_err(|error| format!("failed writing {}: {error}", plist.display()))?;

    let domain = format!("gui/{}", unsafe { libc_getuid() });
    let _ = Command::new("launchctl")
        .arg("bootout")
        .arg(&domain)
        .arg(&plist)
        .output();

    let bootstrap = Command::new("launchctl")
        .arg("bootstrap")
        .arg(&domain)
        .arg(&plist)
        .output();

    let mut lines = vec![format!("wrote {}", plist.display())];
    match bootstrap {
        Ok(output) if output.status.success() => lines.push("loaded LaunchAgent".to_string()),
        Ok(output) => {
            lines.push(format!(
                "launchctl bootstrap did not complete cleanly: {}{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            ));
            lines.push("the plist was still written; load it manually if needed".to_string());
        }
        Err(error) => lines.push(format!("launchctl bootstrap not run: {error}")),
    }

    Ok(LaunchAgentReport { lines })
}

fn uninstall(options: &LaunchAgentOptions) -> Result<LaunchAgentReport, String> {
    let label = label(options);
    let plist = plist_path(&label);
    let mut lines = Vec::new();

    let bootout = Command::new("launchctl")
        .arg("bootout")
        .arg(format!("gui/{}", unsafe { libc_getuid() }))
        .arg(&plist)
        .output();

    match bootout {
        Ok(output) if output.status.success() => lines.push("unloaded LaunchAgent".to_string()),
        Ok(output) => lines.push(format!(
            "launchctl bootout reported: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        )),
        Err(error) => lines.push(format!("launchctl bootout not run: {error}")),
    }

    if plist.exists() {
        fs::remove_file(&plist)
            .map_err(|error| format!("failed removing {}: {error}", plist.display()))?;
        lines.push(format!("removed {}", plist.display()));
    } else {
        lines.push(format!("not installed: {}", plist.display()));
    }

    Ok(LaunchAgentReport { lines })
}

fn status(options: &LaunchAgentOptions) -> Result<LaunchAgentReport, String> {
    let label = label(options);
    let plist = plist_path(&label);
    let mut lines = Vec::new();
    if plist.exists() {
        lines.push(format!("plist exists: {}", plist.display()));
    } else {
        lines.push(format!("plist missing: {}", plist.display()));
    }

    let print = Command::new("launchctl")
        .arg("print")
        .arg(format!("gui/{}/{}", unsafe { libc_getuid() }, label))
        .output();
    match print {
        Ok(output) if output.status.success() => lines.push("launchctl status: loaded".to_string()),
        Ok(_) => lines.push("launchctl status: not loaded or unavailable".to_string()),
        Err(error) => lines.push(format!("launchctl status unavailable: {error}")),
    }
    Ok(LaunchAgentReport { lines })
}

fn render_plist(label: &str, program: &Path, interval_seconds: u64, logs_dir: &Path) -> String {
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
    <string>skills</string>
    <string>sync</string>
    <string>--apply</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>{interval_seconds}</integer>
  <key>StandardOutPath</key>
  <string>{logs_dir}/skills-sync.out.log</string>
  <key>StandardErrorPath</key>
  <string>{logs_dir}/skills-sync.err.log</string>
</dict>
</plist>
"#,
        label = xml_escape(label),
        program = xml_escape(&program.display().to_string()),
        interval_seconds = interval_seconds,
        logs_dir = xml_escape(&logs_dir.display().to_string())
    )
}

fn label(options: &LaunchAgentOptions) -> String {
    options
        .label
        .clone()
        .unwrap_or_else(|| "com.ianwatts.agent-tools.skills-sync".to_string())
}

fn plist_path(label: &str) -> PathBuf {
    home_dir()
        .join("Library/LaunchAgents")
        .join(format!("{label}.plist"))
}

fn program_path(options: &LaunchAgentOptions) -> Result<PathBuf, String> {
    if let Some(program) = &options.program {
        return Ok(program.clone());
    }
    env::current_exe().map_err(|error| format!("failed resolving current executable: {error}"))
}

fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
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
