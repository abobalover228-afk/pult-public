import SwiftUI

@main struct TeamPreview: App {
    @StateObject var workspace = Workspace(connectImmediately: false)
    var body: some Scene {
        WindowGroup("Пульт · команда · проверка") {
            RootView(workspace: workspace).frame(minWidth: 1420, minHeight: 760)
                .onAppear {
                    workspace.showTeamTasks = true
                    workspace.showTeamChat = true
                    let model = TeamRoomModel.shared
                    model.name = "Проверка"
                    model.board = BoardSnapshot(tasks: [
                        TeamTask(title: "Сделать экран входа", detail: "Проверить регистрацию и обработку ошибок"),
                        TeamTask(title: "Добавить поиск", detail: "Поиск по общему проекту", status: .review, ownerID: "preview", ownerName: "Боб", result: "Поиск добавлен. Проверены пустой запрос и Unicode.")
                    ])
                    for (index, account) in workspace.active.accounts.enumerated() {
                        LimitsStore.shared.limits[account.home] = Limits(five: Double(index * 9 + 5), week: Double(index * 13 + 10))
                    }
                }
        }.defaultSize(width: 1480, height: 850)
        .windowStyle(.hiddenTitleBar)
    }
}
