//! AUTH-001：认证与凭证代理（credential broker）。
//!
//! 引擎定义协议与状态，SwiftUI 实现交互（对话框/Keychain），引擎不感知 UI：
//! - `CredentialRequestHandler`（uniffi callback interface）：Swift 注入；
//! - `CredentialBroker`：持有 handler，为 system git 命令挂 `GIT_ASKPASS`/
//!   `SSH_ASKPASS` 桥（临时脚本 + 文件通道），把 git 的凭证提示转成
//!   结构化 `CredentialRequest`，再把 Swift 的决定喂回 git；
//! - 用户取消 → 脚本退出非零 → 结果分类为 `GitFailureKind::Cancelled`；
//! - 凭证只存在于内存与 Keychain，绝不进入日志/错误文本（配合 gitprocess
//!   的脱敏）。
//!
//! 协议细节见 docs/auth-credential-broker.md（设计稿）。

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use crate::error::EngineError;
use crate::gitprocess::{self, GitCancelToken, GitCommandSpec, GitFailureKind, GitProcessOutcome};

/// 凭证类型。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum CredentialKind {
    /// HTTPS 用户名 + 密码/token。
    UsernamePassword,
    /// SSH 私钥 passphrase。
    Passphrase,
    /// OpenSSH 首次连接的 host-key confirmation。
    HostKey,
}

/// 一次 system Git 操作中，broker 观察到的成功 SSH 认证。
///
/// 这里只传递 user/host/method，不传递 secret。若认证由 SSH agent 或
/// 外部 credential helper 静默完成，askpass broker 无法观察到它，也不会
/// 伪造成功事件。
#[derive(uniffi::Record, Clone, Debug)]
pub struct AuthenticationSuccess {
    pub host: String,
    pub username: String,
    /// 稳定值：`publickey` 或 `password`。
    pub method: String,
}

/// 一次凭证请求的结构化描述（git askpass 的 prompt 解析而来）。
#[derive(uniffi::Record, Clone, Debug)]
pub struct CredentialRequest {
    /// 主机（如 github.com；SSH 私钥 passphrase 也尽量填真实远端 host）。
    pub host: String,
    /// 已知道的用户名（可能为空，由 UI 补全）。
    pub username: String,
    /// 当前认证对应的无密码远端 URL；用于按远端记住用户名，不用于日志。
    pub remote_url: String,
    pub kind: CredentialKind,
    /// 第几次尝试（>1 表示上次失败后重试）。
    pub attempt: u32,
    /// 上次失败的分类（脱敏后）；重建 askpass 会话时由引擎传入。
    pub previous_error: Option<String>,
    /// 原始 askpass prompt；host-key confirmation 可能包含多行指纹信息。
    pub prompt: String,
    /// Whether this request may open the interactive credential UI.  Background
    /// incoming checks use the silent mode so a missing/expired credential is
    /// reported as an authentication failure instead of interrupting the user.
    pub allow_interaction: bool,
}

/// Swift 的决定。
#[derive(uniffi::Enum, Clone, Debug)]
pub enum CredentialDecision {
    /// 提供凭证；save_to_keychain 由 UI 勾选。
    Provide {
        username: String,
        secret: String,
        save_to_keychain: bool,
    },
    /// 用户取消：操作结果为 cancelled，而不是 generic error。
    Cancel,
}

#[derive(uniffi::Record, Clone, Debug)]
pub struct CredentialResponse {
    pub decision: CredentialDecision,
}

/// SwiftUI 实现的回调接口：收到请求后查 Keychain、弹对话框并返回决定。
/// 调用发生在引擎的 askpass 服务线程，Swift 侧需自行跳主线程做 UI。
#[uniffi::export(callback_interface)]
pub trait CredentialRequestHandler: Send + Sync {
    fn on_credential_request(&self, request: CredentialRequest) -> CredentialResponse;
    fn on_authentication_succeeded(&self, success: AuthenticationSuccess);
    fn on_authentication_failed(&self, request: CredentialRequest);
}

/// 凭证代理：整个进程一个实例，Swift 在启动时注入 handler。
#[derive(uniffi::Object)]
pub struct CredentialBroker {
    handler: Mutex<Option<Arc<dyn CredentialRequestHandler>>>,
    use_credential_helper: AtomicBool,
    successful_remote_keys: Mutex<HashSet<String>>,
}

impl CredentialBroker {
    fn new_inner() -> Self {
        CredentialBroker {
            handler: Mutex::new(None),
            use_credential_helper: AtomicBool::new(false),
            successful_remote_keys: Mutex::new(HashSet::new()),
        }
    }
}

