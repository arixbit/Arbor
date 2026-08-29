//! 分支管理：列表、分支可达性比较，以及 refs 事务薄封装。

use std::collections::{HashMap, HashSet, VecDeque};

use gix::bstr::ByteSlice;

use crate::error::EngineError;
use crate::log::{boxed_err, shorten_ref_name};

/// 一条分支。
#[derive(uniffi::Record, Clone, Debug)]
pub struct BranchInfo {
    pub name: String,
    pub is_current: bool,
    pub short_id: String,
    pub last_commit_time: i64,
}

/// Branches whose commits exclusive to the ref are all authored by the
/// configured Git user. IntelliJ uses this to implement Show My Branches.
#[derive(uniffi::Record, Clone, Debug, Default)]
pub struct MyBranchNames {
    pub local: Vec<String>,
    pub remote: Vec<String>,
}

/// A commit that would be lost from the local ref when an unmerged branch is
/// force-deleted. Kept deliberately smaller than `CommitInfo`: the delete
/// confirmation and recovery sheet only need an exact id and its title.
#[derive(uniffi::Record, Clone, Debug)]
pub struct BranchDeleteCommit {
    pub id: String,
    pub short_id: String,
    pub summary: String,
    pub time: i64,
}

/// Snapshot captured before a force deletion so the UI can offer the same
/// recovery path as IntelliJ: inspect unmerged commits, then restore the ref
/// at its exact old tip (and its configured upstream when possible).
#[derive(uniffi::Record, Clone, Debug)]
pub struct BranchDeletePreview {
    pub branch_name: String,
    pub tip_id: String,
    pub upstream: Option<String>,
    pub base_branches: Vec<String>,
    pub unmerged_commits: Vec<BranchDeleteCommit>,
}

/// 一条 remote-tracking 分支；名称保留 `origin/main` 这种可直接用于 revision 的形式。
#[derive(uniffi::Record, Clone, Debug)]
pub struct RemoteBranchInfo {
    pub name: String,
    pub remote: String,
    pub short_id: String,
}

/// 本地分支相对其 configured upstream 的同步状态。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct SyncStatus {
    pub branch: String,
    pub upstream: String,
    pub ahead: u32,
    pub behind: u32,
    pub tracking_exists: bool,
}

/// 两个 revision 的可达提交数量差异。
///
/// `ahead` 是 `a` 可达但 `b` 不可达的提交数；`behind` 是反向差集。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct BranchCompare {
    pub ahead: u32,
    pub behind: u32,
}

/// 相对当前 HEAD 的一条分支比较结果。
#[derive(uniffi::Record, Clone, Debug, PartialEq, Eq)]
pub struct BranchCompareEntry {
    pub name: String,
    pub ahead: u32,
    pub behind: u32,
}

/// 一条 Git tag；kind 区分轻量、annotated 和签名 tag。
#[derive(uniffi::Record, Clone, Debug)]
pub struct TagInfo {
    pub name: String,
    /// The peeled object id the tag resolves to. Keeping the full id lets the
    /// UI restore a deleted tag without relying on reflog retention.
    pub id: String,
    /// The object id stored directly in refs/tags/<name>. For annotated and
    /// signed tags this is the tag object, not the peeled commit, and is the
    /// value required by a remote deletion lease.
    pub object_id: String,
    pub short_id: String,
    pub kind: TagKind,
    pub message: String,
    pub is_current: bool,
}

/// A tag read directly from a remote. `object_id` is the ref value used for
/// the delete lease; `id` is the peeled target used for display.
#[derive(uniffi::Record, Clone, Debug)]
pub struct RemoteTagInfo {
    pub remote: String,
    pub name: String,
    pub object_id: String,
    pub id: String,
    pub short_id: String,
    pub kind: TagKind,
}

#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TagKind {
    Lightweight,
    Annotated,
    Signed,
}

/// 列出本地分支（当前分支标记 + 指向提交的短 id）。
pub(crate) fn list_branches(repo: &gix::Repository) -> Result<Vec<BranchInfo>, EngineError> {
    let head_name = repo.head_name().map_err(EngineError::from_gix)?;
    let platform = repo.references().map_err(EngineError::from_gix)?;
    let mut out = Vec::new();
    for r in platform
        .local_branches()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let r = r.map_err(boxed_err)?;
        if let Some(id) = r.try_id() {
            let id = id.detach();
            let name = shorten_ref_name(r.name().as_bstr());
            let is_current = head_name
                .as_ref()
                .map(|h| h.as_bstr() == r.name().as_bstr())
                .unwrap_or(false);
            let last_commit_time = repo
                .find_commit(id)
                .ok()
                .and_then(|commit| commit.time().ok().map(|time| time.seconds))
                .unwrap_or(0);
            out.push(BranchInfo {
                name,
                is_current,
                short_id: id.to_hex().to_string().chars().take(7).collect(),
                last_commit_time,
            });
        }
    }
    Ok(out)
}

