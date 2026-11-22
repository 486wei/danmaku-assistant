//
//  ContentView.swift
//  弹幕助手 for iPad —— 只生成 .ass，播放交给夸克网盘自带的播放器
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 模型

/// 注意：这里不加 @MainActor —— 界面状态全部在主线程改（Task 里用 MainActor.run 回主线程），
/// 不加反而能避开 Swift 5 + SwiftUI 在 actor 隔离上的编译坑。
final class AssistantModel: ObservableObject {
    @Published var inputURL: String = ""
    @Published var keyword: String = ""
    @Published var items: [Danmaku] = []
    @Published var sourceLabel: String = ""
    @Published var status: String = "粘贴链接或搜片名，拉弹幕后生成 .ass"
    @Published var busy = false
    @Published var errorText: String? = nil

    // 样式
    @Published var sizePercent: Double = 100
    @Published var opacityPercent: Double = 100
    @Published var speedPercent: Double = 100
    @Published var areaPercent: Double = 85
    @Published var blockText: String = ""
    @Published var width: Int = 1920
    @Published var height: Int = 1080

    @Published var files: [URL] = []
    @Published var searchRows: [SearchRow] = []
    @Published var importedBaseName: String? = nil   // 本地导入的文件名，用来命名输出的 .ass

    struct SearchRow: Identifiable {
        let id = UUID()
        let title: String
        let author: String
        let bvid: String
    }

    var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    init() { refreshFiles() }

    func refreshFiles() {
        let fm = FileManager.default
        let list = (try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension.lowercased() == "ass" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            } ?? []
        files = list
    }

    // MARK: 拉弹幕

    func fetch() {
        importedBaseName = nil
        let raw = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { status = "先粘贴一个视频链接"; return }
        guard let target = DanmakuFetcher.resolve(raw) else {
            status = "这个链接没认出来（只认 B站 BV 号和腾讯视频 vid 号）"
            return
        }
        busy = true; errorText = nil
        status = "正在拉弹幕…（热门长视频分段多，可能要半分钟）"
        Task {
            do {
                let got = try await DanmakuFetcher.fetch(target, duration: 0)
                await MainActor.run {
                    self.items = got
                    self.sourceLabel = target.source.label
                    self.busy = false
                    self.status = got.isEmpty
                        ? "这个视频没有弹幕"
                        : "拉到 \(got.count) 条（\(target.source.label)）。设置好样式后点「生成 .ass」。"
                }
            } catch {
                await MainActor.run {
                    self.busy = false
                    self.errorText = "\(error)"
                    self.status = "拉取失败"
                }
            }
        }
    }

    func search() {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { status = "输入片名再搜"; return }
        busy = true
        status = "搜索中…"
        Task {
            let rows = await DanmakuFetcher.searchBilibili(kw)
            await MainActor.run {
                self.searchRows = rows.map { SearchRow(title: $0.title, author: $0.author, bvid: $0.bvid) }
                self.busy = false
                self.status = rows.isEmpty ? "没搜到，换个关键词" : "搜到 \(rows.count) 条，点一个试试"
            }
        }
    }

    func use(row: SearchRow) {
        inputURL = "https://www.bilibili.com/video/\(row.bvid)"
        fetch()
    }

    // MARK: 本地导入

    /// 「文件」App 里可选的类型：B站 XML / JSON / ASS / TXT 全部放行
    static var importTypes: [UTType] {
        var types: [UTType] = [.xml, .json, .plainText, .data]
        if let ass = UTType(filenameExtension: "ass") { types.insert(ass, at: 0) }
        return types
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        busy = true
        errorText = nil
        status = "正在读本地文件…"

        var got: [Danmaku] = []
        var bad: [String] = []

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let parsed = try? DanmakuParser.parse(url: url), !parsed.isEmpty {
                got.append(contentsOf: parsed)
            } else {
                bad.append(url.lastPathComponent)
            }
        }

        got.sort { $0.time < $1.time }
        items = got
        sourceLabel = got.isEmpty ? "" : "本地文件"
        if let first = urls.first {
            importedBaseName = first.deletingPathExtension().lastPathComponent
        }
        busy = false

        if got.isEmpty {
            status = "没读到弹幕。支持 B站 XML / JSON / ASS / 纯文本（时间<TAB>内容 或 mm:ss 内容）"
            errorText = bad.isEmpty ? nil : "读不出：\(bad.joined(separator: "、"))"
        } else {
            status = "导入 \(got.count) 条。设置好样式后点「生成 .ass」。"
            errorText = bad.isEmpty ? nil : "有 \(bad.count) 个文件没读出弹幕：\(bad.joined(separator: "、"))"
        }
    }

    /// 给界面回话用（比如从系统面板返回的错误）
    func note(_ text: String) {
        status = text
        errorText = nil
    }

    // MARK: 生成

    func generate() {
        guard !items.isEmpty else { status = "还没有弹幕，先拉取或导入"; return }
        var style = AssStyle()
        style.sizePercent = sizePercent
        style.opacityPercent = opacityPercent
        style.speedPercent = speedPercent
        style.areaPercent = areaPercent
        style.blockWords = blockText.split(separator: " ").map(String.init)

        let text = AssWriter.build(items, width: width, height: height, style: style)

        // 文件名：本地导入沿用原文件名，在线拉取用 BV/vid，退化时间戳
        let name = fileNameHint()
        let url = docs.appendingPathComponent(name + ".ass")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            refreshFiles()
            let n = text.components(separatedBy: "Dialogue:").count - 1
            status = "已生成 \(name).ass（\(n) 条）。在夸克里点「字幕 → 本地字幕」选它。"
        } catch {
            status = "写入失败：\(error.localizedDescription)"
        }
    }

    private func fileNameHint() -> String {
        if let base = importedBaseName, !base.isEmpty { return base }
        let raw = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        // BV 号
        if let r = raw.range(of: "BV[0-9A-Za-z]{10}", options: .regularExpression) {
            return String(raw[r])
        }
        // 腾讯 /x/cover/xxx/VID.html
        if let r = raw.range(of: #"[a-z]\d{7,}[a-z0-9]{0,8}\.html"#, options: .regularExpression) {
            return String(raw[r]).replacingOccurrences(of: ".html", with: "")
        }
        let fmt = DateFormatter(); fmt.dateFormat = "弹幕-yyyyMMdd-HHmmss"
        return fmt.string(from: Date())
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        refreshFiles()
    }
}

