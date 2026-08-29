# Git 进程调用点审计(ENG-001 迁移基线)

生成时间:2026-08-16。共 44 处 system-Git 调用点(不含 gitprocess.rs 本身)，均已收敛到 `src/gitprocess.rs` 的 `git_command()`，因此统一遵守应用级 Git executable 选择；本轮新增 `blame.rs::blame_worktree` 也经过同一入口。
目标:继续迁移到 `GitCommandProcess`(流式/取消/结构化错误/脱敏)，当前 executable 选择已不再被这些调用点绕过。
下方表格保留迁移前的命令分类和位置作为审计基线；当前源码中的调用均使用 `git_command()`，不能再按表中的 `Command::new("git")` 字面量搜索。
已迁移:clone_repository、push_inner、push_refspec(3 处,见分类表)。

## 本轮进度面板接线(2026-08-17)

`gitprocess::run` 现在把 Git 的 stderr 传输行(`Receiving objects`、`Resolving deltas`、`Writing objects` 等)解析为 `GitProgressState`，通过 `git_progress_state()` 暴露当前阶段和百分比。`FeedbackCenter` 在已有可取消操作期间轮询这个快照，`RebasedStatusBar` 显示阶段、百分比和现有 Cancel 入口。

这只覆盖统一 `GitProcess` transport；native rebase 的 structured/branch/root/non-interactive 路径也已迁移到 `run()` 并解析 `Rebasing (n/m)`，而直接使用 gix 状态机的 merge/object-level rebase、未迁移到 `run()` 的同步调用，以及重试策略不会被误标为已完成。完整边界与测试证据见 `docs/git-progress-transport.md`。

## 项目级 Fetch tag policy(2026-08-20)

`GitFetchTagsMode` 的项目设置已经接入所有会触发 Fetch 的业务入口：显式
Fetch、Fetch All、指定 remote branch、Pull、Update Project、Checkout and Update、
prune/unshallow、自动 Fetch，以及 Push rejected 后的 Merge/Rebase recovery。Rust
层将 `Default` / `PruneTags` / `AllTags` / `NoTags` 映射为 Git 的默认行为、
`--prune-tags`、`--tags`、`--no-tags`；旧的无 options API 保留 `Default`，以维持
调用兼容性。证据见 `arbor-engine/tests/remote_config.rs::fetch_tag_modes_control_download_and_pruning`
与 `ArborTests/CompareSelectionTests.swift::testFetchTagsModeIsProjectScopedAndDefaultIsGitDefault`。

## 分类汇总

| 分类 | 数量 | 已迁移 |
|---|---:|---:|
| clone | 0 | 1 |
| fetch | 0 | 0 |
| push | 2 | 2 |
| pull | 0 | 0 |
| merge | 3 | 0 |
| rebase | 4 | 0 |
| stash | 2 | 0 |
| checkout/reset | 2 | 0 |
| config | 3 | 0 |
| status | 3 | 0 |
| submodule | 2 | 0 |
| worktree | 6 | 0 |
| console/hooks | 0 | 0 |
| other | 13 | 0 |

## other(13 处)

| 位置 | 函数 | 命令 |
|---|---|---|
| repo.rs:130 | initialize_repository | `"init", "--", target.to_string_lossy().as_ref()` |
| repo.rs:804 | commit_with_options | `"commit", "--message", &message "--amend" "--no-verify" "--signoff" "--author", &format!("{} <{}>", name.trim(), email.t` |
| repo.rs:828 | commit_with_options | `"rev-parse", "HEAD"` |
| repo.rs:1622 | restore_file | `` |
| repo.rs:1860 | tag_create_with_options | `"tag" "--sign", "--local-user", key.trim() "--annotate" "--message", &message, &name` |
| repo.rs:2058 | run_submodule_command | `` |
| repo.rs:2229 | run_git_command | `` |
| repo.rs:3343 | pull_branch | `` |
| repo.rs:3397 | pull_branch | `"rev-parse", "HEAD"` |
| stash.rs:141 | build_worktree_tree | `` |
| status.rs:76 | compute_status_git | `` |
| status.rs:155 | ignored_paths | `` |
| status.rs:202 | ignored_rule_info | `"check-ignore", "-v", "--no-index", "--", path.as_str()` |

