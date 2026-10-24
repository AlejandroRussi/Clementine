import AppKit
import PDFKit
import SwiftUI

/// Picks specific pages of a PDF and saves just those, as PDF or images.
@MainActor
final class PDFPagesModel: ObservableObject {
    let url: URL
    let document: PDFDocument?
    let pageCount: Int
    @Published var selection: [Int] = [] { didSet { if !editingRange { rangeText = PageRange.describe(selection) } } }
    @Published var rangeText = ""
    @Published var rangeIsValid = true
    @Published var output: PageOutput = .pdf
    @Published private(set) var thumbnails: [Int: NSImage] = [:]
    private var anchor: Int?
    private var editingRange = false

    init(url: URL) {
        self.url = url
        let doc = PDFDocument(url: url)
        document = doc?.isLocked == false ? doc : nil
        pageCount = document?.pageCount ?? 0
    }

    func isSelected(_ i: Int) -> Bool { selection.contains(i) }

    /// Click toggles one page; ⇧-click selects the run from the last clicked page.
    func click(_ i: Int, extend: Bool) {
        if extend, let anchor {
            let run = anchor <= i ? Array(anchor...i) : Array((i...anchor).reversed())
            for p in run where !selection.contains(p) { selection.append(p) }
        } else if let at = selection.firstIndex(of: i) {
            selection.remove(at: at)
        } else {
            selection.append(i)
        }
        anchor = i
        rangeIsValid = true
    }

    func selectAll() { selection = Array(0..<pageCount); rangeIsValid = true }
    func selectNone() { selection = []; rangeIsValid = true }

    /// Applies typed ranges like "1-3, 5, 8-" to the grid selection.
    func applyRange(_ text: String) {
        guard let pages = PageRange.parse(text, pageCount: pageCount) else { rangeIsValid = false; return }
        rangeIsValid = true
        editingRange = true
        selection = pages
        editingRange = false
    }

    func thumbnail(_ i: Int) {
        guard thumbnails[i] == nil, let page = document?.page(at: i) else { return }
        thumbnails[i] = page.thumbnail(of: NSSize(width: 240, height: 240), for: .cropBox)
    }

    /// Pages in document order, which is what people expect from "pages 2, 5 and 9".
    var orderedSelection: [Int] { selection.sorted() }

    var exportTitle: String {
        let n = selection.count
        return n == 0 ? "Save Pages" : "Save \(n) Page\(n == 1 ? "" : "s")"
    }

    func export() {
        let url = url, pages = orderedSelection, output = output
        OperationRunner.shared.runTask("Saving \(pages.count) page\(pages.count == 1 ? "" : "s")") {
            try PDFTools.extract(url, pages: pages, as: output)
        }
    }
}

struct PDFPagesView: View {
    @ObservedObject var model: PDFPagesModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("Pages")
                TextField("e.g. 1-3, 5, 8-", text: $model.rangeText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { model.applyRange(model.rangeText) }
                    .onChange(of: model.rangeText) { model.applyRange($0) }
                if !model.rangeIsValid {
                    Label("Pages run 1–\(model.pageCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Spacer()
                Button("Select All") { model.selectAll() }
                Button("None") { model.selectNone() }.disabled(model.selection.isEmpty)
            }

            if model.document == nil {
                Text("This PDF can't be read or is password-protected.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                        ForEach(0..<model.pageCount, id: \.self) { i in
                            PageCell(index: i, image: model.thumbnails[i], selected: model.isSelected(i))
                                .onAppear { model.thumbnail(i) }
                                .onTapGesture { model.click(i, extend: NSEvent.modifierFlags.contains(.shift)) }
                        }
                    }
                    .padding(14)
                }
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            HStack {
                Text("Save as")
                Picker("Save as", selection: $model.output) {
                    ForEach(PageOutput.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("Click pages to pick them · ⇧-click for a run").font(.caption).foregroundStyle(.secondary)
                Button(model.exportTitle) { model.export() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.selection.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 720, minHeight: 520)
    }
}

private struct PageCell: View {
    let index: Int
    let image: NSImage?
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fit) }
                    else { Color.white.opacity(0.6).aspectRatio(0.77, contentMode: .fit) }
                }
                .frame(height: 150)
                .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(selected ? Color.orange : .clear, lineWidth: 3))

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3).symbolRenderingMode(.palette).foregroundStyle(.white, .orange)
                        .offset(x: 8, y: -8)
                }
            }
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(selected ? .primary : .secondary)
        }
        .padding(8)
        .background(selected ? Color.orange.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}
