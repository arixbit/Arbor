//! 提交日志 / 逐文件历史 / refs 辅助（语言中立，无用户文案）。

use std::collections::{HashMap, HashSet};

use gix::bstr::{BStr, ByteSlice};
use regex::Regex;

use crate::error::EngineError;

/// IntelliJ VCS Log 的图形排序模式。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum LogGraphSortMode {
    /// IntelliJ PermanentGraph.Options.Base(Normal): topological order with
    /// the repository's normal date-oriented traversal (the "Off" option).
    ByCommitDate,
    /// IntelliJ PermanentGraph.Options.Base(Bek): merge branch fragments by
    /// the Bek incoming-first strategy rather than merely using Git's
    /// generic topo-order queue.
    Topologically,
    /// IntelliJ PermanentGraph.Options.LinearBek: use Bek ordering and make
    /// the incoming history the primary visual lane around merges.
    LinearizeMerges,
    /// 遇到合并提交时只沿第一父提交继续。
    FirstParent,
}

/// 一条提交日志记录。
#[derive(uniffi::Record, Clone, Debug)]
pub struct CommitInfo {
    pub id: String,
    /// 所属 Git root 的工作区路径。VCS Log 的 commit identity 是
    /// `(object id, root)`，不能只用 object id 区分多个仓库。
    pub repository_path: Option<String>,
    pub short_id: String,
    /// 提交信息第一段（标题）
    pub summary: String,
    pub author_name: String,
    pub author_email: String,
    /// 提交者（可与作者不同）。
    pub committer_name: String,
    pub committer_email: String,
    /// 提交信息正文（标题之后的部分，去首尾空白）。
    pub message_body: String,
    /// 提交对象是否带 PGP/SSH 签名块。
    pub has_signature: bool,
    /// unix 秒
    pub time: i64,
    pub parent_ids: Vec<String>,
    /// 指向该提交的本地分支短名
    pub refs: Vec<String>,
    /// 指向该提交的 tag 短名
    pub tag_refs: Vec<String>,
    /// 指向该提交的 remote-tracking 分支短名（例如 origin/main）
    pub remote_refs: Vec<String>,
    pub is_head: bool,
    /// log 图泳道（0-based；线性历史全为 0，merge/分支后新 lane）。逐文件历史时为 0。
    pub lane: u32,
    /// 图形视图中可见的父提交在下一行的泳道；通常与 `parent_ids` 一致，
    /// FirstParent 选项下只包含第一父边。
    pub parent_lanes: Vec<u32>,
}

#[derive(Clone, Debug, Default)]
pub(crate) struct RefNames {
    local: Vec<String>,
    tags: Vec<String>,
    remote: Vec<String>,
}

/// 签名验证状态（`git verify-commit` 输出）。
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum SignatureStatus {
    /// 提交对象无签名块。
    None,
    /// Good signature。
    Valid,
    /// BAD signature（密钥不匹配/篡改）。
    Invalid,
    /// 验证器无法判定（无 gpg 等）。
    Unknown,
}

/// The asynchronously loaded signature presentation used by the VCS Log
/// signature column.  `reason` preserves Git's more specific `%G?` result
/// (expired, revoked, unavailable, ...), while the coarse status remains
/// stable for SwiftUI rendering and older callers.
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct CommitSignatureInfo {
    pub commit_id: String,
    pub status: SignatureStatus,
    pub signer: String,
    pub fingerprint: String,
    pub reason: String,
}

/// Parse one Git `%H%x00%G?%x00%GS%x00%GF` record.  Keeping this parser
/// independent of process execution makes status-code coverage deterministic
/// and prevents the UI from having to interpret raw Git output.
pub(crate) fn parse_commit_signature_record(record: &str) -> Option<CommitSignatureInfo> {
    let mut fields = record.split('\0');
    let commit_id = fields.next()?.trim().to_ascii_lowercase();
    let status_code = fields.next()?.trim();
    let signer = fields.next().unwrap_or_default().trim().to_string();
    let fingerprint = fields.next().unwrap_or_default().trim().to_string();
    if commit_id.is_empty() {
        return None;
    }

    let (status, reason) = match status_code {
        "G" => (SignatureStatus::Valid, String::new()),
        "B" => (SignatureStatus::Invalid, String::new()),
        "U" => (SignatureStatus::Unknown, "unknown validity".to_string()),
        "X" => (SignatureStatus::Unknown, "expired signature".to_string()),
        "Y" => (SignatureStatus::Unknown, "expired signing key".to_string()),
        "R" => (SignatureStatus::Unknown, "revoked signing key".to_string()),
        "E" => (
            SignatureStatus::Unknown,
            "unable to verify signature".to_string(),
        ),
        "N" => (SignatureStatus::None, String::new()),
        other => (
            SignatureStatus::Unknown,
            format!("unknown Git signature status '{other}'"),
        ),
    };

    Some(CommitSignatureInfo {
        commit_id,
        status,
        signer,
        fingerprint,
        reason,
    })
}

/// 单个提交的文件级 diff（HISTORY-001）：父选择 + root 空 tree 比较。
#[derive(uniffi::Record, Clone, Debug)]
pub struct CommitDiff {
    pub commit_id: String,
    /// 比较的父提交（root commit 为 None，与空 tree 比较）。
    pub parent_id: Option<String>,
    /// root commit（无父）。
    pub is_root: bool,
    /// 父提交总数（merge commit 为 2+）。
    pub parent_count: u32,
    pub changes: Vec<crate::tree::TreeChange>,
}

/// HEAD reflog 的一条操作记录。
#[derive(uniffi::Record, Clone, Debug)]
pub struct ReflogEntry {
    pub old_id: String,
    pub new_id: String,
    pub message: String,
    pub time: i64,
    pub ref_name: String,
}

/// 迭代器 item 错误是 `Box<dyn Error + Send + Sync>`，不满足 `from_gix` 的 Sized 边界，
/// 直接取 Display（Error 的超 trait）收口。
pub(crate) fn boxed_err(e: Box<dyn std::error::Error + Send + Sync>) -> EngineError {
    EngineError::GitOperation {
        message: e.to_string(),
    }
}

/// 收集本地分支、远程跟踪分支和 tag 指向的提交 id -> 短名列表。
/// 用 `.peeled()` 预解引用（含 annotated tag -> commit），yield 出的 ref 取 `try_id()`。
pub(crate) fn collect_refs(
    repo: &gix::Repository,
) -> Result<HashMap<gix::hash::ObjectId, RefNames>, EngineError> {
    let mut map: HashMap<gix::hash::ObjectId, RefNames> = HashMap::new();
    let platform = repo.references().map_err(EngineError::from_gix)?;
    for r in platform
        .local_branches()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let r = r.map_err(boxed_err)?;
        if let Some(id) = r.try_id() {
            map.entry(id.detach())
                .or_default()
                .local
                .push(shorten_ref_name(r.name().as_bstr()));
        }
    }
    let platform = repo.references().map_err(EngineError::from_gix)?;
    for r in platform
        .tags()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let r = r.map_err(boxed_err)?;
        if let Some(id) = r.try_id() {
            map.entry(id.detach())
                .or_default()
                .tags
                .push(shorten_ref_name(r.name().as_bstr()));
        }
    }
    let platform = repo.references().map_err(EngineError::from_gix)?;
    for r in platform
        .remote_branches()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let r = r.map_err(boxed_err)?;
        if let Some(id) = r.try_id() {
            map.entry(id.detach())
                .or_default()
                .remote
                .push(shorten_ref_name(r.name().as_bstr()));
        }
    }
    Ok(map)
}

