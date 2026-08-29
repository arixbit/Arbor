//! 托管仓库链接回归测试：覆盖 Log Changes Browser 的文件级链接。

mod common;

use common::TestRepo;

#[test]
fn file_permalink_matches_hosting_provider_path_conventions() {
    let repo = TestRepo::new().open();

    assert_eq!(
        repo.permalink_for_path(
            "git@github.com:arbor/example.git".into(),
            "0123456789abcdef".into(),
            "Sources/README #1.md".into(),
        ),
        Some(
            "https://github.com/arbor/example/blob/0123456789abcdef/Sources/README%20%231.md"
                .into()
        )
    );
    assert_eq!(
        repo.permalink_for_path(
            "ssh://git@gitlab.com/arbor/example.git".into(),
            "deadbeef".into(),
            "src/lib.rs".into(),
        ),
        Some("https://gitlab.com/arbor/example/-/blob/deadbeef/src/lib.rs".into())
    );
    assert_eq!(
        repo.permalink_for_path(
            "https://bitbucket.org/arbor/example.git".into(),
            "cafebabe".into(),
            "README.md".into(),
        ),
        Some("https://bitbucket.org/arbor/example/src/cafebabe/README.md".into())
    );
}

#[test]
fn file_permalink_fails_closed_for_invalid_or_unhosted_inputs() {
    let repo = TestRepo::new().open();

    assert_eq!(
        repo.permalink_for_path(
            "https://example.com/arbor/example.git".into(),
            "deadbeef".into(),
            "README.md".into(),
        ),
        None
    );
    assert_eq!(
        repo.permalink_for_path(
            "https://github.com/arbor/example.git".into(),
            "deadbeef".into(),
            "".into(),
        ),
        None
    );
    assert_eq!(
        repo.permalink_for_path(
            "https://github.com/arbor/example.git".into(),
            "deadbeef".into(),
            "bad\0path".into(),
        ),
        None
    );
}

#[test]
fn pull_request_url_matches_hosting_provider_conventions_and_encodes_branch() {
    let repo = TestRepo::new().open();
    let branch = "feature/topic #1";

    assert_eq!(
        repo.pr_url("git@github.com:arbor/example.git".into(), branch.into(),),
        Some("https://github.com/arbor/example/compare/feature%2Ftopic%20%231?expand=1".into())
    );
    assert_eq!(
        repo.pr_url(
            "ssh://git@gitlab.com/arbor/example.git".into(),
            branch.into(),
        ),
        Some(
            "https://gitlab.com/arbor/example/-/merge_requests/new?merge_request%5Bsource_branch%5D=feature%2Ftopic%20%231".into()
        )
    );
    assert_eq!(
        repo.pr_url(
            "ssh://git@bitbucket.org/arbor/example.git".into(),
            branch.into(),
        ),
        Some(
            "https://bitbucket.org/arbor/example/pull-requests/new?source=feature%2Ftopic%20%231"
                .into()
        )
    );
}

#[test]
fn pull_request_url_fails_closed_for_invalid_or_unhosted_inputs() {
    let repo = TestRepo::new().open();

    assert_eq!(
        repo.pr_url("https://github.com/arbor/example.git".into(), "".into()),
        None
    );
    assert_eq!(
        repo.pr_url(
            "https://github.com/arbor/example.git".into(),
            "bad\0branch".into(),
        ),
        None
    );
    assert_eq!(
        repo.pr_url(
            "https://example.com/arbor/example.git".into(),
            "feature/topic".into(),
        ),
        None
    );
}
