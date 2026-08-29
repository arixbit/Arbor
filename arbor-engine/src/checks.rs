//! 提交前检查命令：在仓库根目录执行显式 argv，不经过 shell。

use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use crate::error::EngineError;

const MAX_OUTPUT_CHARS: usize = 1_000_000;

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct CheckOutcome {
    pub success: bool,
    pub output: String,
    pub timed_out: bool,
}

pub(crate) fn run(
    workdir: &Path,
    command: &str,
    args: &[String],
    timeout: Duration,
) -> Result<CheckOutcome, EngineError> {
    if command.trim().is_empty() {
        return Err(EngineError::GitOperation {
            message: "check command is empty".into(),
        });
    }

    let mut child = Command::new(command)
        .args(args)
        .current_dir(workdir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(EngineError::from_gix)?;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let stdout_reader = thread::spawn(move || read_pipe(stdout));
    let stderr_reader = thread::spawn(move || read_pipe(stderr));

    let deadline = Instant::now() + timeout;
    let mut timed_out = false;
    let status = loop {
        match child.try_wait().map_err(EngineError::from_gix)? {
            Some(status) => break status,
            None if Instant::now() >= deadline => {
                timed_out = true;
                let _ = child.kill();
                break child.wait().map_err(EngineError::from_gix)?;
            }
            None => thread::sleep(Duration::from_millis(25)),
        }
    };

    let mut output = stdout_reader
        .join()
        .map_err(|_| EngineError::GitOperation {
            message: "check stdout reader panicked".into(),
        })?
        .map_err(EngineError::from_gix)?;
    let stderr_bytes = stderr_reader
        .join()
        .map_err(|_| EngineError::GitOperation {
            message: "check stderr reader panicked".into(),
        })?
        .map_err(EngineError::from_gix)?;
    if !output.is_empty() && !stderr_bytes.is_empty() {
        output.push(b'\n');
    }
    output.extend(stderr_bytes);
    let mut output = String::from_utf8_lossy(&output).into_owned();
    if output.chars().count() > MAX_OUTPUT_CHARS {
        output = output.chars().take(MAX_OUTPUT_CHARS).collect();
        output.push_str("\n… output truncated …");
    }
    if timed_out {
        output.push_str("\ncheck timed out");
    }

    Ok(CheckOutcome {
        success: status.success() && !timed_out,
        output,
        timed_out,
    })
}

fn read_pipe<R: Read>(reader: Option<R>) -> std::io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    if let Some(mut reader) = reader {
        reader.read_to_end(&mut bytes)?;
    }
    Ok(bytes)
}

/// COMMIT-001：内置提交检查类别（对齐 IntelliJ commit checks）。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommitCheckKind {
    /// user.name / user.email 未配置。
    IdentityMissing,
    /// HEAD detached（提示，不阻塞）。
    DetachedHead,
    /// 在未完成的非交互式 rebase 中提交（提示，不阻塞）。
    RebaseInProgress,
    /// 存在未解决冲突。
    UnresolvedConflicts,
    /// 暂存了超过调用方阈值的大文件（警告）。
    LargeFile,
    /// 工作区存在未被 Git attributes 解释的 CRLF 换行。
    CrlfWarning,
    /// 新增或重命名的路径在 Windows 上不可安全检出。
    BadFileName,
    /// 通过。
    Ok,
}

/// 一条内置检查结果。
#[derive(uniffi::Record, Clone, Debug)]
pub struct CommitCheckResult {
    pub kind: CommitCheckKind,
    /// 引擎产出的结构化消息（无用户文案的约束见 D7，UI 本地化）。
    pub message: String,
    /// 阻塞提交（true）或仅警告。
    pub blocking: bool,
}

