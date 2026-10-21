//! Git hooks 管理：列出 / 启用 / 禁用 / 编辑 / 安装 sample / 删除。
//!
//! 执行侧在 `hooks.rs`（pre-commit、commit-msg）；这里只处理磁盘状态。
//! 所有写入都是用户显式动作，Arbor 不会主动执行被编辑的 hook。
//!
//! 语义与 `git` 保持一致：
//! - hook 目录服从 `core.hooksPath`（绝对路径、`~/...` 或相对工作区根）；
//! - 「启用」即可执行位存在；没有可执行位的文件 Git 会忽略；
//! - `name.sample` 是官方模板，安装即复制成可执行的 `name`。

use std::io::Write;
use std::path::{Path, PathBuf};

use crate::error::EngineError;
use crate::gitprocess::{self, GitCommandCategory, GitCommandSpec};
use crate::hooks;
use crate::repo::Repository;

/// hook 的当前状态。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum GitHookState {
    /// 文件存在且可执行：Git 会运行它。
    Enabled,
    /// 文件存在但没有可执行位：Git 会忽略它。
    Disabled,
    /// 只有 `name.sample`，可以一键安装。
    Sample,
    /// 既没有 hook 也没有 sample。
    Missing,
}

/// 一个 hook 的只读描述。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct GitHookInfo {
    pub name: String,
    pub state: GitHookState,
    /// hook 文件绝对路径；`Missing` 时是该 hook 将来写入的位置。
    pub path: String,
    pub size_bytes: u64,
    pub modified_unix: i64,
    /// 内容含 NUL 字节，界面不提供文本编辑。
    pub is_binary: bool,
    /// 目录里有 `name.sample`。
    pub has_sample: bool,
}

/// hook 文件内容。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct GitHookContents {
    pub name: String,
    pub content: String,
    pub is_binary: bool,
    /// 超过读取上限被截断；界面禁止保存，避免写回半截脚本。
    pub truncated: bool,
}

/// hooks 目录位置与 `core.hooksPath` 覆盖情况。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct GitHooksLocation {
    pub directory: String,
    /// 配置了 `core.hooksPath` 时是配置原文。
    pub custom_path: Option<String>,
}

/// 单文件读取上限：hook 是脚本，超过这个体积按二进制处理。
const MAX_HOOK_BYTES: u64 = 512 * 1024;

fn file_is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        return std::fs::metadata(path)
            .map(|meta| meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false);
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

fn file_is_binary(path: &Path) -> bool {
    use std::io::Read;
    let Ok(mut file) = std::fs::File::open(path) else {
        return false;
    };
    let mut buffer = [0u8; 8192];
    match file.read(&mut buffer) {
        Ok(read) => buffer[..read].contains(&0),
        Err(_) => false,
    }
}

fn modified_unix(path: &Path) -> i64 {
    std::fs::metadata(path)
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|time| time.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

/// hook 名只能是文件名：不允许路径分隔符，也不允许直接改 sample。
fn validate_hook_name(name: &str) -> Result<(), EngineError> {
    let invalid = name.is_empty()
        || name.trim() != name
        || name.contains('/')
        || name.contains('\\')
        || name.ends_with(".sample")
        || name == "."
        || name == ".."
        || name.chars().any(char::is_control);
    if invalid {
        return Err(EngineError::GitOperation {
            message: format!("invalid git hook name: {name}"),
        });
    }
    Ok(())
}

/// 读取 `core.hooksPath`（含 system/global/local 三层）。用系统 Git 读取，
/// 与其它配置读取保持一致。
fn configured_hooks_path(workdir: &Path) -> Option<String> {
    let spec = GitCommandSpec::new(GitCommandCategory::Config, "config")
        .args(["--get".to_string(), "core.hooksPath".to_string()])
        .working_dir(workdir);
    let outcome = gitprocess::run_to_completion(&spec).ok()?;
    if !outcome.success() {
        return None;
    }
    let value = outcome.stdout.trim().to_string();
    if value.is_empty() {
        None
    } else {
        Some(value)
    }
}

/// 相对路径按工作区根解析（与 Git 运行 hook 时的工作目录一致）。
fn hooks_directory(workdir: &Path, git_dir: &Path) -> PathBuf {
    let Some(raw) = configured_hooks_path(workdir) else {
        return git_dir.join("hooks");
    };
    if let Some(rest) = raw.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join(rest);
        }
    }
    let candidate = PathBuf::from(&raw);
    if candidate.is_absolute() {
        return candidate;
    }
    workdir.join(candidate)
}