/// 列出 tip 已合并入当前 HEAD 的所有 branch refs。
///
/// IntelliJ 的 Merge Dialog 使用 `git branch --all --no-merged` 做反向校验，
/// 因此这里必须同时覆盖本地分支和 remote-tracking 分支；远端的 symbolic
/// `*/HEAD` 只用于展示默认分支，不是可合并的用户分支，予以排除。
pub(crate) fn list_all_merged_branches(
    repo: &gix::Repository,
) -> Result<Vec<BranchInfo>, EngineError> {
    let head_name = repo.head_name().map_err(EngineError::from_gix)?;
    if repo.head().map_err(EngineError::from_gix)?.is_unborn() {
        return Ok(Vec::new());
    }
    let head_id = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .id()
        .detach();
    let reachable = reachable_commits(repo, head_id)?;
    let platform = repo.references().map_err(EngineError::from_gix)?;
    let mut out = Vec::new();

    for reference in platform
        .local_branches()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let reference = reference.map_err(boxed_err)?;
        let id = reference.try_id().map(|id| id.detach());
        append_merged_branch(
            repo,
            &head_name,
            &reachable,
            reference.name().as_bstr(),
            false,
            id,
            &mut out,
        );
    }
    for reference in platform
        .remote_branches()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let reference = reference.map_err(boxed_err)?;
        let name = shorten_ref_name(reference.name().as_bstr());
        let is_symbolic_remote_head = name
            .split_once('/')
            .is_some_and(|(_, branch)| branch == "HEAD");
        if is_symbolic_remote_head {
            continue;
        }
        append_merged_branch(
            repo,
            &head_name,
            &reachable,
            reference.name().as_bstr(),
            true,
            reference.try_id().map(|id| id.detach()),
            &mut out,
        );
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

fn append_merged_branch(
    repo: &gix::Repository,
    head_name: &Option<gix::refs::FullName>,
    reachable: &HashSet<gix::hash::ObjectId>,
    full_name: &gix::bstr::BStr,
    is_remote: bool,
    id: Option<gix::hash::ObjectId>,
    output: &mut Vec<BranchInfo>,
) {
    let Some(id) = id else {
        return;
    };
    if !reachable.contains(&id) {
        return;
    }
    let name = shorten_ref_name(full_name);
    let is_current = !is_remote
        && head_name
            .as_ref()
            .map(|head| head.as_bstr() == full_name)
            .unwrap_or(false);
    let last_commit_time = repo
        .find_commit(id)
        .ok()
        .and_then(|commit| commit.time().ok().map(|time| time.seconds))
        .unwrap_or(0);
    output.push(BranchInfo {
        name,
        is_current,
        short_id: id.to_hex().to_string().chars().take(7).collect(),
        last_commit_time,
    });
}

