import SwiftUI
import PDFKit

@main struct PaperRepApp: App {
    @StateObject private var store: LibraryStore
    init() {
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        if testing {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("PaperRep-UITests")
            try? FileManager.default.removeItem(at: base)
            let disk = LibraryDisk(root: base.appendingPathComponent("Library"), support: base.appendingPathComponent("Support"))
            try? disk.initialize()
            if ProcessInfo.processInfo.arguments.contains("--seed-papers") {
                for month in ["2026/11", "2026/10", "2025/06"] { try? disk.makeMonth(month) }
                for (index, name) in ["Attention Is All You Need", "Retrieval-Augmented Generation", "Deep Residual Learning"].enumerated() {
                    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
                    let data = renderer.pdfData { context in
                        for page in 1...3 {
                            context.beginPage()
                            (name as NSString).draw(at: CGPoint(x: 45, y: 65), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 25)])
                            ("PaperRep reader test · Page \(page)\n\nThis document exercises PDF reading, search and annotations.\nAttention and learning are useful for research." as NSString).draw(in: CGRect(x: 45, y: 130, width: 500, height: 600), withAttributes: [.font: UIFont.systemFont(ofSize: 16)])
                        }
                    }
                    let month = index < 2 ? "2026/11" : "2026/10"
                    UserDefaults.standard.removeObject(forKey: "reader.page." + month + "/" + name + ".pdf")
                    try? data.write(to: disk.root.appendingPathComponent(month + "/" + name + ".pdf"))
                }
            }
            _store = StateObject(wrappedValue: LibraryStore(disk: disk))
        } else { _store = StateObject(wrappedValue: LibraryStore()) }
    }
    var body: some Scene {
        WindowGroup {
            LibraryView().environmentObject(store).tint(.paperGreen)
                .task { await store.startup() }
        }
    }
}

extension Color {
    static let paperGreen = Color(red: 0.19, green: 0.36, blue: 0.28)
    static let paperBackground = Color(uiColor: .systemGroupedBackground)
}