fn ensure_directory(dir: &Path) -> Result<(), EngineError> {
    std::fs::create_dir_all(dir).map_err(EngineError::from_gix)
}

fn list_hooks(workdir: &Path, git_dir: &Path) -> Result<Vec<GitHookInfo>, EngineError> {
    let directory = hooks_directory(workdir, git_dir);
    let mut names: Vec<String> = hooks::HOOK_NAMES
        .iter()
        .map(|name| (*name).to_string())
        .collect();
    names.dedup();
    if let Ok(entries) = std::fs::read_dir(&directory) {
        let mut extra: Vec<String> = Vec::new();
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.ends_with(".sample") || names.contains(&name) {
                continue;
            }
            if entry.path().is_file() {
                extra.push(name);
            }
        }
        extra.sort();
        names.extend(extra);
    }
    Ok(names
        .into_iter()
        .map(|name| {
            let path = directory.join(&name);
            let sample = directory.join(format!("{name}.sample"));
            let has_sample = sample.is_file();
            let exists = path.is_file();
            let state = if exists {
                if file_is_executable(&path) {
                    GitHookState::Enabled
                } else {
                    GitHookState::Disabled
                }
            } else if has_sample {
                GitHookState::Sample
            } else {
                GitHookState::Missing
            };
            GitHookInfo {
                size_bytes: std::fs::metadata(&path).map(|meta| meta.len()).unwrap_or(0),
                modified_unix: if exists { modified_unix(&path) } else { 0 },
                is_binary: exists && file_is_binary(&path),
                has_sample,
                state,
                path: path.to_string_lossy().into_owned(),
                name,
            }
        })
        .collect())
}

fn hook_contents(
    workdir: &Path,
    git_dir: &Path,
    name: &str,
) -> Result<GitHookContents, EngineError> {
    validate_hook_name(name)?;
    let path = hooks_directory(workdir, git_dir).join(name);
    let metadata = std::fs::metadata(&path).map_err(EngineError::from_gix)?;
    let truncated = metadata.len() > MAX_HOOK_BYTES;
    let bytes = std::fs::read(&path).map_err(EngineError::from_gix)?;
    let head = if truncated {
        &bytes[..MAX_HOOK_BYTES as usize]
    } else {
        &bytes[..]
    };
    Ok(GitHookContents {
        name: name.to_string(),
        is_binary: head.contains(&0),
        truncated,
        content: String::from_utf8_lossy(head).into_owned(),
    })
}

/// 原子写入 hook：先写临时文件再 rename，随后确保可执行位存在。
fn write_hook_file(directory: &Path, name: &str, contents: &[u8]) -> Result<PathBuf, EngineError> {
    ensure_directory(directory)?;
    let path = directory.join(name);
    let temporary = directory.join(format!(".{name}.arbor-tmp"));
    {
        let mut file = std::fs::File::create(&temporary).map_err(EngineError::from_gix)?;
        file.write_all(contents).map_err(EngineError::from_gix)?;
        file.sync_all().map_err(EngineError::from_gix)?;
    }
    std::fs::rename(&temporary, &path).map_err(EngineError::from_gix)?;
    set_executable(&path, true)?;
    Ok(path)
}

fn set_executable(path: &Path, executable: bool) -> Result<(), EngineError> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut permissions = std::fs::metadata(path)
            .map_err(EngineError::from_gix)?
            .permissions();
        let mode = permissions.mode();
        permissions.set_mode(if executable {
            mode | 0o111
        } else {
            mode & !0o111
        });
        std::fs::set_permissions(path, permissions).map_err(EngineError::from_gix)?;
    }
    #[cfg(not(unix))]
    {
        let _ = (path, executable);
    }
    Ok(())
}

