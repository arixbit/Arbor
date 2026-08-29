//! CFG-001:config 三层解析、check-attr 建模、CRLF 有效行为。
//! 真实 fixture:.gitattributes 规则 + core.autocrlf/core.eol 变体,
//! 断言与 git 自身输出一致。

mod common;

use arbor_engine::{AttributeValue, ConfigScope, LineEnding};
use common::TestRepo;

#[test]
fn parses_config_scopes_and_effective_value() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x", "init");
    // local 层设置
    r.git(&["config", "core.autocrlf", "input"]);

    let repo = r.open();
    let entries = repo.git_config_entries().expect("config entries");
    assert!(!entries.is_empty());
    let local_crlf: Vec<_> = entries
        .iter()
        .filter(|e| e.key == "core.autocrlf")
        .collect();
    assert!(!local_crlf.is_empty(), "core.autocrlf should be listed");
    // 宿主 global/system 配置可能也定义了 core.autocrlf,只断言 local 层存在
    assert!(
        local_crlf
            .iter()
            .any(|e| e.scope == ConfigScope::Local && e.value == "input"),
        "local core.autocrlf=input missing: {local_crlf:?}"
    );
    assert!(local_crlf
        .iter()
        .filter(|e| e.scope == ConfigScope::Local)
        .all(|e| e
            .origin
            .as_deref()
            .map(|o| o.contains(".git/config"))
            .unwrap_or(false)));

    // 生效值取最后一条
    assert_eq!(
        repo.config_value("core.autocrlf".into()).expect("value"),
        Some("input".to_string())
    );
    // 未设置的 key 返回 None
    assert_eq!(
        repo.config_value("no.such.key".into()).expect("value"),
        None
    );
}

#[test]
fn check_attr_matches_gitattributes_rules() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt text\n*.bat eol=crlf\n*.png binary\n*.md diff=hex\n*.gen merge=ours\n*.f filter=lfs\n*.utf16 working-tree-encoding=UTF-16\n*.raw -text\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    r.write("a.txt", "hello\n");
    r.write("run.bat", "dir\r\n");
    r.write("img.png", "\u{fffd}bin");
    r.write("readme.md", "# t");
    r.write("x.gen", "g");
    r.write("blob.f", "f");
    r.write("notes.utf16", "n");
    r.write("movie.raw", "r");

    let repo = r.open();
    let attrs = repo
        .file_attributes(vec![
            "a.txt".into(),
            "run.bat".into(),
            "img.png".into(),
            "readme.md".into(),
            "x.gen".into(),
            "blob.f".into(),
            "notes.utf16".into(),
            "movie.raw".into(),
        ])
        .expect("attributes");
    assert_eq!(attrs.len(), 8);

    let a = &attrs[0];
    assert_eq!(a.text, AttributeValue::Set);
    assert_eq!(a.eol, AttributeValue::Unspecified);
    assert_eq!(a.binary, AttributeValue::Unspecified);

    let bat = &attrs[1];
    assert_eq!(
        bat.eol,
        AttributeValue::Value {
            value: "crlf".into()
        }
    );

    let png = &attrs[2];
    assert_eq!(png.binary, AttributeValue::Set);

    let md = &attrs[3];
    assert_eq!(
        md.diff,
        AttributeValue::Value {
            value: "hex".into()
        }
    );

    let gen = &attrs[4];
    assert_eq!(
        gen.merge,
        AttributeValue::Value {
            value: "ours".into()
        }
    );

    let lfs = &attrs[5];
    assert_eq!(
        lfs.filter,
        AttributeValue::Value {
            value: "lfs".into()
        }
    );

    let utf16 = &attrs[6];
    assert_eq!(
        utf16.working_tree_encoding,
        AttributeValue::Value {
            value: "UTF-16".into()
        }
    );

    let raw = &attrs[7];
    assert_eq!(raw.text, AttributeValue::Unset);
}

#[test]
fn eol_attribute_forces_crlf_checkout_and_lf_commit() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.bat eol=crlf\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    r.write("run.bat", "dir\n");

    let repo = r.open();
    let endings = repo
        .effective_line_endings("run.bat".into())
        .expect("endings");
    assert!(endings.normalize_to_lf_on_commit);
    assert_eq!(endings.checkout_line_ending, LineEnding::Crlf);
}

#[test]
fn binary_attribute_disables_normalization() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.png binary\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    r.write("img.png", "png");

    let repo = r.open();
    let endings = repo
        .effective_line_endings("img.png".into())
        .expect("endings");
    assert!(!endings.normalize_to_lf_on_commit);
}

#[test]
fn autocrlf_true_normalizes_and_checks_out_crlf() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x", "init");
    r.git(&["config", "core.autocrlf", "true"]);
    r.write("plain.txt", "a\r\nb\r\n");

    let repo = r.open();
    let endings = repo
        .effective_line_endings("plain.txt".into())
        .expect("endings");
    assert!(endings.normalize_to_lf_on_commit);
    assert_eq!(endings.checkout_line_ending, LineEnding::Crlf);
}