/// COMMIT-001：签名配置（commit.gpgsign / gpg.format / user.signingkey）。
#[derive(uniffi::Record, Clone, Debug)]
pub struct SigningConfig {
    /// commit.gpgsign 是否开启。
    pub enabled: bool,
    /// gpg.format（openpgp / ssh / x509）。
    pub format: String,
    /// user.signingkey（未配置时 None）。
    pub signing_key: Option<String>,
}

pub(crate) const DEFAULT_COMMIT_CHECK_LARGE_FILE_LIMIT_BYTES: u64 = 1024 * 1024;
const WINDOWS_INVALID_FILE_NAME_CHARS: &str = "<>:\"\\|?*";
const WINDOWS_RESERVED_FILE_NAMES: &[&str] = &[
    "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8",
    "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
];

/// 运行内置提交检查：身份、冲突、detached HEAD、大文件、CRLF 和非法文件名提示。
pub(crate) fn run_commit_checks(
    repo: &gix::Repository,
    max_file_size_bytes: u64,
    paths: Option<&[String]>,
) -> Result<Vec<CommitCheckResult>, EngineError> {
    use gix::bstr::ByteSlice;
    let mut results = Vec::new();

    // 1. 身份检查
    let config_path = repo.git_dir().join("config");
    let config = gix::config::File::from_path_no_includes(config_path, gix::config::Source::Local)
        .map_err(EngineError::from_gix)?;
    let (user_name, user_email) = match repo.workdir() {
        Some(workdir) => (
            crate::repo::git_config_effective_value(workdir, "user.name")?.unwrap_or_default(),
            crate::repo::git_config_effective_value(workdir, "user.email")?.unwrap_or_default(),
        ),
        None => (String::new(), String::new()),
    };
    let name_missing = user_name.trim().is_empty();
    let email_missing = user_email.trim().is_empty();
    if name_missing || email_missing {
        let missing = [
            name_missing.then_some("user.name"),
            email_missing.then_some("user.email"),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(", ");
        results.push(CommitCheckResult {
            kind: CommitCheckKind::IdentityMissing,
            message: format!("git identity missing: {missing}"),
            blocking: true,
        });
    }

    // 2. 未解决冲突
    let status = match paths {
        Some(paths) if !paths.is_empty() => crate::status::compute_status_paths(repo, paths)?,
        _ => crate::status::compute_status(repo)?,
    };
    let conflicts: Vec<String> = status
        .iter()
        .filter(|entry| {
            entry.staged == crate::status::ChangeKind::Conflicted
                || entry.unstaged == crate::status::ChangeKind::Conflicted
        })
        .map(|entry| entry.path.clone())
        .collect();
    if !conflicts.is_empty() {
        results.push(CommitCheckResult {
            kind: CommitCheckKind::UnresolvedConflicts,
            message: format!("unresolved conflicts: {}", conflicts.join(", ")),
            blocking: true,
        });
    }

    // 3. detached HEAD / unfinished rebase warning（不阻塞）。IntelliJ
    // suppresses the generic detached warning for an interactive rebase and
    // uses a rebase-specific message for other native rebase states.
    let detached = repo.head_name().map_err(EngineError::from_gix)?.is_none();
    if detached {
        let rebase = crate::opstate::detect(repo)?
            .filter(|state| state.kind == crate::opstate::OperationKind::Rebase);
        if !rebase.as_ref().is_some_and(|state| state.interactive) {
            let (kind, message) = if rebase.is_some() {
                (
                    CommitCheckKind::RebaseInProgress,
                    "commit during an unfinished rebase".to_string(),
                )
            } else {
                (
                    CommitCheckKind::DetachedHead,
                    "HEAD is detached".to_string(),
                )
            };
            results.push(CommitCheckResult {
                kind,
                message,
                blocking: false,
            });
        }
    }

    // 4. 暂存的大文件、CRLF 与 Windows 非法文件名提示
    let mut large_files = Vec::new();
    let mut crlf_files = Vec::new();
    let mut bad_file_names = Vec::new();
    let large_file_warning_enabled =
        max_file_size_bytes > 0 && config.string("lfs.repositoryformatversion").is_none();
    let index = repo.index().ok();
    let crlf_warning_enabled = repo.workdir().is_some_and(|workdir| {
        match crate::repo::git_config_effective_value(workdir, "core.autocrlf") {
            Ok(value) => !value.is_some_and(|value| {
                matches!(
                    value.trim().to_ascii_lowercase().as_str(),
                    "true" | "input" | "1" | "yes"
                )
            }),
            // GitCrlfProblemsDetector fails gracefully when config cannot be
            // read: an unavailable config must not create a warning storm.
            Err(_) => false,
        }
    });
    let crlf_attributes_by_path: Option<HashMap<String, crate::attributes::FileAttributes>> =
        if crlf_warning_enabled {
            let paths = status
                .iter()
                .filter(|entry| entry.staged != crate::status::ChangeKind::Unchanged)
                .map(|entry| entry.path.clone())
                .collect::<Vec<_>>();
            repo.workdir().and_then(|workdir| {
                crate::attributes::check_attributes(workdir, &paths)
                    .ok()
                    .map(|attributes| {
                        attributes
                            .into_iter()
                            .map(|attributes| (attributes.path.clone(), attributes))
                            .collect()
                    })
            })
        } else {
            None
        };
    for entry in &status {
        if entry.staged == crate::status::ChangeKind::Unchanged {
            continue;
        }
        let path = entry.path.as_bytes().as_bstr();
        if let Some(index) = index.as_ref() {
            if let Some(blob) = index.entry_by_path(path) {
                if large_file_warning_enabled && u64::from(blob.stat.size) > max_file_size_bytes {
                    large_files.push(entry.path.clone());
                }
            }
        }
        let has_explicit_line_ending_attribute = crlf_attributes_by_path
            .as_ref()
            .and_then(|attributes| attributes.get(&entry.path))
            .is_some_and(|attributes| {
                attributes.text != crate::attributes::AttributeValue::Unspecified
                    || attributes.crlf != crate::attributes::AttributeValue::Unspecified
                    || attributes.binary == crate::attributes::AttributeValue::Set
            });
        if crlf_attributes_by_path.is_some() && !has_explicit_line_ending_attribute {
            if let Some(workdir) = repo.workdir() {
                if let Ok(bytes) = std::fs::read(workdir.join(&entry.path)) {
                    let has_crlf = bytes.windows(2).any(|w| w == b"\r\n");
                    if has_crlf {
                        crlf_files.push(entry.path.clone());
                    }
                }
            }
        }
        if matches!(
            entry.staged,
            crate::status::ChangeKind::Added
                | crate::status::ChangeKind::Renamed
                | crate::status::ChangeKind::Copied
        ) {
            if let Some(reason) = first_bad_file_name_reason(&entry.path) {
                bad_file_names.push(format!("{} ({reason})", entry.path));
            }
        }
    }
    if !large_files.is_empty() {
        results.push(CommitCheckResult {
            kind: CommitCheckKind::LargeFile,
            message: format!("large files staged: {}", large_files.join(", ")),
            blocking: false,
        });
    }
    if !crlf_files.is_empty() {
        results.push(CommitCheckResult {
            kind: CommitCheckKind::CrlfWarning,
            message: format!("CRLF line endings: {}", crlf_files.join(", ")),
            blocking: false,
        });
    }
    if !bad_file_names.is_empty() {
        results.push(CommitCheckResult {
            kind: CommitCheckKind::BadFileName,
            message: format!(
                "paths may be invalid on Windows: {}",
                bad_file_names.join(", ")
            ),
            blocking: false,
        });
    }

    Ok(results)
}

fn first_bad_file_name_reason(path: &str) -> Option<String> {
    for component in Path::new(path).components() {
        let std::path::Component::Normal(component) = component else {
            continue;
        };
        let name = component.to_string_lossy();
        let stem = name
            .rsplit_once('.')
            .map(|(stem, _)| stem)
            .unwrap_or(name.as_ref());
        if (3..=4).contains(&stem.len())
            && WINDOWS_RESERVED_FILE_NAMES
                .iter()
                .any(|reserved| reserved.eq_ignore_ascii_case(stem))
        {
            return Some("reserved Windows name".into());
        }
        if name.chars().any(|character| {
            character.is_ascii_control() || WINDOWS_INVALID_FILE_NAME_CHARS.contains(character)
        }) {
            return Some("invalid Windows character".into());
        }
    }
    None
}

/// 读取签名配置。
pub(crate) fn signing_config(repo: &gix::Repository) -> Result<SigningConfig, EngineError> {
    let effective = |key: &str| -> Result<Option<String>, EngineError> {
        match repo.workdir() {
            Some(workdir) => crate::repo::git_config_effective_value(workdir, key),
            None => Ok(None),
        }
    };
    let enabled = effective("commit.gpgsign")?.is_some_and(|value| {
        matches!(
            value.to_ascii_lowercase().as_str(),
            "true" | "yes" | "on" | "1"
        )
    });
    let format = effective("gpg.format")?.unwrap_or_else(|| "openpgp".to_string());
    let signing_key = effective("user.signingkey")?;
    Ok(SigningConfig {
        enabled,
        format,
        signing_key,
    })
}

/// AUTH-001 收口：检测已配置的 credential helper（`git config --get-all
/// credential.helper` + 常用 helper 是否存在）。
#[derive(uniffi::Record, Clone, Debug)]
pub struct CredentialHelperInfo {
    /// helper 名（如 osxkeychain、store）。
    pub name: String,
    /// 该 helper 可执行文件是否存在于 PATH（配置了但缺失 -> 提示）。
    pub available: bool,
}

/// Read-only diagnostics for the OpenSSH authentication agent selected by
/// `SSH_AUTH_SOCK`. The probe never returns identities, fingerprints, or
/// command output; it only reports the agent state and identity count.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SshAgentState {
    NotConfigured,
    Unreachable,
    NoIdentities,
    Ready,
    Error,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct SshAgentDiagnostics {
    pub state: SshAgentState,
    pub socket_path: String,
    pub identity_count: u32,
    /// Stable, non-sensitive reason code for UI and diagnostics logging.
    pub detail_code: String,
}

/// Probe the current user's SSH agent without changing its state. In
/// particular, `ssh-add -l` only lists identities; it does not add, remove,
/// or unlock keys.
pub(crate) fn ssh_agent_diagnostics() -> Result<SshAgentDiagnostics, EngineError> {
    let Some(socket) = std::env::var_os("SSH_AUTH_SOCK") else {
        return Ok(SshAgentDiagnostics {
            state: SshAgentState::NotConfigured,
            socket_path: String::new(),
            identity_count: 0,
            detail_code: "missing-ssh-auth-sock".into(),
        });
    };
    let socket_path = socket.to_string_lossy().into_owned();
    if socket_path.trim().is_empty() {
        return Ok(SshAgentDiagnostics {
            state: SshAgentState::NotConfigured,
            socket_path,
            identity_count: 0,
            detail_code: "empty-ssh-auth-sock".into(),
        });
    }

    let socket_path_ref = Path::new(&socket_path);
    let metadata = match std::fs::metadata(socket_path_ref) {
        Ok(metadata) => metadata,
        Err(_) => {
            return Ok(SshAgentDiagnostics {
                state: SshAgentState::Unreachable,
                socket_path,
                identity_count: 0,
                detail_code: "socket-missing".into(),
            })
        }
    };
    #[cfg(unix)]
    if !std::os::unix::fs::FileTypeExt::is_socket(&metadata.file_type()) {
        return Ok(SshAgentDiagnostics {
            state: SshAgentState::Unreachable,
            socket_path,
            identity_count: 0,
            detail_code: "socket-not-socket".into(),
        });
    }

    let Some(ssh_add) = executable_path("ssh-add") else {
        return Ok(SshAgentDiagnostics {
            state: SshAgentState::Error,
            socket_path,
            identity_count: 0,
            detail_code: "ssh-add-missing".into(),
        });
    };
    let mut child = match Command::new(ssh_add)
        .arg("-l")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => {
            return Ok(SshAgentDiagnostics {
                state: SshAgentState::Error,
                socket_path,
                identity_count: 0,
                detail_code: "ssh-add-spawn-failed".into(),
            })
        }
    };

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(25)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait_with_output();
                return Ok(SshAgentDiagnostics {
                    state: SshAgentState::Unreachable,
                    socket_path,
                    identity_count: 0,
                    detail_code: "agent-timeout".into(),
                });
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait_with_output();
                return Ok(SshAgentDiagnostics {
                    state: SshAgentState::Error,
                    socket_path,
                    identity_count: 0,
                    detail_code: "agent-wait-failed".into(),
                });
            }
        }
    }
    let output = match child.wait_with_output() {
        Ok(output) => output,
        Err(_) => {
            return Ok(SshAgentDiagnostics {
                state: SshAgentState::Error,
                socket_path,
                identity_count: 0,
                detail_code: "agent-output-failed".into(),
            })
        }
    };

    let identity_count = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .count() as u32;
    let (state, detail_code) = classify_ssh_agent_output(
        output.status.success(),
        output.status.code(),
        &output.stdout,
        &output.stderr,
    );
    Ok(SshAgentDiagnostics {
        state,
        socket_path,
        identity_count,
        detail_code: detail_code.into(),
    })
}

