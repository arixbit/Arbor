import SwiftUI
import AppKit

extension ContentView {

    var protectedBranchPatterns: String {
        gitSettings.projectProtectedBranchPatterns ?? globalProtectedBranchPatterns
    }

    var protectedBranchSynchronize: Bool {
        gitSettings.projectProtectedBranchSynchronize ?? globalProtectedBranchSynchronize
    }

    var incomingCheckStrategy: GitIncomingCheckStrategy {
        guard incomingOutgoingInfoEnabled else { return .none }
        if let projectIncomingCheckStrategyRaw = gitSettings.projectIncomingCheckStrategyRaw {
            return GitIncomingCheckStrategy(rawValue: projectIncomingCheckStrategyRaw) ?? .none
        }
        return resolveGitIncomingCheckStrategy(
            storedRawValue: UserDefaults.standard.object(forKey: GitIncomingCheckStrategy.userDefaultsKey) == nil
                ? nil
                : incomingCheckStrategyRaw,
            legacyAutoFetch: gitAutoFetch
        )
    }

    var fetchTagsMode: FetchTagsMode {
        gitSettings.projectFetchTagsMode.engineValue
    }

    var effectiveProtectedBranchPatterns: [String] {
        effectiveProtectedBranchPatterns(forRootPath: nil)
    }

    func effectiveProtectedBranchPatterns(forRootPath rootPath: String?) -> [String] {
        let cachedPatterns = GitProtectedBranchRules.remotePatterns(
            forRootPath: rootPath,
            primaryPatterns: gitSettings.remoteProtectedBranchPatterns,
            patternsByRoot: gitSettings.remoteProtectedBranchPatternsByRoot
        )
        let remotePatterns: [String] = {
            guard let rootPath,
                  !gitSettings.remoteProtectedBranchPatternsByRoot.keys.contains(
                    canonicalExternalLogPath(rootPath)
                  ) else {
                return cachedPatterns
            }
            let key = canonicalExternalLogPath(rootPath)
            return GitProtectedBranchRules.loadRemotePatterns(for: key)
        }()
        return GitProtectedBranchRules.combinedPatterns(
            localRawValue: protectedBranchPatterns,
            remotePatterns: remotePatterns,
            synchronize: protectedBranchSynchronize
        )
    }

    func applyExternalConversionSetting() {
        _ = try? repo?.setExternalConversionEnabled(enabled: gitExternalConversionEnabled)
    }
}
