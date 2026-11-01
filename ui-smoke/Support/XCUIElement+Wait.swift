import XCTest

extension XCUIElement {
    /// Wait until the element stops existing.
    ///
    // Probe commit: exercise the CI shard split. Not part of the branch history.
    /// `waitForNonExistence(timeout:)` is only available in newer Xcode
    /// releases, while the CI runner used by `.github/workflows/ui-smoke.yml`
    /// ships an older one. Waiting on the same predicate keeps the suite
    /// building on both.
    func arborWaitForNonExistence(timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: self
        )
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
// probe 2
