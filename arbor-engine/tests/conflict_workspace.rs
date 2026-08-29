//! CONFLICT-001：统一冲突工作台。
//! 从 merge / rebase / cherry-pick / revert 进入同一工作台；文件级
//! accept ours/theirs/both、mark resolved、reset；binary 降级提示。

mod common;

use arbor_engine::{FilePick, GitCancelHandle, OperationKind, RebaseAction, RebasePauseReason};
use common::TestRepo;

/// 三方冲突 fixture：base -> main/feature 各改同一行。
fn conflicted_pair(r: &TestRepo) {
    common::commit(&r.path, "file.txt", "line1\nbase\nline3", "base");
    r.git(&["branch", "feature"]);
    r.write("file.txt", "line1\nours\nline3");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("file.txt", "line1\ntheirs\nline3");
    r.git(&["add", "file.txt"]);
    r.git(&["commit", "-q", "-m", "theirs"]);
    r.git(&["checkout", "-q", "main"]);
}

/// 两个独立冲突文件，用于验证文件级操作不会覆盖同一操作中的其他路径。
fn conflicted_pair_two_files(r: &TestRepo) {
    common::commit(&r.path, "one.txt", "base-one", "base one");
    r.write("two.txt", "base-two");
    r.git(&["add", "two.txt"]);
    r.git(&["commit", "-q", "-m", "base two"]);
    r.git(&["branch", "feature"]);
    r.write("one.txt", "ours-one");
    r.write("two.txt", "ours-two");
    r.git(&["add", "one.txt", "two.txt"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("one.txt", "theirs-one");
    r.write("two.txt", "theirs-two");
    r.git(&["add", "one.txt", "two.txt"]);
    r.git(&["commit", "-q", "-m", "theirs"]);
    r.git(&["checkout", "-q", "main"]);
}

#[test]
fn workspace_from_merge_operation() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);

    let repo = r.open();
    let ws = repo.conflict_workspace().expect("workspace");
    assert_eq!(ws.operation, Some(OperationKind::Merge));
    assert_eq!(ws.files.len(), 1);
    let file = &ws.files[0];
    assert_eq!(file.path, "file.txt");
    assert!(!file.binary);
    // 四方内容齐备
    assert!(file.file.base.contains("base"));
    assert!(file.file.ours.contains("ours"));
    assert!(file.file.theirs.contains("theirs"));
    assert!(file.file.result.contains("<<<<<<<"));
    // 块级数据可驱动块操作
    assert_eq!(file.file.blocks.len(), 1);
}

#[test]
fn external_merge_tool_resolves_and_rescans_index() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);

    // Use Git's configured mergetool command itself; the engine must not
    // interpolate the tool command or bypass Git's $BASE/$LOCAL/$REMOTE/$MERGED
    // environment contract.
    r.git(&["config", "merge.tool", "arbor-test"]);
    r.git(&[
        "config",
        "mergetool.arbor-test.cmd",
        "cp \"$LOCAL\" \"$MERGED\"",
    ]);
    r.git(&["config", "mergetool.arbor-test.trustExitCode", "true"]);
    r.git(&["config", "mergetool.prompt", "false"]);
    r.git(&["config", "mergetool.keepBackup", "false"]);

    let repo = r.open();
    let result = repo
        .open_external_merge_tool("file.txt".into())
        .expect("external merge tool");
    assert_eq!(result.path, "file.txt");
    assert_eq!(result.tool, "arbor-test");
    assert!(result.resolved, "result: {result:?}");
    assert!(result.remaining_conflicts.is_empty());
    assert!(r.read("file.txt").contains("ours"));
    assert!(repo.conflict_workspace().unwrap().files.is_empty());
}

#[test]
fn external_merge_tool_failure_reports_remaining_conflict() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);
    r.git(&["config", "merge.tool", "arbor-fail"]);
    r.git(&["config", "mergetool.arbor-fail.cmd", "false"]);
    r.git(&["config", "mergetool.arbor-fail.trustExitCode", "true"]);
    r.git(&["config", "mergetool.prompt", "false"]);

    let repo = r.open();
    let error = repo
        .open_external_merge_tool("file.txt".into())
        .expect_err("failed external merge tool");
    assert!(error.to_string().contains("remaining conflicts: file.txt"));
    assert_eq!(repo.conflict_workspace().unwrap().files.len(), 1);
}

