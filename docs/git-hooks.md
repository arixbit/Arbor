# Git hooks 管理

入口：`VCS > Git > Git Hooks…`。左侧是 hook 列表与状态，右侧是脚本编辑器。
Arbor 只管理磁盘状态，**不会从界面执行 hook**——hook 由 Git 在 commit /
push 等时机自动触发。

## 状态语义（与 Git 一致）

| 状态 | 含义 | 界面动作 |
|---|---|---|
| `Enabled` | 文件存在且**有可执行位**，Git 会运行 | Disable、Delete、编辑 |
| `Disabled` | 文件存在但没有可执行位，Git 忽略 | Enable、Delete、编辑 |
| `Sample` | 只有 `name.sample` 模板 | Install sample |
| `Missing` | 既没有 hook 也没有 sample | 直接编辑保存（新建并加可执行位） |

「启用/禁用」只切换可执行位，不移动、不重命名文件；删除只删 `name`，
`name.sample` 模板保留。

## 引擎 API（`arbor-engine/src/hookadmin.rs`）

| 方法 | 说明 |
|---|---|
| `git_hooks_location()` | hooks 目录 + `core.hooksPath` 原文（绝对路径、`~/...`、相对工作区根都支持） |
| `git_hooks()` | 内置 hook 名单（29 个）+ 目录里额外的可执行脚本 |
| `git_hook_contents(name:)` | 读内容，>512 KB 截断并禁止保存，含 NUL 视为二进制 |
| `save_git_hook(name:content:)` | 原子写入（临时文件 + rename）并补可执行位 |
| `set_git_hook_enabled(name:enabled:)` | 切换可执行位 |
| `install_git_hook_sample(name:)` | 复制 `name.sample` → `name`（0755） |
| `delete_git_hook(name:)` | 删除 hook 文件 |

写入前校验 hook 名：不允许空、路径分隔符、控制字符、`name.sample`，因此
`git_hook_contents("../etc/passwd")` 会失败。

## 执行侧的同步修正

`hooks.rs` 之前只认 `.git/hooks`，并且不检查可执行位：

- 现在 `pre-commit` / `commit-msg` 都按 `core.hooksPath` 解析目录；
- 没有可执行位的 hook 文件与 Git 一样被忽略（之前会直接报权限错误，导致
  提交失败）。

## 已知边界

- 只执行 `pre-commit` 与 `commit-msg` 两个 hook（其余 hook 由 `git` 自己在
  push/merge/rebase 等子进程里触发，Arbor 不拦截）。
- 编辑器是纯文本；二进制 hook 不提供编辑。不做 hook 语法高亮。
- 不支持全局（`--global`）hooks 目录的批量管理，只管理当前仓库生效的目录。
