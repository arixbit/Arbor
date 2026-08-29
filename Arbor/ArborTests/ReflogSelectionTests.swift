import Foundation
import XCTest
@testable import Arbor

final class ReflogSelectionTests: XCTestCase {
    private let entries = [
        ReflogEntry(oldId: "0000001", newId: "1111111", message: "checkout: main", time: 30, refName: "HEAD"),
        ReflogEntry(oldId: "1111111", newId: "2222222", message: "commit: one", time: 20, refName: "HEAD"),
        ReflogEntry(oldId: "2222222", newId: "1111111", message: "reset: moving to HEAD~1", time: 10, refName: "HEAD")
    ]

    func testSelectionFollowsReflogOrder() {
        let selected = orderedReflogSelection(
            entries: entries,
            selectedIDs: [reflogEntryIdentifier(entries[2]), reflogEntryIdentifier(entries[0])]
        )

        XCTAssertEqual(selected.map(\.message), ["checkout: main", "reset: moving to HEAD~1"])
    }

    func testRefreshKeepsExistingRowsAndSeedsWhenSelectionDisappears() {
        let retained = reconciledReflogSelection(
            entries: [entries[0], entries[2]],
            previousSelection: reflogEntryIdentifier(entries[1]),
            previousSelectedIDs: [reflogEntryIdentifier(entries[1]), reflogEntryIdentifier(entries[2])]
        )

        XCTAssertEqual(retained.selection, reflogEntryIdentifier(entries[2]))
        XCTAssertEqual(retained.selectedIDs, [reflogEntryIdentifier(entries[2])])

        let seeded = reconciledReflogSelection(
            entries: [entries[0]],
            previousSelection: "stale",
            previousSelectedIDs: ["stale"]
        )
        XCTAssertEqual(seeded.selection, reflogEntryIdentifier(entries[0]))
        XCTAssertEqual(seeded.selectedIDs, [reflogEntryIdentifier(entries[0])])
    }

    func testRebaseRangeRequestRejectsStaleGenerationOrInputs() {
        XCTAssertTrue(
            rebaseRangeRequestIsCurrent(
                generation: 2,
                currentGeneration: 2,
                requestedOnto: "main",
                currentOnto: "main",
                requestedPreserveMerges: true,
                currentPreserveMerges: true
            )
        )
        XCTAssertFalse(
            rebaseRangeRequestIsCurrent(
                generation: 1,
                currentGeneration: 2,
                requestedOnto: "main",
                currentOnto: "main",
                requestedPreserveMerges: true,
                currentPreserveMerges: true
            )
        )
        XCTAssertFalse(
            rebaseRangeRequestIsCurrent(
                generation: 2,
                currentGeneration: 2,
                requestedOnto: "main",
                currentOnto: "release",
                requestedPreserveMerges: true,
                currentPreserveMerges: false
            )
        )
        XCTAssertFalse(
            rebaseRangeRequestIsCurrent(
                generation: 2,
                currentGeneration: 2,
                requestedOnto: "main",
                currentOnto: "main",
                requestedPreserveMerges: true,
                currentPreserveMerges: true,
                requestedRoot: true,
                currentRoot: false
            )
        )
        XCTAssertFalse(
            rebaseRangeRequestIsCurrent(
                generation: 2,
                currentGeneration: 2,
                requestedOnto: "main",
                currentOnto: "main",
                requestedPreserveMerges: true,
                currentPreserveMerges: true,
                requestedBranch: "feature",
                currentBranch: "main"
            )
        )
        XCTAssertFalse(
            rebaseRangeRequestIsCurrent(
                generation: 2,
                currentGeneration: 2,
                requestedOnto: "main",
                currentOnto: "main",
                requestedPreserveMerges: true,
                currentPreserveMerges: true,
                requestedRepositoryPath: "/project/submodule",
                currentRepositoryPath: "/project"
            )
        )
    }

    func testSelectionDropsStaleIDs() {
        let selected = orderedReflogSelection(
            entries: entries,
            selectedIDs: [reflogEntryIdentifier(entries[1]), "missing-40"]
        )

        XCTAssertEqual(selected.map(\.newId), ["2222222"])
    }

    func testDuplicateCommitIDsRemainDistinctReflogRows() {
        let selected = orderedReflogSelection(
            entries: entries,
            selectedIDs: Set(entries.map(reflogEntryIdentifier))
        )

        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(selected.map(\.newId), ["1111111", "2222222", "1111111"])
    }

    func testCommitIDsAreDeduplicatedWithoutReordering() {
        XCTAssertEqual(
            orderedUniqueReflogCommitIDs(entries),
            ["1111111", "2222222"]
        )
    }

    func testOlderReflogPageAppendsInOrderWithoutDuplicatingRows() {
        let older = ReflogEntry(
            oldId: "3333333",
            newId: "4444444",
            message: "checkout: feature",
            time: 5,
            refName: "HEAD"
        )
        XCTAssertEqual(
            appendedReflogEntries(existing: [entries[0], entries[1]], page: [entries[1], older])
                .map(\.newId),
            [older.newId]
        )
    }

    func testPersistedSelectionFollowsRowsAndKeepsPendingIDsWhileLoading() {
        let selected = Set([
            reflogEntryIdentifier(entries[2]),
            reflogEntryIdentifier(entries[0]),
            "stale"
        ])
        XCTAssertEqual(
            persistedReflogSelectionIDs(entries: entries, selectedIDs: selected),
            [reflogEntryIdentifier(entries[0]), reflogEntryIdentifier(entries[2])]
        )
        XCTAssertEqual(
            persistedReflogSelectionIDs(entries: [], selectedIDs: selected),
            selected.sorted()
        )
    }

