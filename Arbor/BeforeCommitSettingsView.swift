import SwiftUI
import AppKit
import UniformTypeIdentifiers


private let beforeCommitCommandsKey = "arbor.beforeCommitCommands"

func loadBeforeCommitCommands() -> [BeforeCommitCommand] {
    guard let data = UserDefaults.standard.data(forKey: beforeCommitCommandsKey),
          let commands = try? JSONDecoder().decode([BeforeCommitCommand].self, from: data) else {
        return []
    }
    return commands
}

func saveBeforeCommitCommands(_ commands: [BeforeCommitCommand]) {
    guard let data = try? JSONEncoder().encode(commands) else { return }
    UserDefaults.standard.set(data, forKey: beforeCommitCommandsKey)
}

struct BeforeCommitSettingsView: View {
    @Binding var commands: [BeforeCommitCommand]
    let onIdentity: () -> Void
    @State private var command = ""
    @State private var arguments = ""

    init(commands: Binding<[BeforeCommitCommand]>, onIdentity: @escaping () -> Void = {}) {
        self._commands = commands
        self.onIdentity = onIdentity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Before Commit Checks")
                .font(.title3)
                .bold()
            Text("Enter one argument per line. Commands run as argv without a shell.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                TextField("Command, e.g. cargo", text: $command)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $arguments)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 180, height: 52)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                Button("Add", action: addCommand)
                    .disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            List {
                ForEach(commands) { item in
                    HStack {
                        Text(item.display)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button("Delete") { commands.removeAll { $0.id == item.id } }
                    }
                }
                .onMove { commands.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.inset)
            HStack {
                Button("Commit identity & signing", action: onIdentity)
                Spacer()
                Button("Done") { saveBeforeCommitCommands(commands) }
            }
        }
        .padding(16)
        .frame(width: 620, height: 380)
        .onDisappear { saveBeforeCommitCommands(commands) }
    }

    private func addCommand() {
        let name = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let args = arguments.split(separator: "\n", omittingEmptySubsequences: true).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        commands.append(BeforeCommitCommand(command: name, args: args))
        command = ""
        arguments = ""
    }
}
