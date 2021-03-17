import XCTest

#if !canImport(ObjectiveC)
    public func allTests() -> [XCTestCaseEntry] {
        [
            testCase(WebSocketTests.allTests),
        ]
    }
#endif