    func testFirstVisibleEntryCanSeedInitialSelection() {
        let firstID = reflogEntryIdentifier(entries[0])
        let selected = orderedReflogSelection(entries: entries, selectedIDs: [firstID])

        XCTAssertEqual(selected.map(\.newId), ["1111111"])
    }

    func testLogDateParserAcceptsCalendarAndEpochForms() {
        XCTAssertNotNil(parseLogDate("2026-08-17"))
        XCTAssertNotNil(parseLogDate("2026-08-17 12:30"))
        XCTAssertEqual(parseLogDate("1700000000"), 1_700_000_000)
        XCTAssertNil(parseLogDate("not-a-date"))
    }

    func testSameRevisionAndTimestampRemainDistinctWhenRecordFieldsDiffer() {
        let sameSecond = [
            ReflogEntry(oldId: "aaaaaaa", newId: "1111111", message: "checkout: main", time: 30, refName: "HEAD"),
            ReflogEntry(oldId: "bbbbbbb", newId: "1111111", message: "reset: main", time: 30, refName: "refs/heads/main")
        ]

        XCTAssertNotEqual(
            reflogEntryIdentifier(sameSecond[0]),
            reflogEntryIdentifier(sameSecond[1])
        )
        XCTAssertEqual(
            orderedReflogSelection(
                entries: sameSecond,
                selectedIDs: Set(sameSecond.map(reflogEntryIdentifier))
            ).count,
            2
        )
    }

    func testReflogTabContextRoundTripsAndLegacyTabsDecode() throws {
        var tab = LogTabDescriptor()
        tab.viewMode = .reflog
        tab.rootPath = "/project"
        tab.reflogRootPath = "/project/services/api"
        tab.reflogSelection = "HEAD|1111111|2222222|30|checkout: main"
        tab.reflogSelectedIDs = [tab.reflogSelection!, "HEAD|aaaaaaa|bbbbbbb|20|reset: main"]

        let encoded = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(LogTabDescriptor.self, from: encoded)
        XCTAssertEqual(decoded.reflogRootPath, tab.reflogRootPath)
        XCTAssertEqual(decoded.reflogSelection, tab.reflogSelection)
        XCTAssertEqual(decoded.reflogSelectedIDs, tab.reflogSelectedIDs)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "reflogRootPath")
        legacyObject.removeValue(forKey: "reflogSelection")
        legacyObject.removeValue(forKey: "reflogSelectedIDs")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(LogTabDescriptor.self, from: legacyData)
        XCTAssertNil(legacy.reflogRootPath)
        XCTAssertNil(legacy.reflogSelection)
        XCTAssertNil(legacy.reflogSelectedIDs)
    }

    func testInteractiveRebaseUsesSelectedCommitParentAsExcludedBase() {
        let commit = CommitInfo(
            id: "commit",
            repositoryPath: nil,
            shortId: "commit",
            summary: "subject",
            authorName: "author",
            authorEmail: "author@example.com",
            committerName: "author",
            committerEmail: "author@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: ["parent"],
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )

        XCTAssertEqual(interactiveRebaseBaseRevision(for: commit), "parent")
    }

    func testInteractiveRebaseUsesFirstParentForMergePreservingEngine() {
        let root = CommitInfo(
            id: "root",
            repositoryPath: nil,
            shortId: "root",
            summary: "root",
            authorName: "author",
            authorEmail: "author@example.com",
            committerName: "author",
            committerEmail: "author@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: [],
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )
        let merge = CommitInfo(
            id: "merge",
            repositoryPath: nil,
            shortId: "merge",
            summary: "merge",
            authorName: "author",
            authorEmail: "author@example.com",
            committerName: "author",
            committerEmail: "author@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: ["left", "right"],
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )

        XCTAssertNil(interactiveRebaseBaseRevision(for: root))
        XCTAssertTrue(isInteractiveRebaseAvailable(for: root))
        XCTAssertEqual(interactiveRebaseBaseRevision(for: merge), "left")
    }

    func testLogRewriteAvailabilityMatchesMergeCommitEditingRules() {
        let headMerge = makeRewriteCommit("M", parents: ["left", "right"], isHead: true)
        let historicalMerge = CommitInfo(
            id: "historical-merge",
            repositoryPath: nil,
            shortId: "historical-merge",
            summary: "historical merge",
            authorName: "author",
            authorEmail: "author@example.com",
            committerName: "author",
            committerEmail: "author@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: ["left", "right"],
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )
        let linear = makeRewriteCommit("linear", parents: ["parent"])

        XCTAssertTrue(isLogRewriteActionAvailable(for: headMerge, action: .reword))
        XCTAssertFalse(isLogRewriteActionAvailable(for: headMerge, action: .drop))
        XCTAssertFalse(isLogRewriteActionAvailable(for: historicalMerge, action: .reword))
        XCTAssertFalse(isLogRewriteActionAvailable(for: historicalMerge, action: .squash))
        XCTAssertFalse(isLogRewriteActionAvailable(for: historicalMerge, action: .fixup))
        XCTAssertFalse(isLogRewriteActionAvailable(for: historicalMerge, action: .drop))
        XCTAssertTrue(isLogRewriteActionAvailable(for: linear, action: .squash))
        XCTAssertTrue(areLogRewriteSelectionActionsAvailable(for: [linear, makeRewriteCommit("linear-2", parents: ["linear"])]))
        XCTAssertFalse(areLogRewriteSelectionActionsAvailable(for: [linear, historicalMerge]))
    }

    func testUncommitAvailabilityRejectsRootHead() {
        let rootHead = makeRewriteCommit("root", parents: [], isHead: true)
        let linearHead = makeRewriteCommit("linear-head", parents: ["parent"], isHead: true)
        let historical = makeRewriteCommit("historical", parents: ["parent"], isHead: false)

        XCTAssertFalse(isUncommitActionAvailable(for: rootHead))
        XCTAssertTrue(isUncommitActionAvailable(for: linearHead))
        XCTAssertFalse(isUncommitActionAvailable(for: historical))
    }

    func testLogActionAvailabilityBlocksActiveAndCrossRootMutations() {
        let activeRoot = LogActionAvailability(
            hasLocalChanges: false,
            activeOperationRootPath: "/project/one"
        )

        XCTAssertTrue(activeRoot.allowsMutation(forRepositoryPaths: ["/project/one"]))
        XCTAssertFalse(activeRoot.allowsHistoryRewrite(forRepositoryPaths: ["/project/one"]))
        XCTAssertTrue(activeRoot.allowsMutation(forRepositoryPaths: ["/project/two"]))
        XCTAssertTrue(
            activeRoot.allowsMutation(
                forRepositoryPaths: ["/project/one", "/project/two"]
            )
        )
        XCTAssertTrue(activeRoot.allowsHistoryRewrite(forRepositoryPaths: ["/project/two"]))
        XCTAssertTrue(activeRoot.allowsMutation(forRepositoryPaths: [nil]))
        XCTAssertFalse(
            activeRoot.allowsSingleRootHistoryRewrite(
                forRepositoryPaths: ["/project/one", "/project/two"]
            )
        )
        XCTAssertTrue(
            activeRoot.allowsSingleRootHistoryRewrite(
                forRepositoryPaths: ["/project/two", "/project/two/."]
            )
        )

        let noOperation = LogActionAvailability(
            hasLocalChanges: true,
            activeOperationRootPath: nil
        )
        XCTAssertFalse(
            noOperation.allowsSingleRootHistoryRewrite(
                forRepositoryPaths: ["/project/one", "/project/two"]
            )
        )

        let noRemote = LogActionAvailability(
            hasLocalChanges: true,
            activeOperationRootPath: nil,
            hasRemotes: false
        )
        XCTAssertFalse(noRemote.allowsAddCommitsToRemote(forRepositoryPaths: ["/project/one"]))
    }

    private func makeRewriteCommit(
        _ id: String,
        parents: [String],
        isHead: Bool = false
    ) -> CommitInfo {
        CommitInfo(
            id: id,
            repositoryPath: nil,
            shortId: id,
            summary: id,
            authorName: "author",
            authorEmail: "author@example.com",
            committerName: "author",
            committerEmail: "author@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: parents,
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: isHead,
            lane: 0,
            parentLanes: []
        )
    }

    func testRevisionBrowserNormalizesInitialFileLocation() {
        XCTAssertEqual(
            revisionBrowserInitialLocation(for: "/Sources/App.swift/" )?.directory,
            "Sources"
        )
        XCTAssertEqual(
            revisionBrowserInitialLocation(for: "/Sources/App.swift/")?.file,
            "Sources/App.swift"
        )
        XCTAssertNil(revisionBrowserInitialLocation(for: "///"))
    }
}

