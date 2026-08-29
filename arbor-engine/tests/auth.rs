//! AUTH-001：askpass 桥的端到端 mock 测试。
//!
//! 用进程内 HTTP 服务器模拟需要认证的 git 远程（智能 HTTP 协议的
//! info/refs 端点）：先 401 要求 Basic 认证，凭证正确后返回空 refs 广告。
//! `git ls-remote` 通过 broker 的 askpass 桥走完「提示 → 提供凭证 → 重试」
//! 全流程，不依赖真实网络。

mod common;

use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

use arbor_engine::{
    CredentialBroker, CredentialDecision, CredentialKind, CredentialRequest,
    CredentialRequestHandler, CredentialResponse, GitFailureKind,
};

/// mock 服务器：要求 Basic user:pass，正确后回空 refs 广告。
fn spawn_auth_server(require_username: &str, require_password: &str) -> (String, Arc<AtomicUsize>) {
    spawn_auth_server_with_policy(require_username, require_password, false)
}

/// 认证凭证已经被 prompt 提供后，返回一次 403 而不是再次返回 401。
/// 这验证的是 broker 自己重建 askpass 会话的恢复路径，而不是 Git 在
/// 同一个进程内重复询问凭证的默认行为。
fn spawn_auth_server_forbidden_once(
    require_username: &str,
    require_password: &str,
) -> (String, Arc<AtomicUsize>) {
    spawn_auth_server_with_policy(require_username, require_password, true)
}

fn spawn_auth_server_with_policy(
    require_username: &str,
    require_password: &str,
    forbidden_after_prompt: bool,
) -> (String, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let requests = Arc::new(AtomicUsize::new(0));
    let counter = requests.clone();
    let expected_user = require_username.to_string();
    let expected_pass = require_password.to_string();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let counter = counter.clone();
            let expected_user = expected_user.clone();
            let expected_pass = expected_pass.clone();
            let forbidden_after_prompt = forbidden_after_prompt;
            std::thread::spawn(move || {
                handle_connection(
                    &mut stream,
                    &expected_user,
                    &expected_pass,
                    &counter,
                    forbidden_after_prompt,
                );
            });
        }
    });
    (format!("http://{addr}/repo.git"), requests)
}

fn handle_connection(
    stream: &mut TcpStream,
    expected_user: &str,
    expected_pass: &str,
    counter: &AtomicUsize,
    forbidden_after_prompt: bool,
) {
    let mut reader = BufReader::new(stream.try_clone().expect("clone"));
    let mut request_line = String::new();
    let _ = reader.read_line(&mut request_line);
    let mut headers = String::new();
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" || line == "\n" {
            break;
        }
        headers.push_str(&line);
    }
    // 只对 header 名做大小写不敏感匹配,值保持原样(base64 大小写敏感!)
    let authorization = headers
        .lines()
        .find_map(|l| {
            let (name, value) = l.split_once(':')?;
            if name.trim().eq_ignore_ascii_case("authorization") {
                Some(value.trim().to_string())
            } else {
                None
            }
        })
        .unwrap_or_default();

    let request_number = counter.fetch_add(1, Ordering::SeqCst) + 1;
    if std::env::var_os("ARBOR_AUTH_DEBUG").is_some() {
        eprintln!(
            "DBG-SRV req={} line={:?} auth={:?}",
            request_number,
            request_line.trim(),
            authorization
        );
    }
    let expected = format!(
        "Basic {}",
        base64_encode(&format!("{expected_user}:{expected_pass}"))
    );
    let mut response = String::new();
    if authorization == expected {
        // 一个 ref 的 v0 广告: service 行 + flush + "<oid> refs/heads/main" + flush
        let oid = "0123456789abcdef0123456789abcdef01234567";
        let line = format!("{oid} refs/heads/main\n");
        let body = format!(
            "001e# service=git-upload-pack\n0000{:04x}{line}0000",
            line.len() + 4
        );
        response.push_str("HTTP/1.1 200 OK\r\n");
        response.push_str("Content-Type: application/x-git-upload-pack-advertisement\r\n");
        response.push_str(&format!("Content-Length: {}\r\n", body.len()));
        response.push_str("Connection: close\r\n\r\n");
        response.push_str(&body);
    } else {
        let status = if forbidden_after_prompt && !authorization.is_empty() {
            "403 Forbidden"
        } else {
            "401 Unauthorized"
        };
        response.push_str(&format!("HTTP/1.1 {status}\r\n"));
        if status.starts_with("401") {
            response.push_str("WWW-Authenticate: Basic realm=\"mock\"\r\n");
        }
        response.push_str("Content-Length: 0\r\n");
        response.push_str("Connection: close\r\n\r\n");
    }
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

