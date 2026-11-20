fn main() {
    // На macOS голос работает через нативный помощник: собираем его до tauri_build, который проверяет ресурсы.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rerun-if-changed=macos/voice.swift");
        let target = if std::env::var("CARGO_CFG_TARGET_ARCH").as_deref() == Ok("x86_64") { "x86_64-apple-macos11" } else { "arm64-apple-macos11" };
        let status = std::process::Command::new("xcrun")
            .args(["swiftc", "-O", "-target", target, "macos/voice.swift", "-o", "macos/pult-voice"])
            .status().expect("xcrun swiftc недоступен");
        assert!(status.success(), "Не удалось собрать macos/voice.swift");
    }
    tauri_build::build()
}
