import SwiftUI
import UniformTypeIdentifiers

enum LibraryMode: String, CaseIterable { case folders = "文件夹", all = "所有论文" }
enum PaperSort: String, CaseIterable { case name = "名称", date = "修改日期" }
struct LibraryRow: Identifiable {
    var id: String
    var name: String
    var date: Date
    var paper: Paper?
    var folder: LibraryFolder?
}
struct ReaderItem: Identifiable { let paper: Paper; var id: String { paper.id } }

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("libraryMode") private var modeValue = LibraryMode.folders.rawValue
    @AppStorage("paperSort") private var sortValue = PaperSort.name.rawValue
    @AppStorage("sortDescending") private var descending = false
    @State private var folder = ""
    @State private var search = ""
    @State private var searching = false
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var selecting = false
    @State private var showingSettings = false
    @State private var showingImporter = false
    @State private var showingMonth = false
    @State private var pendingFiles: [URL] = []
    @State private var monthForImport = false
    @State private var deletion: Set<String> = []
    @State private var showingDelete = false
    @State private var reader: ReaderItem?
    private var mode: LibraryMode { LibraryMode(rawValue: modeValue) ?? .folders }
    private var rows: [LibraryRow] {
        let papers = store.snapshot.papers.filter { (mode == .all || $0.month == folder) && (query.isEmpty || $0.name.localizedStandardContains(query)) }
        let folders = mode == .folders && query.isEmpty ? store.snapshot.folders.filter { folder.isEmpty ? $0.isYear : !$0.isYear && $0.id.split(separator: "/").first.map(String.init) == folder } : []
        func ordered(_ a: LibraryRow, _ b: LibraryRow) -> Bool {
            if sortValue == PaperSort.date.rawValue, a.date != b.date { return descending ? a.date > b.date : a.date < b.date }
            let order = a.name.localizedStandardCompare(b.name)
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
        return folders.map { LibraryRow(id: $0.id, name: $0.title, date: $0.date, folder: $0) }.sorted(by: ordered) + papers.map { LibraryRow(id: $0.id, name: $0.name, date: $0.date, paper: $0) }.sorted(by: ordered)
    }
    var body: some View {
        NavigationStack {
            content
                .navigationTitle("我的论文")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingSettings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("资料库设置")
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button { selecting.toggle(); selected = [] } label: { Image(systemName: selecting ? "checkmark.circle.fill" : "checkmark.circle") }.accessibilityLabel(selecting ? "完成选择" : "多选")
                        Button { add() } label: { Image(systemName: "plus") }.accessibilityLabel("添加论文")
                        Menu {
                            Button("新建文件夹", systemImage: "folder.badge.plus") { monthForImport = false; showingMonth = true }
                            Button("立即同步", systemImage: "arrow.triangle.2.circlepath") { Task { await store.synchronize() } }.disabled(!store.connected)
                            Button("资料库设置", systemImage: "gearshape") { showingSettings = true }
                        } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("更多")
                    }
                }
                .searchable(text: $search, isPresented: $searching, prompt: "搜索当前列表")
                .onChange(of: search) { _, value in if value.isEmpty { searching = false } }
                .onSubmit(of: .search) { searching = false }
                .task(id: search) {
                    do { try await Task.sleep(for: .seconds(1)); guard !Task.isCancelled else { return }; query = search.trimmingCharacters(in: .whitespacesAndNewlines); selected = [] }
                    catch {}
                }
                .sheet(isPresented: $showingSettings) { SettingsView().environmentObject(store) }
                .sheet(isPresented: $showingMonth) {
                    MonthPickerView(title: monthForImport ? "归档月份" : "新建文件夹", initial: folder, count: monthForImport ? pendingFiles.count : nil) { month in
                        let files = pendingFiles; pendingFiles = []
                        Task { if monthForImport { await store.importPDFs(files, month: month) } else { await store.createMonth(month) } }
                    }
                }
                .sheet(isPresented: $showingImporter) { PDFImporter { urls in routeImport(urls) } }
                .fullScreenCover(item: $reader) { item in
                    PDFReaderView(paper: item.paper, url: try! store.disk.url(item.paper.id)) { Task { await store.savedPDF() } }
                }
                .confirmationDialog("移除选中的 \(deletion.count) 个项目？", isPresented: $showingDelete, titleVisibility: .visible) {
                    Button("删除", role: .destructive) { let ids = deletion; selected = []; Task { await store.delete(ids) } }
                }
        }
        .disabled(store.busy)
        .overlay { if store.busy { BusyView(phase: store.phase) } }
        .interactiveDismissDisabled(store.busy)
        .onOpenURL { routeImport([$0]) }
        .onChange(of: scenePhase) { _, phase in if phase == .active && !store.busy { store.refresh() } }
        .onChange(of: store.snapshot.folders) { _, folders in if !folder.isEmpty && !folders.contains(where: { $0.id == folder }) { folder = "" } }
        .alert("", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) { Button("好", role: .cancel) {} } message: { Text(store.notice ?? "") }
    }
    private var content: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("视图", selection: $modeValue) { ForEach(LibraryMode.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
                    .pickerStyle(.segmented).onChange(of: modeValue) { _, _ in folder = ""; resetSelection() }
                Menu {
                    Picker("排序", selection: $sortValue) { ForEach(PaperSort.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
                    Toggle("降序", isOn: $descending)
                } label: { Image(systemName: "arrow.up.arrow.down").frame(width: 38, height: 34) }.accessibilityLabel("排序")
            }.padding(.horizontal).padding(.vertical, 10)
            if mode == .folders {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        Button("全部文件夹") { navigate(mode: .folders) }
                        ForEach(Array(folder.split(separator: "/").enumerated()), id: \.offset) { index, part in
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                            Button(String(part) + (index == 0 ? " 年" : " 月")) { navigate(mode: .folders, path: folder.split(separator: "/").prefix(index + 1).joined(separator: "/")) }
                        }
                    }.font(.subheadline).padding(.horizontal).padding(.vertical, 9)
                }
            }
            if let error = store.error {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    Text(error).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    if store.connected { Button("重试") { Task { await store.synchronize() } }.font(.caption) }
                    Button { store.error = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭错误")
                }.padding().background(Color.orange.opacity(0.08))
            }
            if selecting {
                HStack {
                    Button(selected.count == rows.count ? "取消全选" : "全选") { selected = selected.count == rows.count ? [] : Set(rows.map(\.id)) }
                    Spacer(); Text("已选择 \(selected.count) 项").foregroundStyle(.secondary)
                }.font(.subheadline).padding(.horizontal).padding(.vertical, 8)
            }
            if rows.isEmpty {
                VStack(spacing: 18) {
                    Image(systemName: query.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 43, weight: .ultraLight)).foregroundStyle(Color.paperGreen.opacity(0.65))
                    Text(query.isEmpty ? "暂无论文" : "无搜索结果").font(.headline).fontWeight(.regular).foregroundStyle(.secondary)
                    if !query.isEmpty && mode == .folders && !LibraryPath.isMonth(folder) { Text("进入月份或切换到所有论文后搜索").font(.caption).foregroundStyle(.secondary) }
                    Button(query.isEmpty ? "添加论文" : "清除搜索") { if query.isEmpty { add() } else { search = ""; query = "" } }.buttonStyle(.bordered)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .dropDestination(for: URL.self) { urls, _ in routeImport(urls); return true }
            } else {
                List {
                    ForEach(rows) { row in
                        Button { open(row) } label: { rowView(row) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if selected.count <= 1 { Button("打开", systemImage: row.paper == nil ? "folder" : "doc") { open(row, force: true) } }
                                Button("删除", systemImage: "trash", role: .destructive) { requestDelete(selected.contains(row.id) ? selected : [row.id]) }
                            }
                            .dropDestination(for: URL.self) { urls, _ in routeImport(urls, target: row.folder?.id); return true }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
            HStack {
                Text("\(rows.count) 个项目").foregroundStyle(.secondary)
                Spacer()
                if !store.undoItems.isEmpty { Button("撤销删除") { Task { await store.undoDelete() } } }
                if selecting && !selected.isEmpty { Button(role: .destructive) { requestDelete(selected) } label: { Image(systemName: "trash") }.accessibilityLabel("删除选中项目") }
            }.font(.caption).padding(.horizontal).padding(.vertical, 12)
        }.background(Color.paperBackground)
    }
    private func rowView(_ row: LibraryRow) -> some View {
        HStack(spacing: 13) {
            if selecting { Image(systemName: selected.contains(row.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(row.id) ? Color.paperGreen : .secondary) }
            Image(systemName: row.paper == nil ? "folder.fill" : "doc.richtext")
                .font(.system(size: 24, weight: .light)).foregroundStyle(row.paper == nil ? Color(red: 0.73, green: 0.58, blue: 0.32) : Color(red: 0.72, green: 0.43, blue: 0.36))
                .frame(width: 35)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.name).font(.subheadline).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
                HStack(spacing: 8) {
                    if let p = row.paper {
                        if mode == .all { Text(p.month.replacingOccurrences(of: "/", with: " / ")) }
                        Text(ByteCountFormatter.string(fromByteCount: p.size, countStyle: .file))
                    } else { Text("\(row.folder!.count) 篇论文") }
                    Text(row.date, format: .dateTime.year().month().day())
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 3)
            if row.paper == nil { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
        }.padding(.vertical, 9).contentShape(Rectangle())
    }
    private func resetSelection() { selected = []; search = ""; query = ""; searching = false }
    private func navigate(mode: LibraryMode, path: String = "") { modeValue = mode.rawValue; folder = path; resetSelection() }
    private func open(_ row: LibraryRow, force: Bool = false) {
        if selecting && !force { if selected.contains(row.id) { selected.remove(row.id) } else { selected.insert(row.id) }; return }
        if let p = row.paper { reader = ReaderItem(paper: p) } else { navigate(mode: .folders, path: row.id) }
    }
    private func add() { showingImporter = true }
    private func routeImport(_ urls: [URL], target: String? = nil) {
        guard !store.busy, !urls.isEmpty else { return }
        showingImporter = false
        if mode == .folders && folder.isEmpty { Task { await store.importPDFs(urls, month: LibraryPath.month()) } }
        else if let target, LibraryPath.isMonth(target) { Task { await store.importPDFs(urls, month: target) } }
        else if mode == .folders && LibraryPath.isMonth(folder) { Task { await store.importPDFs(urls, month: folder) } }
        else { pendingFiles = urls; monthForImport = true; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showingMonth = true } }
    }
    private func requestDelete(_ ids: Set<String>) { deletion = ids; showingDelete = true }
}

struct MonthPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let initial: String
    let count: Int?
    let action: (String) -> Void
    @State private var year = Calendar.current.component(.year, from: Date())
    @State private var month = Calendar.current.component(.month, from: Date())
    var body: some View {
        NavigationStack {
            Form {
                if let count { Text("已选择 \(count) 篇论文").foregroundStyle(.secondary) }
                HStack {
                    Picker("年份", selection: $year) { ForEach(1900...2100, id: \.self) { Text(String($0) + " 年").tag($0) } }
                    Picker("月份", selection: $month) { ForEach(1...12, id: \.self) { Text("\($0) 月").tag($0) } }
                }.pickerStyle(.wheel).labelsHidden()
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button(count == nil ? "创建" : "添加") { let value = String(format: "%04d/%02d", year, month); dismiss(); action(value) } }
                }
                .onAppear { let parts = initial.split(separator: "/").compactMap { Int($0) }; if let first = parts.first { year = first }; if parts.count == 2 { month = parts[1] } }
        }.presentationDetents([.medium])
    }
}

