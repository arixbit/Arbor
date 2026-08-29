//! GPG agent discovery and external pinentry configuration.
//!
//! IntelliJ can ship an embedded pinentry implementation. Arbor deliberately
//! does not embed a second GPG UI; instead it provides the same safe
//! configure/backup/reload workflow for a user-selected system pinentry
//! program and reports clearly when GnuPG is unavailable.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::EngineError;

const GPG_AGENT_CONF: &str = "gpg-agent.conf";
const GPG_AGENT_CONF_BACKUP: &str = "gpg-agent.conf.bak";
const DEFAULT_CACHE_TTL: &str = "default-cache-ttl";
const MAX_CACHE_TTL: &str = "max-cache-ttl";
const PINENTRY_PROGRAM: &str = "pinentry-program";

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct GpgAgentStatus {
    /// Whether `gpgconf` was found and could enumerate GnuPG components.
    pub available: bool,
    pub home: String,
    pub config_path: String,
    pub backup_path: String,
    pub pinentry_program: Option<String>,
    pub default_pinentry_program: Option<String>,
}

fn command_output(args: &[&str]) -> Result<String, EngineError> {
    let output = Command::new("gpgconf")
        .args(args)
        .output()
        .map_err(|error| EngineError::GitOperation {
            message: format!("cannot start gpgconf: {error}"),
        })?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(EngineError::GitOperation {
            message: if detail.is_empty() {
                format!("gpgconf {:?} failed", args)
            } else {
                format!("gpgconf {:?} failed: {detail}", args)
            },
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

fn gpg_home() -> Result<PathBuf, EngineError> {
    if let Ok(home) = command_output(&["--list-dirs", "homedir"]) {
        if !home.trim().is_empty() {
            return Ok(PathBuf::from(home));
        }
    }
    std::env::var_os("GNUPGHOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".gnupg")))
        .ok_or_else(|| EngineError::GitOperation {
            message: "cannot resolve GnuPG home directory".into(),
        })
}

fn default_pinentry_program() -> Result<Option<String>, EngineError> {
    let components = command_output(&["--list-components"])?;
    Ok(default_pinentry_program_from_components(&components))
}

fn default_pinentry_program_from_components(components: &str) -> Option<String> {
    components.lines().find_map(|line| {
        let mut fields = line.splitn(3, ':');
        if fields.next()? != "pinentry" {
            return None;
        }
        fields.next()?;
        let path = fields.next()?.trim();
        (!path.is_empty()).then(|| path.to_string())
    })
}

fn read_pinentry_program(path: &Path) -> Result<Option<String>, EngineError> {
    let Ok(content) = fs::read_to_string(path) else {
        return Ok(None);
    };
    Ok(content.lines().rev().find_map(|line| {
        let mut fields = line.split_whitespace();
        if fields.next()? != PINENTRY_PROGRAM {
            return None;
        }
        let value = fields.collect::<Vec<_>>().join(" ");
        (!value.is_empty()).then_some(value)
    }))
}

fn paths() -> Result<(PathBuf, PathBuf, PathBuf), EngineError> {
    let home = gpg_home()?;
    Ok((
        home.clone(),
        home.join(GPG_AGENT_CONF),
        home.join(GPG_AGENT_CONF_BACKUP),
    ))
}

#[uniffi::export]
pub fn gpg_agent_status() -> Result<GpgAgentStatus, EngineError> {
    let (home, config_path, backup_path) = paths()?;
    // Status is also the onboarding probe. A missing gpgconf must be
    // representable so the UI can explain how to install GnuPG instead of
    // reducing the state to an opaque operation error.
    let (available, default_pinentry_program) = match command_output(&["--list-components"]) {
        Ok(components) => (true, default_pinentry_program_from_components(&components)),
        Err(_) => (false, None),
    };
    Ok(GpgAgentStatus {
        available,
        home: home.display().to_string(),
        config_path: config_path.display().to_string(),
        backup_path: backup_path.display().to_string(),
        pinentry_program: read_pinentry_program(&config_path)?,
        default_pinentry_program,
    })
}

fn validate_pinentry_program(path: &str) -> Result<PathBuf, EngineError> {
    let value = path.trim();
    if value.is_empty() || value.contains('\n') || value.contains('\r') {
        return Err(EngineError::GitOperation {
            message: "pinentry program path is empty or contains a newline".into(),
        });
    }
    let candidate = PathBuf::from(value);
    if !candidate.is_absolute() || !candidate.is_file() {
        return Err(EngineError::GitOperation {
            message: format!("pinentry program is not an absolute file: {value}"),
        });
    }
    Ok(candidate)
}

fn config_without_managed_entries(content: &str) -> Vec<String> {
    content
        .lines()
        .filter(|line| {
            let key = line.split_whitespace().next().unwrap_or_default();
            !matches!(key, DEFAULT_CACHE_TTL | MAX_CACHE_TTL | PINENTRY_PROGRAM)
        })
        .map(str::to_string)
        .collect()
}

fn write_config(path: &Path, content: &str) -> Result<(), EngineError> {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    let filename = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or(GPG_AGENT_CONF);
    let temporary = path.with_file_name(format!(
        ".{filename}.arbor-tmp-{}-{nonce}",
        std::process::id()
    ));
    fs::write(&temporary, content).map_err(EngineError::from_gix)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))
            .map_err(EngineError::from_gix)?;
    }
    if let Err(error) = fs::rename(&temporary, path) {
        let _ = fs::remove_file(&temporary);
        return Err(EngineError::from_gix(error));
    }
    Ok(())
}

/// Configure the external pinentry used by GPG agent. When `pinentry_program`
/// is None, the default path reported by `gpgconf` is used. The previous config
/// is copied to `gpg-agent.conf.bak` before the atomic replacement.
#[uniffi::export]
pub fn configure_gpg_agent(
    pinentry_program: Option<String>,
) -> Result<GpgAgentStatus, EngineError> {
    let (home, config_path, backup_path) = paths()?;
    fs::create_dir_all(&home).map_err(EngineError::from_gix)?;
    for path in [&config_path, &backup_path] {
        if let Ok(metadata) = fs::symlink_metadata(path) {
            if metadata.file_type().is_symlink() {
                return Err(EngineError::GitOperation {
                    message: format!(
                        "refusing to replace symlinked GPG config: {}",
                        path.display()
                    ),
                });
            }
        }
    }
    let selected =
        match pinentry_program {
            Some(path) => validate_pinentry_program(&path)?,
            None => validate_pinentry_program(default_pinentry_program()?.as_deref().ok_or_else(
                || EngineError::GitOperation {
                    message: "gpgconf did not report a default pinentry program".into(),
                },
            )?)?,
        };

    if config_path.exists() {
        fs::copy(&config_path, &backup_path).map_err(EngineError::from_gix)?;
    }
    let existing = fs::read_to_string(&config_path).unwrap_or_default();
    let mut lines = config_without_managed_entries(&existing);
    lines.push(format!("{DEFAULT_CACHE_TTL} 1800"));
    lines.push(format!("{MAX_CACHE_TTL} 7200"));
    lines.push(format!("{PINENTRY_PROGRAM} {}", selected.display()));
    write_config(&config_path, &format!("{}\n", lines.join("\n")))?;

    // A failed reload should be visible to the caller: the file is updated,
    // but the user still needs to restart or reload the agent before signing.
    let output = Command::new("gpgconf")
        .args(["--reload", "gpg-agent"])
        .output()
        .map_err(|error| EngineError::GitOperation {
            message: format!("GPG agent configured, but reload could not start: {error}"),
        })?;
    if !output.status.success() {
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(EngineError::GitOperation {
            message: if detail.is_empty() {
                "GPG agent configuration was written, but reload failed".into()
            } else {
                format!("GPG agent configuration was written, but reload failed: {detail}")
            },
        });
    }
    gpg_agent_status()
}

#[cfg(test)]
mod tests {
    use super::{config_without_managed_entries, default_pinentry_program};

    #[test]
    fn managed_entries_are_replaced_without_dropping_comments() {
        let lines = config_without_managed_entries(
            "# keep me\nallow-loopback-pinentry\npinentry-program /old\ndefault-cache-ttl 1\n",
        );
        assert_eq!(lines, ["# keep me", "allow-loopback-pinentry"]);
    }

    #[test]
    fn missing_gpgconf_is_reported_as_unavailable() {
        // The test environment used for the engine does not promise GnuPG.
        // This assertion is intentionally conditional so developer machines
        // with GnuPG remain valid too.
        if std::process::Command::new("gpgconf").output().is_err() {
            assert!(default_pinentry_program().is_err());
        }
    }

    #[test]
    fn parses_pinentry_component_path() {
        let components = "gpg:1:2:3\npinentry:1:/usr/local/bin/pinentry\n";
        assert_eq!(
            super::default_pinentry_program_from_components(components).as_deref(),
            Some("/usr/local/bin/pinentry")
        );
    }
}
