import AppKit
import SwiftUI

private final class TeamSettingsState: ObservableObject { @Published var githubToken = "" }
private final class TeamTasksState: ObservableObject {
    @Published var showNew = false
    @Published var onlyMine = false
    @Published var reviewTask: TeamTask?
    @Published var preview = ""
    @Published var files: [String] = []
    @Published var fingerprint = ""
    @Published var confirmPublish = false
}

struct TeamRoomView: View {
    @ObservedObject private var model = TeamRoomModel.shared
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @StateObject private var settings = TeamSettingsState()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Команда и GitHub", systemImage: "person.2.fill").font(.title2.bold())
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("Общий чат и доска связывают команду. Каждый агент работает через свой аккаунт и расходует свои лимиты.").foregroundStyle(.secondary)
            GroupBox("Комната · прямое соединение") {
                VStack(alignment: .leading, spacing: 10) {
                    if !model.connected {
                        if model.hasSavedRoom { Button("Вернуться в последнюю комнату") { model.restoreRoom() } }
                        HStack {
                            TextField("HTTPS-адрес службы знакомства", text: $model.server)
                            Button("Создать") { model.create() }.disabled(model.working || model.server.isEmpty)
                        }
                        HStack {
                            TextField("Приглашение", text: $model.code)
                            Button("Войти") { model.join() }.disabled(model.working || model.code.isEmpty)
                        }
                    } else {
                        HStack {
                            Label("На связи: \(model.peers) · \(model.isHost ? "ты создатель" : "участник")", systemImage: "link")
                            Spacer()
                            Button("Приглашение") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.invitation, forType: .string) }
                            Button("Переподключить") { model.reconnect() }.disabled(!model.running.isEmpty || !model.publishing.isEmpty)
                            Button("Выйти") { model.leave() }.disabled(!model.running.isEmpty || !model.publishing.isEmpty)
                        }
                    }
                    Text("Назначения подтверждает Пульт создателя комнаты. Пока он недоступен, новые задачи брать нельзя. Чат идёт напрямую; сети, блокирующие P2P, могут не соединиться.").font(.caption).foregroundStyle(.secondary)
                    TextField("Твоё имя", text: $model.name).frame(maxWidth: 250)
                }.padding(6)
            }
            GroupBox("Код проекта · GitHub") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Создавать папки и скачивать проект автоматически", isOn: $model.automaticFolders).disabled(model.working)
                    Text("Пульт подготовит копию проекта и отдельную папку с Git-веткой для каждой задачи. Доступ к приватному GitHub настраивается через Git на этом компьютере.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("https://github.com/команда/проект", text: $model.repository)
                        Button("Подключить к комнате") { model.connectRepository() }.disabled(!model.isHost || model.working)
                    }
                    HStack {
                        Text(model.project.isEmpty ? "Пульт сам скачает проект при запуске задачи" : model.project).font(.caption).textSelection(.enabled).lineLimit(2)
                        Spacer()
                        Button("Папка проекта") { model.chooseProject() }.disabled(model.working)
                        Button("Скачать автоматически") { model.prepareProject() }.disabled(model.working || model.repository.isEmpty)
                    }
                    Button("Обновить проект из GitHub") { model.pullProject() }.disabled(model.project.isEmpty || model.working || !model.running.isEmpty || workspace.anyBusy)
                    SecureField("GitHub-токен для создания PR", text: $settings.githubToken)
                    HStack {
                        Button("Сохранить токен в .env") {
                            model.status = Secrets.write("PULT_GITHUB_TOKEN", settings.githubToken) ? "GitHub-токен сохранён в .env" : "Не удалось сохранить .env"
                            settings.githubToken = ""
                        }.disabled(settings.githubToken.isEmpty)
                        Text(Secrets.read("PULT_GITHUB_TOKEN")?.isEmpty == false ? "Токен настроен" : "Токен не настроен").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Git использует твою локальную авторизацию. Для PR токену нужен доступ к этому репозиторию и Pull requests: write. Push и создание PR выполняются только после кнопки подтверждения. Объединение — на GitHub.").font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            HStack {
                Button("Открыть задачи и чат") { workspace.showTeamTasks = true; workspace.showTeamChat = true; dismiss() }
                Spacer()
                if model.working { ProgressView().controlSize(.small) }
            }
            Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 760)
    }
}

