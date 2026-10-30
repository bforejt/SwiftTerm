#if os(macOS)
import AppKit
import Testing

@testable import SwiftTerm

/// Records what the render path asks and answers with a fixed rule: every
/// occurrence of `word` in a row is decorated.
private final class WordDecorator: TerminalRowDecorationProvider, @unchecked Sendable {
    let word: String
    let decoration: TerminalRowDecoration
    private let lock = NSLock()
    private var requests: [[TerminalRowDecorationRequest]] = []

    init (word: String, decoration: TerminalRowDecoration) {
        self.word = word
        self.decoration = decoration
    }

    var calls: [[TerminalRowDecorationRequest]] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    func reset () {
        lock.lock(); defer { lock.unlock() }
        requests.removeAll()
    }

    func rowDecorations (for rows: [TerminalRowDecorationRequest]) -> [[TerminalRowDecoration]] {
        lock.lock()
        requests.append(rows)
        lock.unlock()
        return rows.map { request in
            var result: [TerminalRowDecoration] = []
            let text = request.text as NSString
            var search = NSRange(location: 0, length: text.length)
            while true {
                let found = text.range(of: word, options: [], range: search)
                guard found.location != NSNotFound else { break }
                if let columns = request.columnRange(utf16: found.location,
                                                     found.location + found.length) {
                    var item = decoration
                    item.columns = columns
                    result.append(item)
                }
                let next = found.location + found.length
                search = NSRange(location: next, length: text.length - next)
            }
            return result
        }
    }
}

@MainActor
struct RowDecorationTests {
    private func makeView (cols: Int = 20, rows: Int = 4) -> TerminalView {
        let view = TerminalView(frame: .zero, font: nil,
                                options: TerminalOptions(cols: cols, rows: rows, scrollback: 20))
        // Bold keeps palette index 1 (bold-as-bright would draw index 9).
        view.useBrightColors = false
        return view
    }

    private func same (_ value: Any?, _ expected: NSColor) -> Bool {
        guard let actual = (value as? NSColor)?.usingColorSpace(.sRGB),
              let expected = expected.usingColorSpace(.sRGB) else { return false }
        return abs(actual.redComponent - expected.redComponent) < 0.001
            && abs(actual.greenComponent - expected.greenComponent) < 0.001
            && abs(actual.blueComponent - expected.blueComponent) < 0.001
    }

    private func refresh (_ snapshot: TerminalSnapshot, from view: TerminalView) {
        view.withTerminal { terminal in
            _ = snapshot.refresh(terminal: terminal, viewState: FrameViewState(view: view),
                                 selection: SnapshotSelectionState(selection: view.selection))
        }
    }

    private func render (_ snapshot: TerminalSnapshot, row: Int, view: TerminalView) throws
        -> NSAttributedString
    {
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        let info = view.textBuilder.buildAttributedString(
            row: try #require(snapshot.rows.dropFirst(row).first),
            absoluteRow: snapshot.firstRow + row, context: context)
        let joined = NSMutableAttributedString()
        for segment in info.segments {
            joined.append(segment.attributedString)
        }
        return joined
    }

    private let red = TerminalRowDecoration(columns: 0..<0, foreground: .ansi256(code: 1),
                                            bold: true)

    @Test func providerIsAskedOnlyForChangedRows () {
        let view = makeView()
        let provider = WordDecorator(word: "down", decoration: red)
        view.setRowDecorationProvider(provider)
        view.feed(text: "Gi1 down\r\nGi2 up")
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        #expect(provider.calls.count == 1)
        #expect(provider.calls.first?.count == snapshot.rows.count)

        // Nothing changed: an idle frame asks nothing.
        provider.reset()
        refresh(snapshot, from: view)
        refresh(snapshot, from: view)
        #expect(provider.calls.isEmpty)

        // One row changed: only that row is asked.
        view.feed(text: " down")
        refresh(snapshot, from: view)
        #expect(provider.calls.count == 1)
        #expect(provider.calls.first?.map(\.text) == ["Gi2 up down"])

        // Invalidation asks every visible row again.
        provider.reset()
        view.invalidateRowDecorations()
        refresh(snapshot, from: view)
        #expect(provider.calls.first?.count == snapshot.rows.count)
    }

