//
//  AssWriter.swift
//  把弹幕列表写成 ASS 字幕 —— 给夸克网盘 / IINA / 任何支持外挂字幕的播放器用
//

import Foundation

struct AssStyle {
    var sizePercent: Double = 100      // 字号百分比（相对基准）
    var opacityPercent: Double = 100   // 不透明度，100 = 完全不透明
    var speedPercent: Double = 100     // 滚动速度，100 = 标准
    var areaPercent: Double = 85       // 弹幕占画面高度的比例
    var blockWords: [String] = []      // 屏蔽词
}

enum AssWriter {

    /// 生成完整 ASS 文本
    /// - Parameters:
    ///   - items: 弹幕
    ///   - width/height: 视频分辨率（必填，位置全按这个算；不知道就用 1920×1080）
    ///   - style: 样式
    static func build(_ items: [Danmaku], width: Int, height: Int, style: AssStyle = AssStyle()) -> String {
        let w = Double(max(320, width))
        let h = Double(max(240, height))

        // 字号：1080p 用 40，按高度等比放大，再乘用户百分比
        let base = max(18.0, h / 27.0)
        let fontSize = max(12.0, base * style.sizePercent / 100.0)

        // 透明度：ASS 的 &HAA 里 AA=00 不透明、FF 全透明
        let alphaHex = String(format: "%02X", Int((100.0 - style.opacityPercent) / 100.0 * 255.0))

        // 滚动可用高度 + 轨道数
        let areaH = h * max(0.2, min(1.0, style.areaPercent / 100.0))
        let lineH = fontSize * 1.35
        let lanes = max(1, Int(areaH / lineH) - 1)

        // 统一线速度：一条和屏幕一样宽的弹幕用 8 秒走完（再按用户倍率缩放）
        let baseStay = 8.0 / max(0.2, style.speedPercent / 100.0)
        let speedPx = w / baseStay

        let blocked = style.blockWords.filter { !$0.isEmpty }

        // 轨道占用表：滚动 / 顶部 / 底部 分开
        var freeScroll = [Double](repeating: -1e9, count: lanes)
        let topLanes = max(1, lanes / 3), bottomLanes = max(1, lanes / 3)
        var freeTopLanes = [Double](repeating: -1e9, count: topLanes)
        var freeBottomLanes = [Double](repeating: -1e9, count: bottomLanes)

        var events: [String] = []
        events.reserveCapacity(items.count)

        let sorted = items.sorted { $0.time < $1.time }

        for d in sorted {
            let text = d.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if blocked.contains(where: { text.contains($0) }) { continue }

            let t = max(0.0, d.time)
            let tw = measure(text, fontSize: fontSize)
            let color = bgrTag(d.color)

            switch d.mode {
            case 4, 5:                                   // 顶部 / 底部
                let isTop = (d.mode == 5)
                var list = isTop ? freeTopLanes : freeBottomLanes
                let stay = 4.0
                var slot = -1
                for i in 0..<list.count where list[i] <= t {
                    slot = i
                    break
                }
                if slot < 0 {
                    // 全占满就找最早空出来的
                    slot = (0..<list.count).min(by: { list[$0] < list[$1] }) ?? 0
                    if list[slot] > t { continue }       // 实在挤不下就丢
                }
                list[slot] = t + stay + 0.15
                if isTop { freeTopLanes = list } else { freeBottomLanes = list }

                let y: Double = isTop
                    ? lineH * Double(slot) + lineH
                    : h - lineH * Double(slot) - lineH * 1.6
                let pos = String(format: "\\an%d\\pos(%.0f,%.0f)", isTop ? 8 : 2, w / 2, y)
                events.append(dialogue(t, t + stay, "{\\\(pos)\(color)}\(esc(text))"))

            default:                                     // 滚动
                let stay = (w + tw) / speedPx
                var slot = -1
                for i in 0..<lanes where freeScroll[i] <= t {
                    slot = i
                    break
                }
                if slot < 0 { continue }                 // 轨道满了就丢，跟 B站一样
                // 同轨道下一条要等前一条的尾巴完全进屏，避免追尾
                freeScroll[slot] = t + (tw + fontSize * 2) / speedPx

                let y = lineH * Double(slot) + lineH * 1.2
                let mv = String(format: "\\an7\\move(%.0f,%.0f,%.0f,%.0f)", w, y, -tw, y)
                events.append(dialogue(t, t + stay, "{\\(mv)\(color)}\(esc(text))"))
            }
        }

        var out = """
        [Script Info]
        ; 由 弹幕助手 for iPad 生成
        ScriptType: v4.00+
        PlayResX: \(Int(w))
        PlayResY: \(Int(h))
        WrapStyle: 2
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: DM,PingFang SC,\(Int(fontSize)),&H\(alphaHex)FFFFFF,&H\(alphaHex)FFFFFF,&H\(alphaHex)000000,&H\(alphaHex)000000,0,0,0,0,100,100,0,0,1,2,1,7,0,0,0,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        out += events.joined(separator: "\n")
        out += "\n"
        return out
    }

    // MARK: - 工具

    /// ASS 时间：0:00:01.23
    static func ts(_ t: Double) -> String {
        let v = max(0, t)
        let total = Int((v * 100).rounded())
        let cs = total % 100
        let s = (total / 100) % 60
        let m = (total / 6000) % 60
        let hr = total / 360000
        return String(format: "%d:%02d:%02d.%02d", hr, m, s, cs)
    }

    static func dialogue(_ start: Double, _ end: Double, _ text: String) -> String {
        "Dialogue: 0,\(ts(start)),\(ts(end)),DM,,0,0,0,,\(text)"
    }

    /// 颜色：ASS 用 &HBBGGRR&
    static func bgrTag(_ rgb: UInt32) -> String {
        let r = (rgb >> 16) & 0xFF
        let g = (rgb >> 8) & 0xFF
        let b = rgb & 0xFF
        if r == 0xFF && g == 0xFF && b == 0xFF { return "" }   // 白色是默认，不加标签
        return String(format: "\\c&H%02X%02X%02X&", b, g, r)
    }

    /// ASS 里 { } \ 要转义
    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "＼")
         .replacingOccurrences(of: "{", with: "｛")
         .replacingOccurrences(of: "}", with: "｝")
         .replacingOccurrences(of: "\n", with: " ")
    }

    /// 估宽：中文 1em，ASCII 0.55em
    static func measure(_ s: String, fontSize: Double) -> Double {
        var w = 0.0
        for u in s.unicodeScalars {
            w += (u.value < 0x2E80) ? fontSize * 0.55 : fontSize
        }
        return max(1.0, w)
    }
}