/// `refs/heads/main` / `refs/tags/v1` -> `main` / `v1`（无前缀则原样）。
pub(crate) fn shorten_ref_name(full: &BStr) -> String {
    full.strip_prefix(b"refs/heads/")
        .or_else(|| full.strip_prefix(b"refs/tags/"))
        .or_else(|| full.strip_prefix(b"refs/remotes/"))
        .unwrap_or(full)
        .to_str_lossy()
        .into_owned()
}

/// 提交是否触碰指定路径：比较提交树与第一父树的路径条目 id。
/// 根提交（无父）视为触碰。不读 blob 内容，开销小。
pub(crate) fn commit_touches_path(
    repo: &gix::Repository,
    commit: &gix::Commit<'_>,
    path: &str,
) -> Result<bool, EngineError> {
    let mut parents = commit.parent_ids();
    let Some(parent) = parents.next() else {
        // 根提交：仅当路径存在于其树中才算触碰
        let tree = repo
            .find_tree(commit.tree_id().map_err(EngineError::from_gix)?)
            .map_err(EngineError::from_gix)?;
        return Ok(tree
            .lookup_entry_by_path(path)
            .map_err(EngineError::from_gix)?
            .is_some());
    };
    let commit_entry = {
        let tree = repo
            .find_tree(commit.tree_id().map_err(EngineError::from_gix)?)
            .map_err(EngineError::from_gix)?;
        tree.lookup_entry_by_path(path)
            .map_err(EngineError::from_gix)?
    };
    let parent_entry = {
        let parent_commit = repo.find_commit(parent).map_err(EngineError::from_gix)?;
        let tree = repo
            .find_tree(parent_commit.tree_id().map_err(EngineError::from_gix)?)
            .map_err(EngineError::from_gix)?;
        tree.lookup_entry_by_path(path)
            .map_err(EngineError::from_gix)?
    };
    Ok(commit_entry.map(|e| e.id()) != parent_entry.map(|e| e.id()))
}

/// --follow 的首父兼容入口。多 parent 的路径历史使用下面的显式 parent
/// helper，以免把 merge 的第二父路径状态污染到首父。
pub(crate) fn maybe_follow_rename(
    repo: &gix::Repository,
    commit: &gix::Commit<'_>,
    current_path: &str,
) -> Result<Option<String>, EngineError> {
    let mut parents = commit.parent_ids();
    let Some(parent) = parents.next() else {
        return Ok(None);
    };
    maybe_follow_rename_from_parent(repo, commit, parent.detach(), current_path)
}

/// Resolve a rename against one specific parent. File history cannot use only
/// the first parent: a merge may carry the rename on either side, and a
/// rename with edits is represented as a Rewrite rather than an exact blob
/// deletion/addition pair.
fn maybe_follow_rename_from_parent(
    repo: &gix::Repository,
    commit: &gix::Commit<'_>,
    parent_id: gix::hash::ObjectId,
    current_path: &str,
) -> Result<Option<String>, EngineError> {
    use gix::object::tree::diff::ChangeDetached;
    let commit_tree_id = commit.tree_id().map_err(EngineError::from_gix)?;
    let commit_tree = repo
        .find_tree(commit_tree_id)
        .map_err(EngineError::from_gix)?;
    let Some(entry) = commit_tree
        .lookup_entry_by_path(current_path)
        .map_err(EngineError::from_gix)?
    else {
        return Ok(None);
    };
    let parent_commit = repo.find_commit(parent_id).map_err(EngineError::from_gix)?;
    let parent_tree_id = parent_commit.tree_id().map_err(EngineError::from_gix)?;
    let parent_tree = repo
        .find_tree(parent_tree_id)
        .map_err(EngineError::from_gix)?;
    let already_exists = parent_tree
        .lookup_entry_by_path(current_path)
        .map_err(EngineError::from_gix)?
        .is_some();
    if already_exists {
        return Ok(None); // 不是新增，无重命名
    }
    let target_id = entry.id();
    let changes = repo
        .diff_tree_to_tree(
            Some(&parent_tree),
            Some(&commit_tree),
            Some(gix::diff::Options::default().with_rewrites(Some(Default::default()))),
        )
        .map_err(EngineError::from_gix)?;
    for change in &changes {
        match change {
            // When rewrite detection is available, this also covers a rename
            // whose content changed in the same commit.
            ChangeDetached::Rewrite {
                source_location,
                location,
                ..
            } if location.to_string() == current_path => {
                return Ok(Some(source_location.to_string()));
            }
            // Keep an exact-blob fallback for repositories where the rewrite
            // detector intentionally leaves the pair as deletion + addition.
            ChangeDetached::Deletion { location, id, .. } if *id == target_id => {
                return Ok(Some(location.to_string()));
            }
            _ => {}
        }
    }
    Ok(None)
}

/// Compare a commit with one parent rather than silently assuming the first
/// parent. This is the visibility predicate used by followed file history.
fn commit_touches_path_against_parent(
    repo: &gix::Repository,
    commit: &gix::Commit<'_>,
    parent_id: gix::hash::ObjectId,
    path: &str,
) -> Result<bool, EngineError> {
    let commit_tree = repo
        .find_tree(commit.tree_id().map_err(EngineError::from_gix)?)
        .map_err(EngineError::from_gix)?;
    let parent_commit = repo.find_commit(parent_id).map_err(EngineError::from_gix)?;
    let parent_tree = repo
        .find_tree(parent_commit.tree_id().map_err(EngineError::from_gix)?)
        .map_err(EngineError::from_gix)?;
    let commit_entry = commit_tree
        .lookup_entry_by_path(path)
        .map_err(EngineError::from_gix)?;
    let parent_entry = parent_tree
        .lookup_entry_by_path(path)
        .map_err(EngineError::from_gix)?;
    Ok(commit_entry.map(|entry| entry.id()) != parent_entry.map(|entry| entry.id()))
}

/// Materialize one commit using the same record shape as the normal log walk.
/// The command-filtered log uses Git's own revision selection, then reuses
/// this formatter so the Swift graph and inspector behave like the standard
/// VCS Log surface.
pub(crate) fn commit_info_for_id(
    repo: &gix::Repository,
    id: gix::hash::ObjectId,
    refs: &HashMap<gix::hash::ObjectId, RefNames>,
    head_commit_id: gix::hash::ObjectId,
) -> Result<CommitInfo, EngineError> {
    let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
    let id_hex = id.to_hex().to_string();
    let (author_name, author_email) = match commit.author() {
        Ok(a) => (
            a.name.to_str_lossy().into_owned(),
            a.email.to_str_lossy().into_owned(),
        ),
        Err(_) => (String::new(), String::new()),
    };
    let (committer_name, committer_email) = match commit.committer() {
        Ok(c) => (
            c.name.to_str_lossy().into_owned(),
            c.email.to_str_lossy().into_owned(),
        ),
        Err(_) => (String::new(), String::new()),
    };
    let parent_ids = commit
        .parent_ids()
        .map(|parent| parent.detach().to_hex().to_string())
        .collect();
    let message_body = commit
        .message_raw()
        .ok()
        .map(|raw| {
            let text = raw.to_str_lossy();
            match text.split_once('\n') {
                Some((_, rest)) => rest.trim().to_string(),
                None => String::new(),
            }
        })
        .unwrap_or_default();
    let names = refs.get(&id);
    let repository_path = repo
        .workdir()
        .map(|path| path.to_string_lossy().into_owned());

    Ok(CommitInfo {
        repository_path,
        short_id: id_hex.chars().take(7).collect(),
        summary: commit
            .message()
            .map(|message| message.title.trim_end().to_str_lossy().into_owned())
            .unwrap_or_default(),
        author_name,
        author_email,
        committer_name,
        committer_email,
        message_body,
        has_signature: commit.signature().ok().flatten().is_some(),
        time: commit.time().map(|time| time.seconds).unwrap_or(0),
        parent_ids,
        refs: names.map(|names| names.local.clone()).unwrap_or_default(),
        tag_refs: names.map(|names| names.tags.clone()).unwrap_or_default(),
        remote_refs: names.map(|names| names.remote.clone()).unwrap_or_default(),
        is_head: id == head_commit_id,
        id: id_hex,
        lane: 0,
        parent_lanes: Vec::new(),
    })
}

