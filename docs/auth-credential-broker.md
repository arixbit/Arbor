# AUTH-001 设计：Rust ↔ SwiftUI 凭证代理（credential broker）

应用设置中的 `Use Git credential helper` 与 IntelliJ 的
`GitVcsApplicationSettings.USE_CREDENTIAL_HELPER` 对齐，默认关闭。关闭时，
所有接入 broker 的 system Git transport 命令都会追加命令级
`credential.helper=`，保证 repository/user 配置不会绕过 Arbor 的 askpass
对话框；打开时保留 Git 自身的 credential helper 链。

状态：Phase 1 基础链已落地；HTTPS/SSH askpass、Keychain、取消/重试、同轮用户名/密码 prompt 复用、按远端记住 HTTP 用户名、失效 secret 清除、Ask host-key 多行 prompt、changed-host-key 专用失败分类/恢复入口与 prompt 认证成功后的 last-successful auth persistence 已接入。认证失败最多重建一次 askpass 会话，重试请求携带脱敏的 `previous_error`，并跳过可能已失效的 Keychain 值；host-key 明确拒绝不会被误重试。后台 incoming check 现在对齐 IntelliJ 的 `AuthenticationMode.NONE` → `SILENT` 两阶段策略：首次 remote 检查禁用 credential helper 和所有交互，已成功认证的 remote 只允许静默复用凭证；SILENT 失败不标记为用户取消，也不重复重试。agent/helper 成功回调和真实 sshd 端到端仍为后续项。

目标：clone/fetch/pull/push 统一走同一认证流程；首次登录、错误重试、取消、
保存/不保存凭证的交互全部由 SwiftUI 呈现，Rust 引擎只定义协议与状态，不
感知 UI 实现。本设计遵循「引擎语言中立」原则：引擎产出结构化状态码 +
最小 message，所有文案在 Swift 层本地化。

## 1. 角色

- **Git 子进程**：clone/push 等系统 git 进程。需要凭证时按约定回调
  `GIT_ASKPASS`（HTTPS）或读取 `SSH_ASKPASS`（SSH passphrase）。
- **Engine CredentialBroker**（Rust）：持有 `GIT_ASKPASS` 的桥接脚本；
  通过 uniffi 回调接口向 Swift 请求凭证，并把结果喂回 git 进程。
- **SwiftUI Authenticator**：呈现登录对话框（用户名/token、SSH passphrase、
  host key 警告），读写 macOS Keychain，把决定（凭证/取消/禁用保存）回调引擎。

## 2. uniffi 接口草案

```swift
// 引擎 → Swift 的请求（uniffi callback interface）
public protocol CredentialRequestHandler {
    func onCredentialRequest(_ request: CredentialRequest) -> CredentialResponse
    func onAuthenticationSucceeded(_ success: AuthenticationSuccess)
    func onAuthenticationFailed(_ request: CredentialRequest)
}

public struct AuthenticationSuccess {
    public let host: String
    public let username: String
    public let method: String       // publickey / password；不含 secret
}

// 一次凭证请求的结构化描述
public struct CredentialRequest {
    public let host: String            // 如 github.com
    public let username: String        // 可为空（git 未提供）
    public let remoteURL: String       // 无密码远端 URL；用于记住用户名
    public let kind: CredentialKind    // usernamePassword / passphrase / hostKey
    public let attempt: UInt32         // 第几次尝试（>1 表示上次失败）
    public let previousError: String?  // 上次失败的分类（脱敏后）
    public let prompt: String          // host-key 请求保留原始多行指纹 prompt
    public let allowInteraction: Bool  // 后台 NONE/SILENT 检查禁止显示 UI
}

public enum CredentialKind { case usernamePassword, passphrase, hostKey }

// Swift → 引擎的答复
public struct CredentialResponse {
    public let decision: CredentialDecision
}

public enum CredentialDecision {
    case provide(username: String, secret: String, saveToKeychain: Bool)
    case cancel                          // 对应操作状态 cancelled
}

// hostKey 请求复用 CredentialResponse：secret = "yes" 或 "no"
```

## 3. 引擎侧状态机

