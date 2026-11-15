import AppKit
import SwiftUI

final class ConversationPreferences: ObservableObject {
    static let shared = ConversationPreferences()
    @Published var globalRules: String { didSet { defaults.set(globalRules, forKey: "globalRules.v2") } }
    @Published private(set) var overrides: [String:String]
    @Published private(set) var pins: Set<String>
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        globalRules = defaults.string(forKey: "globalRules.v2") ?? ""
        overrides = defaults.dictionary(forKey: "chatRules.v2") as? [String:String] ?? [:]
        pins = Set(defaults.stringArray(forKey: "pinnedThreads.v2") ?? [])
    }
    func rules(_ id: String) -> String { overrides[id] ?? globalRules }
    func setOverride(_ text: String?, for id: String) {
        overrides[id] = text; defaults.set(overrides, forKey: "chatRules.v2")
    }
    func togglePin(_ id: String) { if pins.contains(id) { pins.remove(id) } else { pins.insert(id) }; defaults.set(Array(pins).sorted(), forKey: "pinnedThreads.v2") }
    func copyOverride(from: String, to: String) { if let value = overrides[from] { setOverride(value, for: to) } }
}

struct SavedChatItem: Codable {
    let id: String
    let kind: String
    let text: String
    let output: String
    let images: [String]
    let exitCode: Int?
    let decision: String?
    let claude: Bool
    init(_ item: Item) { id=item.id; kind=String(describing:item.kind); text=item.text; output=item.output; images=item.images; exitCode=item.exitCode; decision=item.decision; claude=item.claude }
    func item() -> Item {
        let type: Kind
        switch kind { case "user": type = .user; case "agent": type = .agent; case "command": type = .command; case "file": type = .file; case "thinking": type = .thinking; case "error": type = .error; default: type = .note }
        let item=Item(id,type,text);item.output=output;item.images=images;item.exitCode=exitCode;item.decision=decision;item.claude=claude;item.done=true
        return item
    }
}
struct LocalConversation: Codable {
    var id: UUID
    var date: Date
    var provider: String
    var directory: String
    var accountHome: String
    var title: String
    var items: [SavedChatItem]
}
enum LocalConversationStore {
    static var directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PultConversations")
    static func save(_ value: LocalConversation) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=directory.appendingPathComponent(value.id.uuidString+".json")
        try JSONEncoder().encode(value).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    static func read(_ path:String) throws -> LocalConversation { try JSONDecoder().decode(LocalConversation.self,from:Data(contentsOf:URL(fileURLWithPath:path))) }
    static func threads() -> [ThreadInfo] {
        ((try? FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)) ?? []).compactMap { url in
            guard let value=try? read(url.path) else{return nil}
            return ThreadInfo(id:"local:"+value.id.uuidString,path:url.path,title:value.title,date:value.date,account:"Ветка · "+value.provider,cwd:value.directory)
        }
    }
}

extension Chat {
    var conversationKey: String { localConversationID.map { "local:"+$0.uuidString } ?? (isAPI ? apiConversationID.map { "api:"+$0.uuidString } : threadId) ?? draftConversationKey }
    var effectiveRules: String { preferences.rules(conversationKey) }
    func prepareRulesForTurn() {
        if (appliedRules != nil && appliedRules != effectiveRules || appliedRules == nil && !effectiveRules.isEmpty && (threadId != nil || target == "claude")), target == "codex" || target == "claude" {
            let oldKey=conversationKey
            freshContextSeed=PromptSnapshot.history(items);freshContextImages=items.flatMap(\.images)
            if localConversationID == nil { localConversationID=UUID() }
            detachThreadForBranch();claudeIsolatedSession=UUID().uuidString.lowercased()
            preferences.copyOverride(from:oldKey,to:conversationKey)
            queueContext=UUID();queuePaused=true
        }
        appliedRules=effectiveRules
    }

