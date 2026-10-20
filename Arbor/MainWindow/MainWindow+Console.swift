import SwiftUI
import AppKit


/// The IntelliJ Smart Operation dialog is a decision point, not a transient
/// warning: it shows the exact paths Git reported and keeps Smart/Force/Cancel
/// mutually exclusive until the user chooses one.
struct SmartOperationRequest: Identifiable {
    let id = UUID()
    let operationTitle: String
    let smartButtonTitle: String
    let forceButtonTitle: String?
    let paths: [String]
    let detail: String?
    let localChangesSavePolicy: GitLocalChangesSavePolicyChoice
    let onSmart: () -> Void
    let onForce: (() -> Void)?
}

enum OperationsViewMode: String, CaseIterable, Identifiable {
    case tasks
    case history
    case console
    case worktrees
    case submodules
    case roots

    var id: String { rawValue }
    var title: String {
        switch self {
        case .tasks: "任务"
        case .history: "操作历史"
        case .console: "Git Console"
        case .worktrees: "Worktrees"
        case .submodules: "Submodules"
        case .roots: "Git Roots"
        }
    }
}
