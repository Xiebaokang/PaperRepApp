import SwiftUI
import PDFKit

@MainActor final class ReaderModel: NSObject, ObservableObject {
    @Published var page = 0
    @Published var count = 0
    @Published var dirty = false
    private(set) var savedChanges = false
    @Published var search = ""
    @Published var results: [PDFSelection] = []
    @Published var resultIndex = 0
    @Published var error: String?
    @Published var locked = false
    let document: PDFDocument?
    let url: URL
    let id: String
    weak var view: PDFView?
    private var observer: NSObjectProtocol?
    init(url: URL, id: String) {
        self.url = url; self.id = id; self.document = PDFDocument(url: url)
        super.init()
        locked = document?.isLocked ?? false
        count = document?.pageCount ?? 0
        if document == nil { error = "无法打开此 PDF。" }
    }
    func attach(_ view: PDFView) {
        self.view = view
        observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePage() }
        }
        let saved = UserDefaults.standard.integer(forKey: "reader.page." + id)
        if let target = document?.page(at: saved) { view.go(to: target) }
        updatePage()
    }
    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil; view = nil
    }
    func updatePage() {
        guard let current = view?.currentPage, let document else { return }
        page = document.index(for: current); count = document.pageCount
        UserDefaults.standard.set(page, forKey: "reader.page." + id)
    }
    func go(_ page: Int) { if let target = document?.page(at: page) { view?.go(to: target); updatePage() } }
    func find() {
        guard let document else { return }
        results = search.isEmpty ? [] : document.findString(search, withOptions: [.caseInsensitive])
        resultIndex = 0; revealResult()
    }
    func nextResult(_ offset: Int) { guard !results.isEmpty else { return }; resultIndex = (resultIndex + offset + results.count) % results.count; revealResult() }
    private func revealResult() {
        view?.highlightedSelections = results
        guard !results.isEmpty else { view?.clearSelection(); return }
        let selection = results[resultIndex]
        view?.setCurrentSelection(selection, animate: false); view?.go(to: selection)
    }
    func highlight() {
        guard let selection = view?.currentSelection, !(selection.string ?? "").isEmpty else { error = "请先长按并选择需要高亮的文字。"; return }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard !bounds.isEmpty, !bounds.isInfinite else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = UIColor.systemYellow.withAlphaComponent(0.45)
                annotation.userName = "PaperRep"; annotation.modificationDate = Date()
                page.addAnnotation(annotation)
            }
        }
        view?.clearSelection(); dirty = true; view?.setNeedsDisplay()
    }
    func note(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let page = view?.currentPage else { return }
        let box = page.bounds(for: .cropBox)
        let annotation = PDFAnnotation(bounds: CGRect(x: box.minX + 24, y: box.maxY - 54, width: 26, height: 26), forType: .text, withProperties: nil)
        annotation.contents = text; annotation.color = .systemYellow; annotation.userName = "PaperRep"; annotation.modificationDate = Date()
        page.addAnnotation(annotation); dirty = true; view?.setNeedsDisplay()
    }
    func removeAnnotations() {
        guard let page = view?.currentPage else { return }
        let ours = page.annotations.filter { $0.userName == "PaperRep" }
        guard !ours.isEmpty else { return }
        ours.forEach(page.removeAnnotation); dirty = true; view?.setNeedsDisplay()
    }
    func unlock(_ password: String) {
        if document?.unlock(withPassword: password) == true { locked = false; count = document?.pageCount ?? 0; view?.document = document }
        else { error = "密码不正确。" }
    }
    func save() throws {
        guard dirty, let document else { return }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard document.write(to: temporary), let check = PDFDocument(url: temporary), check.pageCount == document.pageCount else { throw PaperError.message("批注保存失败，原文件未改动。") }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        dirty = false
        savedChanges = true
    }
}

struct PDFCanvas: UIViewRepresentable {
    @ObservedObject var model: ReaderModel
    var onTap: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(model: model, onTap: onTap) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = model.document; view.autoScales = true
        view.displayMode = .singlePageContinuous; view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        for gesture in [singleTap, doubleTap] {
            gesture.cancelsTouchesInView = false
            gesture.delegate = context.coordinator
            view.addGestureRecognizer(gesture)
        }
        // Let PDFKit handle double-tap zoom without also toggling the bars.
        singleTap.require(toFail: doubleTap)
        DispatchQueue.main.async { model.attach(view) }
        return view
    }
    func updateUIView(_ uiView: PDFView, context: Context) { context.coordinator.onTap = onTap }
    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) { uiView.document = nil }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let model: ReaderModel
        var onTap: () -> Void
        init(model: ReaderModel, onTap: @escaping () -> Void) { self.model = model; self.onTap = onTap }
        @objc func tapped() { onTap() }
        @objc func doubleTapped() {}
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            // A tap that dismisses selected text should keep annotation tools available.
            (model.view?.currentSelection?.string ?? "").isEmpty
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}