#[test]
fn external_merge_tool_settings_roundtrip_and_reject_control_characters() {
    let r = TestRepo::new();
    let repo = r.open();

    repo.set_external_merge_tool_settings("arbor-test".into(), "arbor-gui".into())
        .expect("save mergetool settings");
    let settings = repo
        .external_merge_tool_settings()
        .expect("read mergetool settings");
    assert_eq!(settings.merge_tool, "arbor-test");
    assert_eq!(settings.merge_gui_tool, "arbor-gui");

    let error = repo
        .set_external_merge_tool_settings("bad\nvalue".into(), String::new())
        .expect_err("control characters must be rejected");
    assert!(error.to_string().contains("merge.tool"));

    repo.set_external_merge_tool_settings(String::new(), String::new())
        .expect("clear local mergetool settings");
    assert!(
        common::git_allow_failure(&r.path, &["config", "--local", "--get", "merge.tool"])
            .is_empty()
    );
    assert!(
        common::git_allow_failure(&r.path, &["config", "--local", "--get", "merge.guitool"])
            .is_empty()
    );
}

#[test]
fn external_merge_tool_cancellation_returns_cancelled() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);
    r.git(&["config", "merge.tool", "arbor-cancel"]);
    r.git(&["config", "mergetool.arbor-cancel.cmd", "sleep 30"]);
    r.git(&["config", "mergetool.arbor-cancel.trustExitCode", "true"]);
    r.git(&["config", "mergetool.prompt", "false"]);

    let repo = r.open();
    let cancel = GitCancelHandle::new();
    let worker_repo = repo.clone();
    let worker_cancel = cancel.clone();
    let worker = std::thread::spawn(move || {
        worker_repo.open_external_merge_tool_with_cancel("file.txt".into(), worker_cancel)
    });
    std::thread::sleep(std::time::Duration::from_millis(300));
    cancel.cancel();
    let error = worker
        .join()
        .expect("mergetool worker")
        .expect_err("cancelled mergetool");
    assert!(
        matches!(error, arbor_engine::EngineError::Cancelled),
        "unexpected cancellation error: {error:?}"
    );
}

#[test]
fn workspace_from_rebase_cherry_pick_revert() {
    // rebase
    let r = TestRepo::new();
    conflicted_pair(&r);
    r.git(&["checkout", "-q", "feature"]);
    common::git_allow_failure(&r.path, &["rebase", "main"]);
    let repo = r.open();
    let ws = repo.conflict_workspace().expect("rebase ws");
    assert_eq!(ws.operation, Some(OperationKind::Rebase));
    assert_eq!(ws.files.len(), 1);

    // cherry-pick
    let r2 = TestRepo::new();
    conflicted_pair(&r2);
    let theirs = r2.git(&["rev-parse", "feature"]);
    common::git_allow_failure(&r2.path, &["cherry-pick", &theirs]);
    let repo2 = r2.open();
    let ws = repo2.conflict_workspace().expect("cp ws");
    assert_eq!(ws.operation, Some(OperationKind::CherryPick));
    assert_eq!(ws.files.len(), 1);

    // revert
    let r3 = TestRepo::new();
    common::commit(&r3.path, "file.txt", "base", "init");
    r3.write("file.txt", "a");
    r3.git(&["add", "file.txt"]);
    r3.git(&["commit", "-q", "-m", "c1"]);
    r3.write("file.txt", "b");
    r3.git(&["add", "file.txt"]);
    r3.git(&["commit", "-q", "-m", "c2"]);
    let c1 = r3.git(&["rev-parse", "HEAD~1"]);
    common::git_allow_failure(&r3.path, &["revert", &c1]);
    let repo3 = r3.open();
    let ws = repo3.conflict_workspace().expect("revert ws");
    assert_eq!(ws.operation, Some(OperationKind::Revert));
    assert_eq!(ws.files.len(), 1);
}