#[uniffi::export]
impl CredentialBroker {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self::new_inner())
    }

    /// 注入 Swift 的交互实现；重复调用覆盖。
    pub fn set_handler(&self, handler: Box<dyn CredentialRequestHandler>) {
        *self.handler.lock().expect("broker mutex poisoned") = Some(handler.into());
    }

    /// 清空 handler（进程退出/测试隔离）。
    pub fn clear_handler(&self) {
        *self.handler.lock().expect("broker mutex poisoned") = None;
    }

    /// Match IntelliJ's application-level Git setting. When disabled, Git
    /// operations that use this broker bypass configured credential helpers so
    /// authentication is observable by the Arbor credential UI.
    pub fn set_use_credential_helper(&self, enabled: bool) {
        self.use_credential_helper.store(enabled, Ordering::SeqCst);
    }

    pub fn is_use_credential_helper(&self) -> bool {
        self.use_credential_helper.load(Ordering::SeqCst)
    }

    /// Return whether this broker has observed a successful interactive
    /// authentication for the remote.  This is intentionally process-local;
    /// secrets remain in Keychain and the marker is only used to select the
    /// IntelliJ-compatible SILENT mode for later background checks.
    pub fn has_successful_authentication(&self, remote_url: String) -> bool {
        let key = remote_url_key(&remote_url);
        !key.is_empty()
            && self
                .successful_remote_keys
                .lock()
                .expect("successful remote mutex poisoned")
                .contains(&key)
    }

    fn remember_successful_remote(&self, remote_url: &str) {
        let key = remote_url_key(remote_url);
        if key.is_empty() {
            return;
        }
        self.successful_remote_keys
            .lock()
            .expect("successful remote mutex poisoned")
            .insert(key);
    }

    /// 带 askpass 桥的通用 git 执行（认证调试/测试/未来 UI 入口）。
    /// `argv` 是 `git` 之后的完整参数（全局选项、子命令、其余参数），
    /// 如 `["-c", "credential.helper=", "ls-remote", url]`。
    /// 用户取消认证时 `failure == Cancelled`。
    pub fn run_git_with_askpass(
        &self,
        argv: Vec<String>,
        working_dir: Option<String>,
    ) -> Result<GitProcessOutcome, EngineError> {
        self.run_git_with_auth_mode(argv, working_dir, true)
    }

    /// Run a raw Git command with stored credentials only.  This mirrors the
    /// SILENT mode used by background incoming checks and is useful to callers
    /// that need the same no-dialog guarantee outside Repository fetch APIs.
    pub fn run_git_with_silent_auth(
        &self,
        argv: Vec<String>,
        working_dir: Option<String>,
    ) -> Result<GitProcessOutcome, EngineError> {
        self.run_git_with_auth_mode(argv, working_dir, false)
    }

    fn run_git_with_auth_mode(
        &self,
        argv: Vec<String>,
        working_dir: Option<String>,
        allow_interaction: bool,
    ) -> Result<GitProcessOutcome, EngineError> {
        // 全局选项（以 - 开头）位于子命令之前；第一个非选项 token 是子命令。
        let mut global_args = Vec::new();
        let mut rest = argv.into_iter();
        while let Some(token) = rest.next() {
            if token == "-c" {
                global_args.push(token);
                let Some(value) = rest.next() else {
                    return Err(EngineError::GitOperation {
                        message: "git -c requires a configuration value".into(),
                    });
                };
                global_args.push(value);
            } else if token.starts_with('-') {
                global_args.push(token);
            } else {
                let mut spec =
                    GitCommandSpec::new(crate::gitprocess::GitCommandCategory::Other, token.trim());
                for global in global_args {
                    spec = spec.global_arg(global);
                }
                spec = spec.args(rest);
                if let Some(dir) = working_dir {
                    spec = spec.working_dir(dir);
                }
                return run_with_askpass_mode(&spec, self, None, allow_interaction);
            }
        }
        Err(EngineError::GitOperation {
            message: "git argv must contain a subcommand".into(),
        })
    }
}

impl CredentialBroker {
    fn handler(&self) -> Option<Arc<dyn CredentialRequestHandler>> {
        self.handler.lock().expect("broker mutex poisoned").clone()
    }

    fn use_credential_helper(&self) -> bool {
        self.use_credential_helper.load(Ordering::SeqCst)
    }
}

/// askpass 桥的一次会话：临时目录 + prompts/answer 文件通道 + 服务线程。
struct AskpassSession {
    dir: PathBuf,
    prompts_path: PathBuf,
    answer_path: PathBuf,
    done_path: PathBuf,
    script_path: PathBuf,
    stop: Arc<AtomicBool>,
    user_cancelled: Arc<AtomicBool>,
    credential_requested: Arc<AtomicBool>,
    host_key_rejected: Arc<AtomicBool>,
    last_attempt: Arc<AtomicU32>,
    last_authentication: Arc<Mutex<Option<AuthenticationSuccess>>>,
    pending_username_credential: Arc<Mutex<Option<PendingUsernameCredential>>>,
    last_credential_request: Arc<Mutex<Option<CredentialRequest>>>,
}

struct PendingUsernameCredential {
    attempt: u32,
    host: String,
    remote_url: String,
    username: String,
    secret: String,
}

impl AskpassSession {
    fn new(dir: PathBuf) -> Self {
        AskpassSession {
            prompts_path: dir.join("prompts"),
            answer_path: dir.join("answer"),
            done_path: dir.join("answer.done"),
            script_path: dir.join("askpass.sh"),
            dir,
            stop: Arc::new(AtomicBool::new(false)),
            user_cancelled: Arc::new(AtomicBool::new(false)),
            credential_requested: Arc::new(AtomicBool::new(false)),
            host_key_rejected: Arc::new(AtomicBool::new(false)),
            last_attempt: Arc::new(AtomicU32::new(0)),
            last_authentication: Arc::new(Mutex::new(None)),
            pending_username_credential: Arc::new(Mutex::new(None)),
            last_credential_request: Arc::new(Mutex::new(None)),
        }
    }