    @Test func decorationsLandOnTheMatchedColumns () throws {
        let view = makeView()
        let provider = WordDecorator(word: "down", decoration: red)
        view.setRowDecorationProvider(provider)
        view.feed(text: "Gi1 down up")
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        #expect(snapshot.rows[0].decorations.map(\.columns) == [4..<8])
        #expect(view.visibleRowDecorations().first?.map(\.columns) == [4..<8])

        let line = try render(snapshot, row: 0, view: view)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        let decorated = line.attributes(at: 4, effectiveRange: nil)
        let plain = line.attributes(at: 0, effectiveRange: nil)
        #expect((decorated[.font] as? NSFont) == context.fonts.bold)
        #expect((plain[.font] as? NSFont) == context.fonts.normal)
        #expect(same(decorated[.foregroundColor], context.ansiColors[1]))
        #expect((line.attributes(at: 8, effectiveRange: nil)[.font] as? NSFont) == context.fonts.normal)
    }

    @Test func wideCharactersMapToTheirCells () throws {
        let view = makeView()
        let provider = WordDecorator(word: "down", decoration: red)
        view.setRowDecorationProvider(provider)
        // Two wide characters take columns 0-3; "down" starts at column 5.
        view.feed(text: "日本 down")
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        let request = try #require(provider.calls.first?.first)
        #expect(request.text == "日本 down")
        #expect(request.columns == [0, 2, 4, 5, 6, 7, 8, 9])
        #expect(snapshot.rows[0].decorations.map(\.columns) == [5..<9])
        // A match on the wide character covers both of its cells.
        #expect(request.columnRange(utf16: 1, 2) == 2..<4)
    }

    @Test func selectionDrawsOverTheDecoration () throws {
        let view = makeView()
        view.selectedTextForegroundColor = .systemPurple
        let provider = WordDecorator(word: "down", decoration: red)
        view.setRowDecorationProvider(provider)
        view.feed(text: "Gi1 down")
        view.withTerminal { _ in
            view.selection.setSelection(start: Position(col: 4, row: 0), end: Position(col: 6, row: 0))
        }
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        let line = try render(snapshot, row: 0, view: view)
        let selected = line.attributes(at: 4, effectiveRange: nil)
        #expect(same(selected[.foregroundColor], view.selectedTextForegroundColor))
        #expect(selected[.selectionBackgroundColor] != nil)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        #expect(same(line.attributes(at: 7, effectiveRange: nil)[.foregroundColor], context.ansiColors[1]))
    }

    @Test func reverseSwapsAndRemovingTheProviderClears () throws {
        let view = makeView()
        let reverse = TerminalRowDecoration(columns: 0..<0, underline: true, inverse: true)
        let provider = WordDecorator(word: "err", decoration: reverse)
        view.setRowDecorationProvider(provider)
        view.feed(text: "an err here")
        let snapshot = TerminalSnapshot()
        refresh(snapshot, from: view)
        let before = snapshot.rows[0].revision
        let line = try render(snapshot, row: 0, view: view)
        let context = SnapshotRenderContext(viewState: FrameViewState(view: view), snapshot: snapshot)
        let decorated = line.attributes(at: 3, effectiveRange: nil)
        #expect(same(decorated[.backgroundColor], context.effectiveForegroundColor))
        #expect(decorated[.underlineStyle] != nil)

        view.setRowDecorationProvider(nil)
        refresh(snapshot, from: view)
        #expect(snapshot.rows[0].decorations.isEmpty)
        #expect(snapshot.rows[0].revision != before)
        // The buffer never saw the overlay.
        #expect(view.visibleRowsText(0..<1) == ["an err here"])
    }

    @Test func columnRangeRejectsEmptyAndOutOfBounds () {
        let request = TerminalRowDecorationRequest(row: 0, text: "ab", columns: [0, 1, 2])
        #expect(request.columnRange(utf16: 0, 2) == 0..<2)
        #expect(request.columnRange(utf16: 1, 1) == nil)
        #expect(request.columnRange(utf16: 0, 3) == nil)
    }
}
#endif