struct PDFImporter: UIViewControllerRepresentable {
    let completion: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: false)
        picker.allowsMultipleSelection = true; picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: ([URL]) -> Void
        init(completion: @escaping ([URL]) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(urls) }
    }
}

struct BusyView: View {
    let phase: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea().contentShape(Rectangle())
            HStack(spacing: 14) { ProgressView(); Text(phase).font(.subheadline) }.padding(25).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
        }.accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var branch = ""
    @State private var token = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub 仓库") {
                    TextField("https://github.com/you/papers.git", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("默认分支", text: $branch).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    SecureField("GitHub 访问令牌", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                } footer: { Text("令牌需有该论文仓库的 Contents 读写权限，保存在本机钥匙串。") }
                if let date = store.syncState.lastSync { LabeledContent("上次同步") { Text(date, style: .relative) } }
                if let error = store.error { Text(error).foregroundStyle(.red).font(.footnote) }
                Section { Button("保存并同步") { Task { if await store.configure(address: address, branch: branch, token: token) { dismiss() } } }.disabled(address.isEmpty || token.isEmpty) }
            }.navigationTitle("资料库设置").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
                .onAppear { if let r = store.syncState.repository { address = "https://github.com/\(r.owner)/\(r.name).git"; branch = r.branch }; token = TokenVault.read() }
                .disabled(store.busy).overlay { if store.busy { BusyView(phase: store.phase) } }.interactiveDismissDisabled(store.busy)
        }
    }
}