fn base64_encode(input: &str) -> String {
    const TABLE: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes = input.as_bytes();
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b = [
            chunk[0],
            *chunk.get(1).unwrap_or(&0),
            *chunk.get(2).unwrap_or(&0),
        ];
        let n = (b[0] as u32) << 16 | (b[1] as u32) << 8 | b[2] as u32;
        out.push(TABLE[(n >> 18) as usize & 0x3F] as char);
        out.push(TABLE[(n >> 12) as usize & 0x3F] as char);
        out.push(if chunk.len() > 1 {
            TABLE[(n >> 6) as usize & 0x3F] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[n as usize & 0x3F] as char
        } else {
            '='
        });
    }
    out
}

/// 记录调用的 mock handler；按脚本返回凭证序列。
#[derive(Clone)]
struct MockHandler {
    calls: Arc<Mutex<Vec<CredentialRequest>>>,
    failures: Arc<Mutex<Vec<CredentialRequest>>>,
    // (username, password) 序列:第 n 次调用返回第 n 项
    script: Arc<Mutex<Vec<(String, String)>>>,
    cancel_on: Option<u32>,
}

impl CredentialRequestHandler for MockHandler {
    fn on_credential_request(&self, request: CredentialRequest) -> CredentialResponse {
        self.calls.lock().expect("calls").push(request.clone());
        if let Some(round) = self.cancel_on {
            let count = self.calls.lock().expect("calls").len() as u32;
            if count == round {
                return CredentialResponse {
                    decision: CredentialDecision::Cancel,
                };
            }
        }
        let index = self.calls.lock().expect("calls").len() - 1;
        let (username, password) = self
            .script
            .lock()
            .expect("script")
            .get(index)
            .cloned()
            .unwrap_or_default();
        CredentialResponse {
            decision: CredentialDecision::Provide {
                username,
                secret: password,
                save_to_keychain: false,
            },
        }
    }

    fn on_authentication_succeeded(&self, _success: arbor_engine::AuthenticationSuccess) {}

    fn on_authentication_failed(&self, request: CredentialRequest) {
        self.failures.lock().expect("failures").push(request);
    }
}

#[derive(Clone)]
struct PasswordSequenceHandler {
    calls: Arc<Mutex<Vec<CredentialRequest>>>,
    password_calls: Arc<AtomicUsize>,
}

impl CredentialRequestHandler for PasswordSequenceHandler {
    fn on_credential_request(&self, request: CredentialRequest) -> CredentialResponse {
        self.calls.lock().expect("calls").push(request.clone());
        let prompt = request.prompt.to_ascii_lowercase();
        let (username, secret) = if prompt.contains("username for") {
            ("alice".to_string(), String::new())
        } else {
            let password_number = self.password_calls.fetch_add(1, Ordering::SeqCst);
            let secret = if password_number == 0 {
                "wrong".to_string()
            } else {
                "s3cret-token".to_string()
            };
            ("alice".to_string(), secret)
        };
        CredentialResponse {
            decision: CredentialDecision::Provide {
                username,
                secret,
                save_to_keychain: false,
            },
        }
    }

    fn on_authentication_succeeded(&self, _success: arbor_engine::AuthenticationSuccess) {}

    fn on_authentication_failed(&self, _request: CredentialRequest) {}
}