/// Find local and remote branches whose exclusive commits are all authored by
/// the current Git identity. A branch with no exclusive commits is not a
/// "my branch", matching IntelliJ's `isMyBranch` semantics.
pub(crate) fn list_my_branches(repo: &gix::Repository) -> Result<MyBranchNames, EngineError> {
    let config = repo.config_snapshot();
    let user_name = config
        .string("user.name")
        .map(|value| value.to_string())
        .filter(|value| !value.trim().is_empty());
    let user_email = config
        .string("user.email")
        .map(|value| value.to_string())
        .filter(|value| !value.trim().is_empty());
    if user_name.is_none() && user_email.is_none() {
        return Ok(MyBranchNames::default());
    }

    let mut branch_refs: Vec<(bool, String, gix::hash::ObjectId)> = Vec::new();
    {
        let platform = repo.references().map_err(EngineError::from_gix)?;
        for item in platform
            .local_branches()
            .map_err(EngineError::from_gix)?
            .peeled()
            .map_err(EngineError::from_gix)?
        {
            let reference = item.map_err(boxed_err)?;
            if let Some(id) = reference.try_id() {
                branch_refs.push((
                    false,
                    shorten_ref_name(reference.name().as_bstr()),
                    id.detach(),
                ));
            }
        }
        for item in platform
            .remote_branches()
            .map_err(EngineError::from_gix)?
            .peeled()
            .map_err(EngineError::from_gix)?
        {
            let reference = item.map_err(boxed_err)?;
            let Some(id) = reference.try_id() else {
                continue;
            };
            let name = shorten_ref_name(reference.name().as_bstr());
            if name.ends_with("/HEAD") {
                continue;
            }
            branch_refs.push((true, name, id.detach()));
        }
    }

    let reachable = branch_refs
        .iter()
        .map(|(_, _, id)| reachable_commits(repo, *id))
        .collect::<Result<Vec<_>, _>>()?;
    let mut result = MyBranchNames::default();

    for (index, (is_remote, name, _)) in branch_refs.iter().enumerate() {
        let mut reachable_from_other_refs = HashSet::new();
        for (other_index, commits) in reachable.iter().enumerate() {
            // A local branch and its remote-tracking ref can point at the
            // same tip. Treat those refs as aliases; otherwise every branch
            // with a freshly fetched upstream would lose all exclusivity.
            if other_index != index && branch_refs[other_index].2 != branch_refs[index].2 {
                reachable_from_other_refs.extend(commits);
            }
        }
        let exclusive = reachable[index]
            .difference(&reachable_from_other_refs)
            .copied()
            .collect::<Vec<_>>();
        if exclusive.is_empty() {
            continue;
        }

        let mut all_authored_by_user = true;
        for id in exclusive {
            let Ok(commit) = repo.find_commit(id) else {
                all_authored_by_user = false;
                break;
            };
            let Ok(author) = commit.author() else {
                all_authored_by_user = false;
                break;
            };
            let author_name = author.name.to_str_lossy().trim().to_string();
            let author_email = author.email.to_str_lossy().trim().to_string();
            let matches_name = user_name
                .as_deref()
                .is_some_and(|value| value.trim().eq_ignore_ascii_case(&author_name));
            let matches_email = user_email
                .as_deref()
                .is_some_and(|value| value.trim().eq_ignore_ascii_case(&author_email));
            if !matches_name && !matches_email {
                all_authored_by_user = false;
                break;
            }
        }
        if !all_authored_by_user {
            continue;
        }
        if *is_remote {
            result.remote.push(name.clone());
        } else {
            result.local.push(name.clone());
        }
    }

    result.local.sort();
    result.remote.sort();
    Ok(result)
}

/// 列出 remote-tracking refs，不把它们混进本地 checkout 分支列表。
pub(crate) fn list_remote_branches(
    repo: &gix::Repository,
) -> Result<Vec<RemoteBranchInfo>, EngineError> {
    let platform = repo.references().map_err(EngineError::from_gix)?;
    let mut out = Vec::new();
    for item in platform
        .remote_branches()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let reference = item.map_err(boxed_err)?;
        let Some(id) = reference.try_id() else {
            continue;
        };
        let name = shorten_ref_name(reference.name().as_bstr());
        let Some((remote, branch)) = name.split_once('/') else {
            continue;
        };
        if branch == "HEAD" {
            continue;
        }
        out.push(RemoteBranchInfo {
            name: name.clone(),
            remote: remote.to_string(),
            short_id: id.detach().to_hex().to_string().chars().take(7).collect(),
        });
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

/// Return a stable, full-object-id snapshot of the refs that can affect the
/// VCS Log decoration. Display models intentionally expose seven-character
/// ids, but cache invalidation must not rely on those potentially colliding
/// prefixes.
pub(crate) fn ref_tip_snapshot(repo: &gix::Repository) -> Result<Vec<String>, EngineError> {
    let head_name = repo.head_name().map_err(EngineError::from_gix)?;
    let head_id = repo.head_id().ok().map(|id| id.detach());
    let platform = repo.references().map_err(EngineError::from_gix)?;
    let mut out = Vec::new();

    for item in platform
        .local_branches()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let reference = item.map_err(boxed_err)?;
        let Some(id) = reference.try_id().map(|id| id.detach()) else {
            continue;
        };
        let name = shorten_ref_name(reference.name().as_bstr());
        let is_current = head_name
            .as_ref()
            .map(|head| head.as_bstr() == reference.name().as_bstr())
            .unwrap_or(false);
        out.push(format!(
            "local\u{1f}{name}\u{1f}{}\u{1f}{is_current}",
            id.to_hex()
        ));
    }

    for item in platform
        .remote_branches()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let reference = item.map_err(boxed_err)?;
        let Some(id) = reference.try_id().map(|id| id.detach()) else {
            continue;
        };
        let name = shorten_ref_name(reference.name().as_bstr());
        let Some((remote, branch)) = name.split_once('/') else {
            continue;
        };
        if branch == "HEAD" {
            continue;
        }
        out.push(format!(
            "remote\u{1f}{name}\u{1f}{remote}\u{1f}{}",
            id.to_hex()
        ));
    }

    for item in platform.tags().map_err(EngineError::from_gix)? {
        let reference = item.map_err(boxed_err)?;
        let Some(raw_id) = reference.try_id().map(|id| id.detach()) else {
            continue;
        };
        let id = match repo.find_tag(raw_id) {
            Ok(tag) => tag.decode().map_err(EngineError::from_gix)?.target(),
            Err(_) => raw_id,
        };
        let name = shorten_ref_name(reference.name().as_bstr());
        let is_current = head_id == Some(id);
        out.push(format!(
            "tag\u{1f}{name}\u{1f}{}\u{1f}{is_current}",
            id.to_hex()
        ));
    }

    out.sort();
    Ok(out)
}