fn classify_ssh_agent_output(
    success: bool,
    exit_code: Option<i32>,
    stdout: &[u8],
    stderr: &[u8],
) -> (SshAgentState, &'static str) {
    let identity_count = String::from_utf8_lossy(stdout)
        .lines()
        .filter(|line| !line.trim().is_empty())
        .count();
    let stdout_lower = String::from_utf8_lossy(stdout).to_ascii_lowercase();
    let stderr_lower = String::from_utf8_lossy(stderr).to_ascii_lowercase();
    let no_identities = exit_code == Some(1)
        || stdout_lower.contains("no identities")
        || stdout_lower.contains("no identity")
        || stderr_lower.contains("no identities")
        || stderr_lower.contains("no identity");
    let unreachable = stdout_lower.contains("could not open a connection")
        || stderr_lower.contains("could not open a connection")
        || stdout_lower.contains("connection refused")
        || stderr_lower.contains("connection refused")
        || stdout_lower.contains("permission denied")
        || stderr_lower.contains("permission denied");

    if success && identity_count > 0 {
        (SshAgentState::Ready, "agent-ready")
    } else if no_identities || (success && identity_count == 0) {
        (SshAgentState::NoIdentities, "agent-empty")
    } else if unreachable {
        (SshAgentState::Unreachable, "agent-unreachable")
    } else {
        (SshAgentState::Error, "agent-probe-failed")
    }
}

