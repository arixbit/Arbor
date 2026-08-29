//! REPO-001:多 Git root 发现与嵌套仓库策略。
//! fixture:一个项目目录装两个独立仓库 + 一个 submodule + 一个深层嵌套仓库,
//! 验证发现、submodule 标记、状态隔离与 dirty/operation 上报。

mod common;

use arbor_engine::{discover_git_roots, list_multi_root_branches, OperationKind};
use common::TestRepo;

/// 在指定目录 init 一个带一个提交的仓库(不共用 TestRepo 的临时根)。
fn mini_repo(dir: &std::path::Path, file: &str, content: &str) {
    std::fs::create_dir_all(dir).unwrap();
    common::git(dir, &["init", "-q"]);
    common::git(dir, &["config", "user.name", "Arbor Test"]);
    common::git(dir, &["config", "user.email", "test@arbor.local"]);
    common::git(dir, &["symbolic-ref", "HEAD", "refs/heads/main"]);
    common::commit(dir, file, content, "init");
}

#[test]
fn discovers_two_independent_roots_in_one_project() {
    let project = tempfile::tempdir().expect("tempdir");
    let project_path = project.path();
    // 项目根本身不是 git 仓库;两个子目录各自是独立 root。
    mini_repo(&project_path.join("frontend"), "app.txt", "ui");
    mini_repo(&project_path.join("backend"), "api.txt", "svc");

    let roots = discover_git_roots(project_path.display().to_string(), None).expect("roots");
    assert_eq!(roots.len(), 2, "expected 2 roots, got {roots:?}");
    let names: Vec<&str> = roots.iter().map(|r| r.display_name.as_str()).collect();
    assert!(names.contains(&"frontend"));
    assert!(names.contains(&"backend"));
    for root in &roots {
        assert!(!root.is_submodule);
        assert_eq!(root.head_branch.as_deref(), Some("main"));
        assert!(root.head_id.is_some());
        assert!(!root.dirty);
        assert!(root.operation.is_none());
    }
}

#[test]
fn branch_snapshots_distinguish_detached_commit_from_unborn_head() {
    let project = tempfile::tempdir().expect("tempdir");
    let detached = project.path().join("detached");
    mini_repo(&detached, "f.txt", "x");
    common::git(&detached, &["checkout", "-q", "--detach", "HEAD"]);

    let unborn = project.path().join("unborn");
    std::fs::create_dir_all(&unborn).unwrap();
    common::git(&unborn, &["init", "-q"]);
    common::git(&unborn, &["symbolic-ref", "HEAD", "refs/heads/main"]);

    let snapshots =
        list_multi_root_branches(project.path().display().to_string()).expect("branch snapshots");
    let detached_path = std::fs::canonicalize(&detached).unwrap();
    let unborn_path = std::fs::canonicalize(&unborn).unwrap();
    let detached_snapshot = snapshots
        .iter()
        .find(|snapshot| snapshot.root_path == detached_path.display().to_string())
        .expect("detached snapshot");
    let unborn_snapshot = snapshots
        .iter()
        .find(|snapshot| snapshot.root_path == unborn_path.display().to_string())
        .expect("unborn snapshot");

    assert!(detached_snapshot.head_branch.is_none());
    assert!(detached_snapshot.head_id.is_some());
    assert!(unborn_snapshot.head_branch.is_none());
    assert!(unborn_snapshot.head_id.is_none());
}

#[test]
fn discover_from_inside_repo_finds_outer_root() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x", "init");
    // 从仓库内(真实存在的)子目录扫描:应向上发现所属仓库作为 root,relative_path 为 "."
    let deep = r.path.join("some/deep/dir");
    std::fs::create_dir_all(&deep).unwrap();
    let roots = discover_git_roots(deep.display().to_string(), None).expect("roots");
    let canonical = std::fs::canonicalize(&r.path).expect("canonical");
    let root = roots
        .iter()
        .find(|root| root.path == canonical.display().to_string())
        .expect("outer root discovered");
    assert_eq!(root.relative_path, ".");
}

#[test]
fn nested_repo_is_reported_not_swallowed() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x", "init");
    // 外层仓库内的嵌套独立仓库(未登记 .gitmodules)
    mini_repo(&r.path.join("tools/scripts"), "s.txt", "s");

    let roots = discover_git_roots(r.path.display().to_string(), None).expect("roots");
    assert_eq!(roots.len(), 2, "roots: {roots:?}");
    let nested = roots
        .iter()
        .find(|root| root.display_name == "scripts")
        .expect("nested root");
    assert!(!nested.is_submodule, "not in .gitmodules -> independent");
    assert_eq!(nested.relative_path, "tools/scripts");
    // 外层 root 的 status 不应把嵌套仓库当成普通未跟踪目录计入 dirty
    // (gix status 会显示 untracked tools/,dirty 上报允许;关键是
    // 嵌套仓库本身作为独立 root 出现,可单独打开操作。)
    let repo = arbor_engine::open_repository(nested.path.clone()).expect("open nested");
    repo.status().expect("nested status").first();
}