/// The repository-wide graph used by the default VCS Log view.
///
/// IntelliJ keeps this permanent graph separate from the bounded visible pack:
/// loading another page, asking for children, and rebuilding the visible lanes
/// all consult the same commit/index model.  Keep the equivalent engine-side
/// state in memory and invalidate it when refs or HEAD move.  Path history and
/// explicit revision/filter queries intentionally continue to use `collect_log`
/// because their reachability semantics are different from the default graph.
#[derive(Debug)]
pub(crate) struct PermanentLogGraph {
    refs_token: Vec<String>,
    head_id: Option<gix::hash::ObjectId>,
    sort_mode: LogGraphSortMode,
    commits: Vec<CommitInfo>,
    commit_indices: HashMap<gix::hash::ObjectId, usize>,
    child_indices: HashMap<gix::hash::ObjectId, Vec<usize>>,
    containing_branch_refs: HashMap<gix::hash::ObjectId, Vec<String>>,
}

impl PermanentLogGraph {
    pub(crate) fn is_current(
        &self,
        refs_token: &[String],
        head_id: Option<gix::hash::ObjectId>,
        sort_mode: LogGraphSortMode,
    ) -> bool {
        self.refs_token == refs_token && self.head_id == head_id && self.sort_mode == sort_mode
    }

    pub(crate) fn page(
        &self,
        after_id: Option<gix::hash::ObjectId>,
        limit: u32,
    ) -> Vec<CommitInfo> {
        if limit == 0 {
            return Vec::new();
        }
        let start = match after_id {
            None => 0,
            Some(id) => match self.commit_indices.get(&id) {
                Some(index) => index.saturating_add(1),
                None => return Vec::new(),
            },
        };
        self.commits
            .iter()
            .skip(start)
            .take(limit as usize)
            .cloned()
            .collect()
    }

    pub(crate) fn contains_commit(&self, target: gix::hash::ObjectId) -> bool {
        self.commit_indices.contains_key(&target)
    }

    /// Filter the permanent graph into a bounded VisibleGraph-like page.
    ///
    /// The returned rows retain lanes from the complete graph when `heads` is
    /// absent. With selected heads, lanes are re-projected from their
    /// reachable context before message, author, date and parent filters select
    /// matching rows. Hidden commits remain in that context, matching
    /// IntelliJ's `createVisibleGraph(options, heads, matchedCommits)`
    /// contract.
    pub(crate) fn filtered_page(
        &self,
        heads: Option<&[gix::hash::ObjectId]>,
        after_id: Option<gix::hash::ObjectId>,
        limit: u32,
        author: Option<&str>,
        since: Option<i64>,
        until: Option<i64>,
        message: Option<&str>,
        message_regex: bool,
        message_match_case: bool,
        no_merges: bool,
    ) -> Result<Vec<CommitInfo>, EngineError> {
        if limit == 0 {
            return Ok(Vec::new());
        }
        let visible_commits = heads.map(|heads| {
            let mut visible = HashSet::new();
            let mut pending = heads.to_vec();
            while let Some(id) = pending.pop() {
                if !visible.insert(id) || !self.commit_indices.contains_key(&id) {
                    continue;
                }
                let commit = &self.commits[self.commit_indices[&id]];
                let parents = if self.sort_mode == LogGraphSortMode::FirstParent {
                    &commit.parent_ids[..commit.parent_ids.len().min(1)]
                } else {
                    &commit.parent_ids
                };
                for parent in parents {
                    if let Ok(parent_id) = gix::hash::ObjectId::from_hex(parent.as_bytes()) {
                        pending.push(parent_id);
                    }
                }
            }
            visible
        });
        // BranchFilterController does not merely remove rows after the base
        // graph has been painted. It collapses the permanent graph to the
        // selected heads first, so an unselected sibling branch cannot keep a
        // lane alive in the visible graph. Re-project lanes from that
        // selected-head context while retaining the complete context for
        // message/date/No Merges matching below.
        let filtered_lane_by_id = {
            let mut context = match &visible_commits {
                Some(visible) => self
                    .commits
                    .iter()
                    .filter(|commit| {
                        gix::hash::ObjectId::from_hex(commit.id.as_bytes())
                            .ok()
                            .is_some_and(|id| visible.contains(&id))
                    })
                    .cloned()
                    .collect(),
                None => self.commits.clone(),
            };
            assign_graph_lanes(
                &mut context,
                self.sort_mode == LogGraphSortMode::LinearizeMerges,
                self.sort_mode == LogGraphSortMode::FirstParent,
            );
            context
                .into_iter()
                .map(|commit| (commit.id, (commit.lane, commit.parent_lanes)))
                .collect::<HashMap<_, _>>()
        };
        let author = author.map(str::to_lowercase);
        let message_pattern = if message_regex {
            message
                .map(|filter| {
                    let pattern = if message_match_case {
                        filter.to_owned()
                    } else {
                        format!("(?i:{filter})")
                    };
                    Regex::new(&pattern).map_err(|error| EngineError::GitOperation {
                        message: format!("invalid log text filter regex: {error}"),
                    })
                })
                .transpose()?
        } else {
            None
        };
        let message = message.map(str::to_owned);
        let start_after = after_id.map(|id| {
            self.commit_indices
                .get(&id)
                .copied()
                .map(|index| index.saturating_add(1))
        });
        let Some(start_after) = start_after.unwrap_or(Some(0)) else {
            return Ok(Vec::new());
        };
        let mut visible = Vec::new();
        for commit in self.commits.iter().skip(start_after) {
            let id = gix::hash::ObjectId::from_hex(commit.id.as_bytes()).map_err(|error| {
                EngineError::GitOperation {
                    message: format!("invalid permanent graph commit id: {error}"),
                }
            })?;
            if let Some(visible_commits) = &visible_commits {
                if !visible_commits.contains(&id) {
                    continue;
                }
            }
            if let Some(filter) = &author {
                if !commit.author_name.to_lowercase().contains(filter)
                    && !commit.author_email.to_lowercase().contains(filter)
                {
                    continue;
                }
            }
            if since.is_some_and(|minimum| commit.time < minimum)
                || until.is_some_and(|maximum| commit.time >= maximum)
            {
                continue;
            }
            if let Some(filter) = &message {
                let full_message = if commit.message_body.is_empty() {
                    commit.summary.clone()
                } else {
                    format!("{}\n{}", commit.summary, commit.message_body)
                };
                let matches = if let Some(pattern) = &message_pattern {
                    pattern.is_match(&full_message)
                } else if message_match_case {
                    full_message.contains(filter)
                } else {
                    full_message.to_lowercase().contains(&filter.to_lowercase())
                };
                if !matches {
                    continue;
                }
            }
            if no_merges && commit.parent_ids.len() > 1 {
                continue;
            }
            visible.push(commit.clone());
            if visible.len() >= limit as usize {
                break;
            }
        }
        for commit in &mut visible {
            if let Some((lane, parent_lanes)) = filtered_lane_by_id.get(&commit.id) {
                commit.lane = *lane;
                commit.parent_lanes = parent_lanes.clone();
            }
        }
        Ok(visible)
    }

