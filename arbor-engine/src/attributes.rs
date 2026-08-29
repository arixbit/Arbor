//! CFG-001：Git config、attributes 与 CRLF 建模。
//!
//! - config：解析 system/global/local 三层并标注来源（`git config --list
//!   --show-origin --show-scope`），diff/staging/blame 展示换行行为时能
//!   解释「为什么」；
//! - attributes：`git check-attr -z` 的结构化结果，覆盖 text/eol/binary/
//!   diff/merge/filter/working-tree-encoding；
//! - CRLF：把 core.autocrlf、core.eol 与 text/eol 属性合成单个文件的有效
//!   换行行为（入库 normalization + 检出方向），diff 与 staging 用同一套
//!   结果，保证与命令行 Git 一致。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{OnceLock, RwLock};
use std::time::Duration;

use crate::error::EngineError;
use crate::gitprocess::{self, GitCommandCategory, GitCommandSpec};

/// Custom clean/smudge filters and non-UTF-8 working-tree encodings are
/// executable Git configuration. Keep the capability opt-in at application
/// scope so opening a repository never starts a configured command silently.
static DEFAULT_EXTERNAL_CONVERSION_ENABLED: OnceLock<AtomicBool> = OnceLock::new();
static WORKTREE_EXTERNAL_CONVERSION: OnceLock<RwLock<HashMap<PathBuf, bool>>> = OnceLock::new();

fn default_external_conversion_flag() -> &'static AtomicBool {
    DEFAULT_EXTERNAL_CONVERSION_ENABLED.get_or_init(|| AtomicBool::new(false))
}

fn worktree_conversion_settings() -> &'static RwLock<HashMap<PathBuf, bool>> {
    WORKTREE_EXTERNAL_CONVERSION.get_or_init(|| RwLock::new(HashMap::new()))
}

pub(crate) fn set_default_external_conversion_enabled(enabled: bool) {
    default_external_conversion_flag().store(enabled, Ordering::SeqCst);
}

pub(crate) fn register_worktree(workdir: &Path) {
    let key = workdir.to_path_buf();
    let enabled = default_external_conversion_flag().load(Ordering::SeqCst);
    worktree_conversion_settings()
        .write()
        .expect("external conversion settings lock poisoned")
        .entry(key)
        .or_insert(enabled);
}

pub(crate) fn set_worktree_external_conversion_enabled(workdir: &Path, enabled: bool) {
    worktree_conversion_settings()
        .write()
        .expect("external conversion settings lock poisoned")
        .insert(workdir.to_path_buf(), enabled);
}

fn external_conversion_enabled(workdir: &Path) -> bool {
    worktree_conversion_settings()
        .read()
        .expect("external conversion settings lock poisoned")
        .get(workdir)
        .copied()
        .unwrap_or_else(|| default_external_conversion_flag().load(Ordering::SeqCst))
}

/// config 层级。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConfigScope {
    System,
    Global,
    Local,
    Worktree,
    Command,
    Unknown,
}

/// 一条带来源的 config 条目。
#[derive(uniffi::Record, Clone, Debug)]
pub struct ConfigEntry {
    /// 形如 `core.autocrlf`。
    pub key: String,
    pub value: String,
    pub scope: ConfigScope,
    /// 来源文件路径 + 行号（`--show-origin` 的 file:line 格式）。
    pub origin: Option<String>,
}

/// 文件的换行方向。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum LineEnding {
    Lf,
    Crlf,
}

/// 单个文件的有效 CRLF 行为：入库方向 + 检出方向。
/// 与 git 的 convert_to_git / convert_to_working_tree 语义对应。
#[derive(uniffi::Record, Clone, Debug)]
pub struct EffectiveLineEndings {
    /// 入库时是否把 CRLF 规范为 LF（text 开启且非 binary）。
    pub normalize_to_lf_on_commit: bool,
    /// 检出时写入工作区的换行。
    pub checkout_line_ending: LineEnding,
}

/// `git check-attr` 的单文件结果。`unset` 表示属性被显式设为 false，
/// `unspecified` 表示没有匹配的规则。
#[derive(uniffi::Enum, Clone, Debug, PartialEq, Eq)]
pub enum AttributeValue {
    Set,
    Unset,
    /// 带值的属性（diff=my-driver 等）。
    Value {
        value: String,
    },
    Unspecified,
}