final class LinearBekGraphTests: XCTestCase {
    func testCollapseHidesEdgesAndAddsDottedEdgeWithoutRemovingRows() {
        let commits = simpleMergeHistory()
        let graph = LinearBekGraphModel(
            commits: commits,
            collapseAll: true,
            expandedMergeIDs: []
        )

        let fragment = try! XCTUnwrap(graph.fragments["M"])
        XCTAssertEqual(fragment.mergeRow, 0)
        XCTAssertEqual(fragment.leftChildRow, 2)
        XCTAssertEqual(fragment.rightChildRow, 1)
        XCTAssertEqual(graph.dottedEdges, [
            LinearBekDottedEdge(
                mergeID: "M",
                upRow: 1,
                downRow: 2,
                fromLane: 0,
                toLane: 0
            )
        ])
        XCTAssertFalse(graph.visibleEdges.contains {
            $0.upRow == 0 && $0.downRow == 2
        })
        XCTAssertFalse(graph.visibleEdges.contains {
            $0.upRow == 1 && $0.downRow == 4
        })
        XCTAssertEqual(graph.rowAction(at: 0), .expand("M"))
        XCTAssertEqual(graph.rowAction(at: 1), .expand("M"))
        XCTAssertEqual(commits.count, 5)
    }

    func testExpandingMergeRestoresNormalEdgesAndRemovesDottedEdge() {
        let graph = LinearBekGraphModel(
            commits: simpleMergeHistory(),
            collapseAll: true,
            expandedMergeIDs: ["M"]
        )

        XCTAssertTrue(graph.dottedEdges.isEmpty)
        XCTAssertEqual(graph.visibleEdges.count, graph.normalEdges.count)
        XCTAssertEqual(graph.rowAction(at: 0), .collapse("M"))
    }

    func testLinearBekEdgeActionsMirrorCollapseAndExpandStates() {
        let expanded = LinearBekGraphModel(
            commits: simpleMergeHistory(),
            collapseAll: false,
            expandedMergeIDs: []
        )
        let fragment = try! XCTUnwrap(expanded.fragments["M"])
        for edge in fragment.hiddenEdges {
            XCTAssertEqual(
                expanded.action(for: .normal(edge)),
                .collapse("M")
            )
        }

        let collapsed = LinearBekGraphModel(
            commits: simpleMergeHistory(),
            collapseAll: true,
            expandedMergeIDs: []
        )
        let dotted = try! XCTUnwrap(collapsed.dottedEdges.first)
        XCTAssertEqual(
            collapsed.action(for: .dotted(dotted)),
            .expand("M")
        )
    }