    /// `None` means the target is outside this repository-wide graph. `Some`
    /// can be empty, which is the correct result for a known leaf commit.
    pub(crate) fn children(&self, target: gix::hash::ObjectId) -> Option<Vec<CommitInfo>> {
        if !self.commit_indices.contains_key(&target) {
            return None;
        }
        Some(
            self.child_indices
                .get(&target)
                .into_iter()
                .flatten()
                .map(|index| self.commits[*index].clone())
                .collect(),
        )
    }

    pub(crate) fn containing_branches(&self, target: gix::hash::ObjectId) -> Vec<String> {
        self.containing_branch_refs
            .get(&target)
            .cloned()
            .unwrap_or_default()
    }
}

/// Build the complete all-ref graph once for a repository.
pub(crate) fn build_permanent_log_graph(
    repo: &gix::Repository,
    sort_mode: LogGraphSortMode,
) -> Result<PermanentLogGraph, EngineError> {
    let refs_token = crate::branch::ref_tip_snapshot(repo)?;
    if repo.head().map_err(EngineError::from_gix)?.is_unborn() {
        return Ok(PermanentLogGraph {
            refs_token,
            head_id: None,
            sort_mode,
            commits: Vec::new(),
            commit_indices: HashMap::new(),
            child_indices: HashMap::new(),
            containing_branch_refs: HashMap::new(),
        });
    }

    let head_commit_id = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .id()
        .detach();
    let refs = collect_refs(repo)?;
    let mut walk_starts = Vec::with_capacity(refs.len() + 1);
    walk_starts.push(head_commit_id);
    let mut other_starts: Vec<_> = refs
        .keys()
        .copied()
        .filter(|id| *id != head_commit_id)
        .collect();
    other_starts.sort_unstable();
    walk_starts.extend(other_starts);
    walk_starts.dedup();

    let walk_sorting = match sort_mode {
        LogGraphSortMode::ByCommitDate | LogGraphSortMode::FirstParent => {
            gix::traverse::commit::topo::Sorting::DateOrder
        }
        LogGraphSortMode::Topologically | LogGraphSortMode::LinearizeMerges => {
            gix::traverse::commit::topo::Sorting::TopoOrder
        }
    };
    let walk_builder = gix::traverse::commit::topo::Builder::from_iters(
        &repo.objects,
        walk_starts,
        None::<Vec<gix::hash::ObjectId>>,
    )
    .sorting(walk_sorting);
    let walk_builder = if matches!(sort_mode, LogGraphSortMode::FirstParent) {
        walk_builder.parents(gix::traverse::commit::Parents::First)
    } else {
        walk_builder
    };
    let walk = walk_builder
        .build()
        .map_err(|error| EngineError::GitOperation {
            message: format!("cannot build permanent log graph: {error}"),
        })?;
    let ids: Vec<_> = walk
        .map(|item| {
            item.map(|info| info.id)
                .map_err(|error| EngineError::GitOperation {
                    message: format!("cannot traverse permanent log graph: {error}"),
                })
        })
        .collect::<Result<_, _>>()?;

    let mut commits = Vec::with_capacity(ids.len());
    for id in ids {
        commits.push(commit_info_for_id(repo, id, &refs, head_commit_id)?);
    }

    // IntelliJ's Base(Bek) and LinearBek options are not the same as Git's
    // generic topo-order walk.  The permanent graph first builds a stable
    // branch layout and then merges branch fragments by timestamp while
    // respecting graph restrictions.  Do that reorder before assigning lanes;
    // filtered VisibleGraph pages can then reuse the same permanent order.
    if matches!(
        sort_mode,
        LogGraphSortMode::Topologically | LogGraphSortMode::LinearizeMerges
    ) {
        let branch_heads: HashSet<_> = refs
            .iter()
            .filter(|(_, names)| !names.local.is_empty() || !names.remote.is_empty())
            .map(|(id, _)| *id)
            .collect();
        reorder_commits_for_bek(&mut commits, head_commit_id, &branch_heads);
    }
    assign_graph_lanes(
        &mut commits,
        matches!(sort_mode, LogGraphSortMode::LinearizeMerges),
        matches!(sort_mode, LogGraphSortMode::FirstParent),
    );

    let mut commit_indices = HashMap::with_capacity(commits.len());
    for (index, commit) in commits.iter().enumerate() {
        if let Ok(id) = gix::hash::ObjectId::from_hex(commit.id.as_bytes()) {
            commit_indices.insert(id, index);
        }
    }
    let mut child_indices: HashMap<gix::hash::ObjectId, Vec<usize>> = HashMap::new();
    for (index, commit) in commits.iter().enumerate() {
        for parent in &commit.parent_ids {
            let Ok(parent_id) = gix::hash::ObjectId::from_hex(parent.as_bytes()) else {
                continue;
            };
            child_indices.entry(parent_id).or_default().push(index);
        }
    }
    for indices in child_indices.values_mut() {
        indices.sort_by(|left, right| {
            commits[*right]
                .time
                .cmp(&commits[*left].time)
                .then_with(|| commits[*left].id.cmp(&commits[*right].id))
        });
    }

    // Propagate each local and remote branch name from its tip to all of its
    // ancestors. The walk is child-to-parent, so every descendant has already
    // contributed before a parent is visited. This is the same useful contract
    // as IntelliJ's PermanentGraph.getContainingBranches, without re-walking
    // the repository once per branch for each action invocation.
    let mut containing_branch_refs: HashMap<gix::hash::ObjectId, Vec<String>> = HashMap::new();
    for (tip, names) in &refs {
        let entry = containing_branch_refs.entry(*tip).or_default();
        entry.extend(names.local.iter().cloned());
        entry.extend(names.remote.iter().cloned());
    }
    for commit in &commits {
        let Ok(id) = gix::hash::ObjectId::from_hex(commit.id.as_bytes()) else {
            continue;
        };
        let names = containing_branch_refs.get(&id).cloned().unwrap_or_default();
        if names.is_empty() {
            continue;
        }
        for parent in &commit.parent_ids {
            let Ok(parent_id) = gix::hash::ObjectId::from_hex(parent.as_bytes()) else {
                continue;
            };
            let parent_names = containing_branch_refs.entry(parent_id).or_default();
            for name in &names {
                if !parent_names.contains(name) {
                    parent_names.push(name.clone());
                }
            }
        }
    }
    for names in containing_branch_refs.values_mut() {
        names.sort();
        names.dedup();
    }

    Ok(PermanentLogGraph {
        refs_token,
        head_id: Some(head_commit_id),
        sort_mode,
        commits,
        commit_indices,
        child_indices,
        containing_branch_refs,
    })
}

