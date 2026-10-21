import Foundation

func gitProjectSettingsKey(_ prefix: String, for projectPath: String) -> String {
    let normalized = URL(fileURLWithPath: projectPath).standardizedFileURL.path
    return prefix + Data(normalized.utf8).base64EncodedString()
}