    func testLinearBekControllerCollapsesFragmentWhenGlobalCollapseIsOff() {
        let controller = LinearBekGraphController(
            commits: simpleMergeHistory(),
            collapseAll: false,
            expandedMergeIDs: [],
            collapsedMergeIDs: []
        )
        let fragment = try! XCTUnwrap(controller.graph.fragments["M"])
        let edge = try! XCTUnwrap(fragment.hiddenEdges.first)

        let answer = controller.perform(
            LinearBekGraphAction(
                type: .mouseClick,
                affectedElement: .normal(edge)
            )
        )

        XCTAssertEqual(answer.collapsedMergeIDs, ["M"])
        XCTAssertTrue(answer.expandedMergeIDs.isEmpty)
        let collapsed = LinearBekGraphController(
            commits: simpleMergeHistory(),
            collapseAll: false,
            expandedMergeIDs: answer.expandedMergeIDs,
            collapsedMergeIDs: answer.collapsedMergeIDs
        )
        XCTAssertFalse(collapsed.graph.dottedEdges.isEmpty)
    }

    func testLinearBekControllerExpandsFragmentWhenGlobalCollapseIsOn() {
        let controller = LinearBekGraphController(
            commits: simpleMergeHistory(),
            collapseAll: true,
            expandedMergeIDs: [],
            collapsedMergeIDs: []
        )
        let dotted = try! XCTUnwrap(controller.graph.dottedEdges.first)

        let answer = controller.perform(
            LinearBekGraphAction(
                type: .mouseClick,
                affectedElement: .dotted(dotted)
            )
        )

        XCTAssertEqual(answer.expandedMergeIDs, ["M"])
        let expanded = LinearBekGraphController(
            commits: simpleMergeHistory(),
            collapseAll: true,
            expandedMergeIDs: answer.expandedMergeIDs,
            collapsedMergeIDs: answer.collapsedMergeIDs
        )
        XCTAssertTrue(expanded.graph.dottedEdges.isEmpty)
    }

    func testLinearBekControllerCollapseAndExpandButtonsUpdateAllFragments() {
        let expanded = LinearBekGraphController(
            commits: simpleMergeHistory(),
            collapseAll: false,
            expandedMergeIDs: [],
            collapsedMergeIDs: []
        )
        let collapseAnswer = expanded.perform(
            LinearBekGraphAction(type: .buttonCollapse, affectedElement: nil)
        )
        XCTAssertEqual(collapseAnswer.collapsedMergeIDs, ["M"])

        let collapsed = LinearBekGraphController(
            commits: simpleMergeHistory(),
            collapseAll: false,
            expandedMergeIDs: collapseAnswer.expandedMergeIDs,
            collapsedMergeIDs: collapseAnswer.collapsedMergeIDs
        )
        let expandAnswer = collapsed.perform(
            LinearBekGraphAction(type: .buttonExpand, affectedElement: nil)
        )
        XCTAssertTrue(expandAnswer.collapsedMergeIDs.isEmpty)
        XCTAssertTrue(expandAnswer.expandedMergeIDs.isEmpty)
    }

    func testLinearBekGraphCommandIdentityAllowsRepeatedMenuActions() {
        let first = LinearBekGraphCommand(id: 1, action: .buttonCollapse)
        let repeated = LinearBekGraphCommand(id: 2, action: .buttonCollapse)

        XCTAssertNotEqual(first, repeated)
        XCTAssertEqual(first.action, repeated.action)
    }

    func testLinearBekControllerMapsFragmentNodesToCollapseAndExpandActions() {
        let controller = LinearBekGraphController(
            commits: simpleMergeHistory(),
            collapseAll: false,
            expandedMergeIDs: [],
            collapsedMergeIDs: []
        )
        let fragment = try! XCTUnwrap(controller.graph.fragments["M"])
        let nodeRow = try! XCTUnwrap(fragment.affectedRows.sorted().first)
        let node = LinearBekGraphElement.node(nodeRow)

        XCTAssertEqual(controller.graph.action(for: node), .collapse("M"))
        let hoverAnswer = controller.perform(
            LinearBekGraphAction(type: .mouseOver, affectedElement: node)
        )
        XCTAssertEqual(hoverAnswer.highlightedElement, node)

        let collapseAnswer = controller.perform(
            LinearBekGraphAction(type: .mouseClick, affectedElement: node)
        )
        XCTAssertEqual(collapseAnswer.collapsedMergeIDs, ["M"])

        let collapsed = LinearBekGraphController(
            commits: simpleMergeHistory(),
            collapseAll: false,
            expandedMergeIDs: collapseAnswer.expandedMergeIDs,
            collapsedMergeIDs: collapseAnswer.collapsedMergeIDs
        )
        XCTAssertEqual(collapsed.graph.action(for: node), .expand("M"))
    }

    func testLinearBekHoverHighlightsTheCompleteChildFragment() {
        let controller = LinearBekGraphController(
            commits: simpleMergeHistory(),
            collapseAll: false,
            expandedMergeIDs: [],
            collapsedMergeIDs: []
        )
        let fragment = try! XCTUnwrap(controller.graph.fragments["M"])
        let node = LinearBekGraphElement.node(fragment.mergeRow)

        let answer = controller.perform(
            LinearBekGraphAction(type: .mouseOver, affectedElement: node)
        )

        XCTAssertEqual(answer.highlightedElement, node)
        XCTAssertNotNil(answer.highlight)
        XCTAssertTrue(answer.highlight!.rows.isSuperset(of: fragment.affectedRows))
        XCTAssertGreaterThan(answer.highlight!.rows.count, 1)
    }

    func testLinearBekHoverHighlightsDottedEdgeEndpoints() {
        let controller = LinearBekGraphController(
            commits: simpleMergeHistory(),
            collapseAll: true,
            expandedMergeIDs: [],
            collapsedMergeIDs: []
        )
        let dotted = try! XCTUnwrap(controller.graph.dottedEdges.first)

        let answer = controller.perform(
            LinearBekGraphAction(
                type: .mouseOver,
                affectedElement: .dotted(dotted)
            )
        )

        XCTAssertEqual(answer.highlight?.rows, [dotted.upRow, dotted.downRow])
        XCTAssertEqual(answer.highlight?.dottedEdges, [dotted])
    }

