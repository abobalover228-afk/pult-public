// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "Pult", platforms: [.macOS(.v14)], dependencies: [.package(url: "https://github.com/stasel/WebRTC.git", exact: "157.0.0")], targets: [
.executableTarget(name: "Pult", dependencies: ["WebRTC"], path: "Sources/Pult", sources: ["Guide.swift", "App.swift", "Chat.swift", "Codex.swift", "Markdown.swift", "Support.swift", "Views.swift", "Commands.swift", "Questions.swift", "Queue.swift", "IntegratedCommands.swift", "FileLinks.swift", "PromptCoach.swift", "APIConnections.swift", "APIChat.swift", "ConnectionViews.swift", "ConversationState.swift", "FastMode.swift", "FollowingScroll.swift", "Workspace.swift", "Telegram.swift", "Updater.swift", "Theme.swift", "Voice.swift", "ChatTrash.swift", "DirectRoom.swift", "ProjectGit.swift", "TeamRoomView.swift", "TeamBoard.swift", "TeamProject.swift", "TeamRoomModel.swift"])
], swiftLanguageModes: [.v5])