#[test]
fn autocrlf_input_normalizes_but_keeps_lf_checkout() {
    let r = TestRepo::new();
    common::commit(&r.path, "f.txt", "x", "init");
    r.git(&["config", "core.autocrlf", "input"]);
    r.write("plain.txt", "a\r\nb\r\n");

    let repo = r.open();
    let endings = repo
        .effective_line_endings("plain.txt".into())
        .expect("endings");
    assert!(endings.normalize_to_lf_on_commit);
    assert_eq!(endings.checkout_line_ending, LineEnding::Lf);
}

#[test]
fn explicit_text_unset_beats_autocrlf() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.raw -text\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    r.git(&["config", "core.autocrlf", "true"]);
    r.write("data.raw", "x\r\n");

    let repo = r.open();
    let endings = repo
        .effective_line_endings("data.raw".into())
        .expect("endings");
    assert!(!endings.normalize_to_lf_on_commit);
}

#[test]
fn crlf_roundtrip_with_git_matches_prediction() {
    // 端到端:预测的入库规范行为与 git 实际入库结果一致
    // (eol=crlf 文件提交后,库内 blob 是 LF)。
    let r = TestRepo::new();
    r.write(".gitattributes", "*.bat eol=crlf\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    r.write("run.bat", "one\r\ntwo\r\n");
    r.git(&["add", "run.bat"]);
    r.git(&["commit", "-q", "-m", "crlf"]);

    let repo = r.open();
    let endings = repo
        .effective_line_endings("run.bat".into())
        .expect("endings");
    assert!(endings.normalize_to_lf_on_commit);
    // 库内内容应该是 LF
    let blob = r.git(&["cat-file", "-p", "HEAD:run.bat"]);
    assert_eq!(blob, "one\ntwo");
    // 工作区仍是 CRLF(git 不主动重写已存在文件,但检出方向预测为 CRLF)
    assert_eq!(r.read("run.bat"), "one\r\ntwo\r\n");
}

#[test]
fn stage_normalizes_text_crlf_into_index() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt text\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    r.write("notes.txt", "one\r\ntwo\r\n");

    let repo = r.open();
    repo.stage("notes.txt".into()).expect("stage text file");

    let staged = repo
        .staging_file_versions("notes.txt".into())
        .expect("staging versions")
        .staged;
    assert_eq!(staged.text, "one\ntwo\n");
    let status = repo.status().expect("status after stage");
    assert_eq!(r.git(&["status", "--short"]), "A  notes.txt");
    assert_eq!(status.len(), 1);
    assert_eq!(status[0].staged, arbor_engine::ChangeKind::Added);
    assert_eq!(status[0].unstaged, arbor_engine::ChangeKind::Unchanged);
    assert_eq!(r.read("notes.txt"), "one\r\ntwo\r\n");
}

#[test]
fn stage_preserves_binary_attribute_line_endings() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.dat binary\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    r.write("payload.dat", "one\r\ntwo\r\n");

    let repo = r.open();
    repo.stage("payload.dat".into()).expect("stage binary file");

    let staged = repo
        .staging_file_versions("payload.dat".into())
        .expect("staging versions")
        .staged;
    assert_eq!(staged.text, "one\r\ntwo\r\n");
}

#[test]
fn partial_stage_uses_canonical_text_when_worktree_is_crlf() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt text\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    common::commit(&r.path, "notes.txt", "one\ntwo\nthree\n", "base");
    r.write("notes.txt", "one\r\nchanged\r\nthree\r\n");

    let repo = r.open();
    repo.stage_lines(
        "notes.txt".into(),
        vec![arbor_engine::LineSelection {
            hunk_index: 0,
            old_lines: vec![2],
            new_lines: vec![],
        }],
    )
    .expect("partial stage CRLF text");

    let staged = repo
        .staging_file_versions("notes.txt".into())
        .expect("staging versions")
        .staged;
    assert_eq!(staged.text, "one\nchanged\nthree\n");
    assert_eq!(r.read("notes.txt"), "one\r\nchanged\r\nthree\r\n");
}

#[test]
fn restore_unstaged_lines_writes_back_checkout_line_endings() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt text eol=crlf\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    common::commit(&r.path, "notes.txt", "one\ntwo\n", "base");
    r.write("notes.txt", "one\r\nchanged\r\n");

    let repo = r.open();
    repo.restore_unstaged_lines(
        "notes.txt".into(),
        vec![arbor_engine::LineSelection {
            hunk_index: 0,
            old_lines: vec![],
            new_lines: vec![],
        }],
    )
    .expect("restore selected text hunk");

    assert_eq!(r.read("notes.txt"), "one\r\ntwo\r\n");
    assert_eq!(r.git(&["diff", "--", "notes.txt"]), "");
}

#[test]
fn diff_driver_name_does_not_disable_crlf_clean() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt diff=binary\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    r.git(&["config", "core.autocrlf", "true"]);
    r.write("notes.txt", "one\r\ntwo\r\n");

    let repo = r.open();
    repo.stage("notes.txt".into())
        .expect("diff driver must not block clean");
    let staged = repo
        .staging_file_versions("notes.txt".into())
        .expect("staging versions")
        .staged;
    assert_eq!(staged.text, "one\ntwo\n");
}

