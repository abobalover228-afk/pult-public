import SwiftUI

struct QueuedMessage: Identifiable {
    let id = UUID()
    let text: String
    let images: [String]
    let provider: String
    let directory: String
    let context: UUID
}

struct MessageQueueView: View {
    @ObservedObject var chat: Chat
    @ObservedObject var ui: UIState
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Очередь · \(chat.pendingMessages.count)").font(monoSmall)
                Spacer()
                if chat.queuePaused || !chat.busy {
                    Button("Продолжить") { chat.resumeQueue() }.buttonStyle(.borderless)
                }
                Button(chat.queuePaused ? "Приостановлена" : "Пауза") { chat.queuePaused.toggle() }.buttonStyle(.borderless)
            }
            ForEach(Array(chat.pendingMessages.enumerated()), id: \.element.id) { index, message in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1)").foregroundColor(.secondary)
                    ProviderIcon(claude: message.provider == "claude")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.text.isEmpty ? "Картинка" : message.text).lineLimit(2)
                        if !message.images.isEmpty { Text("Вложений: \(message.images.count)").foregroundColor(.secondary) }
                    }
                    Spacer()
                    Button("В поле") {
                        guard ui.draft.isEmpty else { return }
                        ui.draft = message.text; chat.attachments += message.images
                        chat.pendingMessages.removeAll { $0.id == message.id }
                    }.buttonStyle(.borderless).disabled(!ui.draft.isEmpty)
                    Button { chat.pendingMessages.removeAll { $0.id == message.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Убрать из очереди")
                }.font(monoSmall)
            }
            if let first = chat.pendingMessages.first, first.directory != chat.cwd || first.provider != chat.target || first.context != chat.queueContext {
                Text("Очередь ждёт исходный разговор, папку и провайдера. Можно вернуть сообщение в поле и отправить вручную.").font(.caption).foregroundColor(.secondary)
            }
        }.padding(10).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
            .padding(.horizontal, 12).padding(.bottom, 6)
    }
}
