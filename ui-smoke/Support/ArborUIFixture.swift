import XCTest

/// Builds the deterministic Git repository the UI suite drives.
///
/// The shell script is the single source of truth: it is also useful when
/// capturing the visual baseline by hand, and it keeps the fixture identical
/// between a local run and CI.
enum ArborUIFixture {
    enum FixtureError: Error, CustomStringConvertible {
        case missingScript(String)
        case scriptFailed(Int, String)

        var description: String {
            switch self {
            case let .missingScript(path):
                return "fixture script not found at \(path)"
            case let .scriptFailed(status, output):
                return "fixture script exited \(status)\n\(output)"
            }
        }
    }

    /// Repository root, resolved from this file's location so the suite works
    /// from any checkout and from CI.
    static var repositoryRoot: URL {
        if let override = ProcessInfo.processInfo.environment["ARBOR_REPO_ROOT"],
           !override.isEmpty {
            return URL(fileURLWithPath: override).standardizedFileURL
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // ui-smoke
            .deletingLastPathComponent() // repository root
            .standardizedFileURL
    }

    /// Location of the built product under test. The runner script builds it
    /// here; the suite never depends on a machine-specific DerivedData path.
    static var applicationUnderTest: URL {
        if let path = ProcessInfo.processInfo.environment["ARBOR_UI_APP_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return repositoryRoot
            .appendingPathComponent(".build/DerivedData/Build/Products/Debug/Arbor.app")
    }

    /// Template repository created by the runner (git cannot run inside the
    /// sandboxed test runner).
    static var fixtureTemplate: URL? {
        if let path = ProcessInfo.processInfo.environment["ARBOR_UI_FIXTURE_TEMPLATE"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let conventional = repositoryRoot.appendingPathComponent(".build/UISmoke/fixture-template")
        return FileManager.default.fileExists(atPath: conventional.path) ? conventional : nil
    }

    static var fixtureScript: URL {
        repositoryRoot.appendingPathComponent("scripts/make-ui-fixture.sh")
    }

    /// Copies the prepared template into the test's own container so a test
    /// can mutate its repository without disturbing the next test.
    ///
    /// The runner script creates the template: the UI test runner is sandboxed
    /// and cannot execute git itself.
    static func create() throws -> URL {
        if let source = fixtureTemplate {
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw FixtureError.missingScript("fixture template \(source.path)")
            }
            let target = FileManager.default.temporaryDirectory
                .appendingPathComponent("arbor-ui-fixture-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try FileManager.default.copyItem(at: source, to: target)
            return target
        }
        return try createFromScript()
    }

    private static func createFromScript() throws -> URL {
        let script = fixtureScript
        guard FileManager.default.isExecutableFile(atPath: script.path) else {
            throw FixtureError.missingScript(script.path)
        }

        let base = ProcessInfo.processInfo.environment["ARBOR_UI_FIXTURE_PARENT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let target = base.appendingPathComponent("arbor-ui-fixture-\(UUID().uuidString.prefix(8))")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, target.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw FixtureError.scriptFailed(Int(process.terminationStatus), output)
        }
        return target
    }
}
