//
//  DanmakuParser.swift
//  弹幕解析：B站 XML / JSON / ASS / 纯文本
//

import Foundation

struct Danmaku: Identifiable {
    let id = UUID()
    var time: Double
    var text: String
    var color: UInt32 = 0xFFFFFF
    var mode: Int = 1        // 1-3 滚动 / 4 底部 / 5 顶部
    var size: Double = 25
}

enum DanmakuParser {

    static func parse(url: URL) throws -> [Danmaku] {
        let data = try Data(contentsOf: url)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .unicode)
            ?? ""
        return parse(text: text, ext: url.pathExtension.lowercased())
    }

    static func parse(text: String, ext: String) -> [Danmaku] {
        var items: [Danmaku]
        switch ext {
        case "xml":            items = parseXML(text)
        case "ass", "ssa":     items = parseASS(text)
        case "json":           items = parseJSON(text)
        default:
            if text.contains("<d p=") {
                items = parseXML(text)
            } else if text.contains("Dialogue:") {
                items = parseASS(text)
            } else {
                let j = parseJSON(text)
                items = j.isEmpty ? parseTXT(text) : j
            }
        }
        return items.sorted { $0.time < $1.time }
    }

    // MARK: - B站 XML

    private static func parseXML(_ s: String) -> [Danmaku] {
        var out: [Danmaku] = []
        let re = try! NSRegularExpression(
            pattern: #"<d\s+p="([^"]*)"[^>]*>([\s\S]*?)</d>"#)
        let ns = s as NSString
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m = m, m.numberOfRanges >= 3 else { return }
            let p = ns.substring(with: m.range(at: 1)).components(separatedBy: ",")
            let txt = decodeEntities(ns.substring(with: m.range(at: 2)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !txt.isEmpty, let t = Double(p.first ?? "") else { return }
            var d = Danmaku(time: t, text: txt)
            if p.count > 1 { d.mode = Int(p[1]) ?? 1 }
            if p.count > 2 { d.size = Double(p[2]) ?? 25 }
            if p.count > 3 { d.color = UInt32(p[3]) ?? 0xFFFFFF }
            out.append(d)
        }
        return out
    }

    private static func decodeEntities(_ s: String) -> String {
        var r = s
        r = r.replacingOccurrences(of: "&lt;", with: "<")
        r = r.replacingOccurrences(of: "&gt;", with: ">")
        r = r.replacingOccurrences(of: "&quot;", with: "\"")
        r = r.replacingOccurrences(of: "&apos;", with: "'")
        r = r.replacingOccurrences(of: "&amp;", with: "&")
        return r
    }

    // MARK: - JSON

    private static func parseJSON(_ s: String) -> [Danmaku] {
        guard let data = s.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var arr: [[String: Any]] = []
        if let a = obj as? [[String: Any]] {
            arr = a
        } else if let d = obj as? [String: Any] {
            for k in ["danmaku", "items", "data", "list"] {
                if let a = d[k] as? [[String: Any]] { arr = a; break }
            }
        }
        guard !arr.isEmpty else { return [] }

        func rawT(_ d: [String: Any]) -> Double {
            (d["time"] as? Double) ?? (d["t"] as? Double)
                ?? Double(d["time"] as? Int ?? 0) ?? 0
        }
        let mx = arr.map(rawT).max() ?? 0
        let asMS = mx > 86400

        return arr.compactMap { d in
            var t = rawT(d)
            if asMS { t /= 1000 }
            let txt = ((d["text"] as? String) ?? (d["content"] as? String)
                       ?? (d["m"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !txt.isEmpty else { return nil }
            var x = Danmaku(time: max(0, t), text: txt)
            if let c = d["color"] as? UInt32 { x.color = c }
            else if let c = d["color"] as? Int { x.color = UInt32(c) }
            if let mo = d["mode"] as? Int { x.mode = mo }
            return x
        }
    }

    // MARK: - ASS

    private static func parseASS(_ s: String) -> [Danmaku] {
        var out: [Danmaku] = []
        for line in s.components(separatedBy: .newlines) {
            guard line.hasPrefix("Dialogue:") else { continue }
            let body = String(line.dropFirst("Dialogue:".count))
            let f = body.components(separatedBy: ",")
            guard f.count >= 10 else { continue }
            let t = assTime(f[1])
            var txt = f[9...].joined(separator: ",")
            txt = txt.replacingOccurrences(of: #"\{[^}]*\}"#,
                                           with: "", options: .regularExpression)
            txt = txt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !txt.isEmpty else { continue }
            var d = Danmaku(time: t, text: txt)
            let style = f[3].lowercased()
            if style.contains("top") { d.mode = 5 }
            else if style.contains("bottom") || style.contains("bot") { d.mode = 4 }
            if let r = body.range(of: #"\\c&H([0-9A-Fa-f]{6})&"#,
                                  options: .regularExpression) {
                let hex = String(body[r]).replacingOccurrences(
                    of: #"[^0-9A-Fa-f]"#, with: "", options: .regularExpression)
                if hex.count == 6 {
                    let bgr = Array(hex)
                    let rgb = String([bgr[4], bgr[5], bgr[2], bgr[3], bgr[0], bgr[1]])
                    d.color = UInt32(rgb, radix: 16) ?? 0xFFFFFF
                }
            }
            out.append(d)
        }
        return out
    }

    private static func assTime(_ s: String) -> Double {
        let t = s.trimmingCharacters(in: .whitespaces)
        let parts = t.split(whereSeparator: { $0 == ":" || $0 == "." })
        guard parts.count >= 4,
              let h = Double(parts[0]), let m = Double(parts[1]),
              let sec = Double(parts[2]), let cs = Double(parts[3]) else { return 0 }
        return h * 3600 + m * 60 + sec + cs / 100
    }

    // MARK: - 纯文本

    private static func parseTXT(_ s: String) -> [Danmaku] {
        var out: [Danmaku] = []
        for line in s.components(separatedBy: .newlines) {
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty else { continue }
            let parts = l.split(separator: "\t", maxSplits: 1)
            if parts.count == 2, let t = Double(parts[0]) {
                out.append(Danmaku(time: t, text: String(parts[1])))
                continue
            }
            // mm:ss 内容
            let re = try! NSRegularExpression(pattern: #"^(\d+):(\d+(?:\.\d+)?)\s+(.+)$"#)
            let ns = l as NSString
            if let m = re.firstMatch(in: l, range: NSRange(location: 0, length: ns.length)) {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                out.append(Danmaku(time: mm * 60 + ss,
                                   text: ns.substring(with: m.range(at: 3))))
            }
        }
        return out
    }
}