    fn write_script(&self) -> Result<(), EngineError> {
        use std::os::unix::fs::PermissionsExt;
        let dir = shell_quote(&self.dir);
        let script = format!(
            r#"#!/bin/sh
# Arbor askpass bridge: git -> prompts file; engine -> answer.done(指针) + answer.N。
# done 是唯一同步点:读到后立即删除(独占认领),再读指名的应答文件;
# 旧脚本只删自己指名的文件,新应答不受影响。
prompt="$1"
# SSH host-key confirmation prompts contain newlines. Encode them into one
# record so the engine does not mistake the fingerprint lines for separate
# credential requests.
prompt=$(printf '%s' "$prompt" | tr '\n' '\037')
dir={dir}
printf '%s\n' "$prompt" >> "$dir/prompts"
i=0
while [ "$i" -lt 1200 ]; do
  if [ -f "$dir/answer.done" ]; then
    fname=$(cat "$dir/answer.done")
    rm -f "$dir/answer.done"
    answer=$(cat "$dir/$fname")
    rm -f "$dir/$fname"
    if [ "$answer" = "__ARBOR_CANCEL__" ]; then
      exit 1
    fi
    printf '%s' "$answer"
    exit 0
  fi
  i=$((i + 1))
  sleep 0.05
done
exit 1
"#,
            dir = dir
        );
        std::fs::write(&self.script_path, script).map_err(EngineError::from_gix)?;
        let mut permissions = std::fs::metadata(&self.script_path)
            .map_err(EngineError::from_gix)?
            .permissions();
        permissions.set_mode(0o700);
        std::fs::set_permissions(&self.script_path, permissions).map_err(EngineError::from_gix)?;
        Ok(())
    }

    /// 服务线程：轮询 prompts 文件，逐条调用 handler 并写回决定。
    fn spawn_service(
        &self,
        broker: &CredentialBroker,
        target: Option<RemoteIdentity>,
        initial_attempt: u32,
        previous_error: Option<String>,
        allow_interaction: bool,
    ) -> std::thread::JoinHandle<()> {
        let prompts_path = self.prompts_path.clone();
        let answer_path = self.answer_path.clone();
        let done_path = self.done_path.clone();
        let stop = self.stop.clone();
        let user_cancelled = self.user_cancelled.clone();
        let credential_requested = self.credential_requested.clone();
        let host_key_rejected = self.host_key_rejected.clone();
        let last_attempt = self.last_attempt.clone();
        let last_authentication = self.last_authentication.clone();
        let pending_username_credential = self.pending_username_credential.clone();
        let last_credential_request = self.last_credential_request.clone();
        let handler = broker.handler();
        std::thread::spawn(move || {
            let mut offset: u64 = 0;
            // `attempt` is an authentication round, not a prompt count:
            // username and password prompts belonging to one Git attempt
            // must carry the same number.
            let attempt = initial_attempt.max(1);
            // 串行协议:一个应答必须被脚本消费(文件删除)后才能处理下一个。
            // 否则批量到达的 prompt 会覆盖 done 指针,旧脚本读到新应答。
            let mut answer_pending = false;
            while !stop.load(Ordering::SeqCst) {
                if !answer_pending {
                    // 增量读取新 prompt(每次最多处理一个)
                    let (new_lines, new_offset) = read_new_lines(&prompts_path, offset);
                    offset = new_offset;
                    for prompt in new_lines {
                        credential_requested.store(true, Ordering::SeqCst);
                        last_attempt.store(attempt, Ordering::SeqCst);
                        let request = parse_prompt_with_target(
                            &prompt,
                            attempt,
                            target.as_ref(),
                            previous_error.as_deref(),
                            allow_interaction,
                        );
                        *last_credential_request
                            .lock()
                            .expect("askpass request mutex poisoned") = Some(request.clone());
                        let cached = take_pending_username_credential(
                            &pending_username_credential,
                            &request,
                            &prompt,
                        );
                        let response = if let Some(cached) = cached {
                            CredentialResponse {
                                decision: CredentialDecision::Provide {
                                    username: cached.username,
                                    secret: cached.secret,
                                    save_to_keychain: false,
                                },
                            }
                        } else {
                            match &handler {
                                Some(h) => h.on_credential_request(request.clone()),
                                None => CredentialResponse {
                                    decision: CredentialDecision::Cancel,
                                },
                            }
                        };
                        if request.kind == CredentialKind::HostKey {
                            if let CredentialDecision::Provide { secret, .. } = &response.decision {
                                if secret.trim().to_ascii_lowercase() != "yes" {
                                    host_key_rejected.store(true, Ordering::SeqCst);
                                }
                            }
                        }
                        if let CredentialDecision::Provide { username, .. } = &response.decision {
                            if let Some(success) =
                                authentication_candidate(&request, username, target.as_ref())
                            {
                                *last_authentication
                                    .lock()
                                    .expect("askpass auth mutex poisoned") = Some(success);
                            }
                        }
                        remember_username_prompt_credential(
                            &pending_username_credential,
                            &request,
                            &prompt,
                            &response,
                        );
                        let answer = match &response.decision {
                            CredentialDecision::Provide {
                                username, secret, ..
                            } => {
                                // askpass 按 prompt 类型返回:username 或 password
                                if prompt_asks_username(&prompt) {
                                    username.clone()
                                } else {
                                    secret.clone()
                                }
                            }
                            CredentialDecision::Cancel => {
                                if request.allow_interaction {
                                    user_cancelled.store(true, Ordering::SeqCst);
                                }
                                "__ARBOR_CANCEL__".to_string()
                            }
                        };
                        // 唯一文件名 + done 指针:先写 answer.N,再写 done(内容为文件名)。
                        // 脚本独占认领 done 后只删自己指名的文件,不触碰其他应答。
                        let name = format!("answer.{attempt}");
                        let _ = std::fs::write(answer_path.with_file_name(&name), &answer);
                        let _ = std::fs::write(&done_path, &name);
                        answer_pending = true;
                        break; // 等消费完再处理下一个
                    }
                } else {
                    // 等脚本消费:done 消失即消费完成
                    if !done_path.exists() {
                        answer_pending = false;
                    }
                }
                std::thread::sleep(std::time::Duration::from_millis(15));
            }
        })
    }