// MARK: - 主界面

struct ContentView: View {
    @StateObject private var m = AssistantModel()
    @State private var showStyle = true
    @State private var showImporter = false

    var body: some View {
        NavigationSplitView {
            List {
                Section("获取弹幕") {
                    TextField("粘贴 B站 BV 号 / 链接，或腾讯视频链接", text: $m.inputURL, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .lineLimit(1...3)
                    Button {
                        m.fetch()
                    } label: {
                        Label("拉取弹幕", systemImage: "arrow.down.circle")
                    }
                    .disabled(m.busy)

                    TextField("或按片名搜（B站）", text: $m.keyword)
                        .onSubmit { m.search() }
                    Button {
                        m.search()
                    } label: {
                        Label("搜索", systemImage: "magnifyingglass")
                    }
                    .disabled(m.busy)
                }

                Section("本地文件") {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入弹幕文件", systemImage: "folder")
                    }
                    .disabled(m.busy)

                    Text("支持 B站 XML、JSON、ASS、纯文本（时间<TAB>内容 或 mm:ss 内容）。导入后直接「生成 .ass」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !m.searchRows.isEmpty {
                    Section("搜索结果") {
                        ForEach(m.searchRows) { row in
                            Button {
                                m.use(row: row)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).font(.subheadline).lineLimit(2)
                                    Text(row.author).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("弹幕助手")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        m.refreshFiles()
                    } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: AssistantModel.importTypes,
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): m.importFiles(urls)
                case .failure(let err): m.note("选文件失败：\(err.localizedDescription)")
                }
            }
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    if !m.items.isEmpty {
                        styleCard
                        Button {
                            m.generate()
                        } label: {
                            Label("生成 .ass", systemImage: "doc.badge.plus")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }

                    filesCard
                    howtoCard
                }
                .padding(20)
            }
            .navigationTitle("弹幕助手")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 组件

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(m.status)
                .font(.callout)
                .foregroundStyle(m.errorText == nil ? Color.secondary : Color.red)
            if !m.items.isEmpty {
                HStack(spacing: 10) {
                    Label("\(m.items.count) 条", systemImage: "text.bubble")
                    if !m.sourceLabel.isEmpty {
                        Text(m.sourceLabel).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if m.busy { ProgressView().padding(.top, 4) }
        }
    }

    private var styleCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("弹幕样式").font(.headline)

            numRow("字号", value: $m.sizePercent, range: 30...300, suffix: "%")
            numRow("透明度", value: $m.opacityPercent, range: 0...100, suffix: "%")
            numRow("速度", value: $m.speedPercent, range: 20...300, suffix: "%")
            numRow("显示区域", value: $m.areaPercent, range: 20...100, suffix: "%")

            Divider()
            Text("视频分辨率（影响弹幕位置，选错了会偏移）").font(.caption).foregroundStyle(.secondary)
            Picker("分辨率", selection: Binding(
                get: { m.width },
                set: { v in
                    m.width = v
                    m.height = (v == 3840) ? 2160 : (v == 2560 ? 1440 : 1080)
                }
            )) {
                Text("1080p").tag(1920)
                Text("2K").tag(2560)
                Text("4K").tag(3840)
            }
            .pickerStyle(.segmented)

            TextField("屏蔽词，空格分隔", text: $m.blockText)
                .textFieldStyle(.roundedBorder)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func numRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack {
            Text(title).frame(width: 78, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))\(suffix)")
                .frame(width: 56, alignment: .trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Stepper("", value: value, in: range, step: 1).labelsHidden()
        }
        .font(.subheadline)
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("已生成的字幕（\(m.files.count)）").font(.headline)
            if m.files.isEmpty {
                Text("还没有。拉完弹幕点「生成 .ass」就会出现在这里。")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(m.files, id: \.self) { f in
                    HStack {
                        Image(systemName: "doc.text")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(f.lastPathComponent).font(.subheadline).lineLimit(1)
                            if let sz = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                                Text(ByteCountFormatter.string(fromByteCount: Int64(sz), countStyle: .file))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        ShareLink(item: f) { Image(systemName: "square.and.arrow.up") }
                        Button(role: .destructive) {
                            m.delete(f)
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private var howtoCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("怎么挂到夸克播放器上").font(.headline)
            Group {
                Text("1. 生成 .ass 后，点文件右边的分享按钮 →「存储到文件」→ 记住位置")
                Text("2. 打开夸克网盘，播放那个视频")
                Text("3. 点播放器右下角「字幕」→「导入本地字幕」→ 选刚才的 .ass")
                Text("4. 如果夸克版本没有「导入字幕」，用分享按钮把 .ass 存到「文件」App 里，再从夸克的字幕菜单找")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
}
