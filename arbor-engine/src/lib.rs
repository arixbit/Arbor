uniffi::setup_scaffolding!();

mod attributes;
mod auth;
mod blame;
mod branch;
mod changelist;
mod checks;
mod commit_message;
mod conflict;
mod diff;
mod error;
mod gitprocess;
mod gpg;
mod highlight;
mod hooks;
mod index;
mod log;
mod merge;
mod opstate;
mod rebasetodo;
mod remote;
mod repo;
mod roots;
mod shelve;
mod staging;
mod stagingmodel;
mod stash;
mod status;
mod tree;

pub use attributes::{
    AttributeValue, ConfigEntry, ConfigScope, EffectiveLineEndings, FileAttributes, LineEnding,
};
pub use auth::{
    AuthenticationSuccess, CredentialBroker, CredentialDecision, CredentialKind, CredentialRequest,
    CredentialRequestHandler, CredentialResponse,
};
pub use blame::{BlameLine, BlameMovement, BlameOptions};
pub use branch::{
    BranchCompare, BranchCompareEntry, BranchDeleteCommit, BranchDeletePreview, BranchInfo,
    RemoteBranchInfo, RemoteTagInfo, SyncStatus, TagInfo, TagKind,
};
pub use changelist::{ChangeListInfo, ChangeListMetadata};
pub use checks::{
    CheckOutcome, CommitCheckKind, CommitCheckResult, CredentialHelperInfo, SigningConfig,
    SshAgentDiagnostics, SshAgentState,
};
pub use conflict::{
    ConflictBatchAction, ConflictBatchPreview, ConflictBatchResult, ConflictWorkspace,
    ConflictWorkspaceFile, FilePick,
};
pub use diff::{DiffHunk, DiffLine, DiffLineKind, DiffMode, DiffSettings, FileDiff, WordSpan};
pub use error::{EngineError, PushFailureKind};
pub use gitprocess::{
    clear_project_git_executable, git_executable, git_executable_version, git_progress_state,
    project_git_executable, set_git_executable, set_pinentry_user_data, set_project_git_executable,
    test_git_executable, GitCancelHandle, GitFailureKind, GitProcessOutcome, GitProgressState,
    GitStreamEvent,
};
pub use gpg::{configure_gpg_agent, gpg_agent_status, GpgAgentStatus};
pub use highlight::{highlight_code, HighlightKind, HighlightSpan};
pub use log::{
    CommitDiff, CommitInfo, CommitSignatureInfo, LogGraphSortMode, ReflogEntry, SignatureStatus,
};
pub use merge::{
    BlockDecision, ConflictBlock, ConflictFile, MergeMode, MergeOptions, MergeOutcome, PickKind,
    PullOptions,
};
pub use opstate::{OperationKind, OperationOrigin, OperationState, RebaseBackend};
pub use rebasetodo::{RebaseTodo, RebaseTodoAction, RebaseTodoItem};
pub use remote::{
    CommitPushOutcome, FetchOutcome, FetchTagsMode, PushTagMode, RebaseAction, RebaseOutcome,
    RebasePauseReason, RemoteInfo,
};
pub use repo::{
    clone_repository, clone_repository_with_auth_options, clone_repository_with_options,
    initialize_repository, open_repository, workspace_status, CherryPickEmptyPolicy, DirEntry,
    ExternalMergeToolResult, ExternalMergeToolSettings, FileContent,
    ForcePushedBranchUpdateOutcome, GitCommandResult, GitContentTransformMode, GitIdentity,
    LocalChangesRestoreInfo, LocalChangesSavePolicy, PatchApplyMemberResult, PatchApplyResult,
    PatchApplyStatus, Repository, ResetMode, ResetRecoveryInfo, ResetRecoveryTarget,
    RevertMainline, RevisionEntry, SshAuthMethod, SshConnectionSettings, SshHostKeyPolicy,
    StagingFileVersions, StagingVersionContent, SubmoduleAddUndoTarget, SubmoduleChange,
    SubmoduleInfo, SubmoduleRemoveUndoTarget, SubmoduleState, WorkspaceEntry, WorktreeInfo,
};
pub use roots::{
    discover_git_roots, keep_multi_root_reset_recovery, list_multi_root_branches,
    restore_multi_root_checkout, rollback_multi_root_branch_create,
    rollback_multi_root_branch_create_with_state, rollback_multi_root_reset,
    rollback_multi_root_reset_recovery, run_multi_root_branch_create,
    run_multi_root_branch_create_with_options, run_multi_root_checkout,
    run_multi_root_checkout_and_update, run_multi_root_checkout_and_update_with_policy,
    run_multi_root_checkout_and_update_with_policy_and_options,
    run_multi_root_checkout_with_policy, run_multi_root_commit,
    run_multi_root_commit_selected_paths_with_options, run_multi_root_commit_with_options,
    run_multi_root_force_pushed_branch_update_with_auth_and_cancel, run_multi_root_merge,
    run_multi_root_merge_with_policy, run_multi_root_operation, run_multi_root_operation_on_roots,
    run_multi_root_push, run_multi_root_push_recovery, run_multi_root_push_recovery_with_options,
    run_multi_root_push_recovery_with_options_and_fetch_tags,
    run_multi_root_push_with_force_options, run_multi_root_push_with_options,
    run_multi_root_push_with_targets, run_multi_root_rebase, run_multi_root_rebase_with_cancel,
    run_multi_root_reset_with_policy, run_multi_root_reset_with_targets, run_multi_root_update,
    run_multi_root_update_selected_with_policy,
    run_multi_root_update_selected_with_policy_and_options, run_multi_root_update_with_policy,
    run_multi_root_update_with_policy_and_options, run_root_update_for_current_branch_with_options,
    run_root_update_for_push_recovery, run_root_update_for_push_recovery_with_options,
    run_submodule_update_with_policy, GitRootBranchSnapshot, GitRootInfo,
    MultiRootBranchCreateTarget, MultiRootBranchResult, MultiRootBranchTarget,
    MultiRootCheckoutMode, MultiRootCommitCheck, MultiRootCommitOptions, MultiRootCommitSelection,
    MultiRootForcePushedBranchUpdateResult, MultiRootMergeResult, MultiRootOperation,
    MultiRootPushTarget, MultiRootRebaseResult, MultiRootRebaseSpec, MultiRootResetResult,
    MultiRootResetRollbackTarget, MultiRootResetTarget, RootOperationResult,
    RootProtectedBranchPatterns,
};
pub use shelve::{
    ShelveInfo, ShelvePatchSelection, ShelveRestoreHunkResolution, ShelveRestoreInfo,
};
pub use staging::LineSelection;
pub use stagingmodel::{IndexRevision, StagingEntry, StagingFileDiff, StagingModel, StagingStatus};
pub use stash::StashInfo;
pub use status::{ChangeKind, FileEntry, IgnoreRuleInfo, IgnoreRuleSource};
pub use tree::{TreeChange, TreeChangeKind};