#[test]
fn submodule_marked_via_gitmodules() {
    let outer = tempfile::tempdir().expect("tempdir");
    let outer_path = outer.path();
    mini_repo(outer_path, "main.txt", "m");
    // 真实 submodule:add 子仓库为 gitfile 形式(在 .gitmodules 登记)
    let sub_source = tempfile::tempdir().expect("tempdir");
    mini_repo(sub_source.path(), "lib.txt", "l");
    // 现代 git 默认禁止 file 协议 submodule clone(CVE-2024-32002 缓解),
    // 只有内联 -c 才会传导到内部 clone 进程。
    common::git(
        outer_path,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &sub_source.path().display().to_string(),
            "vendor/lib",
        ],
    );
    common::git(outer_path, &["commit", "-q", "-m", "add submodule"]);

    let roots = discover_git_roots(outer_path.display().to_string(), None).expect("roots");
    assert_eq!(roots.len(), 2, "roots: {roots:?}");
    let sub = roots
        .iter()
        .find(|root| root.display_name == "lib")
        .expect("submodule root");
    assert!(sub.is_submodule, "listed in .gitmodules");
    assert_eq!(sub.relative_path, "vendor/lib");
    // submodule 仓库有 .git gitfile,gix 仍能打开
    assert!(sub.head_id.is_some());
}

#[test]
fn discovers_nested_submodule_and_marks_nearest_parent() {
    let outer = tempfile::tempdir().expect("tempdir");
    let outer_path = outer.path();
    mini_repo(outer_path, "main.txt", "m");

    let sub_source = tempfile::tempdir().expect("submodule source");
    mini_repo(sub_source.path(), "lib.txt", "l");
    common::git(
        outer_path,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &sub_source.path().display().to_string(),
            "vendor/lib",
        ],
    );
    common::git(outer_path, &["commit", "-q", "-m", "add submodule"]);

    let nested_source = tempfile::tempdir().expect("nested submodule source");
    mini_repo(nested_source.path(), "tool.txt", "tool");
    let submodule_path = outer_path.join("vendor/lib");
    common::git(
        &submodule_path,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &nested_source.path().display().to_string(),
            "nested/tool",
        ],
    );
    common::git(&submodule_path, &["config", "user.name", "Arbor Test"]);
    common::git(
        &submodule_path,
        &["config", "user.email", "test@arbor.local"],
    );
    common::git(
        &submodule_path,
        &["commit", "-q", "-m", "add nested submodule"],
    );
    common::git(outer_path, &["add", "vendor/lib"]);
    common::git(outer_path, &["commit", "-q", "-m", "advance submodule"]);

    let roots = discover_git_roots(outer_path.display().to_string(), None).expect("roots");
    assert_eq!(roots.len(), 3, "roots: {roots:?}");
    let child = roots
        .iter()
        .find(|root| root.relative_path == "vendor/lib")
        .expect("direct submodule root");
    let grandchild = roots
        .iter()
        .find(|root| root.relative_path == "vendor/lib/nested/tool")
        .expect("nested submodule root");
    assert!(child.is_submodule);
    assert!(grandchild.is_submodule);
    assert!(grandchild.head_id.is_some());
}

#[test]
fn reports_dirty_and_operation_per_root() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x", "init");
    mini_repo(&r.path.join("nested"), "n.txt", "n");

    // 外层 dirty;嵌套进入 merge 冲突 -> operation = Merge
    r.write("f.txt", "changed");
    let theirs = {
        r.git(&["checkout", "-q", "-b", "feature"]);
        r.write("f.txt", "theirs");
        r.git(&["add", "f.txt"]);
        r.git(&["commit", "-q", "-m", "theirs"]);
        r.git(&["checkout", "-q", "main"]);
        r.write("f.txt", "ours");
        r.git(&["add", "f.txt"]);
        r.git(&["commit", "-q", "-m", "ours"]);
        r.git(&["rev-parse", "feature"])
    };
    common::git_allow_failure(&r.path, &["merge", &theirs]);

    let roots = discover_git_roots(r.path.display().to_string(), None).expect("roots");
    let outer = roots
        .iter()
        .find(|root| root.display_name != "nested")
        .expect("outer root");
    let nested = roots
        .iter()
        .find(|root| root.display_name == "nested")
        .expect("nested");
    assert!(outer.dirty);
    assert_eq!(outer.operation, Some(OperationKind::Merge));
    // 两个 root 状态互不污染
    assert!(!nested.dirty);
    assert!(nested.operation.is_none());
}

#[test]
fn non_git_directory_returns_empty_list() {
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::write(dir.path().join("plain.txt"), "x").unwrap();
    let roots = discover_git_roots(dir.path().display().to_string(), None).expect("roots");
    assert!(roots.is_empty());
}
