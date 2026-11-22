// Голос Пульта на macOS: тот же протокол, что у voice.ps1 на Windows.
// stdin: {"action":"listen"|"speak","language":"ru-RU","text":"…"} → stdout: {"text":"…"} или {"ok":true}.
// Разрешения на микрофон и распознавание macOS спрашивает от имени Пульта (ключи в Info.plist).
import AVFoundation
import Foundation
import Speech

func reply(_ value: [String: Any]) -> Never {
    let data = try! JSONSerialization.data(withJSONObject: value)
    FileHandle.standardOutput.write(data)
    exit(0)
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(message.data(using: .utf8)!)
    exit(1)
}

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let request = try? JSONSerialization.jsonObject(with: input) as? [String: Any], let action = request["action"] as? String else { fail("bad request") }
let language = request["language"] as? String ?? "ru-RU"
let selectedVoice = request["voice"] as? String ?? ""

final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    let synth = AVSpeechSynthesizer()
    func speak(_ text: String) {
        synth.delegate = self
        let utterance = AVSpeechUtterance(string: text)
        if !selectedVoice.isEmpty {
            guard let voice = AVSpeechSynthesisVoice(identifier: selectedVoice) else { fail("voice unavailable") }
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        synth.speak(utterance)
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { reply(["ok": true]) }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { reply(["ok": true]) }
}

final class Listener {
    let engine = AVAudioEngine()
    let request = SFSpeechAudioBufferRecognitionRequest()
    var task: SFSpeechRecognitionTask?
    var text = ""
    var silence: Timer?

    func start() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)), recognizer.isAvailable else { fail("recognizer unavailable") }
        request.shouldReportPartialResults = true
        let node = engine.inputNode
        node.installTap(onBus: 0, bufferSize: 1024, format: node.outputFormat(forBus: 0)) { [request] buffer, _ in request.append(buffer) }
        engine.prepare()
        do { try engine.start() } catch { fail("microphone unavailable") }
        task = recognizer.recognitionTask(with: request) { result, error in
            if let result = result {
                self.text = result.bestTranscription.formattedString
                // Пауза в 1,8 секунды после речи — фраза закончена.
                self.silence?.invalidate()
                self.silence = Timer.scheduledTimer(withTimeInterval: 1.8, repeats: false) { _ in self.finish() }
                if result.isFinal { self.finish() }
            } else if error != nil { self.finish() }
        }
        Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { _ in self.finish() }
    }
    func finish() {
        engine.stop(); engine.inputNode.removeTap(onBus: 0); request.endAudio(); task?.cancel()
        reply(["text": text])
    }
}

let speaker = Speaker()
let listener = Listener()
switch action {
case "voices":
    reply(["voices": AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }.map { ["id": $0.identifier, "name": $0.name, "language": $0.language] }])
case "speak":
    speaker.speak(request["text"] as? String ?? "")
case "listen":
    SFSpeechRecognizer.requestAuthorization { status in
        guard status == .authorized else { fail("speech recognition not allowed") }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            guard granted else { fail("microphone not allowed") }
            DispatchQueue.main.async { listener.start() }
        }
    }
default:
    fail("unknown action")
}
RunLoop.main.run()