    func testComplexSideMergeFailsOpenInsteadOfInventingAFragment() {
        let commits = [
            makeCommit("M", parents: ["R", "L"]),
            makeCommit("R", parents: ["X", "Y"]),
            makeCommit("L", parents: ["B"]),
            makeCommit("X", parents: ["B"]),
            makeCommit("Y", parents: ["B"]),
            makeCommit("B", parents: [])
        ]
        let graph = LinearBekGraphModel(
            commits: commits,
            collapseAll: true,
            expandedMergeIDs: []
        )

        XCTAssertNil(graph.fragments["M"])
        XCTAssertNil(graph.rowAction(at: 0))
        XCTAssertEqual(graph.normalEdges.count, 7)
        XCTAssertEqual(graph.visibleEdges.filter { $0.upRow == 0 }.count, 2)
    }

    func testReferenceComplicatedBranchesCollapseToMultipleDottedTails() {
        let commits = [
            makeCommit("0", parents: ["5", "1"]),
            makeCommit("1", parents: ["2", "3"]),
            makeCommit("2", parents: ["4", "3"]),
            makeCommit("3", parents: ["4"]),
            makeCommit("4", parents: ["9"]),
            makeCommit("5", parents: ["6", "7"]),
            makeCommit("6", parents: ["8", "7"]),
            makeCommit("7", parents: ["8"]),
            makeCommit("8", parents: ["9"]),
            makeCommit("9", parents: [])
        ]

        let graph = LinearBekGraphModel(
            commits: commits,
            collapseAll: true,
            expandedMergeIDs: []
        )

        XCTAssertEqual(
            Set(graph.dottedEdges.map { "\($0.upRow)->\($0.downRow)" }),
            ["2->3", "3->4", "4->5", "6->7", "7->8"]
        )
    }

    func testReferenceRecursiveAndCrossedTailTopologies() {
        assertReferenceDottedPairs(
            "recursiveSections",
            commits: [
                makeCommit("0", parents: ["5", "1"]),
                makeCommit("1", parents: ["3", "2"]),
                makeCommit("2", parents: ["4"]),
                makeCommit("3", parents: ["4"]),
                makeCommit("4", parents: ["6"]),
                makeCommit("5", parents: ["6"]),
                makeCommit("6", parents: [])
            ],
            expected: ["2->3", "4->5"]
        )
        assertReferenceDottedPairs(
            "twoTailsBranch",
            commits: [
                makeCommit("0", parents: ["8", "1"]),
                makeCommit("1", parents: ["2"]),
                makeCommit("2", parents: ["6", "3"]),
                makeCommit("3", parents: ["4"]),
                makeCommit("4", parents: ["9", "5"]),
                makeCommit("5", parents: ["11"]),
                makeCommit("6", parents: ["7"]),
                makeCommit("7", parents: ["10"]),
                makeCommit("8", parents: ["9"]),
                makeCommit("9", parents: ["10"]),
                makeCommit("10", parents: ["11"]),
                makeCommit("11", parents: [])
            ],
            expected: ["5->8", "7->8"]
        )
        assertReferenceDottedPairs(
            "hiddenIncomingEdges",
            commits: [
                makeCommit("0", parents: ["2", "1"]),
                makeCommit("1", parents: ["3", "4"]),
                makeCommit("2", parents: ["3"]),
                makeCommit("3", parents: ["5", "4"]),
                makeCommit("4", parents: ["6"]),
                makeCommit("5", parents: ["6"]),
                makeCommit("6", parents: [])
            ],
            expected: ["1->2", "3->4", "4->5"]
        )
        assertReferenceDottedPairs(
            "crossedTails",
            commits: [
                makeCommit("0", parents: ["4", "1"]),
                makeCommit("1", parents: ["3", "2"]),
                makeCommit("2", parents: ["4"]),
                makeCommit("3", parents: ["5"]),
                makeCommit("4", parents: ["5"]),
                makeCommit("5", parents: [])
            ],
            expected: ["2->4", "3->4"]
        )
    }

    func testReferenceBasicLinearBekTopologies() {
        assertReferenceDottedPairs(
            "twoSections",
            commits: [
                makeCommit("0", parents: ["2", "1"]),
                makeCommit("1", parents: ["3"]),
                makeCommit("2", parents: ["3"]),
                makeCommit("3", parents: ["5", "4"]),
                makeCommit("4", parents: ["6"]),
                makeCommit("5", parents: ["6"]),
                makeCommit("6", parents: [])
            ],
            expected: ["1->2", "4->5"]
        )
        assertReferenceDottedPairs(
            "diagonal",
            commits: [
                makeCommit("0", parents: ["2", "1"]),
                makeCommit("1", parents: ["3"]),
                makeCommit("2", parents: ["4", "3"]),
                makeCommit("3", parents: ["5"]),
                makeCommit("4", parents: ["5"]),
                makeCommit("5", parents: [])
            ],
            expected: ["1->2", "3->4"]
        )
        assertReferenceDottedPairs(
            "differentDiagonal",
            commits: [
                makeCommit("0", parents: ["2", "1"]),
                makeCommit("1", parents: ["2", "3"]),
                makeCommit("2", parents: ["3"]),
                makeCommit("3", parents: [])
            ],
            expected: ["1->2", "2->3"]
        )
        assertReferenceDottedPairs(
            "mergeWithOldCommit",
            commits: [
                makeCommit("0", parents: ["5", "1"]),
                makeCommit("1", parents: ["5", "2"]),
                makeCommit("2", parents: ["3"]),
                makeCommit("3", parents: ["4"]),
                makeCommit("4", parents: ["5"]),
                makeCommit("5", parents: ["6"]),
                makeCommit("6", parents: ["7"]),
                makeCommit("7", parents: [])
            ],
            expected: ["4->5"]
        )
        assertReferenceDottedPairs(
            "reversedParents",
            commits: [
                makeCommit("0", parents: ["1", "4"]),
                makeCommit("1", parents: ["2"]),
                makeCommit("2", parents: ["3", "4"]),
                makeCommit("3", parents: ["5", "6"]),
                makeCommit("4", parents: ["5"]),
                makeCommit("5", parents: ["6"]),
                makeCommit("6", parents: [])
            ],
            expected: ["3->4", "5->6"]
        )
        assertReferenceDottedPairs(
            "triangle",
            commits: [
                makeCommit("0", parents: ["2", "1"]),
                makeCommit("1", parents: ["2"]),
                makeCommit("2", parents: [])
            ],
            expected: ["1->2"]
        )
        assertReferenceDottedPairs(
            "initialImport",
            commits: [
                makeCommit("0", parents: ["3", "1"]),
                makeCommit("1", parents: ["2"]),
                makeCommit("2", parents: []),
                makeCommit("3", parents: [])
            ],
            expected: []
        )
    }

