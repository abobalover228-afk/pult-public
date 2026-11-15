// Голос: диктовка задачи в поле ввода, озвучка ответов и режим «без рук».
import AVFoundation
import Foundation
import Speech

final class Voice: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    static let shared = Voice()
    @Published var listening = false
    @Published var problem = ""
    @Published var speakReplies = UserDefaults.standard.bool(forKey: "voiceSpeak") { didSet { UserDefaults.standard.set(speakReplies, forKey: "voiceSpeak"); if !speakReplies { synth.stopSpeaking(at: .immediate) } } }
    @Published var handsFree = UserDefaults.standard.bool(forKey: "voiceHandsFree") { didSet { UserDefaults.standard.set(handsFree, forKey: "voiceHandsFree") } }
    @Published var language = UserDefaults.standard.string(forKey: "voiceLanguage") ?? "ru-RU" { didSet { UserDefaults.standard.set(language, forKey: "voiceLanguage") } }

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let synth = AVSpeechSynthesizer()
    private weak var chat: Chat?
    private var base = ""                       // что было в поле до начала записи
    private var silence: DispatchWorkItem?
    private var session = UUID()
    private var authorization = UUID()

    override init() { super.init(); synth.delegate = self }

    func toggle(_ chat: Chat) { if listening { stop() } else { start(chat) } }

    func start(_ chat: Chat) {
        problem = ""
        let authorization = UUID(); self.authorization = authorization
        synth.stopSpeaking(at: .immediate)
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard self?.authorization == authorization else { return }
                guard status == .authorized else { self?.problem = "Нет доступа к распознаванию речи: Системные настройки → Конфиденциальность → Распознавание речи → Пульт."; return }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    DispatchQueue.main.async {
                        guard self?.authorization == authorization else { return }
                        guard ok else { self?.problem = "Нет доступа к микрофону: Системные настройки → Конфиденциальность → Микрофон → Пульт."; return }
                        self?.begin(chat)
                    }
                }
            }
        }
    }

    private func begin(_ chat: Chat) {
        guard !listening else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else {
            problem = "Распознавание для этого языка сейчас недоступно."; return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request; self.chat = chat
        base = chat.ui.draft.isEmpty ? "" : chat.ui.draft + " "
        let run = UUID(); session = run
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { problem = "Микрофон не найден."; return }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); problem = "Не удалось включить микрофон: " + error.localizedDescription; return }
        listening = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self, self.session == run else { return }
                if let result = result {
                    self.chat?.ui.draft = self.base + result.bestTranscription.formattedString
                    self.armSilence(run)
                    if result.isFinal { self.finish(send: self.handsFree) }
                } else if error != nil, self.listening { self.finish(send: false) }
            }
        }
    }

    /// «Без рук»: пауза в полторы секунды после слов — значит, договорил.
    private func armSilence(_ run: UUID) {
        silence?.cancel()
        guard handsFree else { return }
        let work = DispatchWorkItem { [weak self] in if self?.session == run, self?.listening == true { self?.finish(send: true) } }
        silence = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func stop() { authorization = UUID(); finish(send: false) }

    private func finish(send: Bool) {
        guard listening else { return }
        listening = false; session = UUID(); silence?.cancel()
        engine.stop(); engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.cancel(); request = nil; task = nil
        guard send, let chat = chat else { return }
        let text = chat.ui.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chat.ui.draft = ""
        chat.send(text)
    }

    /// Озвучить ответ: без кода, таблиц и разметки, не длиннее минуты чтения.
    func speak(_ answer: String, for chat: Chat) {
        guard speakReplies, !answer.isEmpty else { return }
        self.chat = chat
        var text = answer.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (код в окне) ", options: .regularExpression)
        text = text.replacingOccurrences(of: "`([^`]*)`", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\|.*\\|$", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[*_#>|]", with: "", options: .regularExpression)
        if text.count > 900 { text = String(text.prefix(900)) + "… Остальное в окне." }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: language)
        utterance.rate = 0.52
        synth.stopSpeaking(at: .immediate)
        synth.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.handsFree, self.speakReplies, let chat = self.chat, !chat.busy, Workspace.shared.active === chat else { return }
            self.start(chat)
        }
    }
}
