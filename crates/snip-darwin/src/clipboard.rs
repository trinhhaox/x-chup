//! macOS Clipboard operations.

use std::path::Path;
use std::process::Command;

/// Copy a PNG file to the macOS system clipboard.
pub fn copy_png_to_clipboard(path: &Path) -> Result<(), String> {
    let script = format!(
        "set the clipboard to (read (POSIX file \"{}\") as «class PNGf»)",
        path.to_string_lossy()
    );
    let output = Command::new("osascript")
        .arg("-e")
        .arg(&script)
        .output()
        .map_err(|e| format!("failed to run osascript: {e}"))?;

    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_string());
    }
    Ok(())
}

/// Copy UTF-8 plain text to the macOS system clipboard.
pub fn copy_text_to_clipboard(text: &str) -> Result<(), String> {
    use std::io::Write;
    let mut child = Command::new("pbcopy")
        .stdin(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| format!("failed to spawn pbcopy: {e}"))?;

    if let Some(mut stdin) = child.stdin.take() {
        stdin
            .write_all(text.as_bytes())
            .map_err(|e| format!("failed to write to pbcopy stdin: {e}"))?;
    }

    let status = child
        .wait()
        .map_err(|e| format!("failed to wait for pbcopy: {e}"))?;
    if !status.success() {
        return Err("pbcopy exited with non-zero status".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_copy_text() {
        assert!(copy_text_to_clipboard("test from xchup").is_ok());
    }
}