## checkout/reset(2 处)

| 位置 | 函数 | 命令 |
|---|---|---|
| repo.rs:1652 | checkout_detached | `"checkout", "--detach", "--quiet", commit_id.as_str()` |
| repo.rs:3150 | checkout_remote_branch | `"switch", "--track", "-c", local.as_str(), remote_branch` |

## push(2 处)

| 位置 | 函数 | 命令 |
|---|---|---|
| repo.rs:7165 | tag_push / tag_push_with_auth_and_cancel | shared `push_refspec_inner` with explicit `refs/tags/<tag>:refs/tags/<tag>`; authenticated UI path uses broker + cancellation |
| repo.rs:3461 | delete_remote_branch | `"push", remote, "--delete", branch` |

## submodule(2 处)

| 位置 | 函数 | 命令 |
|---|---|---|
| repo.rs:1950 | submodule_add | `"submodule", "add", &url, &path` |
| repo.rs:1972 | submodule_update | `"submodule", "update", "--init", "--recursive"` |

## status(3 处)

| 位置 | 函数 | 命令 |
|---|---|---|
| repo.rs:1999 | submodule_list | `"submodule", "status", "--recursive"` |
| repo.rs:4789 | system_rebase_outcome | `"rev-parse", "HEAD" "status", "--porcelain=v1", "-z"` |
| repo.rs:4792 | system_rebase_outcome | `"status", "--porcelain=v1", "-z"` |

## worktree(6 处)

| 位置 | 函数 | 命令 |
|---|---|---|
| repo.rs:2080 | worktree_list | `"worktree", "list", "--porcelain"` |
| repo.rs:2151 | worktree_add | `"worktree", "add" "-b", branch.trim()` |
| repo.rs:2198 | run_worktree_command | `"worktree"` |
| repo.rs:3378 | pull_branch | `abort_command, "--abort" "worktree", "remove", "--force"` |
| repo.rs:3382 | pull_branch | `"worktree", "remove", "--force"` |
| repo.rs:3410 | pull_branch | `"worktree", "remove", "--force"` |

## stash(2 处)

| 位置 | 函数 | 命令 |
|---|---|---|
| repo.rs:2726 | stash_branch | `"stash", "branch", &branch, &stash` |
| repo.rs:2746 | stash_diff | `"stash", "show", "--format=", "--patch", "--binary", &stash` |

## merge(3 处)

| 位置 | 函数 | 命令 |
|---|---|---|
| repo.rs:3365 | pull_branch | `"rebase", tracking_ref.as_str() "merge", "--no-edit", tracking_ref.as_str()` |
| repo.rs:3370 | pull_branch | `"merge", "--no-edit", tracking_ref.as_str() abort_command, "--abort" "worktree", "remove", "--force"` |
| repo.rs:4745 | rebase_preserving_merges_system | `"rebase", "--rebase-merges", "--interactive", "--onto" "--autosquash"` |

## rebase(4 处)

| 位置 | 函数 | 命令 |
|---|---|---|
| repo.rs:4807 | continue_system_rebase | `"status", "--porcelain=v1" "add", "-A" "rebase", "--continue"` |
| repo.rs:4817 | continue_system_rebase | `"add", "-A" "rebase", "--continue"` |
| repo.rs:4819 | continue_system_rebase | `"rebase", "--continue" "rebase", "--abort"` |
| repo.rs:4831 | abort_system_rebase | `"rebase", "--abort"` |

## config(3 处)

| 位置 | 函数 | 命令 |
|---|---|---|
| repo.rs:5772 | git_config_value | `"config", "--local", "--get", key` |
| repo.rs:5785 | set_git_config_value | `"config", "--local", key, value` |
| repo.rs:5799 | unset_git_config_value | `"config", "--local", "--unset", key` |