/// Reorder a complete permanent graph using IntelliJ's Bek branch merge
/// strategy.  The input is already a valid child-before-parent topological
/// order from gix; this function only changes the order and never changes an
/// edge.  Keeping this transformation on the complete graph is important:
/// filtered pages must be projections of one permanent order, not independent
/// partial walks.
fn reorder_commits_for_bek(
    commits: &mut Vec<CommitInfo>,
    head_id: gix::hash::ObjectId,
    branch_heads: &HashSet<gix::hash::ObjectId>,
) {
    if commits.len() < 2 {
        return;
    }

    let index_by_id: HashMap<_, _> = commits
        .iter()
        .enumerate()
        .filter_map(|(index, commit)| {
            gix::hash::ObjectId::from_hex(commit.id.as_bytes())
                .ok()
                .map(|id| (id, index))
        })
        .collect();
    let parent_indices: Vec<Vec<usize>> = commits
        .iter()
        .map(|commit| {
            commit
                .parent_ids
                .iter()
                .filter_map(|parent| {
                    gix::hash::ObjectId::from_hex(parent.as_bytes())
                        .ok()
                        .and_then(|id| index_by_id.get(&id).copied())
                })
                .collect()
        })
        .collect();
    let mut child_indices = vec![Vec::new(); commits.len()];
    for (child, parents) in parent_indices.iter().enumerate() {
        for parent in parents {
            child_indices[*parent].push(child);
        }
    }

    // GraphLayoutBuilder starts from all branch heads and graph heads.  The
    // current HEAD is the most important head; the original permanent order
    // is the stable tie-breaker for the remaining refs.
    let mut heads: Vec<usize> = (0..commits.len())
        .filter(|index| child_indices[*index].is_empty())
        .collect();
    for id in branch_heads {
        if let Some(index) = index_by_id.get(id) {
            heads.push(*index);
        }
    }
    if let Some(index) = index_by_id.get(&head_id) {
        heads.push(*index);
    }
    heads.sort_unstable();
    heads.dedup();
    heads.sort_by_key(|index| {
        let id = gix::hash::ObjectId::from_hex(commits[*index].id.as_bytes()).ok();
        let is_head = id == Some(head_id);
        (!is_head, *index)
    });

    let layout = build_bek_layout(&parent_indices, &heads);
    let (branches, restrictions) =
        create_bek_branches(&parent_indices, &child_indices, &layout, &heads);
    let order = merge_bek_branches(&branches, &restrictions, &parent_indices, commits);
    if order.len() != commits.len() {
        return;
    }

    let old = std::mem::take(commits);
    *commits = order.into_iter().map(|index| old[index].clone()).collect();
}

/// Port of GraphLayoutBuilder's head-first DFS numbering.  A layout number is
/// used only to decide which branch is visually more important; it is not the
/// visible row index.
fn build_bek_layout(parent_indices: &[Vec<usize>], heads: &[usize]) -> Vec<usize> {
    let mut layout = vec![0; parent_indices.len()];
    let mut next_layout = 1;
    for head in heads {
        if layout[*head] != 0 {
            continue;
        }
        let mut stack = vec![*head];
        while let Some(&current) = stack.last() {
            let first_visit = layout[current] == 0;
            if first_visit {
                layout[current] = next_layout;
            }
            let next = parent_indices[current]
                .iter()
                .copied()
                .find(|parent| layout[*parent] == 0);
            let Some(next) = next else {
                if first_visit {
                    next_layout += 1;
                }
                stack.pop();
                continue;
            };
            stack.push(next);
        }
    }
    layout
}

#[derive(Debug)]
struct BekBranch {
    nodes: Vec<usize>,
    no_insert_size: usize,
    prepared_start: Option<usize>,
}

#[derive(Clone, Debug, Default)]
struct BekRestrictions(HashSet<usize>);

impl BekRestrictions {
    fn add(&mut self, up: usize, _down: usize) {
        self.0.insert(up);
    }

    fn contains_node(&self, node: usize) -> bool {
        self.0.contains(&node)
    }

    fn remove_node(&mut self, node: usize) {
        self.0.remove(&node);
    }
}

/// Reproduce BekBranchCreator: each branch follows the first currently safe
/// parent, while already-owned lower-layout edges become restrictions.
fn create_bek_branches(
    parent_indices: &[Vec<usize>],
    child_indices: &[Vec<usize>],
    layout: &[usize],
    heads: &[usize],
) -> (Vec<BekBranch>, BekRestrictions) {
    let mut done = vec![false; parent_indices.len()];
    let mut restrictions = BekRestrictions::default();
    let mut branches = Vec::new();

    for head in heads {
        if done[*head] {
            continue;
        }
        done[*head] = true;
        let start_layout = layout[*head];
        let mut nodes = vec![*head];
        let mut stack = vec![*head];
        while let Some(&current) = stack.last() {
            let current_layout = layout[current];
            let mut next = None;
            for down in parent_indices[current].iter().rev().copied() {
                if done[down] {
                    if layout[down] < start_layout {
                        restrictions.add(current, down);
                    }
                    continue;
                }
                if current_layout > layout[down] {
                    continue;
                }
                let has_undone_up = child_indices[down]
                    .iter()
                    .any(|up| !done[*up] && layout[*up] <= layout[down]);
                if has_undone_up {
                    continue;
                }
                done[down] = true;
                nodes.push(down);
                next = Some(down);
                break;
            }
            if let Some(next_node) = next {
                stack.push(next_node);
            } else {
                stack.pop();
            }
        }
        branches.push(BekBranch {
            no_insert_size: nodes.len(),
            nodes,
            prepared_start: None,
        });
    }

    // Defensive fallback for malformed/dangling graph input. A complete
    // permanent graph should never need this, but leaving a node unassigned
    // would make the option silently drop a commit.
    for node in 0..parent_indices.len() {
        if !done[node] {
            branches.push(BekBranch {
                nodes: vec![node],
                no_insert_size: 1,
                prepared_start: None,
            });
        }
    }
    (branches, restrictions)
}

fn merge_bek_branches(
    branches: &[BekBranch],
    source_restrictions: &BekRestrictions,
    parent_indices: &[Vec<usize>],
    commits: &[CommitInfo],
) -> Vec<usize> {
    let mut branches: Vec<_> = branches
        .iter()
        .map(|branch| BekBranch {
            nodes: branch.nodes.clone(),
            no_insert_size: branch.no_insert_size,
            prepared_start: None,
        })
        .collect();
    let mut restrictions = source_restrictions.clone();
    let mut inverse_result = Vec::with_capacity(commits.len());

    loop {
        let mut any = false;
        for branch in &mut branches {
            if branch.no_insert_size == 0 {
                continue;
            }
            any = true;
            if branch.prepared_start.is_some() {
                continue;
            }
            let current_node = branch.nodes[branch.no_insert_size - 1];
            if restrictions.contains_node(current_node) {
                branch.prepared_start = None;
                continue;
            }
            let mut start = branch.no_insert_size - 1;
            while start > 0 {
                let up = branch.nodes[start - 1];
                let down = branch.nodes[start];
                if restrictions.contains_node(up) || !parent_indices[up].contains(&down) {
                    break;
                }
                let delta = (commits[up].time - commits[down].time).unsigned_abs();
                if delta > 3 * 24 * 60 * 60 {
                    break;
                }
                if start < branch.no_insert_size.saturating_sub(20) && delta > 4 * 60 * 60 {
                    break;
                }
                start -= 1;
            }
            branch.prepared_start = Some(start);
        }
        if !any {
            break;
        }

        let selected = branches
            .iter()
            .enumerate()
            .filter_map(|(index, branch)| {
                let start = branch.prepared_start?;
                Some((commits[branch.nodes[start]].time, index, start))
            })
            .min_by_key(|(timestamp, index, _)| (*timestamp, *index));
        let Some((_, selected_index, start)) = selected else {
            break;
        };
        let branch = &mut branches[selected_index];
        let old_size = branch.no_insert_size;
        for node in branch.nodes[start..old_size].iter().rev() {
            inverse_result.push(*node);
        }
        for node in &branch.nodes[start..old_size] {
            restrictions.remove_node(*node);
        }
        branch.no_insert_size = start;
        branch.prepared_start = None;
    }

    inverse_result.reverse();
    inverse_result
}