/// 一个文件的属性集合（只包含查询过的属性）。
#[derive(uniffi::Record, Clone, Debug)]
pub struct FileAttributes {
    pub path: String,
    pub text: AttributeValue,
    pub eol: AttributeValue,
    pub binary: AttributeValue,
    pub diff: AttributeValue,
    pub merge: AttributeValue,
    pub filter: AttributeValue,
    pub working_tree_encoding: AttributeValue,
    /// Legacy `crlf` attribute. IntelliJ uses this together with `text` to
    /// decide whether a CRLF warning is intentional.
    pub crlf: AttributeValue,
}

pub(crate) const ATTR_KEYS: [&str; 8] = [
    "text",
    "eol",
    "binary",
    "diff",
    "merge",
    "filter",
    "working-tree-encoding",
    "crlf",
];

/// 解析 `git config --list --show-origin --show-scope -z` 的输出。
/// 返回按声明顺序的条目（后面覆盖前面，调用方按 key 取最后一条即为生效值）。
pub(crate) fn list_config(workdir: &Path) -> Result<Vec<ConfigEntry>, EngineError> {
    let spec = GitCommandSpec::new(GitCommandCategory::Config, "config")
        .args(["--list", "--show-origin", "--show-scope", "-z"])
        .working_dir(workdir);
    let outcome = gitprocess::run_to_completion(&spec)?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }
    let mut entries = Vec::new();
    // -z 输出: scope\0origin\0key\nvalue\0（每条 3 个 NUL 分隔字段）
    let tokens: Vec<&str> = outcome.stdout.split('\0').collect();
    for chunk in tokens.chunks(3) {
        if chunk.len() < 3 || chunk[0].is_empty() {
            continue;
        }
        let scope_raw = chunk[0];
        let origin_raw = chunk[1];
        let key_value = chunk[2];
        let (key, value) = match key_value.split_once('\n') {
            Some((k, v)) => (k.to_string(), v.to_string()),
            None => (key_value.to_string(), String::new()),
        };
        if key.is_empty() {
            continue;
        }
        entries.push(ConfigEntry {
            key,
            value,
            scope: parse_scope(scope_raw),
            origin: parse_origin(origin_raw),
        });
    }
    Ok(entries)
}

fn parse_scope(raw: &str) -> ConfigScope {
    match raw {
        "system" => ConfigScope::System,
        "global" => ConfigScope::Global,
        "local" => ConfigScope::Local,
        "worktree" => ConfigScope::Worktree,
        "command" => ConfigScope::Command,
        _ => ConfigScope::Unknown,
    }
}

/// `--show-origin` 输出形如 `file:/path/.git/config` 或 `file:line:...`。
fn parse_origin(raw: &str) -> Option<String> {
    raw.strip_prefix("file:")
        .map(|rest| rest.to_string())
        .or_else(|| {
            if raw.is_empty() {
                None
            } else {
                Some(raw.to_string())
            }
        })
}

/// 生效的 config 值：同 key 多条时取最后一条（git 语义）。
pub(crate) fn effective_config_value<'a>(entries: &'a [ConfigEntry], key: &str) -> Option<&'a str> {
    entries
        .iter()
        .filter(|entry| entry.key.eq_ignore_ascii_case(key))
        .map(|entry| entry.value.as_str())
        .next_back()
}

/// `git check-attr -z <keys> -- <paths>`，返回与 paths 等长的结果。
/// 属性由 git 自己解析（包括 .gitattributes、.git/info/attributes 和
/// core.attributesFile），保证与命令行行为一致。
/// `-z` 输出按输入 path 顺序、请求 attr 顺序，每条记录为
/// `path\0attr\0value\0` 三元组。
pub(crate) fn check_attributes(
    workdir: &Path,
    paths: &[String],
) -> Result<Vec<FileAttributes>, EngineError> {
    check_attributes_with_index(workdir, paths, None)
}