fn ls_remote_with_broker(broker: &CredentialBroker, url: &str) -> arbor_engine::GitProcessOutcome {
    broker
        .run_git_with_askpass(
            vec![
                "-c".into(),
                "credential.helper=".into(),
                "ls-remote".into(),
                url.into(),
            ],
            None,
        )
        .expect("ls-remote spawn")
}

/// 首次错误凭证被 401 拒绝 -> git 重试 -> 第二次正确凭证成功。
/// handler 收到两次请求,host/kind 正确,密码不进入输出。
#[test]
fn wrong_credentials_retry_then_success() {
    let (url, requests) = spawn_auth_server("alice", "s3cret-token");
    let handler = Arc::new(MockHandler {
        calls: Arc::new(Mutex::new(Vec::new())),
        failures: Arc::new(Mutex::new(Vec::new())),
        script: Arc::new(Mutex::new(vec![
            ("alice".to_string(), "wrong".to_string()),
            ("alice".to_string(), "s3cret-token".to_string()),
        ])),
        cancel_on: None,
    });
    let broker = CredentialBroker::new();
    broker.set_handler(Box::new(handler.as_ref().clone()));

    let outcome = ls_remote_with_broker(&broker, &url);
    assert!(
        outcome.success(),
        "ls-remote failed: {} | {}",
        outcome.stderr,
        outcome.stdout
    );
    assert!(outcome.failure.is_none());
    assert!(
        requests.load(Ordering::SeqCst) >= 2,
        "server should have seen retries"
    );
    assert!(
        broker.has_successful_authentication(url.clone()),
        "successful interactive authentication should seed silent mode"
    );

    let calls = handler.calls.lock().expect("calls");
    assert_eq!(calls.len(), 2, "handler should be called twice");
    assert_eq!(calls[0].attempt, 1);
    assert!(calls[1].attempt > calls[0].attempt);
    assert_eq!(calls[0].kind, CredentialKind::UsernamePassword);
    assert!(
        calls[0].host.contains("127.0.0.1:"),
        "host: {}",
        calls[0].host
    );
    let failures = handler.failures.lock().expect("failures");
    assert_eq!(
        failures.len(),
        1,
        "failed authentication should be reported once"
    );
    assert_eq!(failures[0].kind, CredentialKind::UsernamePassword);

    // 凭证不得出现在任何输出里
    assert!(!outcome.stdout.contains("s3cret-token"));
    assert!(!outcome.stderr.contains("s3cret-token"));
    assert!(!outcome.stdout.contains("wrong"));
    assert!(!outcome.stderr.contains("wrong"));
}

/// A server-side 403 after the first prompt must cause the broker to create a
/// fresh askpass session and expose the redacted previous failure to the UI.
#[test]
fn forbidden_after_prompt_restarts_askpass_session() {
    let (url, requests) = spawn_auth_server_forbidden_once("alice", "s3cret-token");
    let handler = Arc::new(PasswordSequenceHandler {
        calls: Arc::new(Mutex::new(Vec::new())),
        password_calls: Arc::new(AtomicUsize::new(0)),
    });
    let broker = CredentialBroker::new();
    broker.set_handler(Box::new(handler.as_ref().clone()));

    let outcome = ls_remote_with_broker(&broker, &url);
    assert!(
        outcome.success(),
        "fresh askpass retry failed: {} | {}",
        outcome.stderr,
        outcome.stdout
    );
    assert!(requests.load(Ordering::SeqCst) >= 4);

    let calls = handler.calls.lock().expect("calls");
    let password_requests: Vec<_> = calls
        .iter()
        .filter(|request| !request.prompt.to_ascii_lowercase().contains("username for"))
        .collect();
    assert!(
        password_requests.len() >= 2,
        "password prompt sequence: {calls:?}"
    );
    assert_eq!(password_requests[0].attempt, 1);
    assert!(password_requests[1].attempt > 1);
    assert_eq!(
        password_requests[1].previous_error.as_deref(),
        Some("Authentication")
    );
}

