import Foundation
import Testing
import ZapFastBridge
@testable import ZapFastCore

@MainActor
struct PollTests {
    private func state(selectable: UInt32, selected: [UInt32], refreshNeeded: Bool = false) -> PollSummary {
        PollSummary(
            selectable: selectable, counts: [0, 0, 0], selected: selected, voters: 0, canVote: true,
            historyComplete: true, refreshNeeded: refreshNeeded, refreshing: false, refreshFailed: false, votes: []
        )
    }

    private func poll(_ state: PollSummary) -> MessageRecord {
        MessageRecord(
            id: "p", chat: "g@g.us", sender: "x@s.whatsapp.net", senderName: nil, fromMe: false,
            timestamp: 1, content: .poll(question: "Lunch?", options: ["A", "B", "C"], state: state),
            status: .none, deliveredAt: nil, readAt: nil, quoted: nil, reactions: [], edited: false,
            mentions: [], forwarded: false, thumbnail: nil, summary: "Poll: Lunch?"
        )
    }

    private func connectedModel() -> (AppModel, PreviewBackend) {
        let backend = PreviewBackend()
        let root = FileManager.default.temporaryDirectory.appending(path: "zapfast-poll-\(UUID().uuidString)")
        let model = AppModel(
            backend: backend,
            paths: AppPaths(data: root, caches: root),
            preferences: Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        )
        model.apply([.link(state: .connected)])
        return (model, backend)
    }

    @Test func singleAnswerSwapsAndClickingTheChoiceWithdrawsIt() {
        #expect(PollBallot.choices(afterClicking: 2, in: state(selectable: 1, selected: [0])) == [2])
        #expect(PollBallot.choices(afterClicking: 0, in: state(selectable: 1, selected: [0])) == [])
    }

    @Test func aFullMultipleChoiceRefusesAnotherButAnyNumberIsUnlimited() {
        #expect(PollBallot.choices(afterClicking: 2, in: state(selectable: 2, selected: [0, 1])) == nil)
        #expect(PollBallot.choices(afterClicking: 0, in: state(selectable: 0, selected: [2, 1])) == [0, 1, 2])
    }

    @Test func oneVoteAtATimeUntilTheBackendAnswers() {
        let (model, backend) = connectedModel()
        let message = poll(state(selectable: 1, selected: []))

        model.vote(message, option: 1)
        model.vote(message, option: 2)
        let votes = backend.sent.filter { if case .votePoll = $0 { true } else { false } }
        #expect(votes == [.votePoll(chat: "g@g.us", message: "p", choices: [1])])

        model.apply([.pollVoted(chat: "g@g.us", message: "p", error: "Could not vote")])
        #expect(model.pollVoting.isEmpty)
        #expect(model.notices.last?.text == "Could not vote")
    }

    @Test func aPollMissingVotesAsksThePhoneOnce() {
        let (model, backend) = connectedModel()
        let message = poll(state(selectable: 1, selected: [], refreshNeeded: true))
        model.pollAppeared(message)
        model.pollAppeared(message)
        #expect(backend.sent.filter { $0 == .refreshPoll(chat: "g@g.us", message: "p") }.count == 1)
    }
}