#[test]
fn accept_ours_removes_file_from_workspace() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);

    let repo = r.open();
    repo.accept_conflict("file.txt".into(), FilePick::Ours)
        .expect("accept ours");
    assert!(r.read("file.txt").contains("ours"));
    assert!(!r.read("file.txt").contains("<<<<<<"));
    // 解决一个文件后立即从冲突列表移除
    let ws = repo.conflict_workspace().expect("workspace");
    assert!(ws.files.is_empty(), "files: {ws:?}");
    // index 干净：status 不再冲突
    let st = repo.status().expect("status");
    assert!(st
        .iter()
        .all(|e| e.staged != arbor_engine::ChangeKind::Conflicted
            && e.unstaged != arbor_engine::ChangeKind::Conflicted));
    // 全部解决后可 continue（操作状态仍在，等待完成）
    assert!(repo.operation_state().expect("op").is_some());
}

#[test]
fn revert_resolved_restores_conflict_and_survives_reopen() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);

    let repo = r.open();
    repo.accept_conflict("file.txt".into(), FilePick::Ours)
        .expect("accept ours");
    let workspace = repo.conflict_workspace().expect("workspace after resolve");
    assert_eq!(workspace.files.len(), 0);
    assert_eq!(workspace.resolved_files, vec!["file.txt".to_string()]);

    // The action target is repository-backed, not only a view-local list.
    let reopened = r.open();
    let reopened_workspace = reopened.conflict_workspace().expect("reopened workspace");
    assert_eq!(
        reopened_workspace.resolved_files,
        vec!["file.txt".to_string()]
    );

    reopened
        .revert_resolved_conflict("file.txt".into())
        .expect("revert resolved");
    let restored = reopened
        .conflict_workspace()
        .expect("workspace after revert");
    assert_eq!(restored.files.len(), 1);
    assert!(restored.resolved_files.is_empty());
    assert!(r.read("file.txt").contains("<<<<<<<"));
}

#[test]
fn revert_resolved_restores_cherry_pick_and_revert_conflicts() {
    let cherry = TestRepo::new();
    conflicted_pair(&cherry);
    let commit = cherry.git(&["rev-parse", "feature"]);
    common::git_allow_failure(&cherry.path, &["cherry-pick", &commit]);
    let cherry_repo = cherry.open();
    cherry_repo
        .accept_conflict("file.txt".into(), FilePick::Ours)
        .expect("resolve cherry-pick");
    cherry_repo
        .revert_resolved_conflict("file.txt".into())
        .expect("revert cherry-pick resolution");
    assert_eq!(cherry_repo.conflict_workspace().unwrap().files.len(), 1);

    let revert = TestRepo::new();
    common::commit(&revert.path, "file.txt", "base", "init");
    revert.write("file.txt", "a");
    revert.git(&["add", "file.txt"]);
    revert.git(&["commit", "-q", "-m", "c1"]);
    revert.write("file.txt", "b");
    revert.git(&["add", "file.txt"]);
    revert.git(&["commit", "-q", "-m", "c2"]);
    let c1 = revert.git(&["rev-parse", "HEAD~1"]);
    common::git_allow_failure(&revert.path, &["revert", &c1]);
    let revert_repo = revert.open();
    revert_repo
        .accept_conflict("file.txt".into(), FilePick::Ours)
        .expect("resolve revert");
    revert_repo
        .revert_resolved_conflict("file.txt".into())
        .expect("revert revert resolution");
    assert_eq!(revert_repo.conflict_workspace().unwrap().files.len(), 1);

    let rebase = TestRepo::new();
    conflicted_pair(&rebase);
    rebase.git(&["checkout", "-q", "feature"]);
    common::git_allow_failure(&rebase.path, &["rebase", "main"]);
    let rebase_repo = rebase.open();
    rebase_repo
        .accept_conflict("file.txt".into(), FilePick::Ours)
        .expect("resolve rebase");
    rebase_repo
        .revert_resolved_conflict("file.txt".into())
        .expect("revert rebase resolution");
    assert_eq!(rebase_repo.conflict_workspace().unwrap().files.len(), 1);
}