struct PDFReaderView: View {
    let paper: Paper
    let onSave: () -> Void
    @StateObject private var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingThumbnails = false
    @State private var showingSearch = false
    @State private var showingNote = false
    @State private var note = ""
    @State private var password = ""
    @State private var sharing = false
    @State private var removeConfirmation = false
    @State private var controlsVisible = true
    init(paper: Paper, url: URL, onSave: @escaping () -> Void) {
        self.paper = paper; self.onSave = onSave
        _model = StateObject(wrappedValue: ReaderModel(url: url, id: paper.id))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if controlsVisible && showingSearch {
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索 PDF", text: $model.search).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("pdf-search")
                        if !model.search.isEmpty {
                            Text(model.results.isEmpty ? "0" : "\(model.resultIndex + 1)/\(model.results.count)").font(.caption).foregroundStyle(.secondary)
                            Button { model.nextResult(-1) } label: { Image(systemName: "chevron.up") }.disabled(model.results.isEmpty)
                            Button { model.nextResult(1) } label: { Image(systemName: "chevron.down") }.disabled(model.results.isEmpty)
                        }
                    }.padding().background(.thinMaterial)
                }
                if model.locked {
                    VStack(spacing: 20) {
                        Image(systemName: "lock.doc").font(.largeTitle).foregroundStyle(.secondary)
                        SecureField("PDF 密码", text: $password).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
                        Button("解锁") { model.unlock(password) }.buttonStyle(.borderedProminent)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    PDFCanvas(model: model) {
                        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
                    }
                    .accessibilityIdentifier("pdf-canvas")
                    .accessibilityAction(named: controlsVisible ? "隐藏工具栏" : "显示工具栏") { controlsVisible.toggle() }
                }
                if controlsVisible { HStack {
                    Button { model.go(model.page - 1) } label: { Image(systemName: "chevron.left") }.disabled(model.page <= 0).accessibilityLabel("上一页")
                    Spacer()
                    Button { showingThumbnails = true } label: { Text("\(model.count == 0 ? 0 : model.page + 1) / \(model.count)").font(.subheadline.monospacedDigit()) }.accessibilityIdentifier("pdf-page-count")
                    Spacer()
                    Button { model.go(model.page + 1) } label: { Image(systemName: "chevron.right") }.disabled(model.page + 1 >= model.count).accessibilityLabel("下一页")
                }.padding(.horizontal, 25).padding(.vertical, 15).background(.bar) }
            }
            .navigationTitle(paper.name).navigationBarTitleDisplayMode(.inline)
            .toolbar(controlsVisible ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("完成") { finish() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showingSearch.toggle() } label: { Image(systemName: "magnifyingglass") }.accessibilityLabel("搜索 PDF")
                    Menu {
                        Button("页面缩略图", systemImage: "square.grid.2x2") { showingThumbnails = true }
                        Button("高亮选中文字", systemImage: "highlighter") { model.highlight() }
                        Button("添加批注", systemImage: "note.text.badge.plus") { note = ""; showingNote = true }
                        Button("清除本页批注", systemImage: "eraser", role: .destructive) { removeConfirmation = true }
                        Button("分享 PDF", systemImage: "square.and.arrow.up") { do { try model.save(); sharing = true } catch { model.error = error.localizedDescription } }
                    } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("阅读选项")
                }
            }
            .task(id: model.search) { do { try await Task.sleep(for: .milliseconds(400)); if !Task.isCancelled { model.find() } } catch {} }
            .sheet(isPresented: $showingThumbnails) {
                NavigationStack {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], spacing: 20) {
                            ForEach(0..<model.count, id: \.self) { index in
                                Button { model.go(index); showingThumbnails = false } label: {
                                    VStack(spacing: 8) {
                                        if let page = model.document?.page(at: index) { Image(uiImage: page.thumbnail(of: CGSize(width: 130, height: 180), for: .cropBox)).resizable().scaledToFit().frame(height: 155).shadow(color: .black.opacity(0.12), radius: 3) }
                                        Text("\(index + 1)").font(.caption).foregroundStyle(index == model.page ? Color.paperGreen : .secondary)
                                    }.padding(8).background(index == model.page ? Color.paperGreen.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                }
                            }
                        }.padding()
                    }.background(Color.paperBackground).navigationTitle("页面").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingThumbnails = false } } }
                }
            }
            .alert("添加批注", isPresented: $showingNote) {
                TextField("批注内容", text: $note)
                Button("取消", role: .cancel) {}
                Button("添加") { model.note(note) }
            }
            .confirmationDialog("清除本页由 PaperRep 添加的批注？", isPresented: $removeConfirmation, titleVisibility: .visible) { Button("清除", role: .destructive) { model.removeAnnotations() } }
            .alert("", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("好", role: .cancel) {} } message: { Text(model.error ?? "") }
            .sheet(isPresented: $sharing) { ShareSheet(url: model.url) }
            .onDisappear { model.detach() }
            .onChange(of: scenePhase) { _, phase in if phase == .inactive { do { try model.save() } catch { model.error = error.localizedDescription } } }
        }.tint(.paperGreen).interactiveDismissDisabled()
    }
    private func finish() {
        let changed = model.dirty || model.savedChanges
        do { try model.save(); model.detach(); dismiss(); if changed { onSave() } }
        catch { model.error = error.localizedDescription }
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