/// Read attributes from an alternate index. Checkout preflight uses a
/// temporary index populated from the target tree so a newly introduced
/// `.gitattributes` rule is validated before the real worktree is touched.
pub(crate) fn check_attributes_with_index(
    workdir: &Path,
    paths: &[String],
    index_path: Option<&Path>,
) -> Result<Vec<FileAttributes>, EngineError> {
    if paths.is_empty() {
        return Ok(Vec::new());
    }
    let mut spec = GitCommandSpec::new(GitCommandCategory::Config, "check-attr").arg("-z");
    if let Some(index_path) = index_path {
        spec = spec
            .arg("--cached")
            .env("GIT_INDEX_FILE", index_path.to_string_lossy());
    }
    spec = spec.args(ATTR_KEYS).separator().working_dir(workdir);
    for path in paths {
        spec = spec.arg(path.clone());
    }
    let outcome = gitprocess::run_to_completion(&spec)?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }
    // 输出以 \0 结尾:去掉尾部分隔符再切分,避免产生空 token。
    let stdout = outcome.stdout.trim_end_matches('\0');
    let tokens: Vec<&str> = stdout.split('\0').collect();
    let attr_count = ATTR_KEYS.len();
    if tokens.len() % (attr_count * 3) != 0 {
        return Err(EngineError::GitOperation {
            message: format!(
                "check-attr: unexpected record count {} for {} path(s)",
                tokens.len() / 3,
                paths.len()
            ),
        });
    }
    let mut results = Vec::with_capacity(paths.len());
    let mut idx = 0;
    while idx + 3 <= tokens.len() {
        let path = tokens[idx].to_string();
        let mut vals: Vec<AttributeValue> = Vec::with_capacity(attr_count);
        for _ in 0..attr_count {
            // tokens[idx+1] 是属性名，顺序即 ATTR_KEYS 的请求顺序
            vals.push(parse_attr_value(tokens[idx + 2]));
            idx += 3;
        }
        results.push(FileAttributes {
            path,
            text: vals[0].clone(),
            eol: vals[1].clone(),
            binary: vals[2].clone(),
            diff: vals[3].clone(),
            merge: vals[4].clone(),
            filter: vals[5].clone(),
            working_tree_encoding: vals[6].clone(),
            crlf: vals[7].clone(),
        });
    }
    Ok(results)
}

fn parse_attr_value(raw: &str) -> AttributeValue {
    match raw {
        "set" => AttributeValue::Set,
        "unset" => AttributeValue::Unset,
        "unspecified" => AttributeValue::Unspecified,
        value => AttributeValue::Value {
            value: value.to_string(),
        },
    }
}

/// 合成单个文件的有效换行行为。规则与 git convert.c 一致：
/// 1. `binary`/`-text` => 完全不做转换；diff driver 名称本身不改变换行转换；
/// 2. eol 属性 => 检出方向由此决定，入库规范为 LF；
/// 3. text 属性 => 入库规范为 LF，检出由 core.eol（autocrlf=true 时为 CRLF）；
/// 4. 无属性 => core.autocrlf：true=入库规范+检出 CRLF；input=入库规范+检出不动；
/// 5. text=auto 的换行嗅探（是否真的含 CRLF）由 git 在写入时决定，
///    这里返回的是「配置意图」，调用方结合文件内容判断。
pub(crate) fn effective_line_endings(
    config: &[ConfigEntry],
    attrs: &FileAttributes,
) -> EffectiveLineEndings {
    let autocrlf = effective_config_value(config, "core.autocrlf")
        .unwrap_or("")
        .to_ascii_lowercase();
    let core_eol = effective_config_value(config, "core.eol")
        .unwrap_or("")
        .to_ascii_lowercase();

    // 只有 binary 宏真正设置的 `binary` 属性会关闭转换。`diff=binary`
    // 只是一个 diff driver 名称，不能把它误判成 -text。
    let is_binary = attrs.binary == AttributeValue::Set;
    if is_binary {
        return EffectiveLineEndings {
            normalize_to_lf_on_commit: false,
            checkout_line_ending: detect_working_tree_eol(&autocrlf, &core_eol, attrs),
        };
    }

    match &attrs.eol {
        AttributeValue::Value { value } => {
            let eol = if value.eq_ignore_ascii_case("crlf") {
                LineEnding::Crlf
            } else {
                LineEnding::Lf
            };
            return EffectiveLineEndings {
                normalize_to_lf_on_commit: true,
                checkout_line_ending: eol,
            };
        }
        AttributeValue::Unset => {
            // eol=- 强制不做检出转换（text 仍可规范化入库）。
            return EffectiveLineEndings {
                normalize_to_lf_on_commit: attrs.text == AttributeValue::Set,
                checkout_line_ending: detect_working_tree_eol(&autocrlf, &core_eol, attrs),
            };
        }
        _ => {}
    }

    match attrs.text {
        AttributeValue::Set => EffectiveLineEndings {
            normalize_to_lf_on_commit: true,
            checkout_line_ending: detect_working_tree_eol(&autocrlf, &core_eol, attrs),
        },
        AttributeValue::Unset => EffectiveLineEndings {
            normalize_to_lf_on_commit: false,
            checkout_line_ending: detect_working_tree_eol(&autocrlf, &core_eol, attrs),
        },
        _ => {
            // text 未指定或 text=auto：入库是否规范由内容嗅探决定，
            // 配置层返回 autocrlf 的意图。
            let normalize = matches!(autocrlf.as_str(), "true" | "input" | "1" | "yes");
            EffectiveLineEndings {
                normalize_to_lf_on_commit: normalize,
                checkout_line_ending: detect_working_tree_eol(&autocrlf, &core_eol, attrs),
            }
        }
    }
}