```
GitCommandProcess(需凭证)
  └─ spawn GIT_ASKPASS=arbor-askpass.sh
       └─ git 回调 askpass → engine 收到 (host, prompt)
            ├─ 显式操作 → Keychain 命中直接返回；否则显示 SwiftUI 对话框
            │     ├─ 用户提供 + 保存 → Keychain 写入 → 返回凭证
            │     ├─ 用户提供 + 不保存 → 返回凭证（仅本次）
            │     ├─ 取消 → 返回空 + 失败分类 Cancelled
            │     └─ 错误凭证 → 新建 askpass 会话并回调 attempt>1 → 重新弹框
            │           （防无限重试：attempt ≥ 3 且无新信息时建议失败）
            └─ 后台 incoming check
                  ├─ remote 未成功认证 → NONE：清空 credential.helper，禁止交互
                  └─ remote 已成功认证 → SILENT：只查已有凭证，禁止交互；失败立即返回
       进程成功结束 → 仅当本次 prompt 认证可确认时回调 user@host + method
```

失败分类复用 `gitprocess::GitFailureKind`：
`Authentication` / `Cancelled` / `Network` / …（已有实现）。

后台 incoming check 的认证模式与显式 Git 操作隔离。首次检查使用 NONE，
通过 `credential.helper=` 与 `GIT_TERMINAL_PROMPT=0` 保证不会读取 helper 或弹出
终端提示；某个 remote 曾由 broker 成功完成认证后，后续检查使用 SILENT，Swift
回调可读取 Keychain，但 `allowInteraction=false` 时即使没有凭证也只能返回
取消答复，不能展示对话框。Rust 只在 `allowInteraction=true` 时把取消分类为
用户取消，且 SILENT 不进入交互认证的重试轮次。显式 Fetch/Pull/Push/Clone 仍
使用 Interactive 模式。

## 4. 与现有代码的接合点

- `GitCommandSpec` 已支持 `env()` 注入；新增 helper
  `spec.with_askpass(broker)` 自动设置 `GIT_ASKPASS` /
  `GIT_TERMINAL_PROMPT=0`（禁止终端交互，杜绝绕过 UI 的提示）。
- 引擎新增 uniffi Object `CredentialBroker`：
  - `setHandler(handler: CredentialRequestHandler)`（Swift 注入实现）
  - `prefillFromKeychain(host:username:)`（Swift 可预填）
- macOS Keychain 读写由 Swift 现有 `KeychainStore.swift` 承担（已有 GitHub
  PAT 保存/清除/测试逻辑，扩展为通用 credential）。
- hosting provider API token（GitHub PAT）与 git remote credential 分离建模：
  `HostingCredential` 与 `GitRemoteCredential` 两个 Swift 类型，互不混用。

## 5. 验收场景（引擎测试）

- mock askpass：fixture 仓库 + 本地 HTTP git server 或 `git -c credential.helper=`
  空配置，验证 GIT_ASKPASS 桥接收到正确 host/prompt 序列（tests 用
  `GIT_ASKPASS` 指向测试脚本，不依赖真实网络）。
- 取消路径：handler 返回 cancel → 操作结果为 cancelled 而非 generic error。
- 重试路径：返回错误凭证 → attempt 递增 → 第二次正确凭证成功。
- 日志/错误/测试快照中不得出现 secret（gitprocess 脱敏已有测试覆盖）。

补充边界：SSH passphrase 只存在本次认证响应的内存中，不会写入
`git:<host>:<username>` Keychain；HTTP/HTTPS 的保存开关仍只作用于 username/token。

## 6. 范围决策

- 首版不做 SSH agent 集成与 key 生成 UI；SSH key selection 只做
  passphrase 回调与 host key 警告（对齐 git4idea 的
  `SSHConnectionSettings` 最小面）。
- last-successful 只记录 broker 观察到的 SSH prompt 认证：私钥 passphrase
  记录为 `publickey`，SSH password 记录为 `password`；HTTPS、host-key
  confirmation、SSH agent 与外部 credential helper 不会被误记。
- Swift 使用 UserDefaults 保存 `user@host -> method` 与按无密码远端 URL 保存的
  HTTP username，SSH Settings 提供可见列表与清除动作；不保存凭证或 agent
  secret。HTTP secret 仍只进入独立 Keychain 条目，认证失败时由无秘密 callback
  清除。
- `credential.helper` 检测与配置（`osxkeychain` 存在性、repository-local 多值
  写入/清除）由 Git SSH Settings 面板管理；用户级配置继续只读诊断。
- 设计稿先不实现：等 ENG-001 的进度/取消事件通道接入 Swift 后，再接线
  认证对话框（Phase 1 闸门内）。