/// 计算所有配置了 upstream 的本地分支同步状态。
pub(crate) fn sync_statuses(repo: &gix::Repository) -> Result<Vec<SyncStatus>, EngineError> {
    let config_path = repo.git_dir().join("config");
    let config = gix::config::File::from_path_no_includes(config_path, gix::config::Source::Local)
        .map_err(EngineError::from_gix)?;
    let platform = repo.references().map_err(EngineError::from_gix)?;
    let mut out = Vec::new();
    for item in platform
        .local_branches()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let reference = item.map_err(boxed_err)?;
        let Some(local_id) = reference.try_id().map(|id| id.detach()) else {
            continue;
        };
        let branch = shorten_ref_name(reference.name().as_bstr());
        let remote_key = format!("branch.{branch}.remote");
        let merge_key = format!("branch.{branch}.merge");
        let Some(remote) = config.string(&remote_key).map(|v| v.to_string()) else {
            continue;
        };
        let Some(merge) = config.string(&merge_key).map(|v| v.to_string()) else {
            continue;
        };
        let upstream_branch = merge
            .strip_prefix("refs/heads/")
            .unwrap_or(merge.as_str())
            .trim_start_matches('/')
            .to_string();
        if upstream_branch.is_empty() {
            continue;
        }
        let upstream = if remote == "." {
            upstream_branch.clone()
        } else {
            format!("{remote}/{upstream_branch}")
        };
        let tracking_ref = if remote == "." {
            format!("refs/heads/{upstream_branch}")
        } else {
            format!("refs/remotes/{remote}/{upstream_branch}")
        };
        let Some(upstream_id) = repo
            .rev_parse_single(gix::bstr::BStr::new(tracking_ref.as_bytes()))
            .ok()
            .map(|id| id.detach())
        else {
            out.push(SyncStatus {
                branch,
                upstream,
                ahead: 0,
                behind: 0,
                tracking_exists: false,
            });
            continue;
        };
        let local_reachable = reachable_commits(repo, local_id)?;
        let upstream_reachable = reachable_commits(repo, upstream_id)?;
        out.push(SyncStatus {
            branch,
            upstream,
            ahead: local_reachable.difference(&upstream_reachable).count() as u32,
            behind: upstream_reachable.difference(&local_reachable).count() as u32,
            tracking_exists: true,
        });
    }
    out.sort_by(|a, b| a.branch.cmp(&b.branch));
    Ok(out)
}

/// 比较任意两个 revision（branch、tag 或 commit id）的可达提交集合。
pub(crate) fn compare_branches(
    repo: &gix::Repository,
    a: &str,
    b: &str,
) -> Result<BranchCompare, EngineError> {
    let a_id = repo
        .rev_parse_single(gix::bstr::BStr::new(a.as_bytes()))
        .map_err(EngineError::from_gix)?
        .detach();
    let b_id = repo
        .rev_parse_single(gix::bstr::BStr::new(b.as_bytes()))
        .map_err(EngineError::from_gix)?
        .detach();

    let reachable_a = reachable_commits(repo, a_id)?;
    let reachable_b = reachable_commits(repo, b_id)?;
    Ok(BranchCompare {
        ahead: reachable_a.difference(&reachable_b).count() as u32,
        behind: reachable_b.difference(&reachable_a).count() as u32,
    })
}

