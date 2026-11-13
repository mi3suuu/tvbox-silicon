import SwiftUI
import TVCore

#if !os(tvOS)
/// Playback on iPhone and iPad: the player's gestures, danmaku and picture, each note under the group it explains.
struct PlaybackSettingsView: View {
    @Environment(Store.self) private var store
    @AppStorage(DanmakuPreference.key) private var showsDanmaku = true
    @AppStorage(DanmakuArea.key) private var danmakuArea = DanmakuArea.standard
    @AppStorage(SpeedBoost.key) private var holdSpeed = SpeedBoost.standard
    /// 广告库里已学的条数，用于入口右侧的状态文字。
    @State private var adSkipCount = 0
    private var adSkipSummary: String? {
        adSkipCount == 0 ? nil : String(adSkipCount)
    }
    @AppStorage(PictureLevel.key) private var slidesLevels = true
    /// 双击左右跳过 10 秒；关掉后双击改为播放/暂停（上游 1.8.12 的开关）。
    @AppStorage(PictureDoubleTap.key) private var doubleTapSkips = true
    @AppStorage(VideoEnhancement.upscaleKey) private var upscalesVideo = false
    @AppStorage(VideoEnhancement.smoothKey) private var smoothsVideo = false
    @AppStorage(PlaybackInfo.key) private var showsPlaybackInfo = false
    /// One 观看页背景的高斯模糊半径（点）。0 = 关。
    ///
    /// 默认 40 是按输出反推的：Frida 实测 One 的背景层是
    /// `CALayer.filters = [CAFilter(name:"gaussianBlur")]`，但 inputRadius
    /// 在私有 C++ 结构里取不到；把两边截图缩到同尺度比边缘能量，
    /// One=3.41 / 我们未模糊=22.95，radius=40 得 3.49 且亮度同时命中。
    @AppStorage(OneWatchPage.Backdrop.blurRadiusKey)
    private var backdropBlur = OneWatchPage.Backdrop.defaultBlurRadius

    /// 三态开关的**响应式**真源。
    ///
    /// ⛔ 不能只用 `PlaySkin.current`（纯计算属性读 UserDefaults）当 `Picker` 的 selection：
    /// 它不参与 SwiftUI 的状态管理，`applySkin` 写完 `UserDefaults` 后**视图不会重算**，
    /// 于是「点了没勾选态 / 没有回馈 / 选了 One 界面不变、再选回来也不变」。
    /// 用户报的正是这三条。
    /// `@AppStorage` 让写入触发重绘；`PlaySkin.current` 仍保留作首次迁移的兜底。
    // ⛔ 默认值**不能**是空串（与 `VideoDetailView.playSkinRaw` 同一铁律）。
    //
    // `@AppStorage` 在键缺失时会把默认值**写回** UserDefaults。若默认写 `""`：
    //   属性初始化 → 写入空串 → `activeSkin` 回退到 `.current`
    //   → Picker 立刻把回退值落盘 → 用户之前选的 One 被覆盖成 native/bilibili。
    // 真机现象正是「选 One 不生效、杀进程重进还是哔哩哔哩」。
    // 默认值取迁移结果即无覆盖窗口。
    @AppStorage(PlaySkin.key) private var skinRaw: String = PlaySkin.current.rawValue
    /// 声音分配档位的响应式真源。`DockAudioPolicy.current` 同属计算属性，
    /// 直接当 selection 会「选了不刷新、没有勾选态」（与皮肤选择同一个坑）。
    /// 同 `skinRaw`：默认值不能是空串，否则键缺失时会把空串写回去覆盖用户选择。
    @AppStorage(DockAudioPolicy.key) private var dockAudioRaw: String = DockAudioPolicy.current.rawValue

    /// 本视图当前生效的皮肤（含「从未存过 → 按旧布尔迁移」）。
    private var activeSkin: PlaySkin {
        if let s = PlaySkin(rawValue: skinRaw), !skinRaw.isEmpty { return s }
        return PlaySkin.current
    }

    /// 当前声音档位（空串 → 回退到 `current` 的默认）。
    private var activeDockAudio: DockAudioPolicy {
        DockAudioPolicy(rawValue: dockAudioRaw) ?? DockAudioPolicy.current
    }

