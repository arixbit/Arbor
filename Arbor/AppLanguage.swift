import SwiftUI

/// The language used by Arbor's own menus and interface.
/// This is intentionally separate from the syntax language of an opened file.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    var locale: Locale {
        switch self {
        case .system:
            return .current
        case .simplifiedChinese:
            return Locale(identifier: "zh-Hans")
        case .english:
            return Locale(identifier: "en")
        }
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .system:
            return "System Default"
        case .simplifiedChinese:
            return "Simplified Chinese"
        case .english:
            return "English"
        }
    }
}

struct AppLanguageMenu: View {
    @AppStorage("arbor.appLanguage") private var selectedLanguage = AppLanguage.system.rawValue

    private var currentLanguage: AppLanguage {
        AppLanguage(rawValue: selectedLanguage) ?? .system
    }

    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { language in
                Button {
                    selectedLanguage = language.rawValue
                } label: {
                    HStack {
                        Text(language.displayName)
                        if language == currentLanguage {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            SettingsLink {
                Label("Language Settings…", systemImage: "gearshape")
            }
        } label: {
            Label("Language", systemImage: "globe")
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .foregroundStyle(.secondary)
        .help("Application language")
        .accessibilityLabel("Application language")
    }
}

struct AppLanguageSettingsSection: View {
    @AppStorage("arbor.appLanguage") private var selectedLanguage = AppLanguage.system.rawValue

    var body: some View {
        Section("Language") {
            Picker("Application Language", selection: $selectedLanguage) {
                ForEach(AppLanguage.allCases) { language in
                    Text(language.displayName).tag(language.rawValue)
                }
            }

            Text("Choose the language Arbor uses for menus and interface.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
