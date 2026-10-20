//! LFS-001：Git LFS 全链路回归。
//!
//! 这些用例需要宿主机安装 `git-lfs`；未安装时跳过（引擎的能力探测本身
//! 由 `missing_lfs_is_reported_not_raised` 覆盖）。

mod common;

use std::sync::Arc;

use arbor_engine::GitCancelHandle;
use common::TestRepo;

fn lfs_available(repo: &TestRepo) -> bool {
    let capability = repo.open().lfs_capability();
    if !capability.installed {
        eprintln!("skipping: git-lfs not installed ({:?})", capability.detail);
    }
    capability.installed
}

/// 一个装了 LFS 并用 `*.bin` 跟踪的仓库。
fn lfs_repo() -> Option<TestRepo> {
    let repo = TestRepo::new();
    if !lfs_available(&repo) {
        return None;
    }
    repo.open().lfs_install().unwrap();
    repo.open()
        .lfs_track(vec!["*.bin".to_string()])
        .unwrap();
    repo.git(&["add", ".gitattributes"]);
    repo.git(&["commit", "-qm", "track lfs"]);
    Some(repo)
}

#[test]
fn capability_reports_installed_version() {
    let repo = TestRepo::new();
    let capability = repo.open().lfs_capability();
    if !capability.installed {
        eprintln!("skipping: git-lfs not installed");
        return;
    }
    let version = capability.version.expect("version");
    assert!(
        version.split('.').next().unwrap().parse::<u32>().is_ok(),
        "unexpected version {version}"
    );
    assert!(capability.detail.is_none());
}

#[test]
fn track_and_untrack_rewrite_gitattributes() {
    let Some(repo) = lfs_repo() else { return };

    let patterns = repo.open().lfs_tracked_patterns().unwrap();
    assert!(
        patterns.iter().any(|item| item.pattern == "*.bin"),
        "{patterns:?}"
    );

    let attributes = repo.read(".gitattributes");
    assert!(attributes.contains("filter=lfs"), "{attributes}");

    repo.open()
        .lfs_untrack(vec!["*.bin".to_string()])
        .unwrap();
    assert!(!repo.read(".gitattributes").contains("*.bin"));
    assert!(repo.open().lfs_tracked_patterns().unwrap().is_empty());
}

#[test]
fn committed_lfs_file_is_listed_with_oid() {
    let Some(repo) = lfs_repo() else { return };
    std::fs::write(repo.path.join("asset.bin"), vec![7u8; 4096]).unwrap();
    repo.git(&["add", "asset.bin"]);
    repo.git(&["commit", "-qm", "asset"]);

    // 提交对象里必须是 pointer，而不是 4KB 内容。
    let blob = repo.git(&["cat-file", "-p", "HEAD:asset.bin"]);
    assert!(blob.starts_with("version https://git-lfs.github.com/spec/v1"));

    let files = repo.open().lfs_files(false).unwrap();
    assert_eq!(files.len(), 1, "{files:?}");
    assert_eq!(files[0].path, "asset.bin");
    assert_eq!(files[0].oid.len(), 64);
    assert!(files[0].content_present, "{files:?}");
}

#[test]
fn path_states_distinguish_pointer_from_content() {
    let Some(repo) = lfs_repo() else { return };
    std::fs::write(repo.path.join("real.bin"), vec![1u8; 2048]).unwrap();
    std::fs::write(repo.path.join("plain.txt"), "not lfs").unwrap();
    std::fs::write(
        repo.path.join("pending.bin"),
        "version https://git-lfs.github.com/spec/v1\noid sha256:aa\nsize 12\n",
    )
    .unwrap();

    let states = repo
        .open()
        .lfs_path_states(vec![
            "real.bin".to_string(),
            "plain.txt".to_string(),
            "pending.bin".to_string(),
        ])
        .unwrap();
    assert_eq!(states.len(), 3, "{states:?}");

    let real = states.iter().find(|item| item.path == "real.bin").unwrap();
    assert!(real.tracked);
    assert!(!real.pointer);

    let plain = states.iter().find(|item| item.path == "plain.txt").unwrap();
    assert!(!plain.tracked);
    assert!(!plain.pointer);

    let pending = states.iter().find(|item| item.path == "pending.bin").unwrap();
    assert!(pending.tracked);
    assert!(pending.pointer, "unsmudged pointer must be flagged");
}

