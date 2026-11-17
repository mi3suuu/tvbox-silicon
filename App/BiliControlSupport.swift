import Foundation

// MARK: - Bili 三页接入统一控件表的桥

/// `PlayerControl` 与哔哩哔哩三页（竖屏 / 横屏 / 全屏）之间的对照。
///
/// ## 为什么需要这一层
///
/// 设置页那张 `PlayerControl` 表只被 **One 皮肤** 与 **原版播放器** 读取，
/// 哔哩哔哩三页的按钮是**硬编码**的（各自 5–7 颗，写在 `HStack` 里）。
/// 于是用户在设置页排好的顺序与显隐，切到 B 站皮肤**完全不生效** ——
/// 设置页文案也承认了这点（"The Bilibili skin keeps its own built-in arrangement"）。
///
/// 这一层把两边对上：给出「这一颗控件在 B 站皮里画什么图标、点击做什么」。
///
/// ## 哪些控件能映射，哪些不能
///
/// B 站皮只实现了一部分能力（例如它没有「音频轨道」「画质」的独立面板）。
/// **不能映射的返回 nil**，调用方就跳过它 —— 绝不画一颗点了没反应的按钮：
/// 那比"没有这颗按钮"更糟（用户会以为功能坏了）。
enum BiliControlSupport {

    /// 这一颗控件在 B 站皮里是否可画。
    static func isSupported(_ control: PlayerControl) -> Bool {
        symbol(for: control) != nil
    }

    /// 图标（SF Symbol）。`nil` = 这颗在 B 站皮里没有对应物。
    static func symbol(for control: PlayerControl) -> String? {
        switch control {
        case .airPlay:        return "airplayvideo"
        case .episodes:       return "list.bullet"
        case .miniPlayer:     return "pip"
        case .lock:           return "lock"
        case .danmaku:        return "text.bubble"
        case .speed:          return "gauge.with.dots.needle.67percent"
        case .quality:        return "4k.tv"
        case .subtitles:      return "captions.bubble"
        case .pictureSize:    return "aspectratio"
        case .videoInfo:      return "info.circle"
        case .anotherPlayer:  return "play.rectangle.on.rectangle"
        case .rotate:         return "rotate.right"
        // 播放类（B 站底栏自带，但也可以被摆到顶栏）
        case .playPause:      return "playpause"
        case .backTen:        return "gobackward.10"
        case .forwardTen:     return "goforward.10"
        case .previousEpisode: return "backward.end"
        case .nextEpisode:    return "forward.end"
        case .fullScreen:     return "arrow.up.left.and.arrow.down.right"
        // B 站皮没有对应面板的：不画。
        case .audio, .speechSubtitles, .markAd, .adBlock,
             .timecode, .progressBar, .remaining,
             .autoPlayNext, .moreInSeries, .skipIntroAuto, .skipIntroManual,
             .pictureInPicture:
            return nil
        }
    }

    /// 是否属于「B 站皮原本就画在底栏/画面中央」的那几颗。
    ///
    /// 这类即使被用户排进顶栏，B 站皮**也不会**再画第二遍 ——
    /// 它的版式里那些位置是固定的（还原 B 站布局的一部分）。
    static func isLayoutFixed(_ control: PlayerControl) -> Bool {
        switch control {
        case .playPause, .backTen, .forwardTen, .previousEpisode, .nextEpisode,
             .fullScreen, .progressBar, .timecode, .remaining:
            return true
        default:
            return false
        }
    }

    /// 从布局里取出「B 站皮顶栏应该画的那几颗」。
    ///
    /// 只取 `top`，并过滤掉不支持的与版式固定的；顺序就是用户在设置页排的顺序。
    static func topControls(from layout: PlayerControlsLayout) -> [PlayerControl] {
        layout.top.filter { isSupported($0) && !isLayoutFixed($0) }
    }

    /// 顶栏放不下时溢出的那些（与 One 皮同一套口径）。
    static func overflowControls(from layout: PlayerControlsLayout,
                                        capacity: Int) -> [PlayerControl] {
        Array(topControls(from: layout).dropFirst(max(0, capacity)))
    }
}
