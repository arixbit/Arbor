//! v0.10：提交前检查命令的成功、失败、超时与 argv 语义。

mod common;

use common::TestRepo;

#[test]
fn check_returns_output_and_exit_status_without_shell_expansion() {
    let r = TestRepo::new();
    let repo = r.open();
    let success = repo
        .run_check_command(
            "sh".into(),
            vec![
                "-c".into(),
                "printf '%s' \"$1\"".into(),
                "check".into(),
                "a b".into(),
            ],
        )
        .unwrap();
    assert!(success.success);
    assert_eq!(success.output, "a b");
    assert!(!success.timed_out);

    let failure = repo
        .run_check_command(
            "sh".into(),
            vec!["-c".into(), "printf failed >&2; exit 7".into()],
        )
        .unwrap();
    assert!(!failure.success);
    assert!(failure.output.contains("failed"));
}

#[test]
fn check_kills_a_timed_out_process() {
    let r = TestRepo::new();
    let outcome = r
        .open()
        .run_check_command_with_timeout("sh".into(), vec!["-c".into(), "sleep 2".into()], 1)
        .unwrap();
    assert!(!outcome.success);
    assert!(outcome.timed_out);
    assert!(outcome.output.contains("timed out"));
}