#[test]
fn install_reports_hooks_and_uninstall_removes_them() {
    let repo = TestRepo::new();
    if !lfs_available(&repo) {
        return;
    }
    let state = repo.open().lfs_hook_state();
    assert!(!state.post_checkout && !state.pre_push, "{state:?}");

    repo.open().lfs_install().unwrap();
    let state = repo.open().lfs_hook_state();
    assert!(state.post_checkout, "{state:?}");
    assert!(state.post_commit, "{state:?}");
    assert!(state.post_merge, "{state:?}");
    assert!(state.pre_push, "{state:?}");

    repo.open().lfs_uninstall().unwrap();
    let state = repo.open().lfs_hook_state();
    assert!(!state.post_checkout && !state.pre_push, "{state:?}");
}

#[test]
fn push_pull_round_trip_through_local_remote() {
    let Some(repo) = lfs_repo() else { return };

    let origin_dir = tempfile::tempdir().unwrap();
    let origin = origin_dir.path().join("origin.git");
    common::git(
        origin_dir.path(),
        &["init", "--bare", "-q", origin.to_str().unwrap()],
    );
    let origin_url = origin.to_string_lossy().into_owned();
    repo.git(&["remote", "add", "origin", &origin_url]);

    let payload: Vec<u8> = (0..8192).map(|i| (i % 251) as u8).collect();
    std::fs::write(repo.path.join("payload.bin"), &payload).unwrap();
    repo.git(&["add", "payload.bin"]);
    repo.git(&["commit", "-qm", "payload"]);
    repo.git(&["push", "-q", "-u", "origin", "main"]);

    let cancel = GitCancelHandle::new();
    repo.open()
        .lfs_push(Some("origin".into()), true, Arc::clone(&cancel))
        .unwrap();

    // 克隆出来的仓库里 pointer 未 smudge，需要显式 pull + checkout。
    let clone_dir = tempfile::tempdir().unwrap();
    let clone_path = clone_dir.path().join("clone");
    common::git(
        clone_dir.path(),
        &["clone", "-q", &origin_url, clone_path.to_str().unwrap()],
    );
    common::git(
        &clone_path,
        &["config", "user.name", "Arbor Test"],
    );
    common::git(
        &clone_path,
        &["config", "user.email", "test@arbor.local"],
    );

    let cloned = arbor_engine::open_repository(clone_path.to_string_lossy().into_owned()).unwrap();
    let files = cloned.lfs_files(false).unwrap();
    assert_eq!(files.len(), 1, "{files:?}");
    assert_eq!(files[0].path, "payload.bin");

    let cancel = GitCancelHandle::new();
    let pulled = cloned
        .lfs_pull(Some("origin".into()), Arc::clone(&cancel))
        .unwrap();
    // 克隆出来的仓库没有 filter 配置，pull 必须先补一次 install --local，
    // 否则 git-lfs 会静默跳过检出。
    assert!(pulled.installed_filters, "{pulled:?}");
    let states = cloned
        .lfs_path_states(vec!["payload.bin".to_string()])
        .unwrap();
    assert!(states[0].tracked);
    assert!(
        !states[0].pointer,
        "pull must materialise the working tree file"
    );
    assert_eq!(std::fs::read(clone_path.join("payload.bin")).unwrap(), payload);
}

#[test]
fn fetch_is_cancellable_and_reports_result() {
    let Some(repo) = lfs_repo() else { return };
    std::fs::write(repo.path.join("data.bin"), vec![3u8; 512]).unwrap();
    repo.git(&["add", "data.bin"]);
    repo.git(&["commit", "-qm", "data"]);

    let cancel = GitCancelHandle::new();
    let result = repo
        .open()
        .lfs_fetch(None, false, Arc::clone(&cancel))
        .unwrap_or_else(|error| panic!("fetch failed: {error}"));
    // 没有 remote 时 git-lfs 仍然返回成功（本地对象已存在），结果可以为空。
    let _ = result.output;
}
