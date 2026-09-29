import SwiftUI
import ZapFastBridge
import ZapFastCore
import ZapFastDesign

/// Writes a poll: a question, two to twelve answers, and whether more than
/// one may be chosen. Upstream's rules decide when it can be sent.
struct CreatePollSheet: View {
    let chatID: String
    let model: AppModel

    @State private var question = ""
    @State private var answers = [Answer(), Answer()]
    @State private var multiple = true
    @FocusState private var focus: Field?
    @Environment(\.dismiss) private var dismiss

    private enum Field: Hashable { case question, answer(UUID) }
    private struct Answer: Identifiable {
        let id = UUID()
        var text = ""
    }
    private static let maxAnswers = 12

    var body: some View {
        let draft = PollDraftInfo(question: question, options: answers.map(\.text), multiple: multiple)
        let problem = pollDraftProblem(draft: draft)
        VStack(alignment: .leading, spacing: Metrics.m) {
            Text("Create Poll").font(.headline)

            VStack(alignment: .leading, spacing: Metrics.xs) {
                Text("Question").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                TextField("Ask a question", text: $question, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .question)
            }

            VStack(alignment: .leading, spacing: Metrics.xs) {
                Text("Answers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: Metrics.xs) {
                        ForEach($answers) { $answer in
                            let number = (answers.firstIndex { $0.id == answer.id } ?? 0) + 1
                            HStack(spacing: Metrics.xs) {
                                TextField("Answer \(number)", text: $answer.text)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focus, equals: .answer(answer.id))
                                    .onSubmit { advance(from: answer.id) }
                                Button("Remove Answer", systemImage: "minus.circle.fill") {
                                    answers.removeAll { $0.id == answer.id }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .foregroundStyle(.secondary)
                                .disabled(answers.count <= 2)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)

                if answers.count < Self.maxAnswers {
                    Button("Add Answer", systemImage: "plus") {
                        let added = Answer()
                        answers.append(added)
                        focus = .answer(added.id)
                    }
                    .buttonStyle(.borderless)
                }
            }

            Toggle("Allow multiple answers", isOn: $multiple)

            if let problem, !question.isEmpty || answers.contains(where: { !$0.text.isEmpty }) {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if model.pollCreating { ProgressView().controlSize(.small) }
                Button("Send Poll") { model.createPoll(draft, in: chatID) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || model.pollCreating || !model.session.isConnected)
            }
        }
        .padding(Metrics.l)
        .frame(width: 380)
        .onAppear { focus = .question }
    }

    /// Return moves to the next answer, adding one at the end while room.
    private func advance(from id: UUID) {
        guard let index = answers.firstIndex(where: { $0.id == id }) else { return }
        if index + 1 < answers.count {
            focus = .answer(answers[index + 1].id)
        } else if answers.count < Self.maxAnswers, !answers[index].text.trimmingCharacters(in: .whitespaces).isEmpty {
            let added = Answer()
            answers.append(added)
            focus = .answer(added.id)
        }
    }
}