/// Resolve every direct child of a commit from the repository graph.
///
/// The visible VCS Log page is intentionally bounded, so looking only at the
/// currently loaded rows cannot implement `Go to Child`: a child may be just
/// outside the viewport or may live on another local/remote ref. Walk the
/// same all-ref graph used by the normal Log and materialize only the direct
/// children for the navigation popup.
pub(crate) fn direct_children(
    repo: &gix::Repository,
    target: gix::hash::ObjectId,
) -> Result<Vec<CommitInfo>, EngineError> {
    if repo.head().map_err(EngineError::from_gix)?.is_unborn() {
        return Ok(Vec::new());
    }
    let head_commit_id = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .id()
        .detach();
    let refs = collect_refs(repo)?;
    let mut starts = Vec::with_capacity(refs.len() + 1);
    starts.push(head_commit_id);
    let mut ref_starts: Vec<_> = refs
        .keys()
        .copied()
        .filter(|id| *id != head_commit_id)
        .collect();
    ref_starts.sort_unstable();
    starts.extend(ref_starts);
    starts.dedup();

    let walk = gix::traverse::commit::topo::Builder::from_iters(
        &repo.objects,
        starts,
        None::<Vec<gix::hash::ObjectId>>,
    )
    .sorting(gix::traverse::commit::topo::Sorting::DateOrder)
    .build()
    .map_err(|error| EngineError::GitOperation {
        message: format!("cannot build child navigation walk: {error}"),
    })?;
    let mut children = Vec::new();
    let mut seen = HashSet::new();
    for item in walk {
        let id = item
            .map(|info| info.id)
            .map_err(|error| EngineError::GitOperation {
                message: format!("cannot traverse child navigation graph: {error}"),
            })?;
        if id == target || !seen.insert(id) {
            continue;
        }
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        if commit.parent_ids().any(|parent| parent.detach() == target) {
            children.push(commit_info_for_id(repo, id, &refs, head_commit_id)?);
        }
    }
    children.sort_by(|left, right| {
        right
            .time
            .cmp(&left.time)
            .then_with(|| left.id.cmp(&right.id))
    });
    Ok(children)
}

/// 收集日志的共享实现。过滤在引擎侧完成，分页用 `after_id` 跳过已返回的旧条目。
pub(crate) fn collect_log(
    repo: &gix::Repository,
    path: Option<String>,
    limit: u32,
    follow: bool,
    start_ids: Option<Vec<gix::hash::ObjectId>>,
    end_ids: Option<Vec<gix::hash::ObjectId>>,
    author: Option<&str>,
    since: Option<i64>,
    until: Option<i64>,
    message: Option<&str>,
    message_regex: bool,
    message_match_case: bool,
    no_merges: bool,
    after_id: Option<gix::hash::ObjectId>,
    sort_mode: LogGraphSortMode,
) -> Result<Vec<CommitInfo>, EngineError> {
    collect_log_paths(
        repo,
        path.map(|path| vec![path]),
        limit,
        follow,
        start_ids,
        end_ids,
        author,
        since,
        until,
        message,
        message_regex,
        message_match_case,
        no_merges,
        after_id,
        sort_mode,
    )
}

