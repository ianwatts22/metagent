use std::path::Path;
use std::process::Command;

pub(crate) fn trash_path(path: &Path) -> Result<(), String> {
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