/// 用户取消认证 -> 结果分类为 Cancelled(而不是 generic error)。
#[test]
fn cancel_auth_classifies_cancelled() {
    let (url, _requests) = spawn_auth_server("alice", "s3cret-token");
    let handler = Arc::new(MockHandler {
        calls: Arc::new(Mutex::new(Vec::new())),
        failures: Arc::new(Mutex::new(Vec::new())),
        script: Arc::new(Mutex::new(vec![("alice".to_string(), "x".to_string())])),
        cancel_on: Some(1),
    });
    let broker = CredentialBroker::new();
    broker.set_handler(Box::new(handler.as_ref().clone()));

    let outcome = ls_remote_with_broker(&broker, &url);
    assert!(!outcome.success());
    assert_eq!(outcome.failure, Some(GitFailureKind::Cancelled));
    assert!(outcome.cancelled);
}

/// 无 handler 时(未注入)取消,不 panic,分类 Cancelled。
#[test]
fn missing_handler_cancels_gracefully() {
    let (url, _requests) = spawn_auth_server("alice", "s3cret-token");
    let broker = CredentialBroker::new(); // 不 set_handler
    let outcome = ls_remote_with_broker(&broker, &url);
    assert!(!outcome.success());
    assert_eq!(outcome.failure, Some(GitFailureKind::Cancelled));
}

/// SILENT mode may ask the callback for a stored credential, but a callback
/// refusal is not a user cancellation and must never be retried as an
/// interactive operation.
#[test]
fn silent_auth_never_classifies_missing_credential_as_user_cancel() {
    let (url, _requests) = spawn_auth_server("alice", "s3cret-token");
    let handler = Arc::new(MockHandler {
        calls: Arc::new(Mutex::new(Vec::new())),
        failures: Arc::new(Mutex::new(Vec::new())),
        script: Arc::new(Mutex::new(Vec::new())),
        cancel_on: Some(1),
    });
    let broker = CredentialBroker::new();
    broker.set_handler(Box::new(handler.as_ref().clone()));

    let outcome = broker
        .run_git_with_silent_auth(
            vec![
                "-c".into(),
                "credential.helper=".into(),
                "ls-remote".into(),
                url.into(),
            ],
            None,
        )
        .expect("silent ls-remote spawn");
    assert!(!outcome.success());
    assert_ne!(outcome.failure, Some(GitFailureKind::Cancelled));
    assert!(!outcome.cancelled);
    let calls = handler.calls.lock().expect("calls");
    assert_eq!(calls.len(), 1);
    assert!(!calls[0].allow_interaction);
}

/// 无认证需求时 askpass 桥不打扰:file:// 远程不经过任何凭证提示。
#[test]
fn no_auth_remote_passes_through() {
    let dir = tempfile::tempdir().expect("tempdir");
    let work = dir.path().join("work");
    std::fs::create_dir_all(&work).unwrap();
    common::git(&work, &["init", "-q"]);
    common::git(&work, &["config", "user.name", "Arbor Test"]);
    common::git(&work, &["config", "user.email", "test@arbor.local"]);
    common::git(&work, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    common::commit(&work, "f.txt", "x", "init");
    common::git(dir.path(), &["init", "-q", "--bare", "origin.git"]);
    let source = dir.path().join("origin.git");
    std::process::Command::new("git")
        .args(["push", "-q", &source.display().to_string(), "main"])
        .current_dir(&work)
        .output()
        .expect("push to bare");
    let url = format!("file://{}", source.display());

    let handler = Arc::new(MockHandler {
        calls: Arc::new(Mutex::new(Vec::new())),
        failures: Arc::new(Mutex::new(Vec::new())),
        script: Arc::new(Mutex::new(Vec::new())),
        cancel_on: None,
    });
    let broker = CredentialBroker::new();
    broker.set_handler(Box::new(handler.as_ref().clone()));

    let outcome = broker
        .run_git_with_askpass(
            vec![
                "-c".into(),
                "credential.helper=".into(),
                "ls-remote".into(),
                url.clone(),
            ],
            Some(dir.path().display().to_string()),
        )
        .expect("ls-remote");
    assert!(outcome.success(), "stderr: {}", outcome.stderr);
    assert!(
        handler.calls.lock().expect("calls").is_empty(),
        "no prompts expected"
    );
}
