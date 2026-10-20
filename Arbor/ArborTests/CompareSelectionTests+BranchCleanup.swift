import XCTest
import Foundation
@testable import Arbor

extension CompareSelectionTests {

    func testFindMergedReportKeepsRootErrorsAndStableRows() {
        let merged = BranchInfo(
            name: "feature/merged",
            isCurrent: false,
            shortId: "1234567",
            lastCommitTime: 10
        )
        let okRoot = BranchCleanupRoot(
            rootPath: "/project/app",
            displayName: "app",
            relativePath: ".",
            branches: [merged],
            trackingByBranch: [:],
            mergedBranches: [merged.name],
            calculatedTarget: "main",
            calculatedPrefix: "feature/",
            calculationError: nil
        )
        let failedRoot = BranchCleanupRoot(
            rootPath: "/project/tools",
            displayName: "tools",
            relativePath: "tools",
            branches: [],
            trackingByBranch: [:],
            mergedBranches: [],
            calculatedTarget: nil,
            calculatedPrefix: nil,
            calculationError: "target branch 'main' was not found"
        )
        let summary = FindMergedScanSummary(
            targetBranch: "main",
            prefix: "feature/",
            repositoriesDiscovered: 2,
            repositoriesScanned: 1,
            candidateBranchesChecked: 1,
            mergedBranchesFound: 1,
            errors: ["tools: target branch 'main' was not found"],
            elapsedMilliseconds: 7,
            isCancelled: false
        )

        let report = findMergedBranchesReportText(
            summary: summary,
            roots: [failedRoot, okRoot],
            projectName: "project"
        )

        XCTAssertEqual(
            mergedBranchNames(in: okRoot, targetBranch: "main", prefix: "feature/"),
            ["feature/merged"]
        )
        XCTAssertTrue(report.contains("Root: /project/app"))
        XCTAssertTrue(report.contains("  feature/merged"))
        XCTAssertTrue(report.contains("Root: /project/tools"))
        XCTAssertTrue(report.contains("  Error: target branch 'main' was not found"))
        XCTAssertTrue(report.contains("Project: project"))
        XCTAssertTrue(report.contains("Repositories scanned: 1"))
        XCTAssertTrue(report.contains("Errors count: 1"))
    }

    func testFindMergedSkipsRootsWithoutTheTargetBranch() {
        let target = BranchInfo(
            name: "main",
            isCurrent: true,
            shortId: "target",
            lastCommitTime: 10
        )
        let matching = BranchCleanupRoot(
            rootPath: "/project/app",
            displayName: "app",
            relativePath: ".",
            branches: [target],
            trackingByBranch: [:],
            mergedBranches: [],
            calculatedTarget: nil,
            calculatedPrefix: nil,
            calculationError: nil
        )
        let unrelated = BranchCleanupRoot(
            rootPath: "/project/tools",
            displayName: "tools",
            relativePath: "tools",
            branches: [
                BranchInfo(
                    name: "develop",
                    isCurrent: true,
                    shortId: "develop",
                    lastCommitTime: 10
                )
            ],
            trackingByBranch: [:],
            mergedBranches: [],
            calculatedTarget: nil,
            calculatedPrefix: nil,
            calculationError: nil
        )

        XCTAssertEqual(
            ContentView.findMergedRootsContainingTarget("main", in: [matching, unrelated])
                .map(\.rootPath),
            ["/project/app"]
        )
    }

    func testCleanupBranchesClipboardUsesIntellijTableColumnsAndOrder() {
        let rows = [
            BranchCleanupClipboardRow(
                branchName: "feature/z",
                lastCommitDate: "Aug 21, 2026 at 10:00 AM",
                trackedBranch: "origin/feature/z"
            ),
            BranchCleanupClipboardRow(
                branchName: "feature/a",
                lastCommitDate: "",
                trackedBranch: ""
            )
        ]

        XCTAssertEqual(
            formattedBranchCleanupClipboardRows(rows),
            "feature/z\tAug 21, 2026 at 10:00 AM\torigin/feature/z\nfeature/a\t\t"
        )
    }

    func testCleanupBranchesCopyUsesTableRowsNotDeleteCheckboxSelection() {
        let ordered = [
            BranchCleanupSelection(rootPath: "/project/app", branchName: "feature/a"),
            BranchCleanupSelection(rootPath: "/project/app", branchName: "feature/b"),
            BranchCleanupSelection(rootPath: "/project/tools", branchName: "feature/a")
        ]

        XCTAssertEqual(
            branchCleanupSelectedRows(
                ordered,
                selected: [
                    BranchCleanupSelection(rootPath: "/project/tools", branchName: "feature/a"),
                    BranchCleanupSelection(rootPath: "/project/app", branchName: "feature/b")
                ]
            ),
            [
                BranchCleanupSelection(rootPath: "/project/app", branchName: "feature/b"),
                BranchCleanupSelection(rootPath: "/project/tools", branchName: "feature/a")
            ]
        )
    }

    func testFindMergedReportMarksCancelledScans() {
        let summary = FindMergedScanSummary(
            targetBranch: "main",
            prefix: "",
            repositoriesDiscovered: 3,
            repositoriesScanned: 1,
            candidateBranchesChecked: 2,
            mergedBranchesFound: 1,
            errors: [],
            elapsedMilliseconds: 12,
            isCancelled: true
        )

        let report = findMergedBranchesReportText(
            summary: summary,
            roots: [],
            projectName: "project"
        )

        XCTAssertTrue(report.contains("Status: Cancelled"))
        XCTAssertTrue(report.contains("Repositories discovered: 3"))
    }

    func testFindMergedReportPersistsAndSemanticActionRoundTrips() throws {
        let suiteName = "FindMergedReportTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let saved = PersistedFindMergedReport(
            id: "report-1",
            projectPath: "/workspace/project",
            targetBranch: "main",
            prefix: "feature/",
            report: "=== Merged local branches into 'main' ===\n",
            createdAt: Date(timeIntervalSince1970: 42)
        )

        FindMergedReportStore.save(saved, defaults: defaults)
        XCTAssertEqual(FindMergedReportStore.load(id: saved.id, defaults: defaults), saved)

        let request = ArborVCSActionRequest(
            kind: .showFindMergedReport,
            projectPath: saved.projectPath,
            rootPath: nil,
            shelfName: "",
            findMergedReportID: saved.id
        )
        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(ArborVCSActionRequest.self, from: encoded)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.findMergedReportID, saved.id)
    }
}
