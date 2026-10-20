import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct RebasedCloneDialog: View {
    @Binding var url: String
    @Binding var parentDirectory: String
    @Binding var directoryName: String
    @Binding var recursiveSubmodules: Bool
    @Binding var shallowClone: Bool
    @Binding var depth: String
    let isRunning: Bool
    let isCancelling: Bool
    let onChooseParent: () -> Void
    let onClone: () -> Void
    let onCancel: () -> Void

    private var canClone: Bool {
        let depthValue = depth.trimmingCharacters(in: .whitespacesAndNewlines)
        let validDepth = !shallowClone || (UInt32(depthValue) != nil && UInt32(depthValue)! > 0)
        return !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && validDepth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clone Git Repository")
                .font(.title3.weight(.semibold))
            TextField("Repository URL", text: $url)
                .textFieldStyle(.roundedBorder)
                .disabled(isRunning)
            HStack(spacing: 8) {
                TextField("Parent directory", text: $parentDirectory)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…", action: onChooseParent)
            }
            .disabled(isRunning)
            TextField("Directory name (optional)", text: $directoryName)
                .textFieldStyle(.roundedBorder)
                .disabled(isRunning)
            Toggle("Initialize and update submodules", isOn: $recursiveSubmodules)
                .toggleStyle(.checkbox)
                .disabled(isRunning)
            Toggle("Shallow clone", isOn: $shallowClone)
                .toggleStyle(.checkbox)
                .disabled(isRunning)
            if shallowClone {
                TextField("Depth (positive integer)", text: $depth)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isRunning)
                    .onChange(of: depth) { _, value in
                        let filtered = value.filter(\.isNumber)
                        if filtered != value { depth = filtered }
                    }
                if !depth.isEmpty && (UInt32(depth) == nil || UInt32(depth)! == 0) {
                    Text("Depth must be a positive integer.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text("The destination folder must not already exist.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(isRunning ? (isCancelling ? "Canceling…" : "Cancel Clone") : "Cancel", role: .cancel, action: onCancel)
                    .disabled(isCancelling)
                Button(action: onClone) {
                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView().controlSize(.small)
                        }
                        Text(isRunning ? "Cloning…" : "Clone")
                    }
                    .frame(minWidth: 76)
                }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canClone || isRunning)
            }
        }
        .padding(20)
        .frame(width: 600)
    }
}
