import AppKit
import SwiftUI

struct PultIcon: View {
    let symbol: String
    var body: some View { Image(systemName: symbol).font(.system(size: 14, weight: .medium)).symbolRenderingMode(.hierarchical).frame(width: 22, height: 22) }
}
final class IconHover: ObservableObject { @Published var value = false }

struct PultIconStyle: ButtonStyle {
    var selected = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, selected: selected, enabled: enabled)
    }
    private struct IconButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        let enabled: Bool
        @StateObject private var hover = IconHover()
        var body: some View {
            configuration.label.padding(5)
                .foregroundStyle(enabled ? (selected ? Color(red: 0.92, green: 0.58, blue: 0.40) : Color.primary) : Color.secondary.opacity(0.4))
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(configuration.isPressed ? 0.18 : selected ? 0.12 : hover.value && enabled ? 0.08 : 0)))
                .onHover { hover.value = $0 }
        }
    }
}

final class APIConnectionForm: ObservableObject {
    @Published var editing = APIConnection(name: "", baseURL: "https://api.openai.com/v1", model: "")
    @Published var key = ""
    @Published var error: String?
    @Published var deleteCandidate: APIConnection?
}

struct APIConnectionsView: View {
    @ObservedObject var store: APIConnectionStore
    let onSelect: (APIConnection) -> Void
    let canSelect: Bool
    @StateObject private var form = APIConnectionForm()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("API-подключения", systemImage: "network").font(.title2.bold()); Spacer(); Button("Готово") { form.key = ""; dismiss() } }
            Text("OpenAI-совместимый Chat Completions. Codex и Claude CLI остаются в меню аккаунтов.").font(.caption).foregroundStyle(.secondary)
            if let message = store.loadError { Text(message).foregroundStyle(.red) }
            ScrollView {
                VStack(spacing: 8) {
                    if store.connections.isEmpty { Text("Пока нет API-подключений. Добавь первое ниже.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(store.connections) { connection in
                        HStack {
                            VStack(alignment: .leading) { Text(connection.name).bold(); Text(connection.model + " · лимиты неизвестны").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Выбрать") { onSelect(connection); form.key = ""; dismiss() }.disabled(!canSelect)
                            Button { form.editing = connection; form.key = ""; form.error = nil } label: { PultIcon(symbol: "pencil") }.buttonStyle(PultIconStyle()).help("Изменить подключение").accessibilityLabel("Изменить " + connection.name)
                            Button { form.deleteCandidate = connection } label: { PultIcon(symbol: "trash") }.buttonStyle(PultIconStyle()).help("Удалить подключение и ключ").accessibilityLabel("Удалить " + connection.name).disabled(!canSelect)
                        }.padding(8).background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
                    }
                }
            }.frame(maxHeight: store.connections.isEmpty ? 38 : 170)
            Divider()
            HStack { Text(store.connections.contains(where: { $0.id == form.editing.id }) ? "Изменение подключения" : "Новое подключение").font(.headline); Spacer(); Button("Новое") { form.editing = APIConnection(name: "", baseURL: "https://api.openai.com/v1", model: ""); form.key = ""; form.error = nil } }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow { Text("Название"); TextField("Например: Мой API", text: $form.editing.name) }
                GridRow { Text("API-ключ"); SecureField(store.connections.contains(where: { $0.id == form.editing.id }) ? "Пусто — оставить ключ в Keychain" : "Сохранится в macOS Keychain", text: $form.key) }
                GridRow { Text("Base URL"); TextField("https://api.openai.com/v1", text: $form.editing.baseURL) }
                GridRow { Text("Модель"); TextField("Идентификатор модели у провайдера", text: $form.editing.model) }
            }.textFieldStyle(.roundedBorder)
            Text("Сохранение не отправляет запросов. При выборе API сообщения и вложения диалога будут отправляться указанному провайдеру только по кнопке отправки. Ключ не попадает в JSON-настройки и историю.").font(.caption).foregroundStyle(.secondary)
            Text("API: чат, изображения, локальная история, очередь и Суперпромпт. Выполнение команд, MCP и вопросы инструментов — функции CLI.").font(.caption).foregroundStyle(.secondary)
            if let message = form.error { Text(message).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Сохранить") {
                    do { try store.save(form.editing, newKey: form.key); form.key = ""; form.error = nil }
                    catch { self.form.error = (error as? APIProblem)?.message ?? "Не удалось сохранить API-подключение." }
                }.buttonStyle(.borderedProminent).disabled(store.loadError != nil || !canSelect)
            }
        }.padding(20).frame(width: 620, height: 620)
        .alert("Удалить подключение и ключ?", isPresented: Binding(get: { form.deleteCandidate != nil }, set: { if !$0 { form.deleteCandidate = nil } })) {
            Button("Удалить", role: .destructive) {
                guard let connection = form.deleteCandidate else { return }
                do { try store.remove(connection) } catch { self.form.error = (error as? APIProblem)?.message ?? "Не удалось удалить подключение." }
                form.deleteCandidate = nil
            }
            Button("Отмена", role: .cancel) { form.deleteCandidate = nil }
        } message: { Text("История останется на компьютере. Ключ будет удалён из Keychain.") }
        .onDisappear { form.key = "" }
    }
}
