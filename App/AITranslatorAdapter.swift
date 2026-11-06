// [mi3s] 二开：AI 字幕翻译接入重封装器的翻译缝（SubtitleTranslating）。
//
// 原本长在 App/SubtitleTranslator.swift（上游文件）里，按「每条二开能力独立成文件」搬到此处。
// 搬的边界干净：
//   - SubtitleTranslating  在 Sources/TVCore/SubtitleTranslation.swift（上游），本模块可见
//   - SubtitleTranslator.Configuration / SubtitleTranslationSetup 也是上游公开类型
// 所以这两个类型不需要连带搬迁任何东西。
//
// 与 Apple Translation 的关系：两者不是竞品，失败点相反 —— Apple 的免费离线但语种有限，
// AI 的语种全但需要网络与配额。重封装器只认 `SubtitleTranslating`，两边都能接。

import Foundation
import TVCore

struct AITranslatorAdapter: SubtitleTranslating {
    let configuration: SubtitleTranslator.Configuration
    let target: Locale.Language

    init(configuration: SubtitleTranslator.Configuration) {
        self.configuration = configuration
        // The protocol asks for the language in the app's own term; the configuration already
        // holds the BCP-47 string the service expects.
        self.target = Locale.Language(identifier: configuration.targetLanguage)
    }

    func supports(_ source: Locale.Language) async -> Bool {
        // Anything but the target itself is worth offering.
        source.languageCode != target.languageCode
    }

    func translate(_ lines: [String], from source: Locale.Language) async throws -> [String] {
        // Build a track from the lines so the batching and the count check are the ones already
        // written, then read the text back out in the same order.
        let cues = lines.enumerated().map { index, text in
            SubtitleTrack.Cue(start: Int64(index) * 1_000_000,
                              end: Int64(index + 1) * 1_000_000,
                              text: text)
        }
        let track = SubtitleTrack(name: "lines", language: source.minimalIdentifier, cues: cues)
        let translated = try await SubtitleTranslator().translate(track, configuration: configuration)
        return translated.cues.map(\.text)
    }
}

extension SubtitleTranslationSetup {
    /// Prefers a configured AI service over the device's translation, when the viewer has filled one
    /// in. Falls back to whatever `install()` already set, so an unconfigured app behaves as before.
    ///
    /// Called after `install()`: the AI configuration, when present, replaces the device translator.
    @MainActor
    static func installAI(configuration: SubtitleTranslator.Configuration?) {
        guard let configuration, configuration.isComplete else { return }
        SubtitleTranslation.translator = AITranslatorAdapter(configuration: configuration)
    }
}
