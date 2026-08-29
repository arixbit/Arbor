//! v0.6 默认 rebase：沿 first-parent 重放，跳过 merge 提交。

mod common;

use arbor_engine::RebaseAction;
use common::TestRepo;

#[test]
fn rebase_skips_merge_commit() {
    let r = TestRepo::new();
    common::commit(&r.path, "base.txt", "base", "base");
    r.git(&["switch", "-q", "-c", "feature"]);
    common::commit(&r.path, "feature.txt", "feature", "feature");
    r.git(&["switch", "-q", "main"]);
    let onto = common::commit(&r.path, "main.txt", "main", "main");
    r.git(&["merge", "--no-ff", "-q", "feature", "-m", "merge"]);
    common::commit(&r.path, "post1.txt", "post1", "post1");
    common::commit(&r.path, "post2.txt", "post2", "post2");

    let outcome = r
        .open()
        .rebase(onto.clone(), vec![RebaseAction::Pick, RebaseAction::Pick])
        .unwrap();
    assert!(!outcome.paused);
    assert!(r.exists("post1.txt"));
    assert!(r.exists("post2.txt"));
    assert!(!r.exists("feature.txt"), "merge side should be skipped");
    assert_eq!(
        r.git(&["rev-list", "--count", &format!("{onto}..HEAD")]),
        "2"
    );
    assert!(r.git(&["status", "--porcelain"]).is_empty());
}