/// 将工作区字节转换为可以写入 index 的内容。
///
/// 这只实现 Git 内建的 text/eol/autocrlf clean 规则。自定义 clean
/// filter 与非 UTF-8 `working-tree-encoding` 依赖外部命令或编码转换，
/// 按 CFG-001 的安全边界不执行；遇到这些属性时必须显式失败，不能把
/// 未转换的工作区字节伪装成已完成的暂存结果。
pub(crate) fn clean_worktree_bytes(
    workdir: &Path,
    path: &str,
    bytes: &[u8],
) -> Result<Vec<u8>, EngineError> {
    let mut attrs = check_attributes(workdir, &[path.to_string()])?;
    let Some(attrs) = attrs.pop() else {
        return Err(EngineError::GitOperation {
            message: format!("check-attr returned no result for '{path}'"),
        });
    };

    if has_external_conversion_metadata(&attrs) && external_conversion_enabled(workdir) {
        return convert_with_system_git(workdir, path, bytes, false);
    }
    if let AttributeValue::Value { value } = &attrs.filter {
        return Err(EngineError::GitOperation {
            message: format!(
                "cannot stage '{path}': custom clean filter '{value}' is disabled by the external-driver safety policy"
            ),
        });
    }
    if let AttributeValue::Value { value } = &attrs.working_tree_encoding {
        if !value.eq_ignore_ascii_case("utf-8") {
            return Err(EngineError::GitOperation {
                message: format!(
                    "cannot stage '{path}': working-tree-encoding '{value}' is not supported by the built-in clean path"
                ),
            });
        }
    }

    let config = list_config(workdir)?;
    let endings = effective_line_endings(&config, &attrs);
    let normalize = should_normalize_to_lf(&attrs, &endings, bytes);
    if !normalize {
        return Ok(bytes.to_vec());
    }

    Ok(to_lf(bytes))
}

/// 将 index 中的 canonical blob 转换成工作区字节。
///
/// 这是 materialize tree/checkout/restore 共用的内建 smudge 边界；symlink
/// 不经过此函数。自定义 filter 与非 UTF-8 编码不执行，避免 checkout
/// 隐式运行仓库配置的外部程序或产生错误编码。
pub(crate) fn checkout_worktree_bytes(
    workdir: &Path,
    path: &str,
    bytes: &[u8],
) -> Result<Vec<u8>, EngineError> {
    let mut attrs = check_attributes(workdir, &[path.to_string()])?;
    let Some(attrs) = attrs.pop() else {
        return Err(EngineError::GitOperation {
            message: format!("check-attr returned no result for '{path}'"),
        });
    };
    if has_external_conversion_metadata(&attrs) && external_conversion_enabled(workdir) {
        return convert_with_system_git(workdir, path, bytes, true);
    }
    reject_unsupported_conversion(&attrs, path, "checkout")?;

    // Binary and `eol=-` files keep their stored bytes. `text=auto` also
    // keeps binary-looking content, matching Git's NUL sniffing boundary.
    let explicitly_text =
        attrs.text == AttributeValue::Set || matches!(&attrs.eol, AttributeValue::Value { .. });
    if attrs.binary == AttributeValue::Set
        || attrs.text == AttributeValue::Unset
        || attrs.eol == AttributeValue::Unset
        || (content_looks_binary(bytes) && !explicitly_text)
    {
        return Ok(bytes.to_vec());
    }

    let config = list_config(workdir)?;
    match effective_line_endings(&config, &attrs).checkout_line_ending {
        LineEnding::Lf => Ok(to_lf(bytes)),
        LineEnding::Crlf => Ok(to_crlf(bytes)),
    }
}

