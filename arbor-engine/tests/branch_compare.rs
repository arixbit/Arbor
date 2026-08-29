//! v0.9：分支 ahead/behind 比较。

mod common;

use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use arbor_engine::{EngineError, GitCancelHandle};
use common::TestRepo;

#[test]
fn compares_diverged_branches_in_both_directions() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    let feature = common::commit(&r.path, "feature.txt", "feature", "feature");

    r.git(&["switch", "-q", "main"]);
    let main = common::commit(&r.path, "main.txt", "main", "main");

    let repo = r.open();
    let feature_vs_main = repo
        .branch_compare("feature".into(), "main".into())
        .unwrap();
    assert_eq!(feature_vs_main.ahead, 1);
    assert_eq!(feature_vs_main.behind, 1);

    let main_vs_feature = repo
        .branch_compare("main".into(), "feature".into())
        .unwrap();
    assert_eq!(main_vs_feature.ahead, 1);
    assert_eq!(main_vs_feature.behind, 1);

    let same = repo.branch_compare(feature.clone(), feature).unwrap();
    assert_eq!(same.ahead, 0);
    assert_eq!(same.behind, 0);

    // The common base is not counted in either difference.
    let feature_vs_base = repo.branch_compare("feature".into(), base).unwrap();
    assert_eq!(feature_vs_base.ahead, 1);
    assert_eq!(feature_vs_base.behind, 0);

    let _ = main;
}

#[test]
fn compares_all_local_branches_in_one_graph_walk() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");

    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["merge", "--no-edit", "--no-ff", "feature"]);

    let repo = r.open();
    let all = repo.branch_compare_all().unwrap();
    let feature = all.iter().find(|entry| entry.name == "feature").unwrap();
    let single = repo
        .branch_compare("feature".into(), "main".into())
        .unwrap();
    assert_eq!(feature.ahead, single.ahead);
    assert_eq!(feature.behind, single.behind);

    let main = all.iter().find(|entry| entry.name == "main").unwrap();
    assert_eq!((main.ahead, main.behind), (0, 0));
}

#[test]
fn detects_only_non_empty_merge_commits_in_revision_range() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["merge", "--no-edit", "--no-ff", "feature"]);

    let repo = r.open();
    assert!(repo
        .has_non_empty_merge_commits_in_range(base.clone(), "HEAD".into())
        .unwrap());
    assert!(!repo
        .has_non_empty_merge_commits_in_range("HEAD".into(), "HEAD".into())
        .unwrap());
}

#[test]
fn ignores_noop_no_ff_merge_commits() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "shared.txt", "same", "feature");
    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "shared.txt", "same", "main");
    r.git(&["merge", "--no-edit", "--no-ff", "feature"]);

    let repo = r.open();
    assert!(!repo
        .has_non_empty_merge_commits_in_range(base, "HEAD".into())
        .unwrap());
}

#[test]
fn finds_cherry_picked_commits_by_patch_not_commit_message_or_id() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");

    r.git(&["switch", "-q", "-c", "feature"]);
    let picked = common::commit(&r.path, "picked.txt", "picked", "feature message");
    common::commit(
        &r.path,
        "unpicked.txt",
        "unpicked",
        "another feature message",
    );

    r.git(&["switch", "-q", "main"]);
    common::commit(&r.path, "picked.txt", "picked", "different target message");
    let repo = r.open();
    let before = repo.head_commit_id();

    let picked_ids = repo
        .cherry_picked_commits("feature".into(), "main".into())
        .unwrap();

    assert_eq!(picked_ids, vec![picked]);
    assert_eq!(repo.head_commit_id(), before);
    assert!(repo.status().unwrap().is_empty());
}

#[cfg(unix)]
#[test]
fn cancelled_cherry_picked_comparison_kills_the_git_process_group() {
    use std::os::unix::fs::PermissionsExt;

    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");

    let real_git = String::from_utf8(
        Command::new("sh")
            .args(["-c", "command -v git"])
            .output()
            .expect("find git")
            .stdout,
    )
    .expect("git path is utf-8")
    .trim()
    .to_string();
    let wrapper = r.path.join("slow-git-wrapper");
    std::fs::write(
        &wrapper,
        format!(
            "#!/bin/sh\nif [ \"$1\" = \"cherry\" ]; then sleep 30; exit 0; fi\nexec '{}' \"$@\"\n",
            real_git
        ),
    )
    .expect("write slow Git wrapper");
    let mut permissions = std::fs::metadata(&wrapper)
        .expect("wrapper metadata")
        .permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(&wrapper, permissions).expect("make wrapper executable");

    let repo = r.open();
    repo.set_git_executable_override(Some(wrapper.display().to_string()))
        .expect("set repository Git wrapper");
    let cancel = GitCancelHandle::new();
    let worker_repo = repo.clone();
    let worker_cancel = cancel.clone();
    let worker = std::thread::spawn(move || {
        worker_repo.cherry_picked_commits_with_cancel("main".into(), "main".into(), worker_cancel)
    });

    std::thread::sleep(Duration::from_millis(200));
    cancel.cancel();
    let result = worker.join().expect("comparison worker");
    assert!(matches!(result, Err(EngineError::Cancelled)));
}

/// 手动性能门：用 fast-import 构造 50k 线性历史，避免 50k 次 git 进程启动。
#[test]
#[ignore = "manual v0.11 performance gate"]
fn compares_all_50k_history() {
    let r = TestRepo::new();
    let mut stream = String::from("commit refs/heads/main\nmark :1\nauthor Arbor Test <test@arbor.local> 0 +0000\ncommitter Arbor Test <test@arbor.local> 0 +0000\ndata 4\nbase\nM 100644 inline file.txt\ndata 5\nbase\n");
    for index in 2..=50_001 {
        let parent = index - 1;
        let message = format!("commit {index}");
        stream.push_str(&format!(
            "commit refs/heads/main\nmark :{index}\nauthor Arbor Test <test@arbor.local> 0 +0000\ncommitter Arbor Test <test@arbor.local> 0 +0000\ndata {}\n{}\nfrom :{parent}\n",
            message.len(),
            message,
        ));
    }
    stream.push_str("done\n");
    let mut child = Command::new("git")
        .args(["fast-import"])
        .current_dir(&r.path)
        .stdin(Stdio::piped())
        .spawn()
        .expect("git fast-import");
    std::io::Write::write_all(
        child.stdin.as_mut().expect("fast-import stdin"),
        stream.as_bytes(),
    )
    .expect("write fast-import stream");
    drop(child.stdin.take());
    let status = child.wait().expect("wait for fast-import");
    assert!(status.success(), "fast-import failed: {status}");

    let repo = r.open();
    let started = Instant::now();
    let result = repo.branch_compare_all().expect("branch compare all");
    let elapsed = started.elapsed();
    println!("branch_compare_all: 50,000 commits in {elapsed:?}");
    assert_eq!(result.len(), 1);
    assert_eq!(result[0].ahead, 0);
    assert_eq!(result[0].behind, 0);
}