pub(crate) fn collect_log_paths(
    repo: &gix::Repository,
    paths: Option<Vec<String>>,
    limit: u32,
    follow: bool,
    start_ids: Option<Vec<gix::hash::ObjectId>>,
    end_ids: Option<Vec<gix::hash::ObjectId>>,
    author: Option<&str>,
    since: Option<i64>,
    until: Option<i64>,
    message: Option<&str>,
    message_regex: bool,
    message_match_case: bool,
    no_merges: bool,
    after_id: Option<gix::hash::ObjectId>,
    sort_mode: LogGraphSortMode,
) -> Result<Vec<CommitInfo>, EngineError> {
    if limit == 0 {
        return Ok(Vec::new());
    }
    if repo.head().map_err(EngineError::from_gix)?.is_unborn() {
        return Ok(Vec::new());
    }
    let head_commit_id = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .id()
        .detach();
    let repository_path = repo
        .workdir()
        .map(|path| path.to_string_lossy().into_owned());
    let refs = collect_refs(repo)?;
    // IntelliJ's Git log is a repository graph, not merely `git log HEAD`:
    // the default view includes HEAD, all local branches and remote-tracking
    // branches (and keeps tag-only commits reachable as well).  Starting only
    // at HEAD makes refs point at commits that are absent from the graph,
    // which is especially visible for unmerged branches.
    let mut walk_starts = match start_ids {
        Some(starts) if !starts.is_empty() => starts,
        Some(_) | None => {
            let mut starts = Vec::with_capacity(refs.len() + 1);
            starts.push(head_commit_id);
            let mut other_starts: Vec<_> = refs
                .keys()
                .copied()
                .filter(|id| *id != head_commit_id)
                .collect();
            other_starts.sort_unstable();
            starts.extend(other_starts);
            starts.dedup();
            starts
        }
    };
    if walk_starts.is_empty() {
        walk_starts.push(head_commit_id);
    }
    let walk_sorting = match sort_mode {
        LogGraphSortMode::ByCommitDate | LogGraphSortMode::FirstParent => {
            gix::traverse::commit::topo::Sorting::DateOrder
        }
        LogGraphSortMode::Topologically | LogGraphSortMode::LinearizeMerges => {
            gix::traverse::commit::topo::Sorting::TopoOrder
        }
    };
    // A followed path is stateful: after a rename, each parent may carry a
    // different path. Seed every revision start so aggregate Log roots keep
    // their existing all-refs behavior while the state itself remains
    // parent-specific.
    let follow_path_starts = if follow && paths.as_ref().is_some_and(|paths| !paths.is_empty()) {
        Some(walk_starts.clone())
    } else {
        None
    };
    let walk_builder =
        gix::traverse::commit::topo::Builder::from_iters(&repo.objects, walk_starts, end_ids)
            .sorting(walk_sorting);
    let walk_builder = if matches!(sort_mode, LogGraphSortMode::FirstParent) {
        walk_builder.parents(gix::traverse::commit::Parents::First)
    } else {
        walk_builder
    };
    let walk = walk_builder
        .build()
        .map_err(|error| EngineError::GitOperation {
            message: format!("cannot build log walk: {error}"),
        })?;
    let walk_ids: Box<dyn Iterator<Item = Result<gix::hash::ObjectId, EngineError>> + '_> =
        Box::new(walk.map(|item| {
            item.map(|info| info.id)
                .map_err(|error| EngineError::GitOperation {
                    message: format!("cannot traverse log: {error}"),
                })
        }));
    let author = author.map(str::to_lowercase);
    let message = message.map(str::to_owned);
    let message_pattern = if message_regex {
        message
            .as_deref()
            .map(|filter| {
                let pattern = if message_match_case {
                    filter.to_owned()
                } else {
                    format!("(?i:{filter})")
                };
                Regex::new(&pattern).map_err(|error| EngineError::GitOperation {
                    message: format!("invalid log text filter regex: {error}"),
                })
            })
            .transpose()?
    } else {
        None
    };
    let mut after_seen = after_id.is_none();
    // The Swift UI appends pages to one graph. Rebuild the lane state from
    // the same filtered prefix whenever paging a revision log without a path
    // filter, otherwise the first commit on page N starts at lane 0 even when
    // it continued a lane from page N-1. Path-follow history has its own
    // parent-specific state machine and remains outside this fast path.
    let mut cursor_found = false;
    let mut visible_count = 0usize;
    let mut commits = Vec::new();
    let mut current_paths = paths.filter(|paths| !paths.is_empty());
    let path_filtered = current_paths.is_some();
    let preserve_graph_context = after_id.is_some() && !path_filtered;
    // IntelliJ filters a permanent graph into a VisibleGraph, so hidden
    // commits still contribute lane state. Keep a private full-context prefix
    // for every revision/filter query without a path-follow state machine, and
    // publish only matching rows to the caller.
    let preserve_filtered_graph_context = !path_filtered;
    let mut graph_context_commits = Vec::new();
    let use_followed_path_states = follow && path_filtered;
    let mut followed_path_states: HashMap<gix::hash::ObjectId, Vec<Vec<String>>> = HashMap::new();
    if let (Some(starts), Some(initial_paths)) = (follow_path_starts, current_paths.as_ref()) {
        for start in starts {
            followed_path_states
                .entry(start)
                .or_default()
                .push(initial_paths.clone());
        }
    }

    for item in walk_ids {
        let id = item?;
        let is_cursor = !after_seen && Some(id) == after_id;
        if !after_seen && !is_cursor && !preserve_graph_context && !use_followed_path_states {
            continue;
        }
        if is_cursor {
            after_seen = true;
            cursor_found = true;
            if !preserve_graph_context && !use_followed_path_states {
                continue;
            }
        }
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        let id_hex = id.to_hex().to_string();
        let graph_context_parent_ids = if preserve_filtered_graph_context {
            let parent_ids: Vec<String> = commit
                .parent_ids()
                .map(|parent| parent.detach().to_hex().to_string())
                .collect();
            graph_context_commits.push(CommitInfo {
                repository_path: None,
                short_id: String::new(),
                summary: String::new(),
                author_name: String::new(),
                author_email: String::new(),
                committer_name: String::new(),
                committer_email: String::new(),
                message_body: String::new(),
                has_signature: false,
                time: 0,
                parent_ids: parent_ids.clone(),
                refs: Vec::new(),
                tag_refs: Vec::new(),
                remote_refs: Vec::new(),
                is_head: false,
                id: id_hex.clone(),
                lane: 0,
                parent_lanes: Vec::new(),
            });
            Some(parent_ids)
        } else {
            None
        };
        let path_matches = if use_followed_path_states {
            let active_states = followed_path_states.remove(&id).unwrap_or_default();
            if active_states.is_empty() {
                continue;
            }
            let parent_ids: Vec<gix::hash::ObjectId> =
                commit.parent_ids().map(|parent| parent.detach()).collect();
            let mut touches_path = false;
            if parent_ids.is_empty() {
                for paths in &active_states {
                    for path in paths {
                        if commit_touches_path(repo, &commit, path)? {
                            touches_path = true;
                        }
                    }
                }
            } else {
                for paths in active_states {
                    for parent_id in &parent_ids {
                        let mut next_paths = paths.clone();
                        for (index, path) in paths.iter().enumerate() {
                            if commit_touches_path_against_parent(repo, &commit, *parent_id, path)?
                            {
                                touches_path = true;
                            }
                            if let Some(source) =
                                maybe_follow_rename_from_parent(repo, &commit, *parent_id, path)?
                            {
                                next_paths[index] = source;
                            }
                        }
                        let states = followed_path_states.entry(*parent_id).or_default();
                        if !states.contains(&next_paths) {
                            states.push(next_paths);
                        }
                    }
                }
            }
            if !touches_path {
                continue;
            }
            // A path-filtered page still has to replay the prefix through the
            // cursor so the first row after `after_id` inherits the right
            // pre-rename path. The cursor itself is not part of the page.
            if !after_seen && !preserve_graph_context {
                continue;
            }
            if is_cursor && !preserve_graph_context {
                continue;
            }
            true
        } else if let Some(paths) = &mut current_paths {
            let mut touches_path = false;
            for path in paths.iter() {
                if commit_touches_path(repo, &commit, path)? {
                    touches_path = true;
                    break;
                }
            }
            if !touches_path {
                continue;
            }
            if follow {
                for path in paths.iter_mut() {
                    if let Some(src) = maybe_follow_rename(repo, &commit, path)? {
                        *path = src;
                    }
                }
            }
            true
        } else {
            true
        };
        if !path_matches {
            continue;
        }
        let (author_name, author_email) = match commit.author() {
            Ok(a) => (
                a.name.to_str_lossy().into_owned(),
                a.email.to_str_lossy().into_owned(),
            ),
            Err(_) => (String::new(), String::new()),
        };
        let time = commit.time().map(|t| t.seconds).unwrap_or(0);
        if let Some(filter) = &author {
            let name = author_name.to_lowercase();
            let email = author_email.to_lowercase();
            if !name.contains(filter) && !email.contains(filter) {
                continue;
            }
        }
        if since.is_some_and(|minimum| time < minimum) {
            continue;
        }
        // IntelliJ's VcsLogDateFilter uses a strict upper bound (`before`).
        // Keep the same boundary semantics for the optional Until field.
        if until.is_some_and(|maximum| time >= maximum) {
            continue;
        }
        if let Some(filter) = &message {
            let raw_message = commit
                .message_raw()
                .map_err(EngineError::from_gix)?
                .to_str_lossy();
            let matches = if let Some(pattern) = &message_pattern {
                pattern.is_match(&raw_message)
            } else if message_match_case {
                raw_message.contains(filter)
            } else {
                raw_message.to_lowercase().contains(&filter.to_lowercase())
            };
            if !matches {
                continue;
            }
        }
        let parent_ids = graph_context_parent_ids.unwrap_or_else(|| {
            commit
                .parent_ids()
                .map(|parent| parent.detach().to_hex().to_string())
                .collect()
        });
        if no_merges && parent_ids.len() > 1 {
            continue;
        }
        // Rows before the cursor and the cursor itself are graph context but
        // never part of the next page. Apply this after the filters so a
        // filtered-out cursor still advances the walk without becoming a
        // visible result.
        if !after_seen || is_cursor {
            continue;
        }
        // 正文 = message_raw 去掉标题行后的内容
        let message_body = commit
            .message_raw()
            .ok()
            .map(|raw| {
                let text = raw.to_str_lossy();
                match text.split_once('\n') {
                    Some((_, rest)) => rest.trim().to_string(),
                    None => String::new(),
                }
            })
            .unwrap_or_default();
        let (committer_name, committer_email) = match commit.committer() {
            Ok(c) => (
                c.name.to_str_lossy().into_owned(),
                c.email.to_str_lossy().into_owned(),
            ),
            Err(_) => (String::new(), String::new()),
        };
        let has_signature = commit.signature().ok().flatten().is_some();
        commits.push(CommitInfo {
            repository_path: repository_path.clone(),
            short_id: id_hex.chars().take(7).collect(),
            summary: commit
                .message()
                .map(|m| m.title.trim_end().to_str_lossy().into_owned())
                .unwrap_or_default(),
            message_body,
            committer_name,
            committer_email,
            has_signature,
            refs: refs
                .get(&id)
                .map(|names| names.local.clone())
                .unwrap_or_default(),
            is_head: id == head_commit_id,
            id: id_hex,
            author_name,
            author_email,
            time,
            parent_ids,
            tag_refs: refs
                .get(&id)
                .map(|names| names.tags.clone())
                .unwrap_or_default(),
            remote_refs: refs
                .get(&id)
                .map(|names| names.remote.clone())
                .unwrap_or_default(),
            lane: 0,
            parent_lanes: Vec::new(),
        });

        if after_seen {
            visible_count += 1;
        }
        if visible_count >= limit as usize {
            break;
        }
    }

    if preserve_filtered_graph_context {
        assign_graph_lanes(
            &mut graph_context_commits,
            matches!(sort_mode, LogGraphSortMode::LinearizeMerges),
            matches!(sort_mode, LogGraphSortMode::FirstParent),
        );
        let lane_by_id: HashMap<_, _> = graph_context_commits
            .into_iter()
            .map(|commit| (commit.id, (commit.lane, commit.parent_lanes)))
            .collect();
        for commit in &mut commits {
            if let Some((lane, parent_lanes)) = lane_by_id.get(&commit.id) {
                commit.lane = *lane;
                commit.parent_lanes = parent_lanes.clone();
            }
        }
    }
    if preserve_graph_context && !cursor_found {
        return Ok(Vec::new());
    }
    Ok(commits)
}

