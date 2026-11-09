import SwiftUI
import TVCore

#if !os(tvOS)
/// Playback on iPhone and iPad: the player's gestures, danmaku and picture, each note under the group it explains.
struct PlaybackSettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @AppStorage(SpeedBoost.key) private var holdSpeed = SpeedBoost.standard
    @AppStorage(PictureLevel.key) private var slidesLevels = true
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    var body: some View {
        SettingsPage(title: L10n.text("Playback"), symbol: "slider.horizontal.below.rectangle") {
            #if os(iOS)
            SettingsGroup(footer: L10n.text("Choose which buttons sit in the player and which are tucked into the More menu.")) {
                SettingsLinkRow(symbol: "slider.horizontal.3", tint: .indigo, title: L10n.text("Player Controls"),
                                subtitle: L10n.text("Drag to arrange the player's buttons.")) { PlayerControlsSettingsView() }
            }
            #endif
            // [mi3s] 二开：One 观看页外观。开关存 UserDefaults（`OneSkin.enabledKey`），
            // 播放页据此在「One 版式」与「原版式」之间切换；关掉即完全回到上游原样。
            SettingsGroup(title: "观看页外观",
                          footer: "开启后播放页换成 One 的版式：黑底、控制条在画面上、选集横排。功能不变，只换外观。") {
                Toggle(isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: OneSkin.enabledKey) },
                    set: { UserDefaults.standard.set($0, forKey: OneSkin.enabledKey) }
                )) {
                    FormLabel(symbol: "paintbrush.fill", tint: .purple, title: "One 风格播放页")
                }
                .settingsSwitch()
            }
            SettingsGroup(footer: L10n.text("Touch and hold the video to play at this speed. Slide sideways to change it, or slide down to keep it after you let go.")) {
                Picker(selection: $holdSpeed) {
                    ForEach(SpeedBoost.startRates, id: \.self) { Text($0.formatted(.number.precision(.fractionLength(0...2))) + "×").tag($0) }
                } label: {
                    FormLabel(symbol: "forward.fill", tint: .orange, title: L10n.text("Touch and Hold Speed"))
                }
            }
            SettingsGroup(footer: L10n.text("Slide up or down on the left of the video to change the brightness, or on the right to change the volume.")) {
                Toggle(isOn: $slidesLevels) {
                    FormLabel(symbol: "sun.max.fill", tint: .yellow, title: L10n.text("Slide for Brightness and Volume"))
                }
                .settingsSwitch()
            }
            SettingsGroup(footer: SettingsNote.playbackInfo) {
                Toggle(isOn: $showsPlaybackInfo) {
                    FormLabel(symbol: "info.circle.fill", tint: .blue, title: L10n.text("Show Video Info"))
                }
                .settingsSwitch()
            }
            if store.extrasUnlocked {
                SettingsGroup(footer: SettingsNote.danmaku) {
                    Toggle(isOn: $showsDanmaku) {
                        FormLabel(symbol: "text.bubble.fill", tint: .teal, title: L10n.text("Show Danmaku"))
                    }
                    .settingsSwitch()
                    Picker(selection: $danmakuArea) {
                        ForEach(DanmakuArea.allCases, id: \.self) { Text($0.title).tag($0) }
                    } label: {
                        FormLabel(symbol: "rectangle.tophalf.inset.filled", tint: .teal, title: L10n.text("Danmaku Area"))
                    }
                }
            }
            if VideoEnhancement.canUpscale || VideoEnhancement.canSmooth {
                SettingsGroup(title: L10n.text("Picture"), footer: VideoEnhancement.note) {
                    if VideoEnhancement.canUpscale {
                        Toggle(isOn: $upscalesVideo) {
                            FormLabel(symbol: "wand.and.sparkles", tint: .purple, title: L10n.text("Sharper Picture"))
                        }
                        .settingsSwitch()
                    }
                    if VideoEnhancement.canSmooth {
                        Toggle(isOn: $smoothsVideo) {
                            FormLabel(symbol: "film.stack", tint: .indigo, title: L10n.text("Smooth Motion (60 fps)"))
                        }
                        .settingsSwitch()
                    }
                }
            }
        }
    }
}
#endif
