import Foundation

/// 在线拉弹幕：B站（protobuf 分段）/ 腾讯（JSON 分段）
enum DanmakuSource: String {
    case bilibili, tencent
    var label: String { self == .bilibili ? "B站" : "腾讯" }
}

struct FetchTarget {
    var source: DanmakuSource
    var mainID: String        // bvid 或 vid
    var subID: String = ""    // 腾讯 cid
}

enum DanmakuFetcher {

    // MARK: - 识别链接

    /// 支持：BV 号裸串、bilibili.com/video/BVxxx、
    /// 腾讯 /x/cover/{cid}/{vid}.html、/x/page/{vid}.html、m.v.qq.com?vid=、裸 vid
    static func resolve(_ input: String) -> FetchTarget? {
        // iOS 文本框会把长链接折行，粘贴进来常带换行/空格 —— 先全部清掉再解析
        let s = input
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{3002}", with: "")
            .replacingOccurrences(of: "\u{FF0C}", with: "")
            .replacingOccurrences(of: "\u{201C}", with: "")
            .replacingOccurrences(of: "\u{201D}", with: "")
            .precomposedStringWithCompatibilityMapping   // 全角 → 半角
        guard !s.isEmpty else { return nil }

        if let r = s.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression) {
            return FetchTarget(source: .bilibili, mainID: String(s[r]))
        }
        // 腾讯分享链接常把 vid / cid 放在 query 里
        if let vid = queryValue(s, "vid"), isValidVid(vid) {
            return FetchTarget(source: .tencent, mainID: vid, subID: queryValue(s, "cid") ?? "")
        }
        // /x/cover/{cid}/{vid}.html —— 注意 split 后 parts[0] 是空串
        if let r = s.range(of: "/x/cover/([0-9A-Za-z]+)/([0-9A-Za-z]+)\\.html", options: .regularExpression) {
            let parts = String(s[r]).split(separator: "/")
            if parts.count >= 5 {
                return FetchTarget(source: .tencent,
                                   mainID: String(parts[4]).replacingOccurrences(of: ".html", with: ""),
                                   subID: String(parts[3]))
            }
        }
        // /x/page/{vid}.html 或 /x/cover/{vid}.html（单段形式）
        if let r = s.range(of: "/x/(?:page|cover)/([0-9A-Za-z]+)\\.html", options: .regularExpression) {
            let parts = String(s[r]).split(separator: "/")
            if let last = parts.last {
                return FetchTarget(source: .tencent,
                                   mainID: String(last.replacingOccurrences(of: ".html", with: "")))
            }
        }
        // 兜底：qq.com 上任何 xxx.html，取最后一段当 vid
        if s.contains("qq.com"),
           let r = s.range(of: "/([0-9A-Za-z]{8,16})\\.html", options: .regularExpression) {
            let token = String(s[r])
                .replacingOccurrences(of: "/", with: "")
                .replacingOccurrences(of: ".html", with: "")
            if isValidVid(token) {
                return FetchTarget(source: .tencent, mainID: token)
            }
        }
        if isValidVid(s) {
            return FetchTarget(source: .tencent, mainID: s)
        }
        if s.range(of: "^\\d+$", options: .regularExpression) != nil {
            return FetchTarget(source: .tencent, mainID: s)
        }
        // 最后兜底：任何带 .html 的串，取 .html 前面最后一段字母数字
        if let dot = s.range(of: ".html", options: .caseInsensitive) {
            let head = String(s[..<dot.lowerBound])
            if let last = head.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "&" }).last {
                let token = String(last)
                if token.count >= 6, token.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    return FetchTarget(source: .tencent, mainID: token)
                }
            }
        }
        return nil
    }

    private static func queryValue(_ s: String, _ key: String) -> String? {
        guard let items = URLComponents(string: s)?.queryItems else { return nil }
        return items.first(where: { $0.name == key })?.value
    }

    private static func isValidVid(_ v: String) -> Bool {
        v.range(of: "^[A-Za-z][0-9]{7,}[A-Za-z0-9]{0,10}$", options: .regularExpression) != nil
    }

    // MARK: - 入口

    static func fetch(_ t: FetchTarget, duration: Double) async throws -> [Danmaku] {
        switch t.source {
        case .bilibili: return try await fetchBilibili(t.mainID, duration: duration)
        case .tencent:  return try await fetchTencent(t.mainID, duration: duration)
        }
    }

    // MARK: - B站

    private static func fetchBilibili(_ bvid: String, duration: Double) async throws -> [Danmaku] {
        let cid = try await biliCID(bvid)
        // 时长未知就先问 view 接口，拿到总时长才算得对分段数
        let total: Double
        if duration > 0 {
            total = duration
        } else {
            total = await biliDuration(bvid)
        }
        let planned = total > 0 ? max(1, min(600, Int(ceil(total / 360.0)))) : 600

        var out: [Danmaku] = []
        var failures = 0
        var emptyStreak = 0

        for i in 1...planned {
            do {
                let data = try await biliSegment(cid: cid, index: i)
                if data.isEmpty {
                    // 越界段返回空：连续两段空就认为到底
                    emptyStreak += 1
                    if emptyStreak >= 2 { break }
                    continue
                }
                emptyStreak = 0
                out.append(contentsOf: parseDanmakuElems(data))
            } catch {
                failures += 1
                if failures >= 3 {
                    if out.isEmpty { throw error }
                    break          // 连续失败就不再往下 hammer
                }
            }
        }

        if out.isEmpty && failures > 0 {
            throw NSError(domain: "bili", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "B站拒绝了弹幕请求（\(failures) 段失败）。换网络重试，或改用腾讯源"
            ])
        }
        return out.sorted { $0.time < $1.time }
    }

    /// 单个分段（每段约 6 分钟）
    private static func biliSegment(cid: Int, index: Int) async throws -> [UInt8] {
        guard let url = URL(string: "https://api.bilibili.com/x/v2/dm/web/seg.so?type=1&oid=\(cid)&segment_index=\(index)") else {
            throw NSError(domain: "bili", code: -1)
        }
        var req = URLRequest(url: url)
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "bili", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "B站返回 \(http.statusCode)"
            ])
        }
        return [UInt8](data)
    }

    /// 视频总时长（秒）。拿不到就返回 0，走"边拉边停"分支
    private static func biliDuration(_ bvid: String) async -> Double {
        guard let url = URL(string: "https://api.bilibili.com/x/web-interface/view?bvid=\(bvid)") else { return 0 }
        var req = URLRequest(url: url)
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = obj["data"] as? [String: Any],
              let dur = body["duration"] as? Int, dur > 0 else { return 0 }
        return Double(dur)
    }

    private static func biliCID(_ bvid: String) async throws -> Int {
        guard let url = URL(string: "https://api.bilibili.com/x/player/pagelist?bvid=\(bvid)") else {
            throw NSError(domain: "bili", code: -1)
        }
        var req = URLRequest(url: url)
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]],
              let cid = arr.first?["cid"] as? Int else {
            throw NSError(domain: "bili", code: -2, userInfo: [NSLocalizedDescriptionKey: "拿不到 cid，BV 号可能不对"])
        }
        return cid
    }

    /// 手写 protobuf：外层 field1 = DanmakuElem 子消息
    /// DanmakuElem { 2:progress(ms) 3:mode 5:color 7:content }
    private static func parseDanmakuElems(_ data: [UInt8]) -> [Danmaku] {
        var out: [Danmaku] = []
        var i = 0
        let n = data.count
        while i < n {
            guard let (tag, ni) = readVarint(data, i) else { break }
            i = ni
            let field = Int(tag >> 3), wt = Int(tag & 7)
            if wt == 2 {
                guard let (len, li) = readVarint(data, i) else { break }
                let end = li + Int(len)
                guard end <= n else { break }
                if field == 1 {
                    if let d = parseElem(Array(data[li..<end])) { out.append(d) }
                }
                i = end
            } else if wt == 0 {
                guard let (_, n2) = readVarint(data, i) else { break }
                i = n2
            } else if wt == 5 {
                i += 4
            } else if wt == 1 {
                i += 8
            } else { break }
        }
        return out
    }

    private static func parseElem(_ sub: [UInt8]) -> Danmaku? {
        var p = 0
        var prog = -1
        var mode = 1
        var color = 0xFFFFFF
        var text: String?
        while p < sub.count {
            guard let (t, p2) = readVarint(sub, p) else { break }
            p = p2
            let f = Int(t >> 3), w = Int(t & 7)
            if w == 0 {
                guard let (v, p3) = readVarint(sub, p) else { break }
                p = p3
                if f == 2 { prog = Int(v) } else if f == 3 { mode = Int(v) } else if f == 5 { color = Int(v) }
            } else if w == 2 {
                guard let (l, p3) = readVarint(sub, p) else { break }
                let end = p3 + Int(l)
                guard end <= sub.count else { break }
                if f == 7 { text = String(decoding: sub[p3..<end], as: UTF8.self) }
                p = end
            } else if w == 5 {
                p += 4
            } else if w == 1 {
                p += 8
            } else { break }
        }
        guard let txt = text, !txt.isEmpty, prog >= 0 else { return nil }
        return Danmaku(time: Double(prog) / 1000.0, text: txt, color: UInt32(max(0, min(color, 0xFFFFFF))), mode: mode)
    }

    private static func readVarint(_ b: [UInt8], _ start: Int) -> (UInt64, Int)? {
        var v: UInt64 = 0
        var shift: UInt64 = 0
        var i = start
        while i < b.count {
            let byte = b[i]
            v |= UInt64(byte & 0x7F) << shift
            i += 1
            if byte & 0x80 == 0 { return (v, i) }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    // MARK: - 腾讯

    private static func fetchTencent(_ vid: String, duration: Double) async throws -> [Danmaku] {
        _ = duration
        guard let idxURL = URL(string: "https://dm.video.qq.com/barrage/base/\(vid)") else {
            throw NSError(domain: "tx", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "vid 不合法：\(vid)"])
        }
        let (data, resp) = try await URLSession.shared.data(for: tencentRequest(idxURL))
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw NSError(domain: "tx", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "腾讯弹幕接口返回 \(http.statusCode)，vid=\(vid)"])
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "tx", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "腾讯弹幕接口返回的不是 JSON（可能是网络被拦或 vid 不对）"])
        }

        // 注意：腾讯的 total 字段不可靠（真实有弹幕的视频也可能返回 0），
        // 所以不能用它判断"没有弹幕"，只能以分段里的实际内容为准。

        guard let info = obj["segment_index"] as? [String: Any], !info.isEmpty else {
            throw NSError(domain: "tx", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "拿不到腾讯分段信息（vid=\(vid)）。换个链接或确认视频公开可看"
            ])
        }

        var names: [String] = []
        for (_, raw) in info {
            guard let seg = raw as? [String: Any], let name = seg["segment_name"] as? String else { continue }
            names.append(name)
        }
        names.sort()

        // 并发拉分段（最多 6 个同时），比串行快很多
        let collected = try await withThrowingTaskGroup(of: [Danmaku].self) { group -> [Danmaku] in
            var iterator = names.makeIterator()
            let cap = 6
            var inflight = 0
            while inflight < cap, let name = iterator.next() {
                group.addTask { await tencentSegment(vid: vid, name: name) }
                inflight += 1
            }
            var acc: [Danmaku] = []
            while let part = try await group.next() {
                acc.append(contentsOf: part)
                if let name = iterator.next() {
                    group.addTask { await tencentSegment(vid: vid, name: name) }
                }
            }
            return acc
        }
        return collected.sorted { $0.time < $1.time }
    }

    private static func tencentRequest(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue("https://v.qq.com", forHTTPHeaderField: "Referer")
        req.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        return req
    }

    private static func tencentSegment(vid: String, name: String) async -> [Danmaku] {
        guard let url = URL(string: "https://dm.video.qq.com/barrage/segment/\(vid)/\(name)") else { return [] }
        guard let (d, resp) = try? await URLSession.shared.data(for: tencentRequest(url)),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = o["barrage_list"] as? [[String: Any]] else { return [] }
        return list.compactMap { e -> Danmaku? in
            let text = (e["content"] as? String) ?? ""
            if text.isEmpty { return nil }
            let off: Double
            if let n = e["time_offset"] as? NSNumber { off = n.doubleValue }
            else if let sOff = e["time_offset"] as? String { off = Double(sOff) ?? 0 }
            else { off = 0 }
            return Danmaku(time: max(0, off / 1000.0), text: text)
        }
    }
}

// MARK: - 搜索

struct SearchHit {
    var title: String
    var author: String
    var bvid: String
    var duration: Int
}

extension DanmakuFetcher {

    /// B站搜索（只接 B站，接口最稳）
    static func searchBilibili(_ kw: String) async -> [SearchHit] {
        guard let enc = kw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword=\(enc)&page=1")
        else { return [] }

        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.bilibili.com", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let body = root["data"] as? [String: Any],
                  let list = body["result"] as? [[String: Any]]
            else { return [] }

            return list.compactMap { d -> SearchHit? in
                guard let bvid = d["bvid"] as? String else { return nil }
                var title = (d["title"] as? String) ?? ""
                // 搜索结果标题里带 <em class="keyword"> 高亮标签，去掉
                title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                let author = (d["author"] as? String) ?? ""
                let dur = parseDur((d["duration"] as? String) ?? "")
                return SearchHit(title: title, author: author, bvid: bvid, duration: dur)
            }
        } catch {
            return []
        }
    }

    /// "12:34" → 754
    private static func parseDur(_ s: String) -> Int {
        let parts = s.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        return 0
    }
}