    func migrateRules(from old:String) { preferences.copyOverride(from:old,to:conversationKey) }
    func collapseServiceBlocks() {
        expandedTools = false
        for item in items where item.canCollapse { item.serviceCollapsed=true;item.expanded=false }
    }
    func saveLocalBranch() {
        guard let id=localConversationID else{return}
        do { try LocalConversationStore.save(LocalConversation(id:id,date:Date(),provider:target,directory:cwd,accountHome:account.home,title:String((items.first{$0.kind == .user}?.text ?? "Ветка разговора").prefix(120)),items:items.map(SavedChatItem.init))) }
        catch { add(.error,"Не удалось сохранить ветку разговора на диск.") }
    }
    func openLocalBranch(_ thread:ThreadInfo) {
        guard !busy,!nativeCLIIsRunning,!team.running else { add(.note,"Сначала останови текущую работу.");return }
        do {
            let value=try LocalConversationStore.read(thread.path)
            newChat();target=value.provider;cwd=value.directory
            if let idx=accounts.firstIndex(where:{$0.home == value.accountHome}) { current=idx }
            if target == "claude" { claudeIsolatedSession=UUID().uuidString.lowercased() }
            localConversationID=value.id;items=value.items.map{$0.item()};rebuildItemIndex()
            freshContextSeed=PromptSnapshot.history(items);freshContextImages=items.flatMap(\.images)
            if target == "codex" && connectBranches { connect(current) }
        } catch { add(.error,"Не удалось прочитать сохранённую ветку.") }
    }
    func integrateTeamResult(_ text:String) {
        guard !busy,!nativeCLIIsRunning,team.contextID == queueContext else{return}
        let oldKey=conversationKey
        if localConversationID == nil { localConversationID=UUID() }
        add(.agent,text)
        preferences.copyOverride(from:oldKey,to:conversationKey)
        if !isAPI {
            freshContextSeed=PromptSnapshot.history(items);freshContextImages=items.flatMap(\.images)
            detachThreadForBranch();claudeIsolatedSession=UUID().uuidString.lowercased()
        }
        saveLocalBranch();loadThreads()
    }
    func beginEdit(_ item:Item) { guard item.kind == .user else{return};editingItem=item;editingText=item.text;editingImages=item.images }
    func editAndContinue() {
        guard let item=editingItem,let index=items.firstIndex(where:{$0 === item}),!busy,!nativeCLIIsRunning,!team.running else{return}
        let text=editingText.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty || !editingImages.isEmpty else{return}
        let previous=LocalConversation(id:UUID(),date:Date(),provider:target,directory:cwd,accountHome:account.home,title:"До редактирования · "+String(item.text.prefix(90)),items:items.map(SavedChatItem.init))
        do { try LocalConversationStore.save(previous) } catch { add(.error,"Не удалось сохранить старое продолжение. Редактирование отменено.");return }
        let oldKey=conversationKey
        preferences.copyOverride(from:oldKey,to:"local:"+previous.id.uuidString)
        restorePoint=previous;restoreQueue=pendingMessages;pendingMessages=[];queuePaused=true;queueContext=UUID()
        localConversationID=UUID();apiConversationID=nil;detachThreadForBranch()
        items=Array(items.prefix(index));rebuildItemIndex()
        freshContextSeed=PromptSnapshot.history(items);freshContextImages=items.flatMap(\.images)
        preferences.copyOverride(from:oldKey,to:conversationKey)
        if target == "claude" { claudeIsolatedSession=UUID().uuidString.lowercased() }
        let images=editingImages;editingItem=nil;attachments=images
        saveLocalBranch()
        send(text)
    }
    func restoreEditedBranch() {
        guard !busy,!nativeCLIIsRunning,!team.running,let value=restorePoint else{return}
        saveLocalBranch();newChat();target=value.provider;cwd=value.directory;localConversationID=value.id
        if let idx=accounts.firstIndex(where:{$0.home == value.accountHome}) { current=idx }
        items=value.items.map{$0.item()};rebuildItemIndex();freshContextSeed=PromptSnapshot.history(items);freshContextImages=items.flatMap(\.images)
        pendingMessages=restoreQueue.map { QueuedMessage(text:$0.text,images:$0.images,provider:$0.provider,directory:$0.directory,context:queueContext) };queuePaused=true
        restorePoint=nil;restoreQueue=[]
        if target == "claude" { claudeIsolatedSession=UUID().uuidString.lowercased() }
        if target == "codex" && connectBranches { connect(current) }
        loadThreads()
    }
}
extension Item {
    var canCollapse: Bool { kind == .thinking || kind == .file || (kind == .command && (exitCode ?? 0) == 0) || (kind == .note && isPlan) }
}

struct RulesEditor: View {
    @ObservedObject var chat:Chat
    @ObservedObject var preferences:ConversationPreferences
    @Environment(\.dismiss) var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Правила приложения и чата").font(.title2.bold())
            Text("Общие правила").bold()
            TextEditor(text:$preferences.globalRules).font(.system(size:13)).frame(height:140)
            Toggle("Переопределить общие правила в этом чате",isOn:Binding(get:{preferences.overrides[chat.conversationKey] != nil},set:{preferences.setOverride($0 ? preferences.rules(chat.conversationKey) : nil,for:chat.conversationKey)}))
            if preferences.overrides[chat.conversationKey] != nil {
                TextEditor(text:Binding(get:{preferences.overrides[chat.conversationKey] ?? ""},set:{preferences.setOverride($0,for:chat.conversationKey)})).font(.system(size:13)).frame(height:140)
            }
            Text(preferences.overrides[chat.conversationKey] == nil ? "Действуют общие правила (наследование)" : "Действует переопределение чата вместо общих правил").foregroundColor(accent)
            ScrollView { Text(chat.effectiveRules.isEmpty ? "Дополнительные правила не заданы" : chat.effectiveRules).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }.frame(height:90)
            Text("Изменения применяются со следующего запроса. Для начатого Codex/Claude-разговора создаётся отдельный контекст с доступной историей, чтобы прежние правила не остались активными. Внешние действия не откатываются. Обязательные правила провайдера сохраняются.").font(.caption).foregroundColor(.secondary)
            HStack { Spacer();Button("Готово"){dismiss()} }
        }.padding(20).frame(width:600)
    }
}
struct EditMessageView:View {
    @ObservedObject var chat:Chat
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Изменить сообщение и продолжить").font(.headline)
            TextEditor(text:$chat.editingText).frame(minHeight:160)
            ForEach(chat.editingImages,id:\.self) { path in HStack { Text((path as NSString).lastPathComponent);Spacer();Button("Убрать"){chat.editingImages.removeAll{$0 == path}} } }
            Text("Последующее продолжение будет исключено из нового контекста и сохранено отдельной веткой. Уже выполненные команды и внешние действия не отменяются и сами не повторяются. Очередь сохранится для восстановления, но не уйдёт в новую ветку.").font(.caption).foregroundColor(.secondary)
            if chat.busy || chat.nativeCLIIsRunning || chat.team.running { Text("Сначала останови генерацию и дождись завершения.").foregroundColor(.orange);Button("Остановить"){chat.interrupt();chat.team.cancel()} }
            HStack { Button("Отмена"){chat.editingItem=nil};Spacer();Button("Сохранить старую ветку и продолжить"){chat.editAndContinue()}.disabled(chat.busy || chat.nativeCLIIsRunning || chat.team.running || (chat.editingText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && chat.editingImages.isEmpty)) }
        }.padding(20).frame(width:600)
    }
}