    private func assertReferenceDottedPairs(
        _ name: String,
        commits: [CommitInfo],
        expected: Set<String>
    ) {
        let graph = LinearBekGraphModel(
            commits: commits,
            collapseAll: true,
            expandedMergeIDs: []
        )
        XCTAssertEqual(
            Set(graph.dottedEdges.map { "\($0.upRow)->\($0.downRow)" }),
            expected,
            name
        )
    }

    func testRootQualifiedIdentityKeepsEqualObjectIDsInSeparateHistories() {
        let commits = [
            makeRootCommit("same", repositoryPath: "/project/one", parents: ["parent"]),
            makeRootCommit("same", repositoryPath: "/project/two", parents: ["parent"]),
            makeRootCommit("parent", repositoryPath: "/project/one", parents: []),
            makeRootCommit("parent", repositoryPath: "/project/two", parents: [])
        ]
        let graph = LinearBekGraphModel(
            commits: commits,
            collapseAll: false,
            expandedMergeIDs: [],
            identity: { commit in
                "\(commit.repositoryPath ?? "")\u{1f}\(commit.id)"
            }
        )

        XCTAssertEqual(graph.normalEdges.count, 2)
        XCTAssertEqual(Set(graph.normalEdges.map(\.downRow)), Set([2, 3]))
    }

    private func simpleMergeHistory() -> [CommitInfo] {
        [
            makeCommit("M", parents: ["L", "R"]),
            makeCommit("L", parents: ["B"]),
            makeCommit("R", parents: ["X"]),
            makeCommit("X", parents: ["B"]),
            makeCommit("B", parents: [])
        ]
    }

    private func makeCommit(
        _ id: String,
        parents: [String],
        lane: UInt32 = 0,
        parentLanes: [UInt32] = []
    ) -> CommitInfo {
        CommitInfo(
            id: id,
            repositoryPath: nil,
            shortId: id,
            summary: id,
            authorName: "author",
            authorEmail: "author@example.com",
            committerName: "author",
            committerEmail: "author@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: parents,
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: id == "M",
            lane: lane,
            parentLanes: parentLanes
        )
    }

    private func makeRootCommit(
        _ id: String,
        repositoryPath: String,
        parents: [String]
    ) -> CommitInfo {
        CommitInfo(
            id: id,
            repositoryPath: repositoryPath,
            shortId: id,
            summary: id,
            authorName: "author",
            authorEmail: "author@example.com",
            committerName: "author",
            committerEmail: "author@example.com",
            messageBody: "",
            hasSignature: false,
            time: 0,
            parentIds: parents,
            refs: [],
            tagRefs: [],
            remoteRefs: [],
            isHead: false,
            lane: 0,
            parentLanes: []
        )
    }
}

final class OperationRecoveryTests: XCTestCase {
    @MainActor
    func testFeedbackCenterSuccessFinishesRecoveryOperation() {
        let feedback = FeedbackCenter()
        feedback.begin("Continue operation")

        feedback.success("Operation continued", detail: "The Git operation is no longer paused.")

        XCTAssertFalse(feedback.isRunning)
        XCTAssertFalse(feedback.canCancel)
        XCTAssertEqual(feedback.current?.title, "Operation continued")
        XCTAssertEqual(feedback.history.first?.title, "Operation continued")
        XCTAssertNotNil(feedback.history.first?.finishedAt)
    }

    @MainActor
    func testFeedbackCenterKeepsVcsNotifierGroupsAndExpiresDisplayID() {
        let suiteName = "Arbor.VcsNotifierGroupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let feedback = FeedbackCenter(defaults: defaults)

        feedback.warning(
            "Recovery available",
            notificationID: "arbor.test.recovery",
            notificationGroup: .important,
            localized: false
        )
        XCTAssertEqual(feedback.current?.notificationGroup, .important)
        XCTAssertEqual(feedback.toast?.notificationGroup, .important)
        XCTAssertEqual(feedback.history.first?.notificationGroup, .important)

        feedback.expire(notificationID: "arbor.test.recovery")
        XCTAssertNil(feedback.current)
        XCTAssertNil(feedback.toast)

        feedback.warning(
            "Background result",
            notificationGroup: .silent,
            localized: false
        )
        XCTAssertNil(feedback.current)
        XCTAssertNil(feedback.toast)
        XCTAssertEqual(feedback.history.first?.title, "Background result")
        let reloaded = FeedbackCenter(defaults: defaults)
        XCTAssertEqual(reloaded.history.first?.notificationGroup, .silent)
        XCTAssertEqual(reloaded.history.dropFirst().first?.notificationGroup, .important)
    }