struct TeamChatPanel: View {
    @ObservedObject private var model = TeamRoomModel.shared
    @ObservedObject var workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Чат команды", systemImage: "bubble.left.and.bubble.right").font(.headline)
                Spacer()
                Button { workspace.showTeamChat = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            HStack {
                Text("Участников на связи: \(model.peers)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Настроить") { workspace.showTeamRoom = true }.font(.caption)
            }
            Toggle("Агенты общаются автоматически", isOn: $model.agentDialogue).font(.caption)
            HStack {
                Text(model.agentStatus).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Ещё 8 ходов") { model.resumeAgentDialogue() }.font(.caption).disabled(!model.agentDialogue)
            }
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if model.conversation.isEmpty { Text("Здесь договариваетесь с командой. Из любого сообщения можно создать задачу.").foregroundStyle(.secondary).padding(.vertical) }
                        ForEach(model.conversation) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(message.author).font(.callout.bold())
                                    Spacer()
                                    Text(message.date, style: .time).font(.caption2).foregroundStyle(.secondary)
                                }
                                Text(message.text).font(.callout).textSelection(.enabled)
                                Button("Создать задачу") { model.taskFrom(message); workspace.showTeamTasks = true }
                                    .font(.caption).disabled(!model.boardReady)
                            }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10)).id(message.id)
                        }
                    }
                }.onChange(of: model.conversation.last?.id) { _, id in if let id = id { scroll.scrollTo(id, anchor: .bottom) } }
            }
            TextEditor(text: $model.draft).font(.callout).frame(height: 80).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                TextField("Твоё имя", text: $model.name).textFieldStyle(.roundedBorder)
                Button("Отправить") { model.send() }.disabled(model.peers == 0 || model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(model.status).font(.caption2).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
        }.padding(14).frame(width: 300).background(panel.opacity(0.94))
    }
}

