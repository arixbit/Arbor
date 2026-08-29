//! v0.6 hooks：失败中断、skip_hooks 和 commit-msg 改写。

mod common;

use std::os::unix::fs::PermissionsExt;

use common::TestRepo;

fn write_hook(r: &TestRepo, name: &str, body: &str) {
    let path = r.path.join(".git/hooks").join(name);
    std::fs::write(&path, body).unwrap();
    let mut permissions = std::fs::metadata(&path).unwrap().permissions();
    permissions.set_mode(0o755);
    std::fs::set_permissions(path, permissions).unwrap();
}

#[test]
fn pre_commit_can_block_and_skip_can_bypass() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    write_hook(&r, "pre-commit", "#!/bin/sh\necho blocked >&2\nexit 1\n");
    r.write("next.txt", "next");
    let repo = r.open();
    repo.stage("next.txt".into()).unwrap();
    let before = r.git(&["rev-parse", "HEAD"]);
    let error = repo.commit("blocked".into(), false).unwrap_err();
    assert!(error.to_string().contains("blocked"));
    assert_eq!(r.git(&["rev-parse", "HEAD"]), before);
    let id = repo.commit("allowed".into(), true).unwrap();
    assert_eq!(r.git(&["rev-parse", "HEAD"]), id);
}

#[test]
fn commit_msg_hook_can_rewrite_message() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    write_hook(
        &r,
        "commit-msg",
        "#!/bin/sh\nprintf 'rewritten by hook\\n' > \"$1\"\n",
    );
    r.write("next.txt", "next");
    let repo = r.open();
    repo.stage("next.txt".into()).unwrap();
    repo.commit("original".into(), false).unwrap();
    assert_eq!(r.git(&["log", "-1", "--format=%s"]), "rewritten by hook");
}
