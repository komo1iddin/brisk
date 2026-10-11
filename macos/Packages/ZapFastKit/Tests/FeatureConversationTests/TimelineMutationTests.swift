import Testing
@testable import FeatureConversation
@testable import ZapFastCore

@MainActor
struct TimelineMutationTests {
    @Test func contiguousUpdatesAndAppendsResolveOnlyEditedOldRows() {
        let changes = [ConversationDelta(revision: 11, previousCount: 10_000, count: 10_000, updated: [0, 9_999]),
                       ConversationDelta(revision: 12, previousCount: 10_000, count: 10_001, updated: []),
                       ConversationDelta(revision: 13, previousCount: 10_001, count: 10_001, updated: [9_999, 10_000])]
        #expect(TimelineMutation.resolve(changes, after: 10, through: 13, previousCount: 10_000, count: 10_001) == [0, 9_999, 10_000])
    }

    @Test func missingRevisionsOrWrongCountsRequireTheGeneralDiff() {
        let change = ConversationDelta(revision: 12, previousCount: 10, count: 11, updated: [])
        #expect(TimelineMutation.resolve([change], after: 10, through: 12, previousCount: 10, count: 11) == nil)
        #expect(TimelineMutation.resolve([change], after: 11, through: 12, previousCount: 9, count: 11) == nil)
        #expect(TimelineMutation.resolve([change], after: 11, through: 12, previousCount: 10, count: 12) == nil)
    }

    @Test func deletedOrInvalidRowsRequireTheGeneralDiff() {
        let removed = ConversationDelta(revision: 2, previousCount: 10, count: 9, updated: [])
        let invalid = ConversationDelta(revision: 2, previousCount: 10, count: 10, updated: [10])
        #expect(TimelineMutation.resolve([removed], after: 1, through: 2, previousCount: 10, count: 9) == nil)
        #expect(TimelineMutation.resolve([invalid], after: 1, through: 2, previousCount: 10, count: 10) == nil)
    }
}
