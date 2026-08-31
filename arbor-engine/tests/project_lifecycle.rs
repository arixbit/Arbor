//! Git 项目生命周期：初始化已有目录、克隆本地仓库。

mod common;

use common::{commit, TestRepo};

#[test]
fn initialize_existing_directory() {
    let directory = tempfile::tempdir().expect("tempdir");
    let path = directory.path().to_string_lossy().into_owned();

    let initialized = arbor_engine::initialize_repository(path.clone()).unwrap();

    assert_eq!(
        initialized,
        directory
            .path()
            .canonicalize()
            .unwrap()
            .display()
            .to_string()
    );
    assert!(directory.path().join(".git").is_dir());
    arbor_engine::open_repository(initialized).expect("initialized repository opens");
}

#[test]
fn clone_local_repository() {
    let source = TestRepo::new();
    commit(&source.path, "README.md", "hello", "initial");
    let destination_parent = tempfile::tempdir().expect("destination parent");
    let destination = destination_parent.path().join("cloned");

    let cloned = arbor_engine::clone_repository(
        source.path.to_string_lossy().into_owned(),
        destination.to_string_lossy().into_owned(),
        false,
    )
    .unwrap();

    assert_eq!(
        cloned,
        destination.canonicalize().unwrap().display().to_string()
    );
    assert_eq!(
        std::fs::read_to_string(destination.join("README.md")).unwrap(),
        "hello"
    );
    arbor_engine::open_repository(cloned).expect("cloned repository opens");
}

#[test]
fn clone_local_repository_with_recursive_submodule() {
    let submodule = TestRepo::new();
    commit(&submodule.path, "lib.txt", "submodule content", "submodule");

    let source = TestRepo::new();
    commit(&source.path, "README.md", "parent", "initial");
    common::git(
        &source.path,
        &[
            "-c",
            "protocol.file.allow=always",
            "submodule",
            "add",
            "-q",
            &submodule.path.display().to_string(),
            "vendor/lib",
        ],
    );
    common::git(&source.path, &["commit", "-q", "-m", "add submodule"]);

    let destination_parent = tempfile::tempdir().expect("destination parent");
    let destination = destination_parent.path().join("cloned-recursive");
    let previous_protocols = std::env::var_os("GIT_ALLOW_PROTOCOL");
    // Modern Git blocks local submodule URLs by default. Keep the test's
    // allowance process-local and restore the caller environment afterwards;
    // the engine still invokes the normal `git clone --recurse-submodules`.
    std::env::set_var("GIT_ALLOW_PROTOCOL", "file");
    let cloned = arbor_engine::clone_repository(
        source.path.to_string_lossy().into_owned(),
        destination.to_string_lossy().into_owned(),
        true,
    );
    match previous_protocols {
        Some(value) => std::env::set_var("GIT_ALLOW_PROTOCOL", value),
        None => std::env::remove_var("GIT_ALLOW_PROTOCOL"),
    }
    let cloned = cloned.unwrap();

    assert_eq!(
        std::fs::read_to_string(destination.join("vendor/lib/lib.txt")).unwrap(),
        "submodule content"
    );
    arbor_engine::open_repository(cloned).expect("recursive clone opens");
}

#[test]
fn shallow_clone_accepts_positive_depth_and_unshallow_restores_history() {
    let source = TestRepo::new();
    commit(&source.path, "README.md", "one", "initial");
    commit(&source.path, "README.md", "two", "second");
    commit(&source.path, "README.md", "three", "third");

    let destination_parent = tempfile::tempdir().expect("destination parent");
    let destination = destination_parent.path().join("shallow");
    let source_url = format!("file://{}", source.path.display());
    let cloned = arbor_engine::clone_repository_with_options(
        source_url,
        destination.to_string_lossy().into_owned(),
        false,
        Some(1),
    )
    .expect("shallow clone");
    let repo = arbor_engine::open_repository(cloned).expect("open shallow clone");
    assert!(repo.is_shallow());
    assert_eq!(
        common::git(&destination, &["rev-list", "--count", "HEAD"]),
        "1"
    );

    repo.fetch_unshallow(Some("origin".into()))
        .expect("fetch full history");
    assert!(!repo.is_shallow());
    assert_eq!(
        common::git(&destination, &["rev-list", "--count", "HEAD"]),
        "3"
    );
}

#[test]
fn shallow_clone_rejects_zero_depth_before_creating_destination() {
    let source = TestRepo::new();
    commit(&source.path, "README.md", "hello", "initial");
    let destination_parent = tempfile::tempdir().expect("destination parent");
    let destination = destination_parent.path().join("invalid");

    let error = arbor_engine::clone_repository_with_options(
        source.path.to_string_lossy().into_owned(),
        destination.to_string_lossy().into_owned(),
        false,
        Some(0),
    )
    .expect_err("zero depth must be rejected");
    assert!(error.to_string().contains("greater than zero"));
    assert!(!destination.exists());
}

#[test]
fn checkout_remote_tracking_branch_creates_local_branch() {
    let source = TestRepo::new();
    commit(&source.path, "README.md", "hello", "initial");
    let destination_parent = tempfile::tempdir().expect("destination parent");
    let destination = destination_parent.path().join("cloned");
    let cloned = arbor_engine::clone_repository(
        source.path.to_string_lossy().into_owned(),
        destination.to_string_lossy().into_owned(),
        false,
    )
    .unwrap();
    let repo = arbor_engine::open_repository(cloned).unwrap();

    repo.checkout_remote_branch("origin/main".into(), Some("from-origin".into()))
        .unwrap();

    let branches = repo.branch_list().unwrap();
    assert!(branches
        .iter()
        .any(|branch| branch.name == "from-origin" && branch.is_current));
    let upstream = common::git(&destination, &["config", "branch.from-origin.remote"]);
    assert_eq!(upstream, "origin");
}