pub(crate) fn credential_helpers(
    repo: &gix::Repository,
) -> Result<Vec<CredentialHelperInfo>, EngineError> {
    let mut helpers = Vec::new();
    // local + 常见 global 路径的 credential.helper 都算
    let mut seen = std::collections::HashSet::new();
    let collect = |file: gix::config::File,
                   seen: &mut std::collections::HashSet<String>,
                   helpers: &mut Vec<CredentialHelperInfo>| {
        for section in file.sections() {
            let header = section.header();
            if header.name() != "credential" {
                continue;
            }
            for value in section.values("helper") {
                let name = value.to_string();
                if name.starts_with('!') {
                    continue; // shell 命令形式,跳过
                }
                let binary = name.split_whitespace().next().unwrap_or(&name).to_string();
                if !seen.insert(binary.clone()) {
                    continue;
                }
                let available = which(&binary);
                helpers.push(CredentialHelperInfo { name, available });
            }
        }
    };
    let local = gix::config::File::from_path_no_includes(
        repo.git_dir().join("config"),
        gix::config::Source::Local,
    )
    .map_err(EngineError::from_gix)?;
    collect(local, &mut seen, &mut helpers);
    if let Some(home) = std::env::var("HOME").ok() {
        for candidate in [".gitconfig", ".config/git/config"] {
            let path = std::path::PathBuf::from(&home).join(candidate);
            if path.exists() {
                if let Ok(file) =
                    gix::config::File::from_path_no_includes(path, gix::config::Source::User)
                {
                    collect(file, &mut seen, &mut helpers);
                }
            }
        }
    }
    // 默认 osxkeychain 提示:未配置任何 helper 时给出建议条目
    if helpers.is_empty() {
        helpers.push(CredentialHelperInfo {
            name: "osxkeychain (suggested)".into(),
            available: which("git-credential-osxkeychain"),
        });
    }
    Ok(helpers)
}

