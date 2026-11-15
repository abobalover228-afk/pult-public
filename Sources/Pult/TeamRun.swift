import AppKit
import SwiftUI

struct TeamTask:Identifiable {let id=UUID();let title:String;var status:String;var result:String=""}
protocol TeamRequest:AnyObject {func start(prompt:String,instructions:String,completion:@escaping(Result<String,APIProblem>)->Void);func cancel()}
final class TeamTextRequest:TeamRequest {
    let home:String;let model:String;let api:APIConnection?;let vault:APIKeyVault
    var codex:CodexClient?;var http:CompatibleAPIClient?;var finished=false;var callback:((Result<String,APIProblem>)->Void)?;var text="";var timer:DispatchWorkItem?
    init(home:String,model:String,api:APIConnection?,vault:APIKeyVault){self.home=home;self.model=model;self.api=api;self.vault=vault}
    func complete(_ result:Result<String,APIProblem>){guard !finished else{return};finished=true;timer?.cancel();let cb=callback;callback=nil;codex?.stop();http=nil;cb?(result)}
    func start(prompt:String,instructions:String,completion:@escaping(Result<String,APIProblem>)->Void){
        callback=completion
        let timeout=DispatchWorkItem{[weak self] in self?.complete(.failure(APIProblem(message:"Исполнитель не ответил за 4 минуты.")))};timer=timeout;DispatchQueue.main.asyncAfter(deadline:.now()+240,execute:timeout)
        if let api {
            do {guard let key=try vault.read(api.id) else{throw APIProblem(message:"Нет API-ключа в Keychain")};let http=CompatibleAPIClient();self.http=http
                http.send(connection:api,key:key,messages:[["role":"system","content":instructions],["role":"user","content":prompt]]){[weak self] result in self?.complete(result.map{$0.text})}
            }catch{complete(.failure(error as? APIProblem ?? APIProblem(message:"Не удалось открыть API-ключ")))}
            return
        }
        let c=CodexClient(home:home,extraEnv:Proxy.shared.env);codex=c
        c.onServerRequest={[weak c] id,_,_ in c?.reject(id,"Исполнители только анализируют. Изменения и внешние действия запрещены.")}
        c.onExit={[weak self] in self?.complete(.failure(APIProblem(message:"Процесс исполнителя завершился.")))}
        c.onNotification={[weak self] method,p in
            guard let self,!self.finished else{return}
            if method == "item/agentMessage/delta" {self.text += p["delta"] as? String ?? ""}
            if method == "item/completed",let item=p["item"] as? JSON,item["type"] as? String == "agentMessage",let value=item["text"] as? String {self.text=value}
            if method == "turn/completed" {
                let turn=p["turn"] as? JSON ?? [:]
                if turn["error"] is JSON || self.text.isEmpty {self.complete(.failure(APIProblem(message:"Исполнитель завершил ход без результата.")))}else{self.complete(.success(self.text))}
            }
        }
        c.start{[weak self] ok in
            guard let self,!self.finished else{return};guard ok else{self.complete(.failure(APIProblem(message:"Не удалось запустить Codex")));return}
            c.call("thread/start",["cwd":NSTemporaryDirectory(),"model":self.model,"sandbox":"read-only","approvalPolicy":"on-request","ephemeral":true,"baseInstructions":instructions]){[weak self] response in
                guard let self,!self.finished else{return}
                guard let id=((response["result"] as? JSON)?["thread"] as? JSON)?["id"] as? String else{self.complete(.failure(APIProblem(message:"Не удалось создать отдельную сессию исполнителя")));return}
                c.call("turn/start",["threadId":id,"input":[["type":"text","text":prompt]],"serviceTier":"default"]){[weak self] r in if r["error"] != nil{self?.complete(.failure(APIProblem(message:"Провайдер отклонил запрос исполнителя")))}}
            }
        }
    }
    func cancel(){finished=true;callback=nil;timer?.cancel();codex?.stop();http?.cancel();codex=nil;http=nil}
}
final class TeamRun:ObservableObject {
    @Published private(set) var running=false
    @Published private(set) var tasks:[TeamTask]=[]
    @Published private(set) var result=""
    @Published private(set) var error:String?
    @Published var visible=false
    private var generation=UUID();private var requests:[TeamRequest]=[]
    private var completed=0;private var context="";private var original="";private var rules=""
    var contextID:UUID?
    var makeRequest:(()->TeamRequest)?
    private var activeFactory:(()->TeamRequest)?
    func start(prompt:String,chat:Chat){
        cancel();visible=true;running=true;result="";error=nil;completed=0;contextID=chat.queueContext
        original=prompt;context=PromptSnapshot.history(chat.items);rules=chat.effectiveRules
        let home=chat.account.home,model=chat.model,api=chat.selectedAPI,vault=chat.apiConnectionStore.vault
        activeFactory = makeRequest ?? {TeamTextRequest(home:home,model:model,api:api,vault:vault)}
        tasks=[TeamTask(title:"Главный: распределение",status:"Работает")]
        run(prompt:"Задача:\n\(prompt)\nИстория:\n\(context)\nРаздели задачу на две независимые аналитические подзадачи. Верни JSON {\"tasks\":[{\"title\":\"...\",\"prompt\":\"...\"},{\"title\":\"...\",\"prompt\":\"...\"}]}. Никаких команд и изменений."){[weak self] value in
            guard let self else{return}
            switch value {
            case .failure(let failure):self.tasks[0].status="Ошибка";self.error=failure.message;self.running=false
            case .success(let text):
                guard let data=text.data(using:.utf8),let json=(try? JSONSerialization.jsonObject(with:data)) as? JSON,let rows=json["tasks"] as? [JSON],rows.count == 2,rows.allSatisfy({($0["prompt"] as? String)?.isEmpty == false && ($0["title"] as? String)?.isEmpty == false}) else{self.tasks[0].status="Ошибка";self.error="Главный не вернул две подзадачи. Можно повторить запуск.";self.running=false;return}
                self.tasks[0].status="Готово";self.tasks[0].result=text
                self.tasks += rows.map{TeamTask(title:$0["title"] as! String,status:"Работает")}
                for (i,row) in rows.enumerated(){self.worker(i+1,prompt:row["prompt"] as! String)}
            }
        }
    }
    private func run(prompt:String,completion:@escaping(Result<String,APIProblem>)->Void){
        guard let activeFactory else{return};let req=activeFactory();requests.append(req);let token=generation
        req.start(prompt:prompt,instructions:"Ты участник ограниченной группы анализа. Только текстовые результаты: не выполняй команды, не читай файлы, не используй инструменты, не изменяй проект, не обращайся к другим агентам. Все данные для задачи переданы в сообщении. Применение любых изменений остаётся главному основному диалогу после отдельного решения пользователя. Правила пользователя:\n"+rules){[weak self] value in guard let self,self.generation == token,self.running else{return};completion(value)}
    }
    private func worker(_ index:Int,prompt:String){
        run(prompt:"Исходная задача:\n\(original)\nИстория:\n\(context)\nТвоя отдельная подзадача:\n\(prompt)"){[weak self] value in
            guard let self else{return}
            switch value{case .success(let text):self.tasks[index].status="Готово";self.tasks[index].result=text
            case .failure(let error):self.tasks[index].status="Ошибка";self.tasks[index].result=error.message}
            self.completed += 1
            if self.completed == 2{self.synthesize()}
        }
    }
    private func synthesize(){
        if tasks.dropFirst().allSatisfy({$0.status == "Ошибка"}){running=false;error="Оба исполнителя завершились с ошибкой. Частичные данные сохранены в панели.";return}
        tasks.append(TeamTask(title:"Главный: общий ответ",status:"Работает"))
        let summaries=tasks.dropFirst().dropLast().map{"\($0.title) [\($0.status)]\n\($0.result)"}.joined(separator:"\n\n")
        run(prompt:"Собери общий ответ на задачу:\n\(original)\nКонтекст:\n\(context)\nРезультаты независимых исполнителей:\n\(summaries)\nОтдели подтверждённое от предположений и укажи частичные сбои. Не утверждай, что изменения применены."){[weak self] value in
            guard let self else{return};self.running=false
            switch value{case .success(let text):self.result=text;self.tasks[self.tasks.count-1].status="Готово";self.tasks[self.tasks.count-1].result=text
            case .failure(let error):self.error=error.message;self.tasks[self.tasks.count-1].status="Ошибка"}
        }
    }
    func cancel(){generation=UUID();for req in requests{req.cancel()};requests=[];if running{for i in tasks.indices where tasks[i].status == "Работает"{tasks[i].status="Остановлено"}};running=false;activeFactory=nil}
}
struct TeamPanel:View {
    @ObservedObject var team:TeamRun
    @ObservedObject var chat:Chat
    var body:some View {
        VStack(alignment:.leading,spacing:10){
            HStack{Label("Группа GPT",systemImage:"person.3").font(.headline);Spacer();if team.running{Button("Остановить"){team.cancel()}};Button("Закрыть"){team.cancel();team.visible=false}}
            Text("Главный + 2 независимых исполнителя + сборка ответа: до 4 запросов. Только анализ; файлы не редактируются параллельно. Дополнительный расход лимитов.").font(.caption).foregroundColor(.secondary)
            ScrollView{VStack(alignment:.leading,spacing:10){ForEach(team.tasks){task in DisclosureGroup(task.title+" · "+task.status){Text(task.result).textSelection(.enabled)}};if !team.result.isEmpty{MarkdownView(text:team.result)};if let error=team.error{Text(error).foregroundColor(.orange)}}}
            if !team.result.isEmpty{Button("Добавить общий ответ в диалог") {guard !chat.busy,team.contextID == chat.queueContext else{return};chat.integrateTeamResult(team.result);team.visible=false}.disabled(chat.busy || team.contextID != chat.queueContext)}
        }.padding(16).frame(width:380)
    }
}