/// Canonicalize only the worktree side for diff/staging comparisons.
///
/// Unlike `clean_worktree_bytes`, this helper does not reject external filter
/// metadata: the diff safety policy is to compare the visible raw bytes when
/// an external conversion would be required, rather than executing it.
pub(crate) fn normalize_worktree_for_diff(
    workdir: &Path,
    path: &str,
    bytes: &[u8],
) -> Result<Vec<u8>, EngineError> {
    let mut attrs = check_attributes(workdir, &[path.to_string()])?;
    let Some(attrs) = attrs.pop() else {
        return Err(EngineError::GitOperation {
            message: format!("check-attr returned no result for '{path}'"),
        });
    };
    if has_external_conversion_metadata(&attrs) {
        if external_conversion_enabled(workdir) {
            return convert_with_system_git(workdir, path, bytes, false);
        }
        return Ok(bytes.to_vec());
    }
    let config = list_config(workdir)?;
    let endings = effective_line_endings(&config, &attrs);
    if should_normalize_to_lf(&attrs, &endings, bytes) {
        Ok(to_lf(bytes))
    } else {
        Ok(bytes.to_vec())
    }
}

fn should_normalize_to_lf(
    attrs: &FileAttributes,
    endings: &EffectiveLineEndings,
    bytes: &[u8],
) -> bool {
    if attrs.binary == AttributeValue::Set || attrs.text == AttributeValue::Unset {
        return false;
    }
    let explicitly_text =
        attrs.text == AttributeValue::Set || matches!(&attrs.eol, AttributeValue::Value { .. });
    (endings.normalize_to_lf_on_commit && (explicitly_text || !content_looks_binary(bytes)))
        || (is_text_auto(attrs) && !content_looks_binary(bytes))
}

fn is_text_auto(attrs: &FileAttributes) -> bool {
    matches!(
        &attrs.text,
        AttributeValue::Value { value } if value.eq_ignore_ascii_case("auto")
    )
}

fn content_looks_binary(bytes: &[u8]) -> bool {
    bytes.iter().take(8000).any(|byte| *byte == 0)
}

fn has_external_conversion_metadata(attrs: &FileAttributes) -> bool {
    matches!(&attrs.filter, AttributeValue::Value { .. })
        || matches!(&attrs.working_tree_encoding, AttributeValue::Value { value } if !value.eq_ignore_ascii_case("utf-8"))
}

/// Ask the configured system Git to perform exactly one clean or smudge
/// conversion without touching the repository index or worktree.
///
/// `hash-object --path` applies clean filters and working-tree encoding. For
/// the reverse direction, the canonical input is first stored with
/// `--no-filters`, then `cat-file --filters --path` applies Git's smudge and
/// checkout encoding. Objects are written into a temporary object directory
/// with the repository object store as an alternate, so a failed conversion
/// cannot mutate the repository's real object database.
fn convert_with_system_git(
    workdir: &Path,
    path: &str,
    bytes: &[u8],
    checkout: bool,
) -> Result<Vec<u8>, EngineError> {
    let temp = tempfile::Builder::new()
        .prefix("arbor-external-conversion-")
        .tempdir()
        .map_err(EngineError::from_gix)?;
    let input_path = temp.path().join("input");
    let output_path = temp.path().join("output");
    let object_dir = temp.path().join("objects");
    std::fs::create_dir(&object_dir).map_err(EngineError::from_gix)?;
    std::fs::write(&input_path, bytes).map_err(EngineError::from_gix)?;

    let repository_objects = repository_objects_dir(workdir)?;
    let object_dir_text = object_dir.to_string_lossy().into_owned();
    let alternate_objects = repository_objects.to_string_lossy().into_owned();
    let hash_args = if checkout {
        vec![
            "--no-filters".to_string(),
            "-w".to_string(),
            input_path.to_string_lossy().into_owned(),
        ]
    } else {
        vec![
            format!("--path={path}"),
            "-w".to_string(),
            input_path.to_string_lossy().into_owned(),
        ]
    };
    let hash_spec = GitCommandSpec::new(GitCommandCategory::Other, "hash-object")
        .args(hash_args)
        .env("GIT_OBJECT_DIRECTORY", &object_dir_text)
        .env("GIT_ALTERNATE_OBJECT_DIRECTORIES", &alternate_objects)
        .timeout(Duration::from_secs(10))
        .working_dir(workdir);
    let hash_outcome = gitprocess::run_to_completion(&hash_spec)?;
    if !hash_outcome.success() {
        return Err(hash_outcome.into_error(&hash_spec));
    }
    let object_id = hash_outcome.stdout.trim();
    if object_id.is_empty() || !object_id.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(EngineError::GitOperation {
            message: format!("{} returned an invalid object id", hash_spec.display()),
        });
    }

    let cat_spec = GitCommandSpec::new(GitCommandCategory::Other, "cat-file")
        .args(if checkout {
            vec![
                "--filters".to_string(),
                format!("--path={path}"),
                object_id.to_string(),
            ]
        } else {
            vec!["blob".to_string(), object_id.to_string()]
        })
        .env("GIT_OBJECT_DIRECTORY", &object_dir_text)
        .env("GIT_ALTERNATE_OBJECT_DIRECTORIES", &alternate_objects)
        .timeout(Duration::from_secs(10))
        .stdout_file(&output_path)
        .working_dir(workdir);
    let cat_outcome = gitprocess::run_to_completion(&cat_spec)?;
    if !cat_outcome.success() {
        return Err(cat_outcome.into_error(&cat_spec));
    }
    std::fs::read(&output_path).map_err(EngineError::from_gix)
}