    @MainActor
    func testMergeRollbackActionStaysAvailableAndIsInvokable() {
        let feedback = FeedbackCenter()
        var invoked = false

        feedback.success(
            "Merge completed",
            actionTitle: "Rollback Merge",
            action: { invoked = true }
        )

        XCTAssertEqual(feedback.current?.actionTitle, "Rollback Merge")
        XCTAssertNotNil(feedback.toast)
        feedback.current?.action?()
        XCTAssertTrue(invoked)
    }

    func testMergeRollbackHeadIsOfferedOnlyWhenMergeMovedHEAD() {
        XCTAssertEqual(mergeRollbackHead(initial: "before", final: "after"), "before")
        XCTAssertNil(mergeRollbackHead(initial: "same", final: "same"))
        XCTAssertNil(mergeRollbackHead(initial: nil, final: "after"))
    }

    func testRebaseContextIncludesBranchOntoAndBackend() {
        let state = OperationState(
            kind: .rebase,
            origin: .git,
            backend: .merge,
            interactive: true,
            conflictedFiles: ["Sources/App.swift"],
            onto: "abcdef1234567890",
            originalBranch: "refs/heads/feature",
            stepsDone: 2,
            stepsTotal: 4,
            message: nil
        )

        XCTAssertEqual(
            operationRecoveryContext(for: state),
            "from refs/heads/feature · onto abcdef1234 · interactive merge backend"
        )
    }

    func testNonRebaseRecoveryHasNoRebaseContext() {
        let state = OperationState(
            kind: .merge,
            origin: .git,
            backend: nil,
            interactive: false,
            conflictedFiles: [],
            onto: nil,
            originalBranch: nil,
            stepsDone: nil,
            stepsTotal: nil,
            message: nil
        )

        XCTAssertNil(operationRecoveryContext(for: state))
    }

    func testRebaseEditPauseAllowsAmendOnlyWithoutConflicts() {
        let edit = OperationState(
            kind: .rebase,
            origin: .engine,
            backend: nil,
            interactive: false,
            conflictedFiles: [],
            onto: nil,
            originalBranch: nil,
            stepsDone: nil,
            stepsTotal: nil,
            message: "edit"
        )
        let conflict = OperationState(
            kind: .rebase,
            origin: .engine,
            backend: nil,
            interactive: false,
            conflictedFiles: ["file.txt"],
            onto: nil,
            originalBranch: nil,
            stepsDone: nil,
            stepsTotal: nil,
            message: "edit"
        )

        XCTAssertTrue(rebaseEditPauseAllowsAmend(edit))
        XCTAssertFalse(rebaseEditPauseAllowsAmend(conflict))
        XCTAssertFalse(rebaseEditPauseAllowsAmend(nil))
    }

    func testOperationRecoveryContinueDisablesMergeWithConflicts() {
        let mergeConflict = OperationState(
            kind: .merge,
            origin: .git,
            backend: nil,
            interactive: false,
            conflictedFiles: ["file.txt"],
            onto: nil,
            originalBranch: nil,
            stepsDone: nil,
            stepsTotal: nil,
            message: nil
        )
        let mergeReady = OperationState(
            kind: .merge,
            origin: .git,
            backend: nil,
            interactive: false,
            conflictedFiles: [],
            onto: nil,
            originalBranch: nil,
            stepsDone: nil,
            stepsTotal: nil,
            message: nil
        )
        let rebaseConflict = OperationState(
            kind: .rebase,
            origin: .git,
            backend: .merge,
            interactive: false,
            conflictedFiles: ["file.txt"],
            onto: nil,
            originalBranch: nil,
            stepsDone: nil,
            stepsTotal: nil,
            message: nil
        )

        XCTAssertFalse(operationRecoveryContinueIsEnabled(for: mergeConflict))
        XCTAssertTrue(operationRecoveryContinueIsEnabled(for: mergeReady))
        XCTAssertTrue(operationRecoveryContinueIsEnabled(for: rebaseConflict))
    }

    func testOperationAbortConfirmationNamesEveryGitOperation() {
        let expected: [(OperationKind, String, String)] = [
            (.merge, "Merge", "merge"),
            (.rebase, "Rebase", "rebase"),
            (.cherryPick, "Cherry-pick", "cherry-pick"),
            (.revert, "Revert", "revert")
        ]

        for (kind, title, operation) in expected {
            let confirmation = operationAbortConfirmation(
                for: kind,
                repositoryName: "demo-repository"
            )
            XCTAssertEqual(confirmation.title, "Abort \(title)?")
            XCTAssertEqual(
                confirmation.message,
                "Abort the in-progress \(operation) operation in demo-repository? The repository will be restored to its pre-operation state."
            )
            XCTAssertEqual(confirmation.confirmTitle, "Abort")
        }
    }

    func testStashClearConfirmationIsDestructiveAndRootScoped() {
        let confirmation = stashClearConfirmation(repositoryName: "demo-repository")

        XCTAssertEqual(confirmation.title, "Clear all stashes in demo-repository?")
        XCTAssertEqual(
            confirmation.message,
            "This permanently removes every stash in demo-repository."
        )
        XCTAssertEqual(confirmation.confirmTitle, "Clear All")
        XCTAssertEqual(
            stashClearConfirmation(repositoryName: " ").title,
            "Clear all stashes in the current Git root?"
        )
    }

