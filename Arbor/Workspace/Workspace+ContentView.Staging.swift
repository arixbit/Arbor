import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ContentView {
func createChangeList() {
    guard let repo else { return }
    let alert = NSAlert()
    alert.messageText = "New Changelist"
    alert.informativeText = "Create an empty local Changes Browser list."
    let nameField = NSTextField(frame: .zero)
    nameField.placeholderString = "Name"
    let descriptionField = NSTextField(frame: .zero)
    descriptionField.placeholderString = "Description (optional)"
    let activeButton = NSButton(checkboxWithTitle: "Set active", target: nil, action: nil)
    activeButton.state = .off
    let contextLabel = NSTextField(labelWithString: "Track Context is unavailable without a task provider.")
    contextLabel.textColor = .secondaryLabelColor
    contextLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    let stack = NSStackView(views: [nameField, descriptionField, activeButton, contextLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.setCustomSpacing(2, after: descriptionField)
    nameField.translatesAutoresizingMaskIntoConstraints = false
    descriptionField.translatesAutoresizingMaskIntoConstraints = false
    nameField.widthAnchor.constraint(equalToConstant: 320).isActive = true
    descriptionField.widthAnchor.constraint(equalToConstant: 320).isActive = true
    alert.accessoryView = stack
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    let description = descriptionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    let shouldActivate = activeButton.state == .on

    beginFeedbackOperation("Create changelist")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.changelistCreate(name: name)
            if !description.isEmpty {
                try repo.changelistSetMetadata(
                    name: name,
                    description: description,
                    trackContext: false,
                    taskIdentity: nil
                )
            }
            if shouldActivate {
                try repo.changelistActivate(name: name)
            }
            let lists = try repo.changelistList()
            await MainActor.run {
                guard self.projectRepo === repo else { return }
                self.changeLists = lists
                self.feedbackCenter.success("Changelist created", detail: name)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Changelist creation failed", detail: errorMessage(error))
            }
        }
    }
}

func renameChangeList(_ oldName: String) {
    guard let repo else { return }
    let alert = NSAlert()
    alert.messageText = "Rename Changelist"
    alert.informativeText = oldName
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.stringValue = oldName
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !newName.isEmpty, newName != oldName else { return }

    beginFeedbackOperation("Rename changelist")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.changelistRename(oldName: oldName, newName: newName)
            let lists = try repo.changelistList()
            await MainActor.run {
                guard self.projectRepo === repo else { return }
                self.changeLists = lists
                self.feedbackCenter.success("Changelist renamed", detail: newName)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Changelist rename failed", detail: errorMessage(error))
            }
        }
    }
}

func deleteChangeList(_ name: String) {
    guard let repo else { return }
    let alert = NSAlert()
    alert.messageText = "Delete Changelist"
    alert.informativeText = "Changes in \"\(name)\" will move to the default list."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }

    beginFeedbackOperation("Delete changelist")
    Task.detached(priority: .userInitiated) {
        do {
            try repo.changelistDelete(name: name)
            let lists = try repo.changelistList()
            await MainActor.run {
                guard self.projectRepo === repo else { return }
                self.changeLists = lists
                self.feedbackCenter.success("Changelist deleted", detail: name)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Changelist deletion failed", detail: errorMessage(error))
            }
        }
    }
}

func activateChangeList(_ name: String) {
    guard let repo else { return }
    Task.detached(priority: .utility) {
        do {
            try repo.changelistActivate(name: name)
            let lists = try repo.changelistList()
            await MainActor.run {
                guard self.projectRepo === repo else { return }
                self.changeLists = lists
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Changelist activation failed", detail: errorMessage(error))
            }
        }
    }
}

func movePathsToChangeList(_ paths: [String], _ targetName: String) {
    guard let repo, !paths.isEmpty else { return }
    let commentField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    commentField.placeholderString = "Comment (optional)"
    let alert = NSAlert()
    alert.messageText = "Move to Changelist"
    alert.informativeText = "Move \(paths.count) change(s) to \"\(targetName)\"."
    alert.accessoryView = commentField
    alert.addButton(withTitle: "Move")
    alert.addButton(withTitle: "Cancel")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let comment = commentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    Task.detached(priority: .userInitiated) {
        do {
            try repo.changelistMovePaths(paths: paths, targetName: targetName)
            if !comment.isEmpty {
                let metadata = try repo.changelistMetadata()
                    .first(where: { $0.name == targetName })
                let existing = metadata?.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let description = existing.isEmpty
                    ? comment
                    : (existing == comment ? existing : "\(existing)\n\n\(comment)")
                try repo.changelistSetMetadata(
                    name: targetName,
                    description: description,
                    trackContext: metadata?.trackContext ?? false,
                    taskIdentity: metadata?.taskIdentity
                )
            }
            let lists = try repo.changelistList()
            await MainActor.run {
                guard self.projectRepo === repo else { return }
                self.changeLists = lists
                self.feedbackCenter.success("Changes moved", detail: targetName)
            }
        } catch {
            await MainActor.run {
                self.feedbackCenter.error("Move changes failed", detail: errorMessage(error))
            }
        }
    }
}

}