fn repository_objects_dir(workdir: &Path) -> Result<PathBuf, EngineError> {
    let spec = GitCommandSpec::new(GitCommandCategory::Config, "rev-parse")
        .args(["--git-path", "objects"])
        .working_dir(workdir)
        .timeout(Duration::from_secs(5));
    let outcome = gitprocess::run_to_completion(&spec)?;
    if !outcome.success() {
        return Err(outcome.into_error(&spec));
    }
    let raw = outcome.stdout.trim();
    if raw.is_empty() {
        return Err(EngineError::GitOperation {
            message: "git rev-parse returned an empty object directory".into(),
        });
    }
    let path = PathBuf::from(raw);
    let path = if path.is_absolute() {
        path
    } else {
        workdir.join(path)
    };
    Ok(path)
}

pub(crate) fn validate_checkout_attributes(
    workdir: &Path,
    attrs: &[FileAttributes],
) -> Result<(), EngineError> {
    for attr in attrs {
        if has_external_conversion_metadata(attr) && external_conversion_enabled(workdir) {
            continue;
        }
        reject_unsupported_conversion(attr, &attr.path, "checkout")?;
    }
    Ok(())
}

fn reject_unsupported_conversion(
    attrs: &FileAttributes,
    path: &str,
    operation: &str,
) -> Result<(), EngineError> {
    if let AttributeValue::Value { value } = &attrs.filter {
        return Err(EngineError::GitOperation {
            message: format!(
                "cannot {operation} '{path}': custom clean filter '{value}' is disabled by the external-driver safety policy"
            ),
        });
    }
    if let AttributeValue::Value { value } = &attrs.working_tree_encoding {
        if !value.eq_ignore_ascii_case("utf-8") {
            return Err(EngineError::GitOperation {
                message: format!(
                    "cannot {operation} '{path}': working-tree-encoding '{value}' is not supported by the built-in conversion path"
                ),
            });
        }
    }
    Ok(())
}

fn to_lf(bytes: &[u8]) -> Vec<u8> {
    let mut normalized = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\r' && bytes.get(index + 1) == Some(&b'\n') {
            normalized.push(b'\n');
            index += 2;
        } else {
            normalized.push(bytes[index]);
            index += 1;
        }
    }
    normalized
}

fn to_crlf(bytes: &[u8]) -> Vec<u8> {
    let mut converted = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'\n' && (index == 0 || bytes[index - 1] != b'\r') {
            converted.push(b'\r');
        }
        converted.push(bytes[index]);
        index += 1;
    }
    converted
}

fn detect_working_tree_eol(autocrlf: &str, core_eol: &str, attrs: &FileAttributes) -> LineEnding {
    if let AttributeValue::Value { value } = &attrs.eol {
        return if value.eq_ignore_ascii_case("crlf") {
            LineEnding::Crlf
        } else {
            LineEnding::Lf
        };
    }
    match core_eol {
        "lf" => LineEnding::Lf,
        "crlf" => LineEnding::Crlf,
        _ => match autocrlf {
            "true" | "1" | "yes" => LineEnding::Crlf,
            _ => LineEnding::Lf,
        },
    }
}