struct TeamTasksPanel: View {
    @ObservedObject private var model = TeamRoomModel.shared
    @ObservedObject var workspace: Workspace
    @StateObject private var state = TeamTasksState()
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Задачи · \(model.board.tasks.count)", systemImage: "checklist").font(.headline)
                Spacer()
                Button { workspace.showTeamTasks = false } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            HStack {
                Label(model.boardReady ? "Доска на связи" : "Доска без подтверждения", systemImage: model.boardReady ? "checkmark.circle" : "wifi.slash").font(.caption).foregroundStyle(model.boardReady ? .green : .orange)
                Spacer()
                Button { workspace.showTeamRoom = true } label: { Image(systemName: "gearshape") }
            }
            HStack {
                Button("Новая задача", systemImage: "plus") { state.showNew.toggle() }.disabled(!model.boardReady)
                Spacer()
                Toggle("Мои", isOn: $state.onlyMine).toggleStyle(.checkbox).font(.caption)
            }
            if state.showNew {
                VStack(spacing: 8) {
                    TextField("Название", text: $model.taskTitle).textFieldStyle(.roundedBorder)
                    TextEditor(text: $model.taskDetail).frame(height: 65).font(.callout)
                    Button("Добавить на доску") { model.addTask() }.disabled(model.taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
            if model.board.tasks.isEmpty {
                Text("Создай задачу сам или из сообщения команды. Агент сможет добавить найденные задачи после выполнения своей части.").font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.board.tasks.filter { !state.onlyMine || $0.ownerID == model.identity }) { task in
                        taskCard(task)
                    }
                }
            }
            Divider()
            Button {
                model.claim(workspace)
            } label: {
                HStack { if model.pendingClaims || model.working { ProgressView().controlSize(.small) }; Text("Взять в работу · \(model.selected.count)"); Spacer(); Image(systemName: "play.fill") }
            }.buttonStyle(.borderedProminent).disabled(!model.canClaim || model.selected.isEmpty)
            if let reason = model.claimBlockReason {
                Text(reason).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                Button("Настроить команду и проект") { workspace.showTeamRoom = true }.font(.caption)
            } else if model.selected.isEmpty {
                Text("Отметь галочкой свободную задачу, затем нажми «Взять в работу»").font(.caption).foregroundStyle(.secondary)
            }
            Text("Переписка с агентом личная. Чат команды, задачи, статусы и результаты видны всем. Отдельная Git-ветка на каждую задачу; расходуются твои лимиты.").font(.caption2).foregroundStyle(.secondary)
            Text(model.status).font(.caption2).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
        }.padding(14).frame(width: 320).background(panel.opacity(0.94))
        .sheet(item: $state.reviewTask) { task in
            VStack(alignment: .leading, spacing: 14) {
                Text("Проверка: " + task.title).font(.title2.bold())
                ScrollView { Text(state.preview).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Открыть папку") { if let url = model.folder(task) { NSWorkspace.shared.open(url) } }
                    Spacer()
                    Button("Закрыть") { state.reviewTask = nil }
                    Button("Отправить ветку и создать PR") { state.confirmPublish = true }.disabled(model.publishing.contains(task.id))
                }
            }.padding(24).frame(width: 800, height: 600)
            .alert("Опубликовать изменения на GitHub?", isPresented: $state.confirmPublish) {
                Button("Отправить и создать PR") { model.publish(task, files: state.files, fingerprint: state.fingerprint); state.reviewTask = nil }
                Button("Отмена", role: .cancel) {}
            } message: { Text("Будет создан коммит и отправлена ветка задачи. PR станет доступен участникам репозитория. Основная ветка объединяется отдельно на GitHub.") }
        }
    }
    @ViewBuilder private func taskCard(_ task: TeamTask) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                if task.status == .available {
                    Toggle(isOn: Binding(get: { model.selected.contains(task.id) }, set: { if $0 { model.selected.insert(task.id) } else { model.selected.remove(task.id) } })) { EmptyView() }.toggleStyle(.checkbox).labelsHidden().disabled(!model.boardReady)
                }
                Text(task.title).font(.callout.bold()).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            HStack {
                Text(task.status.label).font(.caption.bold()).foregroundStyle(task.status == .done ? .green : task.status == .failed ? .red : .secondary)
                if let owner = task.ownerName { Text("· " + owner).font(.caption).foregroundStyle(.secondary) }
            }
            if !task.detail.isEmpty { Text(task.detail).font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled) }
            if let branch = task.branch { Text(branch).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) }
            if !task.result.isEmpty {
                DisclosureGroup("Результат") { Text(task.result).font(.caption).textSelection(.enabled) }.font(.caption)
            }
            if let pr = task.pullRequest, let url = URL(string: pr), TeamRepository.validPR(pr, repository: model.board.repository) { Link("Открыть PR на GitHub", destination: url).font(.caption) }
            if task.ownerID == model.identity {
                if model.running.values.contains(task.id) {
                    Button("Открыть агента") { model.openTask(task, workspace: workspace) }.font(.caption)
                } else if task.status != .done {
                    HStack {
                        Button(task.status == .failed ? "Повторить" : "Продолжить") { model.launch([task], workspace: workspace) }.disabled(!model.boardReady || model.working)
                        if model.folder(task) != nil {
                            Button(model.publishing.contains(task.id) ? "Публикую…" : "Изменения и PR") {
                                model.preview(task) { text, changed, fingerprint in state.preview = text; state.files = changed; state.fingerprint = fingerprint; state.reviewTask = task }
                            }.disabled(model.working || model.publishing.contains(task.id))
                        }
                    }.font(.caption)
                    if [.failed, .review].contains(task.status) && task.pullRequest == nil { Button("Освободить задачу") { model.release(task) }.font(.caption).disabled(!model.boardReady || model.publishing.contains(task.id)) }
                }
            }
            if task.status == .review && (model.isHost || task.ownerID == model.identity) {
                Button("Проверено · завершить") { model.complete(task) }.font(.caption).disabled(!model.boardReady || model.publishing.contains(task.id))
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}