    /// 写三态开关，并把旧的那一个布尔同步过去。
    ///
    /// 为什么要同步：`VideoDetailView.oneSkinActive` 仍然读 `oneSkinEnabled`
    ///（它同时被 QA 启动参数和 One 的偏好面板写）。两边不同步时会出现
    ///「设置里选了 One，播放页还是原版」这种自相矛盾。让这里成为旧键的唯一写入点，
    /// 判据就只有一份。
    private func applySkin(_ skin: PlaySkin) {
        UserDefaults.standard.set(skin.rawValue, forKey: PlaySkin.key)
        UserDefaults.standard.set(skin == .one, forKey: OneSkin.enabledKey)
    }
    var body: some View {
        SettingsPage(title: L10n.text("Playback"), symbol: "slider.horizontal.below.rectangle") {
            #if os(iOS)
            SettingsGroup(footer: L10n.text("Choose which buttons sit in the player and which are tucked into the More menu.")) {
                SettingsLinkRow(symbol: "slider.horizontal.3", tint: .indigo, title: L10n.text("Player Controls"),
                                subtitle: L10n.text("Drag to arrange the player's buttons.")) { PlayerControlsSettingsView() }
            }
            #endif
            // [mi3s] 二开：观看页外观（三态）。
            //
            // 原来只有一个「One 风格」布尔。现在要能选「我们自己的风格 / One / 哔哩哔哩」，
            // 所以换成三选一；写进 `playSkin`，旧布尔只作为首次迁移的来源，
            // 选过之后两者不再互相覆盖（One 分支仍然读 `oneSkinEnabled`，值由这里同步写入）。
            SettingsGroup(title: "观看页外观",
                          footer: "三选一。原版是上游原样；One 是黑底、控制条压在画面上、选集横排；哔哩哔哩是半屏卡片、选集抽屉、全屏右侧设置面板。功能不变，只换外观。") {
                Picker(selection: Binding(
                    get: { activeSkin },
                    set: { newSkin in
                        skinRaw = newSkin.rawValue   // 先写 @AppStorage → 触发重绘
                        applySkin(newSkin)           // 再同步旧布尔键
                    }
                )) {
                    ForEach(PlaySkin.allCases) { skin in
                        Label(skin.title, systemImage: skin.symbol).tag(skin)
                    }
                } label: {
                    FormLabel(symbol: "paintbrush.fill", tint: .purple, title: "播放页风格")
                }
                .pickerStyle(.inline)
                ForEach(PlaySkin.allCases) { skin in
                    if activeSkin == skin {
                        Text(skin.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // One 观看页背景模糊半径。
            // 只在选 One 皮肤时有意义，所以条件显示；但值始终保留（切回 One 时不丢）。
            if activeSkin == .one {
                SettingsGroup(title: "背景模糊",
                              footer: "One 观看页的背景虚化强度。实测 One 用的是 gaussianBlur 滤镜；"
                                    + "默认 40 是按两边截图边缘能量反推出来的（One 3.41 / 我们半径 40 时 3.49）。"
                                    + "0 = 关闭虚化（背景变成 48px 硬放大）。") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            FormLabel(symbol: "drop.halffull", tint: .teal, title: "模糊半径")
                            Spacer()
                            Text(backdropBlur == 0 ? "关" : "\(Int(backdropBlur)) pt")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $backdropBlur,
                               in: OneWatchPage.Backdrop.blurRadiusRange,
                               step: OneWatchPage.Backdrop.blurRadiusStep)
                            .accessibilityLabel("背景模糊半径")
                            .accessibilityValue("\(Int(backdropBlur)) 点")
                        HStack {
                            Text("清晰").font(.caption2).foregroundStyle(.tertiary)
                            Spacer()
                            Text("最糊").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            // 广告跳过：库管理单独一页（它跨作品），入口放这里。
            // `AdSkipSettingsView` 是 iOS-only（整文件 `#if os(iOS)`）：macOS / tvOS 的
            // 广告识别走不到这里，入口也就不该出现，否则编译器找不到类型。
            #if os(iOS)
            SettingsGroup {
                FormLink(symbol: "megaphone.slash.fill", tint: .pink,
                         title: L10n.text("Ad Skipping"),
                         value: adSkipSummary) { AdSkipSettingsView() }
            }
            #endif
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
            // 上游 1.8.12 `972a75a` 的开关。融合时整条链被吃掉：
            // 定义（`PictureDoubleTap`）在，行为门与这个 Toggle 都没了，
            // 用户失去「把双击改成播放/暂停」的能力，且没有任何入口能看出曾经有过。
            SettingsGroup(footer: L10n.text("Double-tap the left or right of the video to skip 10 seconds. Turn this off and a double tap plays or pauses instead.")) {
                Toggle(isOn: $doubleTapSkips) {
                    FormLabel(symbol: "goforward.10", tint: .green, title: L10n.text("Double-Tap to Skip"))
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
            #if os(iOS)
            // 坞里多个迷你播放器时声音怎么分（用户 2026-11-12：「这些都做成设置里可选」）。
            //
            // 三档都实现了，说明文字必须写清 `.mixed` 的边界：`AVPlayer.volume` 是
            // 播放器级音量，多路能否真的同时输出取决于系统，**需真机确认**。
            // 不在这里假装「一定能」，否则用户开了没效果会以为开关坏了。
            SettingsGroup(title: "多任务同时播放的声音",
                          footer: "坞里同时挂着多个迷你播放器时，声音怎么分配。这一档是**全局默认**；某一张卡片上单独设过声音的，以卡片上的为准（卡片左上角的喇叭键）。") {
                Picker(selection: Binding(
                    get: { activeDockAudio },
                    set: { dockAudioRaw = $0.rawValue }
                )) {
                    Text("全部静音（画面照常播）").tag(DockAudioPolicy.silent)
                    Text("只有当前播放的出声").tag(DockAudioPolicy.focused)
                    Text("其余降到 15% 作背景").tag(DockAudioPolicy.dimmed)
                    Text("全部出声（音量按路数均分）").tag(DockAudioPolicy.mixed)
                } label: {
                    FormLabel(symbol: "speaker.wave.2.bubble", tint: .orange, title: "声音分配")
                }
                .pickerStyle(.inline)
            }
            #endif
        }
            .task { adSkipCount = await AdSignatureLibrary.shared.count() }
    }
}
#endif
