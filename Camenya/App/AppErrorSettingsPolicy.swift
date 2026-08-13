import Foundation

enum AppErrorSettingsPolicy {
    static func allowsOpeningSettings(for message: String?) -> Bool {
        guard let message else { return false }
        return message == "Camera and microphone access are required before recording."
            || message == "Camera access is required."
            || message == "Speech Recognition access is required to create captions."
            || message == "Speech Recognition is restricted on this device."
            || message.contains("couldn't add it to Photos")
    }
}
