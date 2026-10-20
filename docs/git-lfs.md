# Git LFS 集成

Arbor 不实现 LFS 协议，而是驱动用户安装的 `git-lfs`（与 IntelliJ 一致），
把它的行为收敛成结构化结果。入口：`VCS > Git > Git LFS…`。

## 引擎 API（`arbor-engine/src/lfs.rs`）

| 方法 | 底层命令 | 说明 |
|---|---|---|
| `lfs_capability()` | `git lfs version` | 未安装时返回 `installed=false` + `detail`，不抛异常 |
| `lfs_tracked_patterns()` | `git lfs track` | 解析 listing，返回 pattern + 定义它的属性文件 |
| `lfs_files(all_revisions:)` | `git lfs ls-files --long [--all]` | oid + 工作区是否已有真实内容 |
| `lfs_path_states(paths:)` | `git check-attr -z filter` + 文件头检测 | `tracked` / `pointer` 两态，用于列表标记 |
| `lfs_track(patterns:)` / `lfs_untrack(patterns:)` | `git lfs track/untrack` | 改写 `.gitattributes` |
| `lfs_install()` / `lfs_uninstall()` | `git lfs install/uninstall --local` | 安装 filter 与四个 hook |
| `lfs_hook_state()` | 读取 `.git/hooks/*` | post-checkout / post-commit / post-merge / pre-push |
| `lfs_fetch(remote:all_revisions:paths:)` | `git lfs fetch [--all] [--include=path]` | 只下载不检出 |
| `lfs_pull(remote:paths:)` | `git lfs pull [--include=path]` | 下载并检出；`paths` 为空表示整仓库 |
| `lfs_push(remote:all_revisions:)` | `git lfs push [--all] <remote>` | 上传对象 |
| `lfs_prune()` | `git lfs prune --force` | 清理未被引用的本地对象 |
| `lfs_checkout(paths:)` | `git lfs checkout -- <paths>` | 从本地对象还原，不下载 |

所有传输命令接 `GitCancelHandle`（杀整个进程组），并复用 `GitCommandSpec`
的可执行文件设置、脱敏日志与失败分类。

## 两个容易踩的坑

1. **`git lfs pull` 在没有 filter 配置的仓库里会静默跳过**：退出码 0，只打印
   `Skipping object checkout, Git LFS is not installed for this repository`。
   克隆出来的仓库默认没有 `filter.lfs.*`，所以 `lfs_pull` / `lfs_checkout`
   会先补一次 `git lfs install --local`（结果里 `installedFilters` 会置位），
   万一仍然跳过则折叠成错误，不会报告「已下载」。
2. **push 只上传代码引用**：`git push` 靠 pre-push hook 触发 LFS 上传。仓库没装
   hook 或本次显式跳过 hooks 时，代码推上去了、对象没上传。单 root Push 与
   多 root Push All 都会在完成后用 `lfsPushCoverageWarning` 给出可操作告警。

## 界面

- **Git LFS 面板**：能力/版本、hook 安装状态、跟踪规则（可增删）、文件列表
  （path / oid / downloaded 或 pointer）、远端名 + Fetch / Pull / Push / Prune /
  Checkout。勾选文件后 Fetch / Pull / Checkout 只作用于选中路径。
- **Changes 列表标记**：LFS 文件带 `LFS` 徽标；工作区仍是 pointer 时显示橙色
  `LFS ↓`。标记由 `refreshLfsPathMarkers()` 在每次 `loadRepoData` 后刷新，
  每次只跑一条 `git check-attr`。
- **文件内容视图**：`.local` 版本是 pointer 时显示横幅与 `Download` 按钮，
  下载完成后自动重载内容。

## 已知边界

- LFS 认证走 `git-lfs` 自己的 credential/netrc 链路，没有接入 Arbor 的
  credential broker；HTTPS 需要凭据时会在终端提示层失败，错误会原样上报。
- 只扫描仓库根 `.gitattributes` 之外的规则由 `git lfs track` 的 listing 提供，
  不做自己的属性文件遍历。
- 大文件 diff 仍按文本处理；LFS 文件下载后按普通文件查看。