/// Assign stable lanes to the visible portion of a topologically ordered log.
///
/// A lane is an expected next commit.  The first parent continues the current
/// lane and additional parents are inserted beside it, while already-active
/// parents reuse their existing lane.  This mirrors the important invariant
/// of IntelliJ's permanent graph: every visible `parent_lanes[i]` is the lane
/// occupied by the corresponding parent on the following row. FirstParent
/// intentionally omits secondary parent edges from this visible lane list.
pub(crate) fn assign_graph_lanes(
    commits: &mut [CommitInfo],
    linearize_merges: bool,
    first_parent_only: bool,
) {
    let mut lane_tips: Vec<gix::hash::ObjectId> = Vec::new();

    for commit in commits {
        let Ok(id) = gix::hash::ObjectId::from_hex(commit.id.as_bytes()) else {
            continue;
        };

        let lane = lane_tips
            .iter()
            .position(|tip| *tip == id)
            .unwrap_or_else(|| {
                lane_tips.push(id);
                lane_tips.len() - 1
            });
        commit.lane = lane as u32;

        let mut parent_ids: Vec<_> = commit
            .parent_ids
            .iter()
            .filter_map(|parent| gix::hash::ObjectId::from_hex(parent.as_bytes()).ok())
            .collect();
        if first_parent_only {
            parent_ids.truncate(1);
        }
        let mut parent_lanes = Vec::with_capacity(parent_ids.len());

        if parent_ids.is_empty() {
            lane_tips.remove(lane);
        } else {
            let primary_parent_index = if linearize_merges && parent_ids.len() > 1 {
                1
            } else {
                0
            };
            let first_parent = parent_ids[primary_parent_index];
            let existing_first_parent = lane_tips.iter().position(|tip| *tip == first_parent);
            if let Some(existing) = existing_first_parent.filter(|existing| *existing != lane) {
                lane_tips.remove(lane);
                let primary_lane = if existing > lane {
                    existing - 1
                } else {
                    existing
                };
                parent_lanes.resize(parent_ids.len(), 0);
                parent_lanes[primary_parent_index] = primary_lane;
            } else {
                lane_tips[lane] = first_parent;
                parent_lanes.resize(parent_ids.len(), 0);
                parent_lanes[primary_parent_index] = lane;
            }

            let parent_count = parent_ids.len();
            for (parent_index, parent) in parent_ids.into_iter().enumerate() {
                if parent_index == primary_parent_index {
                    continue;
                }
                if let Some(existing) = lane_tips.iter().position(|tip| *tip == parent) {
                    parent_lanes[parent_index] = existing;
                } else {
                    let inserted_before = (0..parent_count)
                        .take(parent_index)
                        .filter(|index| *index != primary_parent_index)
                        .count();
                    let insertion = (lane + 1 + inserted_before).min(lane_tips.len());
                    lane_tips.insert(insertion, parent);
                    parent_lanes[parent_index] = insertion;
                }
            }
        }

        commit.parent_lanes = parent_lanes.into_iter().map(|lane| lane as u32).collect();
    }
}

#[cfg(test)]
mod tests {
    use std::collections::{HashMap, HashSet};

    use super::{
        parse_commit_signature_record, reorder_commits_for_bek, CommitInfo, SignatureStatus,
    };

    fn synthetic_id(index: usize) -> String {
        format!("{index:040x}")
    }

    fn synthetic_commit(index: usize, parents: &[usize], time: i64) -> CommitInfo {
        CommitInfo {
            id: synthetic_id(index),
            repository_path: None,
            short_id: synthetic_id(index)[..7].to_string(),
            summary: index.to_string(),
            author_name: String::new(),
            author_email: String::new(),
            committer_name: String::new(),
            committer_email: String::new(),
            message_body: String::new(),
            has_signature: false,
            time,
            parent_ids: parents.iter().map(|parent| synthetic_id(*parent)).collect(),
            refs: Vec::new(),
            tag_refs: Vec::new(),
            remote_refs: Vec::new(),
            is_head: index == 0,
            lane: 0,
            parent_lanes: Vec::new(),
        }
    }

    #[test]
    fn parses_git_signature_codes_and_reasons() {
        let cases = [
            ("G", SignatureStatus::Valid, ""),
            ("B", SignatureStatus::Invalid, ""),
            ("U", SignatureStatus::Unknown, "unknown validity"),
            ("X", SignatureStatus::Unknown, "expired signature"),
            ("Y", SignatureStatus::Unknown, "expired signing key"),
            ("R", SignatureStatus::Unknown, "revoked signing key"),
            ("E", SignatureStatus::Unknown, "unable to verify signature"),
            ("N", SignatureStatus::None, ""),
        ];

        for (code, expected_status, expected_reason) in cases {
            let record = format!("ABC123\0{code}\0Signer\0FINGERPRINT");
            let parsed = parse_commit_signature_record(&record).expect("signature record");
            assert_eq!(parsed.commit_id, "abc123");
            assert_eq!(parsed.status, expected_status);
            assert_eq!(parsed.reason, expected_reason);
            assert_eq!(parsed.signer, "Signer");
            assert_eq!(parsed.fingerprint, "FINGERPRINT");
        }
    }

    #[test]
    fn unknown_git_signature_code_fails_closed_to_unknown() {
        let parsed = parse_commit_signature_record("abc\0?\0\0\0").expect("record");
        assert_eq!(parsed.status, SignatureStatus::Unknown);
        assert!(parsed.reason.contains("unknown Git signature status"));
    }

    #[test]
    fn bek_places_incoming_merge_branch_before_main_branch() {
        // Same topology as the reference fork's simpleMerge Bek test:
        // 0(1,2), 1(3), 2(4), 3(5), 4(5), 5().
        let mut commits = vec![
            synthetic_commit(0, &[1, 2], 600),
            synthetic_commit(1, &[3], 500),
            synthetic_commit(2, &[4], 400),
            synthetic_commit(3, &[5], 300),
            synthetic_commit(4, &[5], 200),
            synthetic_commit(5, &[], 100),
        ];
        let head_id = gix::hash::ObjectId::from_hex(synthetic_id(0).as_bytes()).unwrap();
        reorder_commits_for_bek(&mut commits, head_id, &HashSet::new());

        assert_eq!(
            commits
                .iter()
                .map(|commit| commit.summary.as_str())
                .collect::<Vec<_>>(),
            vec!["0", "2", "4", "1", "3", "5"]
        );
    }

    #[test]
    fn bek_preserves_topology_across_two_heads_and_a_merge() {
        let mut commits = vec![
            synthetic_commit(0, &[2, 3], 700),
            synthetic_commit(1, &[4], 600),
            synthetic_commit(2, &[4], 500),
            synthetic_commit(3, &[5], 400),
            synthetic_commit(4, &[6], 300),
            synthetic_commit(5, &[6], 200),
            synthetic_commit(6, &[], 100),
        ];
        let head_id = gix::hash::ObjectId::from_hex(synthetic_id(0).as_bytes()).unwrap();
        reorder_commits_for_bek(&mut commits, head_id, &HashSet::new());

        let positions: HashMap<_, _> = commits
            .iter()
            .enumerate()
            .map(|(position, commit)| (commit.id.as_str(), position))
            .collect();
        for commit in &commits {
            for parent in &commit.parent_ids {
                assert!(positions[commit.id.as_str()] < positions[parent.as_str()]);
            }
        }
    }
}
