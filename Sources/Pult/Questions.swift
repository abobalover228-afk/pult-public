import SwiftUI

struct UserQuestionView: View {
    @ObservedObject var item: Item
    @ObservedObject var chat: Chat
    var questions: [JSON] { (item.payload["questions"] as? [JSON]) ?? [] }
    var answeredAll: Bool {
        !questions.isEmpty && questions.allSatisfy { question in
            guard let id = question["id"] as? String else { return false }
            return !(item.questionAnswers[id]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
    func answer(_ id: String) -> Binding<String> {
        Binding(get: { item.questionAnswers[id] ?? "" }, set: { item.questionAnswers[id] = $0 })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.decision == nil ? "Нужен твой ответ" : "Ответ отправлен").font(.headline).foregroundColor(accent)
            ForEach(Array(questions.enumerated()), id: \.offset) { _, question in
                if let id = question["id"] as? String {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(question["question"] as? String ?? "Вопрос").textSelection(.enabled)
                        if item.decision == nil {
                            ForEach(Array(((question["options"] as? [JSON]) ?? []).enumerated()), id: \.offset) { _, option in
                                if let label = option["label"] as? String {
                                    Button { item.questionAnswers[id] = label } label: {
                                        HStack(alignment: .top, spacing: 8) {
                                            Image(systemName: item.questionAnswers[id] == label ? "largecircle.fill.circle" : "circle")
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(label)
                                                if let description = option["description"] as? String, !description.isEmpty {
                                                    Text(description).font(.caption).foregroundColor(.secondary)
                                                }
                                            }
                                            Spacer()
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                }
                            }
                            if question["isSecret"] as? Bool == true {
                                SecureField("Твой ответ", text: answer(id)).textFieldStyle(.roundedBorder)
                            } else {
                                TextField("Свой ответ или уточнение", text: answer(id), axis: .vertical)
                                    .textFieldStyle(.roundedBorder).lineLimit(1...6)
                            }
                        }
                    }
                }
            }
            if item.decision == nil {
                Button("Отправить ответ") { chat.submitQuestion(item) }.disabled(!answeredAll)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.65)))
    }
}

struct QuestionPayload {
    static func response(_ payload: JSON, answers: [String: String]) -> JSON? {
        guard let questions = payload["questions"] as? [JSON], !questions.isEmpty else { return nil }
        var response: JSON = [:]
        for question in questions {
            guard let id = question["id"] as? String, !id.isEmpty,
                  let answer = answers[id]?.trimmingCharacters(in: .whitespacesAndNewlines), !answer.isEmpty else { return nil }
            response[id] = ["answers": [answer]]
        }
        return ["answers": response]
    }
}
