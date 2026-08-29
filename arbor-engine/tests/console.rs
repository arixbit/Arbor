//! Git Console 的原始命令边界测试。

mod common;

use arbor_engine::{EngineError, GitCancelHandle};
use std::time::{Duration, Instant};

use common::{commit, TestRepo};

#[test]
fn raw_git_command_returns_display_and_streams() {
    let r = TestRepo::new();
    let result = r
        .open()
        .run_git_command("status".into(), vec!["--short".into()])
        .unwrap();
    assert_eq!(result.exit_code, 0);
    assert_eq!(result.command, "git status --short");
    assert!(result.stderr.is_empty());

    let failed = r
        .open()
        .run_git_command("not-a-command".into(), Vec::new())
        .unwrap();
    assert_ne!(failed.exit_code, 0);
    assert!(!failed.stderr.is_empty());
}

#[test]
fn cancellable_raw_git_command_maps_process_group_cancel_to_engine_error() {
    let r = TestRepo::new();
    r.git(&["config", "alias.hang", "!sleep 30"]);
    let cancel = GitCancelHandle::new();
    let worker_cancel = cancel.clone();
    let repo = r.open();
    let started = Instant::now();
    let worker = std::thread::spawn(move || {
        repo.run_git_command_with_cancel("hang".into(), Vec::new(), worker_cancel)
    });
    std::thread::sleep(Duration::from_millis(100));
    cancel.cancel();

    let result = worker.join().expect("cancellable git worker panicked");
    assert!(matches!(result, Err(EngineError::Cancelled)));
    assert!(started.elapsed() < Duration::from_secs(5));
}

#[test]
fn raw_git_command_can_render_commit_patches() {
    let r = TestRepo::new();
    let root = commit(&r.path, "note.txt", "one\n", "root");
    let next = commit(&r.path, "note.txt", "one\ntwo\n", "next");
    let repo = r.open();

    let patch = repo
        .run_git_command(
            "diff".into(),
            vec![
                "--binary".into(),
                "--no-ext-diff".into(),
                root.clone(),
                next,
            ],
        )
        .unwrap();
    assert_eq!(patch.exit_code, 0);
    assert!(patch.stdout.contains("diff --git"));
    assert!(patch.stdout.contains("+two"));

    let root_patch = repo
        .run_git_command(
            "show".into(),
            vec![
                "--format=".into(),
                "--binary".into(),
                "--no-ext-diff".into(),
                "--root".into(),
                root,
            ],
        )
        .unwrap();
    assert_eq!(root_patch.exit_code, 0);
    assert!(root_patch.stdout.contains("diff --git"));
    assert!(root_patch.stdout.contains("+one"));
}

#[test]
fn raw_git_command_preserves_non_utf8_stdout_bytes() {
    let r = TestRepo::new();
    std::fs::write(r.path.join("payload.bin"), [0x63, 0x61, 0x66, 0xE9, 0x0A]).unwrap();
    let object = r.git(&["hash-object", "-w", "payload.bin"]);

    let result = r
        .open()
        .run_git_command("cat-file".into(), vec!["blob".into(), object.clone()])
        .unwrap();

    assert_eq!(result.exit_code, 0);
    assert_eq!(result.stdout_bytes, [0x63, 0x61, 0x66, 0xE9, 0x0A]);
    assert!(result.stdout.contains("caf�"));

    let cancellable = r
        .open()
        .run_git_command_with_cancel(
            "cat-file".into(),
            vec!["blob".into(), object],
            GitCancelHandle::new(),
        )
        .unwrap();
    assert_eq!(cancellable.stdout_bytes, [0x63, 0x61, 0x66, 0xE9, 0x0A]);
}

#[test]
fn raw_git_commands_cover_external_vfs_add_and_remove_semantics() {
    let r = TestRepo::new();
    commit(&r.path, "tracked.txt", "tracked\n", "init");
    commit(&r.path, "removed.txt", "removed\n", "second");
    r.write("new.txt", "new\n");
    let repo = r.open();

    let add = repo
        .run_git_command("add".into(), vec!["--".into(), "new.txt".into()])
        .unwrap();
    assert_eq!(add.exit_code, 0);
    assert!(r
        .git(&["diff", "--cached", "--name-only"])
        .lines()
        .any(|path| path == "new.txt"));

    std::fs::remove_file(r.path.join("removed.txt")).unwrap();
    let remove = repo
        .run_git_command(
            "rm".into(),
            vec![
                "--cached".into(),
                "--ignore-unmatch".into(),
                "-r".into(),
                "--".into(),
                "removed.txt".into(),
            ],
        )
        .unwrap();
    assert_eq!(remove.exit_code, 0);
    assert!(!r.exists("removed.txt"));
    assert!(r
        .git(&["ls-files"])
        .lines()
        .all(|path| path != "removed.txt"));
}

#[test]
fn raw_git_commands_cover_external_case_rename_semantics() {
    let r = TestRepo::new();
    commit(&r.path, "CaseName.txt", "case\n", "init");
    std::fs::rename(r.path.join("CaseName.txt"), r.path.join("casename.txt")).unwrap();

    let repo = r.open();
    let move_result = repo
        .run_git_command(
            "mv".into(),
            vec![
                "-f".into(),
                "--".into(),
                "CaseName.txt".into(),
                "casename.txt".into(),
            ],
        )
        .unwrap();
    assert_eq!(move_result.exit_code, 0);
    assert!(r.exists("casename.txt"));
    assert_eq!(r.git(&["ls-files"]), "casename.txt");
}