/// 一次反向多源遍历计算所有本地分支相对 HEAD 的 ahead/behind。
///
/// 每个提交携带一个 source bitset：某个 bit 被置位表示该分支/HEAD 可以
/// 到达它。沿父边传播并合并 bitset 后，差集计数与逐分支 reachable 集合
/// 完全一致，同时避免 UI 为每条分支启动一次 rev walk。
pub(crate) fn compare_branches_all(
    repo: &gix::Repository,
) -> Result<Vec<BranchCompareEntry>, EngineError> {
    let platform = repo.references().map_err(EngineError::from_gix)?;
    let mut branches: Vec<(String, gix::hash::ObjectId)> = Vec::new();
    for item in platform
        .local_branches()
        .map_err(EngineError::from_gix)?
        .peeled()
        .map_err(EngineError::from_gix)?
    {
        let reference = item.map_err(boxed_err)?;
        if let Some(id) = reference.try_id() {
            branches.push((shorten_ref_name(reference.name().as_bstr()), id.detach()));
        }
    }
    branches.sort_by(|a, b| a.0.cmp(&b.0));

    let head_id = repo
        .head_commit()
        .map_err(EngineError::from_gix)?
        .id()
        .detach();
    let source_count = branches.len() + 1;
    let words = source_count.div_ceil(64);
    let head_bit = branches.len();
    let mut masks: HashMap<gix::hash::ObjectId, Vec<u64>> = HashMap::new();
    let mut queue = VecDeque::new();

    let mut seed = |id: gix::hash::ObjectId, bit: usize| {
        let mask = masks.entry(id).or_insert_with(|| vec![0; words]);
        let word = bit / 64;
        let flag = 1u64 << (bit % 64);
        if mask[word] & flag == 0 {
            mask[word] |= flag;
            queue.push_back(id);
        }
    };
    seed(head_id, head_bit);
    for (index, (_, id)) in branches.iter().enumerate() {
        seed(*id, index);
    }

    while let Some(id) = queue.pop_front() {
        let mask = masks.get(&id).cloned().unwrap_or_default();
        let commit = repo.find_commit(id).map_err(EngineError::from_gix)?;
        for parent in commit.parent_ids() {
            let parent_id = parent.detach();
            let entry = masks.entry(parent_id).or_insert_with(|| vec![0; words]);
            let mut changed = false;
            for (index, word) in mask.iter().enumerate() {
                let merged = entry[index] | word;
                changed |= merged != entry[index];
                entry[index] = merged;
            }
            if changed {
                queue.push_back(parent_id);
            }
        }
    }

    let mut result = Vec::with_capacity(branches.len());
    for (index, (name, _)) in branches.into_iter().enumerate() {
        let word = index / 64;
        let branch_flag = 1u64 << (index % 64);
        let head_flag = 1u64 << (head_bit % 64);
        let mut ahead = 0u32;
        let mut behind = 0u32;
        for mask in masks.values() {
            let branch_reaches = mask[word] & branch_flag != 0;
            let head_reaches = mask[head_bit / 64] & head_flag != 0;
            match (branch_reaches, head_reaches) {
                (true, false) => ahead += 1,
                (false, true) => behind += 1,
                _ => {}
            }
        }
        result.push(BranchCompareEntry {
            name,
            ahead,
            behind,
        });
    }
    Ok(result)
}

fn reachable_commits(
    repo: &gix::Repository,
    start: gix::hash::ObjectId,
) -> Result<HashSet<gix::hash::ObjectId>, EngineError> {
    let walk = repo
        .rev_walk([start])
        .all()
        .map_err(EngineError::from_gix)?;
    let mut reachable = HashSet::new();
    for item in walk {
        reachable.insert(item.map_err(EngineError::from_gix)?.id);
    }
    Ok(reachable)
}

pub(crate) fn list_tags(repo: &gix::Repository) -> Result<Vec<TagInfo>, EngineError> {
    let platform = repo.references().map_err(EngineError::from_gix)?;
    let mut out = Vec::new();
    for r in platform.tags().map_err(EngineError::from_gix)? {
        let r = r.map_err(boxed_err)?;
        let Some(raw_id) = r.try_id().map(|id| id.detach()) else {
            continue;
        };
        let (id, kind, message) = match repo.find_tag(raw_id) {
            Ok(tag) => {
                let decoded = tag.decode().map_err(EngineError::from_gix)?;
                let kind = if decoded.pgp_signature.is_some() {
                    TagKind::Signed
                } else {
                    TagKind::Annotated
                };
                (
                    decoded.target(),
                    kind,
                    decoded.message.to_str_lossy().trim().to_string(),
                )
            }
            Err(_) => (raw_id, TagKind::Lightweight, String::new()),
        };
        out.push(TagInfo {
            name: shorten_ref_name(r.name().as_bstr()),
            id: id.to_hex().to_string(),
            object_id: raw_id.to_hex().to_string(),
            short_id: id.to_hex().to_string().chars().take(7).collect(),
            kind,
            message,
            is_current: repo
                .head_id()
                .map(|head| head.detach() == id)
                .unwrap_or(false),
        });
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}
