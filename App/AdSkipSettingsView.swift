import SwiftUI
import TVCore

#if os(iOS)
/// 设置 → 播放 → 广告跳过。
///
/// 这个页面只管**库**，不管「本集有哪些广告段」——后者在播放页里标注，
/// 存在 `EpisodeSkipSettings.ads`（跟着作品走）。库是跨作品的，所以单独一页。
struct AdSkipSettingsView: View {
    @AppStorage("player.skipAds") private var skipsAds = true

    @State private var ads: [AdSignature] = []
    @State private var learned: [AdAutoLearn.Learned] = []
    @State private var busy = false
    @State private var message: String?
    @State private var confirmingClear = false
    @State private var importing = false

    var body: some View {
        SettingsPage(title: L10n.text("Ad Skipping"), symbol: "megaphone.slash.fill") {
            SettingsGroup(footer: L10n.text("Ads are recognised by what they look like, not where they sit, so a marked ad is skipped in every video afterwards.")) {
                Toggle(isOn: $skipsAds) {
                    FormLabel(symbol: "forward.fill", tint: .pink,
                              title: L10n.text("Skip Ads Automatically"))
                }
                .settingsSwitch()
            }

            SettingsGroup(footer: L10n.text("Mark an ad while watching, then it plays no more. Marked ads are shared across your devices.")) {
                HStack {
                    FormLabel(symbol: "megaphone.fill", tint: .orange,
                              title: L10n.text("Learned Ads"),
                              subtitle: ads.isEmpty
                                ? L10n.text("None yet. Use “Mark Ad” while watching.")
                                : L10n.text("%d ads, about %@ in total", ads.count, totalLength))
                    Spacer()
                }
            }

            if !ads.isEmpty {
                SettingsGroup {
                    ForEach(ads) { ad in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ad.title.isEmpty ? L10n.text("Ad %@", shortID(ad)) : ad.title)
                                    .font(.subheadline)
                                // 显示算法**实际找到**的区间长度与采样数。
                                // 用户需要这个来确认「多长剪多长」有没有生效 ——
                                // 如果每次都恰好 30 秒，说明自适应没起作用。
                                Text(L10n.text("%@ · %d frames · covers %@",
                                               durationText(ad.duration),
                                               ad.hashes.count,
                                               durationText(ad.span)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                Task { await remove(ad) }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                // 自动学到的「站点固定开头」。
                //
                // 与上面的「广告库」分开两栏，因为两者语义不同：
                // 上面是「某支广告」的指纹，跨站点通用、用户手动标的；
                // 这里是「某个站点每条视频开头都一样的那段」，只对该站点有效、自动学的。
                // 混在一栏会让用户以为可以导出通用。
                if !learned.isEmpty {
                    SettingsGroup(footer: L10n.text("Learned automatically from videos you have played on the same source. Only applies to that source.")) {
                        ForEach(learned) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.sourceKey).font(.subheadline)
                                    Text(L10n.text("%@ · from %d videos", durationText(item.span), item.sampleCount))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    Task { await forgetLearned(item) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                }

                SettingsGroup(footer: L10n.text("The file holds only picture fingerprints — no video, no audio.")) {
                    Button {
                        Task { await exportFile() }
                    } label: {
                        FormLabel(symbol: "square.and.arrow.up", tint: .blue,
                                  title: L10n.text("Export Fingerprints"))
                    }
                    Button {
                        importing = true
                    } label: {
                        FormLabel(symbol: "square.and.arrow.down", tint: .green,
                                  title: L10n.text("Import Fingerprints"))
                    }
                    Button(role: .destructive) {
                        confirmingClear = true
                    } label: {
                        FormLabel(symbol: "trash.fill", tint: .red,
                                  title: L10n.text("Clear All Ads"))
                    }
                }
            }

            if let message {
                SettingsGroup { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .task { await reload() }
        .confirmationDialog(L10n.text("Clear all ads?"), isPresented: $confirmingClear, titleVisibility: .visible) {
            Button(L10n.text("Clear All Ads"), role: .destructive) {
                Task {
                    await AdSignatureLibrary.shared.removeAll()
                    await reload()
                    message = L10n.text("Cleared.")
                }
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            Task { await importFile(result) }
        }
    }

    // MARK: - 数据

    private var totalLength: String {
        durationText(ads.reduce(0) { $0 + $1.duration })
    }

    private func durationText(_ seconds: Double) -> String {
        EpisodeSkipSettings.formatTime(seconds)
    }

    private func shortID(_ ad: AdSignature) -> String {
        String(ad.id.uuidString.prefix(6))
    }

    private func reload() async {
        ads = await AdSignatureLibrary.shared.all().sorted { $0.createdAt > $1.createdAt }
        learned = await AutoLearnStore.shared.allLearned()
            .filter(\.isUsable)
            .sorted { $0.learnedAt > $1.learnedAt }
    }

    private func forgetLearned(_ item: AdAutoLearn.Learned) async {
        await AutoLearnStore.shared.forget(sourceKey: item.sourceKey)
        await reload()
    }

    private func remove(_ ad: AdSignature) async {
        await AdSignatureLibrary.shared.remove(id: ad.id)
        await reload()
    }

    private func exportFile() async {
        busy = true
        defer { busy = false }
        let data = await AdSignatureLibrary.shared.exportData()
        // 写到临时目录再交给分享面板：库文件在 Application Support，
        // 不应该让外部直接读那个位置（也避免导入时覆盖正在用的库）。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ad-fingerprints.json")
        do {
            try data.write(to: url, options: .atomic)
            // 复用下载页那套分享面板：它会先复制到临时目录再交给系统，
            // 用户存到文件 App / 隔空投送都行，不会动到我们正在用的库。
            DownloadSharing.share(url, named: "ad-fingerprints.json")
        } catch {
            message = L10n.text("Could not write the file.")
        }
    }

    private func importFile(_ result: Result<[URL], Error>) async {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let got = url.startAccessingSecurityScopedResource()
        defer { if got { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(AdSignatureLibrary.Snapshot.self, from: data) else {
            message = L10n.text("That file is not an ad fingerprint export.")
            return
        }
        let added = await AdSignatureLibrary.shared.merge(snapshot)
        await reload()
        message = L10n.text("Imported %d new ads.", added)
    }
}

#endif