    fn cleanup(&self) {
        if std::env::var_os("ARBOR_KEEP_ASKPASS_DIR").is_some() {
            return;
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }

    fn successful_authentication(&self) -> Option<AuthenticationSuccess> {
        self.last_authentication
            .lock()
            .expect("askpass auth mutex poisoned")
            .clone()
    }

    fn credential_was_requested(&self) -> bool {
        self.credential_requested.load(Ordering::SeqCst)
    }

    fn host_key_was_rejected(&self) -> bool {
        self.host_key_rejected.load(Ordering::SeqCst)
    }

    fn last_attempt(&self) -> u32 {
        self.last_attempt.load(Ordering::SeqCst)
    }

    fn last_credential_request(&self) -> Option<CredentialRequest> {
        self.last_credential_request
            .lock()
            .expect("askpass request mutex poisoned")
            .clone()
    }
}

fn remember_username_prompt_credential(
    pending: &Mutex<Option<PendingUsernameCredential>>,
    request: &CredentialRequest,
    prompt: &str,
    response: &CredentialResponse,
) {
    if request.kind != CredentialKind::UsernamePassword || !prompt_asks_username(prompt) {
        return;
    }
    let CredentialDecision::Provide {
        username, secret, ..
    } = &response.decision
    else {
        return;
    };
    if username.trim().is_empty() || secret.is_empty() {
        return;
    }
    *pending.lock().expect("askpass credential mutex poisoned") = Some(PendingUsernameCredential {
        attempt: request.attempt,
        host: request.host.clone(),
        remote_url: request.remote_url.clone(),
        username: username.clone(),
        secret: secret.clone(),
    });
}

fn take_pending_username_credential(
    pending: &Mutex<Option<PendingUsernameCredential>>,
    request: &CredentialRequest,
    prompt: &str,
) -> Option<PendingUsernameCredential> {
    if request.kind != CredentialKind::UsernamePassword || prompt_asks_username(prompt) {
        return None;
    }
    let mut pending = pending.lock().expect("askpass credential mutex poisoned");
    let matches = pending.as_ref().is_some_and(|value| {
        value.attempt == request.attempt
            && value.host == request.host
            && remote_url_key(&value.remote_url) == remote_url_key(&request.remote_url)
    });
    if matches {
        pending.take()
    } else {
        // A different password prompt means the previous username/password
        // pair does not belong to this Git request. Do not retain its secret
        // for a later prompt in a multi-remote process.
        *pending = None;
        None
    }
}

fn read_new_lines(path: &Path, mut offset: u64) -> (Vec<String>, u64) {
    let Ok(meta) = std::fs::metadata(path) else {
        return (Vec::new(), offset);
    };
    let len = meta.len();
    if len <= offset {
        return (Vec::new(), offset);
    }
    let Ok(file) = std::fs::File::open(path) else {
        return (Vec::new(), offset);
    };
    use std::io::{Read, Seek, SeekFrom};
    let mut file = file;
    let _ = file.seek(SeekFrom::Start(offset));
    let mut buf = Vec::with_capacity((len - offset) as usize);
    // 用实际读到的字节数推进 offset:metadata 与 read 之间文件可能继续增长,
    // 用 metadata 长度会导致同一行被重复处理(并行负载下稳定复现)。
    let read = match file.read_to_end(&mut buf) {
        Ok(n) => n,
        Err(_) => return (Vec::new(), offset),
    };
    offset += read as u64;
    let text = String::from_utf8_lossy(&buf);
    let lines = text
        .lines()
        .map(|line| {
            line.replace('\u{1f}', "\n")
                .trim_end_matches(':')
                .trim()
                .to_string()
        })
        .filter(|line| !line.is_empty())
        .collect();
    (lines, offset)
}

/// prompt 形状: "Username for 'https://host/path':" / "Password for 'https://user@host/path':"
/// / "user@host's password:" / "Enter passphrase for key '/path/key':"
#[cfg(test)]
fn parse_prompt(prompt: &str, attempt: u32) -> CredentialRequest {
    parse_prompt_with_target(prompt, attempt, None, None, true)
}

fn parse_prompt_with_target(
    prompt: &str,
    attempt: u32,
    target: Option<&RemoteIdentity>,
    previous_error: Option<&str>,
    allow_interaction: bool,
) -> CredentialRequest {
    let lower = prompt.to_ascii_lowercase();
    if lower.contains("are you sure you want to continue connecting") {
        return CredentialRequest {
            host: parse_host_key_host(prompt),
            username: String::new(),
            remote_url: format!("ssh://{}", parse_host_key_host(prompt)),
            kind: CredentialKind::HostKey,
            attempt,
            previous_error: previous_error.map(str::to_string),
            prompt: prompt.to_string(),
            allow_interaction,
        };
    }
    if lower.starts_with("enter passphrase for key") {
        let (host, username, remote_url) = target
            .filter(|target| target.is_ssh)
            .map(|target| {
                (
                    target.host.clone(),
                    target.username.clone(),
                    target.remote_url.clone(),
                )
            })
            .unwrap_or_else(|| {
                (
                    "ssh-key".to_string(),
                    String::new(),
                    "ssh://ssh-key".to_string(),
                )
            });
        return CredentialRequest {
            host,
            username,
            remote_url,
            kind: CredentialKind::Passphrase,
            attempt,
            previous_error: previous_error.map(str::to_string),
            prompt: prompt.to_string(),
            allow_interaction,
        };
    }
    if lower.contains("'s password") {
        // "user@host's password"
        let user_host = prompt.split('\'').next().unwrap_or("").trim().to_string();
        let (username, host) = split_user_host(&user_host);
        let remote_url = format!("ssh://{}@{}", username, host);
        return CredentialRequest {
            host,
            username,
            remote_url,
            kind: CredentialKind::UsernamePassword,
            attempt,
            previous_error: previous_error.map(str::to_string),
            prompt: prompt.to_string(),
            allow_interaction,
        };
    }
    // "Username for 'URL':" / "Password for 'URL':"
    let url = extract_single_quoted(prompt).unwrap_or(prompt);
    let (username, host) = parse_url_userinfo(&url);
    CredentialRequest {
        host,
        username,
        remote_url: safe_remote_url(url),
        kind: CredentialKind::UsernamePassword,
        attempt,
        previous_error: previous_error.map(str::to_string),
        prompt: prompt.to_string(),
        allow_interaction,
    }
}

#[derive(Clone, Debug)]
struct RemoteIdentity {
    username: String,
    host: String,
    is_ssh: bool,
    remote_url: String,
}

fn authentication_candidate(
    request: &CredentialRequest,
    provided_username: &str,
    target: Option<&RemoteIdentity>,
) -> Option<AuthenticationSuccess> {
    let target = target.filter(|target| target.is_ssh)?;
    let method = match request.kind {
        CredentialKind::Passphrase => "publickey",
        CredentialKind::UsernamePassword => "password",
        CredentialKind::HostKey => return None,
    };
    let username = [
        provided_username,
        request.username.as_str(),
        target.username.as_str(),
    ]
    .into_iter()
    .map(str::trim)
    .find(|value| !value.is_empty())?
    .to_string();
    let host = if request.host == "ssh-key" || request.host == "ssh-host" {
        target.host.clone()
    } else {
        request.host.clone()
    };
    if host.trim().is_empty() {
        return None;
    }
    Some(AuthenticationSuccess {
        host,
        username,
        method: method.to_string(),
    })
}

fn should_remember_successful_remote(
    target: Option<&RemoteIdentity>,
    credential_was_requested: bool,
    successful_authentication: Option<&AuthenticationSuccess>,
) -> bool {
    // HTTPS has no separate success callback, so a credential prompt plus a
    // successful command is sufficient. For SSH, host-key confirmation is a
    // prompt too, but it is not authentication; require a recognized
    // password/publickey candidate there.
    (credential_was_requested && target.is_some_and(|target| !target.is_ssh))
        || successful_authentication.is_some()
}

fn parse_host_key_host(prompt: &str) -> String {
    let lower = prompt.to_ascii_lowercase();
    let Some(start) = lower.find("host '") else {
        return "ssh-host".to_string();
    };
    let value_start = start + "host '".len();
    let Some(end) = prompt[value_start..].find('\'') else {
        return "ssh-host".to_string();
    };
    let value = &prompt[value_start..value_start + end];
    value
        .split(|ch: char| ch.is_whitespace() || ch == '(')
        .next()
        .filter(|host| !host.is_empty())
        .unwrap_or("ssh-host")
        .to_string()
}

fn prompt_asks_username(prompt: &str) -> bool {
    let lower = prompt.to_ascii_lowercase();
    lower.contains("username for") || lower.contains("user name")
}

fn extract_single_quoted(text: &str) -> Option<&str> {
    let start = text.find('\'')? + 1;
    let rest = &text[start..];
    let end = rest.find('\'')?;
    Some(&rest[..end])
}

/// 从 "user@host" 拆分;无 @ 时 username 为空。
fn split_user_host(text: &str) -> (String, String) {
    match text.rsplit_once('@') {
        Some((user, host)) => (user.to_string(), host.to_string()),
        None => (String::new(), text.to_string()),
    }
}

/// 从 "https://user@host/path" 解析 (username, host)。
fn parse_url_userinfo(url: &str) -> (String, String) {
    let after_scheme = match url.find("://") {
        Some(i) => &url[i + 3..],
        None => url,
    };
    let host_part = after_scheme.split(['/', '?', '#']).next().unwrap_or("");
    let (username, host) = split_url_user_host(host_part);
    (username, host)
}

/// 从 URL authority 拆分 user/host，并丢弃误放入 URL 的 password。
/// URL 中的 password 绝不能进入 CredentialRequest 或 AuthenticationSuccess。
fn split_url_user_host(text: &str) -> (String, String) {
    let (username, host) = split_user_host(text);
    let username = username
        .split_once(':')
        .map_or(username.as_str(), |(user, _)| user)
        .to_string();
    (username, host)
}

/// 从 system Git 命令推导这次认证对应的远端。
///
/// push/clone/ls-remote 等命令会直接带 URL；fetch、push、ls-remote 使用
/// remote name 时，从该仓库的 local config 读取 `remote.<name>.url`。读取
/// 失败时返回 None，成功事件也随之保持未知，避免把 `ssh-key` 或任意
/// 参数误存成 host。
fn remote_identity_for_spec(spec: &GitCommandSpec) -> Option<RemoteIdentity> {
    for arg in &spec.args {
        if arg.starts_with('-') {
            continue;
        }
        if let Some(identity) = parse_remote_identity(arg) {
            return Some(identity);
        }
    }

    if !matches!(spec.subcommand.as_str(), "fetch" | "push" | "ls-remote") {
        return None;
    }
    let workdir = spec.working_dir.as_deref()?;
    for remote_name in spec
        .args
        .iter()
        .rev()
        .filter(|arg| !arg.starts_with('-') && !arg.contains(':') && is_safe_remote_name(arg))
    {
        let key = format!("remote.{remote_name}.url");
        let Ok(output) = crate::gitprocess::git_command_for_working_dir(workdir)
            .args(["config", "--local", "--get", key.as_str()])
            .current_dir(workdir)
            .output()
        else {
            continue;
        };
        if !output.status.success() {
            continue;
        }
        let url = String::from_utf8_lossy(&output.stdout);
        if let Some(identity) = parse_remote_identity(url.lines().next()?.trim()) {
            return Some(identity);
        }
    }
    None
}

fn is_safe_remote_name(name: &str) -> bool {
    !name.is_empty() && !name.starts_with('-') && !name.contains(['/', '\\', ' ', '\n', '\r', '\0'])
}

/// 解析 HTTPS/SSH URL 与 scp-style SSH URL，且不保留 URL 中的 secret。
fn parse_remote_identity(url: &str) -> Option<RemoteIdentity> {
    let url = url.trim();
    if url.is_empty() {
        return None;
    }
    if let Some((scheme, rest)) = url.split_once("://") {
        let scheme = scheme.to_ascii_lowercase();
        let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
        let (username, host) = split_url_user_host(authority);
        let host = host.trim_matches(['[', ']']).to_string();
        if host.is_empty() {
            return None;
        }
        return Some(RemoteIdentity {
            username,
            host,
            is_ssh: scheme == "ssh",
            remote_url: safe_remote_url(url),
        });
    }

    // scp-style: user@host:path. Absolute/local paths are deliberately ignored.
    let colon = url.find(':')?;
    let authority = &url[..colon];
    if authority.is_empty() || authority.contains(['/', '\\']) {
        return None;
    }
    let (username, host) = split_user_host(authority);
    if host.is_empty() {
        return None;
    }
    Some(RemoteIdentity {
        username,
        host,
        is_ssh: true,
        remote_url: url.to_string(),
    })
}

/// Remove a password from a remote URL before it crosses the askpass callback.
/// Git normally omits it from prompts, but a configured remote may still contain
/// userinfo and the request object must remain safe even in that case.
fn safe_remote_url(url: &str) -> String {
    let Some((scheme, rest)) = url.split_once("://") else {
        return url.to_string();
    };
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    let Some(at) = authority.rfind('@') else {
        return url.to_string();
    };
    let userinfo = &authority[..at];
    let username = userinfo.split_once(':').map_or(userinfo, |(user, _)| user);
    format!(
        "{}://{}@{}{}",
        scheme,
        username,
        &authority[at + 1..],
        &rest[authority_end..]
    )
}

/// Build a stable session key for prompts whose password URL gains the
/// username returned by the preceding username prompt.
fn remote_url_key(url: &str) -> String {
    let Some((scheme, rest)) = url.split_once("://") else {
        return url.to_string();
    };
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    let authority = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    format!(
        "{}://{}{}",
        scheme.to_ascii_lowercase(),
        authority.to_ascii_lowercase(),
        &rest[authority_end..]
    )
}

fn shell_quote(path: &Path) -> String {
    let value = path.to_string_lossy();
    format!("'{}'", value.replace('\'', "'\\''"))
}

/// 用 broker 的 askpass 桥运行一条 git 命令。
/// 返回的 outcome 中,若用户取消了认证,`failure` 为 `Cancelled`。
/// 会话目录序号：纳秒时间戳在并行测试下会撞名（两个会话写同一个
/// prompts/answer 文件互相污染），加进程内单调计数器保证唯一。
static SESSION_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

pub(crate) fn run_with_askpass(
    spec: &GitCommandSpec,
    broker: &CredentialBroker,
    cancel: Option<&GitCancelToken>,
) -> Result<GitProcessOutcome, EngineError> {
    run_with_askpass_mode(spec, broker, cancel, true)
}

/// Run Git with askpass backed by stored credentials only.  A missing
/// credential must never open the UI; the caller can surface the resulting
/// authentication failure as a background-check diagnostic.
pub(crate) fn run_with_silent_askpass(
    spec: &GitCommandSpec,
    broker: &CredentialBroker,
    cancel: Option<&GitCancelToken>,
) -> Result<GitProcessOutcome, EngineError> {
    run_with_askpass_mode(spec, broker, cancel, false)
}

fn run_with_askpass_mode(
    spec: &GitCommandSpec,
    broker: &CredentialBroker,
    cancel: Option<&GitCancelToken>,
    allow_interaction: bool,
) -> Result<GitProcessOutcome, EngineError> {
    let target = remote_identity_for_spec(spec);

    // IntelliJ retries an interactive Git command once after an
    // authentication failure. Each retry gets a fresh askpass session so a
    // stale Keychain/helper answer cannot be silently reused forever. A
    // SILENT background check has no new credential source after its first
    // refusal, so retrying would only repeat the same hidden failure.
    let mut authentication_round = 1;
    let mut initial_attempt = 1;
    let mut previous_error: Option<String> = None;
    loop {
        let seq = SESSION_COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!(
            "arbor-askpass-{}-{}-{seq}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.subsec_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).map_err(EngineError::from_gix)?;
        let session = AskpassSession::new(dir);
        session.write_script()?;

        let mut askpass_spec = apply_credential_helper_policy(spec, broker);
        askpass_spec = askpass_spec
            .env(
                "GIT_ASKPASS",
                session.script_path.to_string_lossy().into_owned(),
            )
            .env("GIT_TERMINAL_PROMPT", "0")
            .env(
                "SSH_ASKPASS",
                session.script_path.to_string_lossy().into_owned(),
            )
            .env("SSH_ASKPASS_REQUIRE", "force");

        let service = session.spawn_service(
            broker,
            target.clone(),
            initial_attempt,
            previous_error.clone(),
            allow_interaction,
        );
        let outcome_result = gitprocess::run(&askpass_spec, cancel, |_| {});
        session.stop.store(true, Ordering::SeqCst);
        let _ = service.join();
        let was_cancelled = session.user_cancelled.load(Ordering::SeqCst);
        let credential_was_requested = session.credential_was_requested();
        let host_key_was_rejected = session.host_key_was_rejected();
        let next_attempt = session.last_attempt().saturating_add(1).max(2);
        session.cleanup();

        let mut outcome = outcome_result?;
        if was_cancelled {
            outcome.cancelled = true;
            outcome.failure = Some(GitFailureKind::Cancelled);
        }

        let should_retry = allow_interaction
            && authentication_round < 2
            && outcome.failure == Some(GitFailureKind::Authentication)
            && credential_was_requested
            && !host_key_was_rejected
            && !outcome.cancelled;
        if should_retry {
            if let Some(request) = session.last_credential_request() {
                if let Some(handler) = broker.handler() {
                    handler.on_authentication_failed(request);
                }
            }
            authentication_round += 1;
            initial_attempt = next_attempt;
            previous_error = Some("Authentication".to_string());
            continue;
        }

        if outcome.failure == Some(GitFailureKind::Authentication) {
            if let Some(request) = session.last_credential_request() {
                if let Some(handler) = broker.handler() {
                    handler.on_authentication_failed(request);
                }
            }
        }

        let successful_authentication = session.successful_authentication();
        if outcome.success() {
            if should_remember_successful_remote(
                target.as_ref(),
                credential_was_requested,
                successful_authentication.as_ref(),
            ) {
                if let Some(target) = target.as_ref() {
                    broker.remember_successful_remote(&target.remote_url);
                }
            }
            if let Some(success) = successful_authentication {
                if let Some(handler) = broker.handler() {
                    handler.on_authentication_succeeded(success);
                }
            }
        }
        return Ok(outcome);
    }
}

fn apply_credential_helper_policy(
    spec: &GitCommandSpec,
    broker: &CredentialBroker,
) -> GitCommandSpec {
    if broker.use_credential_helper() {
        return spec.clone();
    }
    // Git accepts this as a command-level override and applies it after the
    // repository/user config, which is the same policy used by IntelliJ when
    // its application setting is disabled.
    spec.clone()
        .global_arg("-c")
        .global_arg("credential.helper=")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn credential_helper_policy_defaults_to_disabled_and_can_be_enabled() {
        let broker = CredentialBroker::new_inner();
        let spec = GitCommandSpec::new(crate::gitprocess::GitCommandCategory::Other, "fetch");

        assert!(!broker.is_use_credential_helper());
        assert_eq!(
            apply_credential_helper_policy(&spec, &broker).global_args,
            vec!["-c", "credential.helper="]
        );

        broker.set_use_credential_helper(true);
        assert!(broker.is_use_credential_helper());
        assert!(apply_credential_helper_policy(&spec, &broker)
            .global_args
            .is_empty());
    }

    #[test]
    fn host_key_confirmation_does_not_seed_silent_remote_auth() {
        let ssh_target = RemoteIdentity {
            username: "alice".into(),
            host: "git.example.com".into(),
            is_ssh: true,
            remote_url: "ssh://alice@git.example.com/repo".into(),
        };
        let https_target = RemoteIdentity {
            is_ssh: false,
            ..ssh_target.clone()
        };

        assert!(!should_remember_successful_remote(
            Some(&ssh_target),
            true,
            None
        ));
        assert!(should_remember_successful_remote(
            Some(&ssh_target),
            true,
            Some(&AuthenticationSuccess {
                host: "git.example.com".into(),
                username: "alice".into(),
                method: "publickey".into(),
            })
        ));
        assert!(should_remember_successful_remote(
            Some(&https_target),
            true,
            None
        ));
    }

    #[test]
    fn parses_username_prompt() {
        let req = parse_prompt("Username for 'https://github.com/org/repo.git':", 1);
        assert_eq!(req.host, "github.com");
        assert_eq!(req.username, "");
        assert_eq!(req.remote_url, "https://github.com/org/repo.git");
        assert_eq!(req.kind, CredentialKind::UsernamePassword);
        assert_eq!(req.attempt, 1);
    }

    #[test]
    fn parses_password_prompt_with_user() {
        let req = parse_prompt("Password for 'https://octocat@github.com/org/repo.git':", 2);
        assert_eq!(req.host, "github.com");
        assert_eq!(req.username, "octocat");
        assert_eq!(req.remote_url, "https://octocat@github.com/org/repo.git");
        assert_eq!(req.attempt, 2);
    }

    #[test]
    fn parses_ssh_passphrase_and_password() {
        let req = parse_prompt("Enter passphrase for key '/Users/x/.ssh/id_ed25519':", 1);
        assert_eq!(req.kind, CredentialKind::Passphrase);
        assert_eq!(req.host, "ssh-key");

        let req = parse_prompt("git@github.com's password:", 1);
        assert_eq!(req.kind, CredentialKind::UsernamePassword);
        assert_eq!(req.host, "github.com");
        assert_eq!(req.username, "git");
    }

    #[test]
    fn parses_multiline_host_key_confirmation() {
        let prompt = "The authenticity of host 'github.com (140.82.112.4)' can't be established.\nED25519 key fingerprint is SHA256:abc.\nAre you sure you want to continue connecting (yes/no/[fingerprint])?";
        let req = parse_prompt(prompt, 1);
        assert_eq!(req.kind, CredentialKind::HostKey);
        assert_eq!(req.host, "github.com");
        assert_eq!(req.prompt, prompt);
    }

    #[test]
    fn parses_ssh_target_and_enriches_passphrase_request() {
        let target = parse_remote_identity("git@github.com:org/repo.git").expect("ssh target");
        assert!(target.is_ssh);
        assert_eq!(target.username, "git");
        assert_eq!(target.host, "github.com");

        let req = parse_prompt_with_target(
            "Enter passphrase for key '/Users/x/.ssh/id_ed25519':",
            1,
            Some(&target),
            None,
            true,
        );
        assert_eq!(req.kind, CredentialKind::Passphrase);
        assert_eq!(req.host, "github.com");
        assert_eq!(req.username, "git");
        let success = authentication_candidate(&req, "", Some(&target)).expect("candidate");
        assert_eq!(success.username, "git");
        assert_eq!(success.host, "github.com");
        assert_eq!(success.method, "publickey");
    }

    #[test]
    fn retry_prompt_carries_redacted_previous_error() {
        let req = parse_prompt_with_target(
            "Password for 'https://alice@example.com/repo.git':",
            2,
            None,
            Some("Authentication"),
            true,
        );
        assert_eq!(req.attempt, 2);
        assert_eq!(req.previous_error.as_deref(), Some("Authentication"));

        let req = parse_prompt_with_target(
            "git@example.com's password:",
            2,
            None,
            Some("Authentication"),
            true,
        );
        assert_eq!(req.previous_error.as_deref(), Some("Authentication"));
    }

    #[test]
    fn does_not_record_https_as_ssh_authentication() {
        let target = parse_remote_identity("https://alice@example.com/repo.git").expect("http");
        assert!(!target.is_ssh);
        let req = parse_prompt("Password for 'https://alice@example.com/repo.git':", 1);
        assert!(authentication_candidate(&req, "alice", Some(&target)).is_none());
    }

    #[test]
    fn askpass_prompt_records_decode_multiline_host_key_text() {
        let dir = tempfile::tempdir().expect("tempdir");
        let path = dir.path().join("prompts");
        std::fs::write(
            &path,
            "The authenticity of host 'github.com' can't be established.\u{1f}ED25519 key fingerprint is SHA256:abc.\u{1f}Are you sure you want to continue connecting (yes/no)?\n",
        )
        .expect("write prompt record");
        let (prompts, offset) = read_new_lines(&path, 0);
        assert_eq!(prompts.len(), 1);
        assert_eq!(offset, std::fs::metadata(&path).expect("metadata").len());
        assert!(prompts[0].contains("\nED25519 key fingerprint is SHA256:abc."));
        assert_eq!(parse_prompt(&prompts[0], 1).kind, CredentialKind::HostKey);
    }

    #[test]
    fn username_vs_secret_answer_routing() {
        assert!(prompt_asks_username("Username for 'https://x/':"));
        assert!(!prompt_asks_username("Password for 'https://u@x/':"));
    }

    #[test]
    fn username_prompt_credential_is_reused_by_matching_password_prompt() {
        let pending = Mutex::new(None);
        let username_request = parse_prompt("Username for 'https://github.com/org/repo.git':", 1);
        let response = CredentialResponse {
            decision: CredentialDecision::Provide {
                username: "alice".into(),
                secret: "token".into(),
                save_to_keychain: false,
            },
        };
        remember_username_prompt_credential(
            &pending,
            &username_request,
            &username_request.prompt,
            &response,
        );

        let password_request =
            parse_prompt("Password for 'https://alice@github.com/org/repo.git':", 1);
        let cached =
            take_pending_username_credential(&pending, &password_request, &password_request.prompt)
                .expect("cached password");
        assert_eq!(cached.username, "alice");
        assert_eq!(cached.secret, "token");
        assert!(take_pending_username_credential(
            &pending,
            &password_request,
            &password_request.prompt
        )
        .is_none());
    }

    #[test]
    fn pending_username_credential_does_not_cross_auth_rounds_or_remotes() {
        let pending = Mutex::new(Some(PendingUsernameCredential {
            attempt: 1,
            host: "github.com".into(),
            remote_url: "https://github.com/org/repo.git".into(),
            username: "alice".into(),
            secret: "token".into(),
        }));
        let request = parse_prompt("Password for 'https://alice@github.com/org/other.git':", 1);
        assert!(take_pending_username_credential(&pending, &request, &request.prompt).is_none());
        let request = parse_prompt("Password for 'https://alice@github.com/org/repo.git':", 2);
        assert!(take_pending_username_credential(&pending, &request, &request.prompt).is_none());
    }

    #[test]
    fn safe_remote_url_never_exposes_password() {
        assert_eq!(
            safe_remote_url("https://alice:secret@example.com/org/repo.git"),
            "https://alice@example.com/org/repo.git"
        );
        assert_eq!(
            remote_url_key("https://alice@example.com/org/repo.git"),
            remote_url_key("https://example.com/org/repo.git")
        );
        let request = parse_prompt(
            "Password for 'https://alice:secret@example.com/org/repo.git':",
            1,
        );
        assert_eq!(request.username, "alice");
        assert_eq!(request.remote_url, "https://alice@example.com/org/repo.git");
        assert!(!request.remote_url.contains("secret"));
    }

    #[test]
    fn named_remote_identity_is_available_to_ls_remote_and_push() {
        let dir = tempfile::tempdir().expect("tempdir");
        let status = std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(dir.path())
            .status()
            .expect("git init");
        assert!(status.success());
        let status = std::process::Command::new("git")
            .args([
                "config",
                "remote.origin.url",
                "git@github.com:arbor/example.git",
            ])
            .current_dir(dir.path())
            .status()
            .expect("git config");
        assert!(status.success());

        for (subcommand, args) in [
            ("ls-remote", ["--tags", "origin"].as_slice()),
            ("push", ["--force-with-lease", "origin", "HEAD"].as_slice()),
        ] {
            let spec =
                GitCommandSpec::new(crate::gitprocess::GitCommandCategory::Other, subcommand)
                    .args(args.iter().copied())
                    .working_dir(dir.path());
            let target = remote_identity_for_spec(&spec).expect("named remote identity");
            assert_eq!(target.host, "github.com");
            assert_eq!(target.username, "git");
            assert!(target.is_ssh);
        }
    }
}
