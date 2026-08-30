import SwiftUI

enum ArborAboutMetadata {
    static let repositoryURL = URL(string: "https://github.com/arixbit/Arbor")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? String(localized: "Development Build")
    }

    static var architecture: String {
        #if arch(arm64)
        return "Apple Silicon (arm64)"
        #elseif arch(x86_64)
        return "Intel (x86_64)"
        #else
        return "Unknown"
        #endif
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: Design.Spacing.lg) {
            Image("ArborAppIcon")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 96, height: 96)

            VStack(spacing: Design.Spacing.sm) {
                Text("Arbor")
                    .font(.system(size: 28, weight: .semibold))
                Text("Native macOS Git workbench")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Arbor helps you review changes, manage branches, resolve conflicts, and work with Git remotes in a focused native macOS app.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: Design.Spacing.sm) {
                aboutRow("Version", value: ArborAboutMetadata.version)
                aboutRow("Platform", value: "macOS 14 or later")
                aboutRow("Architecture", value: ArborAboutMetadata.architecture)
                aboutRow("License", value: "MIT License")
            }
            .frame(maxWidth: .infinity)

            Link(destination: ArborAboutMetadata.repositoryURL) {
                Label("GitHub Repository", systemImage: "arrow.up.right.square")
            }
            .help("Open the Arbor source repository on GitHub")

            Text("Open source under the MIT License.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Built with SwiftUI and Rust.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(Design.Spacing.xl)
        .frame(width: 430)
    }

    private func aboutRow(_ title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: Design.Spacing.md)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

#Preview {
    AboutView()
}