/// bare 仓库没有工作区；解析相对 hooksPath 时回退到 Git 目录。
fn hook_workdir(repository: &Repository) -> PathBuf {
    repository
        .workdir()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(repository.git_dir()))
}

#[uniffi::export]
impl Repository {
    /// hooks 目录位置；配置了 `core.hooksPath` 时一并返回配置原文。
    pub fn git_hooks_location(&self) -> GitHooksLocation {
        let workdir = hook_workdir(self);
        let git_dir = PathBuf::from(self.git_dir());
        let custom = configured_hooks_path(&workdir);
        GitHooksLocation {
            directory: hooks_directory(&workdir, &git_dir)
                .to_string_lossy()
                .into_owned(),
            custom_path: custom,
        }
    }

    /// 列出所有 hook（内置名单 + 目录里额外的可执行脚本）。
    pub fn git_hooks(&self) -> Result<Vec<GitHookInfo>, EngineError> {
        list_hooks(&hook_workdir(self), &PathBuf::from(self.git_dir()))
    }

    /// 读取 hook 内容。
    pub fn git_hook_contents(&self, name: String) -> Result<GitHookContents, EngineError> {
        hook_contents(&hook_workdir(self), &PathBuf::from(self.git_dir()), &name)
    }

    /// 保存 hook 内容；文件不存在时创建并加可执行位。
    pub fn save_git_hook(&self, name: String, content: String) -> Result<GitHookInfo, EngineError> {
        validate_hook_name(&name)?;
        let workdir = hook_workdir(self);
        let git_dir = PathBuf::from(self.git_dir());
        let directory = hooks_directory(&workdir, &git_dir);
        write_hook_file(&directory, &name, content.as_bytes())?;
        find_hook(&workdir, &git_dir, &name)
    }

    /// 启用/禁用 hook：只切换可执行位，不移动或删除文件。
    pub fn set_git_hook_enabled(
        &self,
        name: String,
        enabled: bool,
    ) -> Result<GitHookInfo, EngineError> {
        validate_hook_name(&name)?;
        let workdir = hook_workdir(self);
        let git_dir = PathBuf::from(self.git_dir());
        let path = hooks_directory(&workdir, &git_dir).join(&name);
        if !path.is_file() {
            return Err(EngineError::GitOperation {
                message: format!("git hook does not exist: {name}"),
            });
        }
        set_executable(&path, enabled)?;
        find_hook(&workdir, &git_dir, &name)
    }

    /// 用 `name.sample` 安装 hook（覆盖已有文件），安装后可执行。
    pub fn install_git_hook_sample(&self, name: String) -> Result<GitHookInfo, EngineError> {
        validate_hook_name(&name)?;
        let workdir = hook_workdir(self);
        let git_dir = PathBuf::from(self.git_dir());
        let directory = hooks_directory(&workdir, &git_dir);
        let sample = directory.join(format!("{name}.sample"));
        let contents = std::fs::read(&sample).map_err(EngineError::from_gix)?;
        write_hook_file(&directory, &name, &contents)?;
        find_hook(&workdir, &git_dir, &name)
    }

    /// 删除 hook 文件；`.sample` 模板保留。
    pub fn delete_git_hook(&self, name: String) -> Result<(), EngineError> {
        validate_hook_name(&name)?;
        let workdir = hook_workdir(self);
        let path = hooks_directory(&workdir, &PathBuf::from(self.git_dir())).join(&name);
        if !path.is_file() {
            return Ok(());
        }
        std::fs::remove_file(&path).map_err(EngineError::from_gix)
    }
}

fn find_hook(workdir: &Path, git_dir: &Path, name: &str) -> Result<GitHookInfo, EngineError> {
    list_hooks(workdir, git_dir)?
        .into_iter()
        .find(|hook| hook.name == name)
        .ok_or_else(|| EngineError::GitOperation {
            message: format!("git hook not found after update: {name}"),
        })
}