#[test]
fn revert_resolved_only_reopens_selected_path() {
    let r = TestRepo::new();
    conflicted_pair_two_files(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);

    let repo = r.open();
    repo.accept_conflict("one.txt".into(), FilePick::Ours)
        .expect("resolve one");
    repo.accept_conflict("two.txt".into(), FilePick::Ours)
        .expect("resolve two");
    assert_eq!(
        repo.conflict_workspace().unwrap().resolved_files,
        vec!["one.txt", "two.txt"]
    );

    repo.revert_resolved_conflict("one.txt".into())
        .expect("reopen one");
    let workspace = repo.conflict_workspace().expect("workspace after reopen");
    assert_eq!(
        workspace
            .files
            .iter()
            .map(|file| file.path.as_str())
            .collect::<Vec<_>>(),
        vec!["one.txt"]
    );
    assert_eq!(workspace.resolved_files, vec!["two.txt"]);
    assert!(r.read("one.txt").contains("<<<<<<<"));
    assert_eq!(r.read("two.txt"), "ours-two");
}

#[test]
fn revert_resolved_restores_engine_rebase_conflict() {
    let r = TestRepo::new();
    let base = common::commit(&r.path, "file.txt", "base\n", "base");
    common::commit(&r.path, "file.txt", "ours\n", "ours");
    r.git(&["switch", "-q", "-c", "onto", &base]);
    let onto = common::commit(&r.path, "file.txt", "theirs\n", "theirs");
    r.git(&["switch", "-q", "main"]);

    let repo = r.open();
    let outcome = repo
        .rebase(onto, vec![RebaseAction::Pick])
        .expect("engine rebase conflict");
    assert_eq!(outcome.pause_reason, Some(RebasePauseReason::Conflict));
    repo.accept_conflict("file.txt".into(), FilePick::Ours)
        .expect("resolve engine rebase");
    repo.revert_resolved_conflict("file.txt".into())
        .expect("reopen engine rebase resolution");
    assert_eq!(repo.conflict_workspace().unwrap().files.len(), 1);
}

#[test]
fn accept_theirs_and_both() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);
    let repo = r.open();
    repo.accept_conflict("file.txt".into(), FilePick::Theirs)
        .expect("theirs");
    assert!(r.read("file.txt").contains("theirs"));

    // both:两段都保留
    let r2 = TestRepo::new();
    conflicted_pair(&r2);
    common::git_allow_failure(&r2.path, &["merge", "feature"]);
    let repo2 = r2.open();
    repo2
        .accept_conflict("file.txt".into(), FilePick::Both)
        .expect("both");
    let content = r2.read("file.txt");
    assert!(
        content.contains("ours") && content.contains("theirs"),
        "both: {content}"
    );
    assert!(!content.contains("<<<<<<"));
}

#[test]
fn reset_restores_marker_from_stages() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);
    // 用户把文件改坏/清空
    r.write("file.txt", "scratch");
    let repo = r.open();
    repo.reset_conflict("file.txt".into()).expect("reset");
    let content = r.read("file.txt");
    assert!(
        content.contains("<<<<<<<"),
        "marker should be restored: {content}"
    );
    assert!(content.contains("ours") && content.contains("theirs"));
    // stages 未动：仍是冲突状态
    let ws = repo.conflict_workspace().expect("workspace");
    assert_eq!(ws.files.len(), 1);
}