    func testOperationRecoveryNotificationFingerprintTracksRootRelevantState() {
        let paused = OperationState(
            kind: .rebase,
            origin: .git,
            backend: .merge,
            interactive: true,
            conflictedFiles: ["Sources/App.swift"],
            onto: "abcdef1234567890",
            originalBranch: "refs/heads/feature",
            stepsDone: 2,
            stepsTotal: 4,
            message: "pick feature"
        )
        var resolvedOne = paused
        resolvedOne.conflictedFiles = []
        var nextStep = paused
        nextStep.stepsDone = 3

        XCTAssertEqual(
            operationRecoveryNotificationRootKey("/tmp/ArborOperation/./repo"),
            "/tmp/ArborOperation/repo"
        )
        XCTAssertEqual(
            operationRecoveryNotificationFingerprint(paused),
            operationRecoveryNotificationFingerprint(paused)
        )
        XCTAssertNotEqual(
            operationRecoveryNotificationFingerprint(paused),
            operationRecoveryNotificationFingerprint(resolvedOne)
        )
        XCTAssertNotEqual(
            operationRecoveryNotificationFingerprint(paused),
            operationRecoveryNotificationFingerprint(nextStep)
        )
    }

    func testOperationRecoveryNotificationIDIsRootQualifiedAndStable() {
        let root = "/tmp/ArborOperation/./repo/"
        let equivalentRoot = "/tmp/ArborOperation/repo"
        let otherRoot = "/tmp/ArborOperation/other"

        XCTAssertEqual(
            operationRecoveryNotificationID(rootPath: root),
            operationRecoveryNotificationID(rootPath: equivalentRoot)
        )
        XCTAssertNotEqual(
            operationRecoveryNotificationID(rootPath: root),
            operationRecoveryNotificationID(rootPath: otherRoot)
        )
        XCTAssertTrue(
            operationRecoveryNotificationID(rootPath: root)
                .contains("_tmp_ArborOperation_repo")
        )
    }

    @MainActor
    func testFeedbackCenterReusesOperationRecoveryEntryAcrossLifecycle() {
        let suiteName = "Arbor.FeedbackCenterOperationRecoveryLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let feedback = FeedbackCenter(defaults: defaults)
        let notificationID = "arbor.operation-recovery._tmp_ArborOperation_repo"

        feedback.warning(
            "Rebase recovery available",
            notificationID: notificationID,
            localized: false
        )
        feedback.begin("Continue operation", notificationID: notificationID)
        feedback.success(
            "Operation continued",
            detail: "The Git operation is no longer paused.",
            notificationID: notificationID
        )

        XCTAssertEqual(feedback.history.count, 1)
        XCTAssertEqual(feedback.history.first?.notificationID, notificationID)
        XCTAssertEqual(feedback.history.first?.title, "Operation continued")
    }
}

final class LogColumnLayoutTests: XCTestCase {
    func testColumnOrderIsNormalizedAndPersists() {
        let layout = LogColumnLayout(orderRaw: "hash,commit,hash")

        XCTAssertEqual(layout.order, [.hash, .commit, .author, .date, .root, .signature])
        XCTAssertEqual(
            LogColumnLayout(orderRaw: layout.orderRaw).order,
            layout.order
        )
    }

    func testColumnMoveStopsAtBoundaries() {
        let layout = LogColumnLayout()

        XCTAssertEqual(layout.moving(.commit, by: -1).order, layout.order)
        XCTAssertEqual(layout.moving(.signature, by: 1).order, layout.order)
        XCTAssertEqual(
            layout.moving(.hash, by: 1).order,
            [.commit, .author, .date, .root, .hash, .signature]
        )
        XCTAssertEqual(
            layout.moving(.hash, by: -2).order,
            [.commit, .hash, .date, .author, .root, .signature]
        )
    }

    func testColumnDragMovesSourceBeforeDropTarget() {
        let layout = LogColumnLayout(order: [.commit, .author, .date, .hash])

        XCTAssertEqual(
            layout.moving(.hash, before: .author).order,
            [.commit, .hash, .author, .date, .root, .signature]
        )
        XCTAssertEqual(layout.moving(.author, before: .author), layout)
    }

    func testVisibleColumnsFollowIndependentToggles() {
        let layout = LogColumnLayout(order: [.hash, .date, .commit, .author])

        XCTAssertEqual(
            layout.visibleOrder(
                showAuthor: false,
                showDate: true,
                showHash: true,
                showRoot: false,
                showSignature: false
            ),
            [.hash, .date, .commit]
        )

        XCTAssertEqual(
            layout.visibleOrder(
                showAuthor: false,
                showDate: false,
                showHash: false,
                showRoot: true,
                showSignature: true
            ),
            [.commit, .root, .signature]
        )
    }

    func testColumnWidthsAreClampedAndRoundTrip() {
        let layout = LogColumnLayout(
            orderRaw: "commit,author,date,hash",
            widthsRaw: "author=20;date=180;hash=90"
        )

        XCTAssertEqual(layout.width(for: .author), LogColumnID.author.minimumWidth)
        XCTAssertEqual(layout.width(for: .date), 180)
        XCTAssertEqual(
            LogColumnLayout(orderRaw: layout.orderRaw, widthsRaw: layout.widthsRaw),
            layout
        )
    }

    func testRootDisplayNameUsesLastPathComponentAndHandlesMissingPath() {
        XCTAssertEqual(logRepositoryDisplayName("/tmp/project/."), "project")
        XCTAssertEqual(logRepositoryDisplayPath("/tmp/project/."), "/tmp/project")
        XCTAssertEqual(logRepositoryDisplayName(nil), "—")
        XCTAssertEqual(logRepositoryDisplayPath(nil), "")
    }

    func testSignatureColumnHasIndependentVisibilityAndWidth() {
        let layout = LogColumnLayout(order: [.commit, .signature])
        XCTAssertFalse(LogColumnID.signature.isResizable)
        XCTAssertTrue(LogColumnID.root.isResizable)
        XCTAssertEqual(
            layout.visibleOrder(
                showAuthor: false,
                showDate: false,
                showHash: false,
                showRoot: false,
                showSignature: true
            ),
            [.commit, .signature]
        )
        XCTAssertEqual(
            layout.settingWidth(20, for: .signature).width(for: .signature),
            LogColumnID.signature.minimumWidth
        )
    }
}