#[test]
fn branch_checkout_applies_attribute_checkout_line_endings() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt text eol=crlf\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    common::commit(&r.path, "notes.txt", "one\n", "base");
    r.git(&["branch", "other"]);
    common::commit(&r.path, "notes.txt", "two\n", "main change");

    let repo = r.open();
    repo.switch_branch("other".into())
        .expect("checkout branch with eol=crlf");
    assert_eq!(r.read("notes.txt"), "one\r\n");

    repo.switch_branch("main".into())
        .expect("checkout main with eol=crlf");
    assert_eq!(r.read("notes.txt"), "two\r\n");
}

#[test]
fn branch_checkout_uses_target_attributes_for_same_tree_change() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.txt text eol=lf\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "lf attributes",
    );
    common::commit(&r.path, "notes.txt", "one\n", "base");
    r.git(&["branch", "lf"]);

    r.write(".gitattributes", "*.txt text eol=crlf\n");
    r.write("notes.txt", "two\n");
    r.git(&["add", ".gitattributes", "notes.txt"]);
    r.git(&["commit", "-q", "-m", "crlf attributes"]);

    let repo = r.open();
    repo.switch_branch("lf".into())
        .expect("checkout branch with lf attributes");
    assert_eq!(r.read("notes.txt"), "one\n");

    repo.switch_branch("main".into())
        .expect("checkout branch with changed attributes");
    assert_eq!(r.read("notes.txt"), "two\r\n");
}

#[test]
fn checkout_rejects_target_clean_filter_before_mutating_worktree() {
    let r = TestRepo::new();
    common::commit(&r.path, "notes.txt", "base\n", "base");
    r.git(&["branch", "filter"]);
    r.git(&["switch", "filter"]);
    r.write(".gitattributes", "*.secret filter=secret-clean\n");
    r.write("token.secret", "secret\n");
    r.git(&["add", ".gitattributes", "token.secret"]);
    r.git(&["commit", "-q", "-m", "filter"]);
    r.git(&["switch", "main"]);

    let repo = r.open();
    let error = repo
        .switch_branch("filter".into())
        .expect_err("unsupported checkout filter must fail closed");
    assert!(error.to_string().contains("custom clean filter"));
    assert_eq!(r.git(&["branch", "--show-current"]), "main");
    assert_eq!(r.read("notes.txt"), "base\n");
    assert!(!r.exists(".gitattributes"));
    assert!(!r.exists("token.secret"));
}

#[test]
fn stage_rejects_custom_clean_filter_instead_of_silently_misindexing() {
    let r = TestRepo::new();
    r.write(".gitattributes", "*.secret filter=secret-clean\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    r.write("token.secret", "plain\n");

    let error = r
        .open()
        .stage("token.secret".into())
        .expect_err("custom clean filter must be rejected");
    let message = error.to_string();
    assert!(message.contains("custom clean filter"), "{message}");
}

#[test]
fn external_filter_opt_in_matches_git_clean_and_checkout() {
    let r = TestRepo::new();
    r.git(&["config", "filter.upper.clean", "tr a-z A-Z"]);
    r.git(&["config", "filter.upper.smudge", "tr A-Z a-z"]);
    r.write(".gitattributes", "*.txt filter=upper\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    common::commit(&r.path, "note.txt", "base\n", "base");
    r.git(&["branch", "target"]);
    r.git(&["switch", "target"]);
    r.write("note.txt", "TARGET\n");
    r.git(&["add", "note.txt"]);
    r.git(&["commit", "-q", "-m", "target"]);
    r.git(&["switch", "main"]);

    let repo = r.open();
    repo.set_external_conversion_enabled(true)
        .expect("enable external conversion for this root");
    r.write("note.txt", "mixed\n");
    repo.stage("note.txt".into())
        .expect("custom clean filter should run when opted in");
    let staged = repo
        .staging_file_versions("note.txt".into())
        .expect("staging versions")
        .staged;
    assert_eq!(staged.text, "MIXED\n");

    r.git(&["reset", "--hard", "main"]);
    let checkout_repo = r.open();
    checkout_repo
        .set_external_conversion_enabled(true)
        .expect("enable external conversion for checkout root");
    checkout_repo
        .switch_branch("target".into())
        .expect("custom smudge filter should run on checkout");
    assert_eq!(r.read("note.txt"), "target\n");
}

#[test]
fn diff_driver_attribute_visible_for_diff_consistency() {
    // .gitattributes 改变 diff driver 后,引擎能读到同一事实,
    // DIFF-001 的 attributes-aware diff 以此为数据源。
    let r = TestRepo::new();
    r.write(".gitattributes", "*.spec diff=spec\n");
    common::commit(
        &r.path,
        ".gitattributes",
        &r.read(".gitattributes"),
        "attrs",
    );
    r.write("a.spec", "x");

    let repo = r.open();
    let attrs = repo
        .file_attributes(vec!["a.spec".into()])
        .expect("attributes");
    assert_eq!(
        attrs[0].diff,
        AttributeValue::Value {
            value: "spec".into()
        }
    );
}