#[test]
fn binary_conflict_flagged_with_no_blocks() {
    let r = TestRepo::new();
    // 二进制内容（含 NUL）：base 用 git hash-object 构造
    common::commit(&r.path, "f.txt", "x\n", "init");
    r.git(&["branch", "feature"]);
    std::fs::write(r.path.join("img.bin"), b"\x00\x01BIN\x00").unwrap();
    r.git(&["add", "img.bin"]);
    r.git(&["commit", "-q", "-m", "add bin"]);
    r.git(&["checkout", "-q", "feature"]);
    std::fs::write(r.path.join("img.bin"), b"\x00\x02BIN\x00").unwrap();
    r.git(&["add", "img.bin"]);
    r.git(&["commit", "-q", "-m", "change bin"]);
    r.git(&["checkout", "-q", "main"]);
    common::git_allow_failure(&r.path, &["merge", "feature"]);

    let repo = r.open();
    let ws = repo.conflict_workspace().expect("workspace");
    let bin = ws
        .files
        .iter()
        .find(|f| f.path == "img.bin")
        .expect("binary conflict");
    assert!(bin.binary);
    assert!(
        bin.file.blocks.is_empty(),
        "binary files have no text blocks"
    );

    // binary accept 仍可用（走 bytes 路径）
    repo.accept_conflict("img.bin".into(), FilePick::Theirs)
        .expect("accept binary");
    assert_eq!(
        std::fs::read(r.path.join("img.bin")).unwrap(),
        b"\x00\x02BIN\x00"
    );
    // reset 二进制给出明确提示
    let r2 = TestRepo::new();
    common::commit(&r2.path, "f.txt", "x\n", "init");
    r2.git(&["branch", "feature"]);
    std::fs::write(r2.path.join("img.bin"), b"\x00\x01BIN\x00").unwrap();
    r2.git(&["add", "img.bin"]);
    r2.git(&["commit", "-q", "-m", "add bin"]);
    r2.git(&["checkout", "-q", "feature"]);
    std::fs::write(r2.path.join("img.bin"), b"\x00\x02BIN\x00").unwrap();
    r2.git(&["add", "img.bin"]);
    r2.git(&["commit", "-q", "-m", "change bin"]);
    r2.git(&["checkout", "-q", "main"]);
    common::git_allow_failure(&r2.path, &["merge", "feature"]);
    let repo2 = r2.open();
    let err = repo2
        .reset_conflict("img.bin".into())
        .unwrap_err()
        .to_string();
    assert!(err.contains("二进制"), "clear binary reset error: {err}");
}

#[test]
fn binary_attribute_conflict_flagged_without_nul_bytes() {
    let r = TestRepo::new();
    r.write(".gitattributes", "asset.dat binary\n");
    r.write("asset.dat", "base\n");
    r.git(&["add", ".gitattributes", "asset.dat"]);
    r.git(&["commit", "-q", "-m", "init"]);
    r.git(&["branch", "feature"]);

    r.write("asset.dat", "ours\n");
    r.git(&["add", "asset.dat"]);
    r.git(&["commit", "-q", "-m", "ours"]);
    r.git(&["checkout", "-q", "feature"]);
    r.write("asset.dat", "theirs\n");
    r.git(&["add", "asset.dat"]);
    r.git(&["commit", "-q", "-m", "theirs"]);
    r.git(&["checkout", "-q", "main"]);
    common::git_allow_failure(&r.path, &["merge", "feature"]);

    let repo = r.open();
    let file = repo
        .conflict_workspace()
        .expect("workspace")
        .files
        .into_iter()
        .find(|file| file.path == "asset.dat")
        .expect("attribute-declared binary conflict");
    assert!(file.binary);
    assert!(file.file.blocks.is_empty());

    let reset_error = repo
        .reset_conflict("asset.dat".into())
        .expect_err("attribute-declared binary cannot be reset as text markers");
    assert!(reset_error.to_string().contains("二进制"));

    repo.accept_conflict("asset.dat".into(), FilePick::Theirs)
        .expect("accept attribute-declared binary");
    assert_eq!(r.read("asset.dat"), "theirs\n");
}

#[test]
fn workspace_survives_reopen() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);

    // 应用"重启"：重开仓库后工作台仍完整可操作
    let repo = r.open();
    let ws = repo.conflict_workspace().expect("workspace");
    assert_eq!(ws.files.len(), 1);
    repo.accept_conflict("file.txt".into(), FilePick::Ours)
        .expect("accept after reopen");
    let ws = repo.conflict_workspace().expect("workspace after");
    assert!(ws.files.is_empty());
}

#[test]
fn manual_edit_mark_resolved() {
    let r = TestRepo::new();
    conflicted_pair(&r);
    common::git_allow_failure(&r.path, &["merge", "feature"]);
    let repo = r.open();

    // 手动编辑：写自定义结果并标记解决
    let custom = "line1\nhand-made resolution\nline3\n";
    repo.resolve_edited("file.txt".into(), custom.into())
        .expect("resolve edited");
    assert_eq!(r.read("file.txt"), custom);
    let ws = repo.conflict_workspace().expect("workspace");
    assert!(ws.files.is_empty());
}
