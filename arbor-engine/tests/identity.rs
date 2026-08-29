//! 提交身份、author/committer 与 sign-off 语义。

mod common;

use common::TestRepo;

struct GlobalConfigEnv(Option<std::ffi::OsString>);

impl Drop for GlobalConfigEnv {
    fn drop(&mut self) {
        match self.0.take() {
            Some(value) => std::env::set_var("GIT_CONFIG_GLOBAL", value),
            None => std::env::remove_var("GIT_CONFIG_GLOBAL"),
        }
    }
}

#[test]
fn identity_round_trip_and_commit_options() {
    let repo = TestRepo::new();
    repo.open()
        .set_git_identity(
            "Configured User".into(),
            "configured@example.test".into(),
            Some("ABC123".into()),
            Some("ssh".into()),
            true,
        )
        .unwrap();
    let identity = repo.open().git_identity().unwrap();
    assert_eq!(identity.name.as_deref(), Some("Configured User"));
    assert_eq!(identity.email.as_deref(), Some("configured@example.test"));
    assert_eq!(identity.signing_key.as_deref(), Some("ABC123"));
    assert_eq!(identity.signing_format.as_deref(), Some("ssh"));
    assert!(identity.sign_commits);
    repo.open()
        .set_git_identity(
            "Configured User".into(),
            "configured@example.test".into(),
            Some("ABC123".into()),
            Some("ssh".into()),
            false,
        )
        .unwrap();

    repo.write("identity.txt", "identity");
    repo.open().stage("identity.txt".into()).unwrap();
    let id = repo
        .open()
        .commit_with_options(
            "identity commit".into(),
            false,
            Some("Author User".into()),
            Some("author@example.test".into()),
            Some("Committer User".into()),
            Some("committer@example.test".into()),
            None,
            true,
            Vec::new(),
            false,
        )
        .unwrap();
    assert_eq!(repo.git(&["rev-parse", "HEAD"]), id);
    assert_eq!(
        repo.git(&["show", "-s", "--format=%an <%ae>", "HEAD"]),
        "Author User <author@example.test>"
    );
    assert_eq!(
        repo.git(&["show", "-s", "--format=%cn <%ce>", "HEAD"]),
        "Committer User <committer@example.test>"
    );
    assert!(repo
        .git(&["show", "-s", "--format=%B", "HEAD"])
        .contains("Signed-off-by: Committer User <committer@example.test>"));
}

#[test]
fn global_identity_is_effective_and_removes_local_override() {
    let repo = TestRepo::new();
    common::commit(&repo.path, "f.txt", "1\n", "init");
    let global_path = repo.path.join("global.gitconfig");
    let _global_config_env = GlobalConfigEnv(std::env::var_os("GIT_CONFIG_GLOBAL"));
    std::env::set_var("GIT_CONFIG_GLOBAL", &global_path);

    repo.open()
        .set_git_identity_with_global_name_email(
            "Global User".into(),
            "global@example.test".into(),
            None,
            None,
            false,
        )
        .unwrap();
    let identity = repo.open().git_identity().unwrap();

    assert_eq!(identity.name.as_deref(), Some("Global User"));
    assert_eq!(identity.email.as_deref(), Some("global@example.test"));
    assert_eq!(
        common::git_allow_failure(&repo.path, &["config", "--local", "--get", "user.name"]),
        ""
    );
    assert_eq!(
        common::git_allow_failure(&repo.path, &["config", "--local", "--get", "user.email"]),
        ""
    );
}
