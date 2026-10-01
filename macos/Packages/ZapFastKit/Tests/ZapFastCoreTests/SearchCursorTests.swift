import Testing
@testable import ZapFastCore

struct SearchCursorTests {
    private let ids = ["a", "b", "c"]

    @Test func downStartsAtTheFirstResultAndStopsAtTheLast() {
        #expect(SearchCursor.moved(from: nil, in: ids, down: true) == "a")
        #expect(SearchCursor.moved(from: "a", in: ids, down: true) == "b")
        #expect(SearchCursor.moved(from: "c", in: ids, down: true) == "c")
    }

    @Test func upStaysOnNoneAndStopsAtTheFirst() {
        #expect(SearchCursor.moved(from: nil, in: ids, down: false) == nil)
        #expect(SearchCursor.moved(from: "c", in: ids, down: false) == "b")
        #expect(SearchCursor.moved(from: "a", in: ids, down: false) == "a")
    }

    @Test func aResultThatLeftTheListIsAsNone() {
        // The results changed under the cursor.
        #expect(SearchCursor.moved(from: "gone", in: ids, down: true) == "a")
        #expect(SearchCursor.moved(from: "gone", in: ids, down: false) == nil)
        #expect(SearchCursor.moved(from: "a", in: [], down: true) == nil)
    }

    @Test func enterOpensTheReachedChatElseTheFirst() {
        #expect(SearchCursor.opened(from: "b", in: ids) == "b")
        #expect(SearchCursor.opened(from: nil, in: ids) == "a")
        #expect(SearchCursor.opened(from: "gone", in: ids) == "a")
        #expect(SearchCursor.opened(from: nil, in: []) == nil)
    }
}