/// PATH 中是否存在可执行文件。
fn which(binary: &str) -> bool {
    if binary.contains('/') {
        return std::path::Path::new(binary).exists();
    }
    std::env::var("PATH")
        .map(|paths| {
            paths.split(':').any(|dir| {
                let candidate = std::path::Path::new(dir).join(binary);
                candidate.exists()
                    || candidate.with_extension("exe").exists()
                    || std::path::Path::new(dir)
                        .join(format!("git-credential-{binary}"))
                        .exists()
            })
        })
        .unwrap_or(false)
}

fn executable_path(binary: &str) -> Option<PathBuf> {
    if binary.contains('/') {
        let path = PathBuf::from(binary);
        return path.is_file().then_some(path);
    }
    let paths = std::env::var_os("PATH")?;
    std::env::split_paths(&paths)
        .map(|directory| directory.join(binary))
        .find(|candidate| candidate.is_file())
}

#[cfg(test)]
mod tests {
    use super::{classify_ssh_agent_output, SshAgentDiagnostics, SshAgentState};

    #[test]
    fn ssh_agent_states_are_explicit_and_non_sensitive() {
        let diagnostics = SshAgentDiagnostics {
            state: SshAgentState::NoIdentities,
            socket_path: "/private/tmp/agent.sock".into(),
            identity_count: 0,
            detail_code: "agent-empty".into(),
        };
        assert_eq!(diagnostics.state, SshAgentState::NoIdentities);
        assert_eq!(diagnostics.identity_count, 0);
        assert_eq!(diagnostics.detail_code, "agent-empty");
    }

    #[test]
    fn ssh_agent_output_classification_counts_only_identity_lines() {
        let (state, detail_code) = classify_ssh_agent_output(
            true,
            Some(0),
            b"256 SHA256:one comment (ED25519)\n256 SHA256:two comment (ED25519)\n",
            b"",
        );
        assert_eq!(state, SshAgentState::Ready);
        assert_eq!(detail_code, "agent-ready");
    }

    #[test]
    fn ssh_agent_exit_code_one_is_the_empty_agent_case() {
        let (state, detail_code) = classify_ssh_agent_output(false, Some(1), b"", b"");
        assert_eq!(state, SshAgentState::NoIdentities);
        assert_eq!(detail_code, "agent-empty");
    }

    #[test]
    fn ssh_agent_connection_failure_is_not_reported_as_empty() {
        let (state, detail_code) = classify_ssh_agent_output(
            false,
            Some(2),
            b"",
            b"Could not open a connection to your authentication agent.",
        );
        assert_eq!(state, SshAgentState::Unreachable);
        assert_eq!(detail_code, "agent-unreachable");
    }
}
