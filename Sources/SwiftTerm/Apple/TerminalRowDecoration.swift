//
//  TerminalRowDecoration.swift
//  SwiftTerm
//
//  A per-row style overlay applied at draw time: ranges of columns drawn with
//  a different foreground, background, bold, underline or reverse video, on
//  top of the cells' own attributes. The buffer, the selection, copy, search
//  and accessibility text never see it; it changes only what is drawn.
//
//  A host supplies the ranges through a `TerminalRowDecorationProvider`. The
//  render path asks it only for the visible rows whose content changed since
//  the last frame (or all visible rows after `invalidateRowDecorations()`), so
//  an idle screen costs nothing. Keyword highlighting is the motivating use.
//

#if !SWIFTTERM_EMBEDDED
#if os(macOS) || os(iOS) || os(visionOS) || os(macCatalyst)
import Foundation

/// One styled range of a row, in buffer columns.
///
/// A `nil` color keeps the cell's own. Bold and underline are added to the
/// cell's style; `inverse` toggles reverse video. The selection and the hovered link draw on
/// top of a decoration.
public struct TerminalRowDecoration: Equatable, Hashable, Sendable {
    /// The columns covered, `lowerBound` inclusive. A wide character is
    /// covered when any of its two columns is.
    public var columns: Range<Int>
    public var foreground: Attribute.Color?
    public var background: Attribute.Color?
    public var bold: Bool
    public var underline: Bool
    /// Reverse video: the cell's colors, after `foreground` and `background`
    /// are applied, are swapped (a cell the host already shows in reverse
    /// video is drawn without it, so the range still stands out).
    public var inverse: Bool

    public init (columns: Range<Int>, foreground: Attribute.Color? = nil,
                 background: Attribute.Color? = nil, bold: Bool = false,
                 underline: Bool = false, inverse: Bool = false)
    {
        self.columns = columns
        self.foreground = foreground
        self.background = background
        self.bold = bold
        self.underline = underline
        self.inverse = inverse
    }

    /// The attribute a cell is drawn with under this decoration.
    func apply (to attribute: Attribute) -> Attribute {
        var style = attribute.style
        if bold { style.insert(.bold) }
        if underline { style.insert(.underline) }
        if inverse { style.formSymmetricDifference(.inverse) }
        return Attribute(fg: foreground ?? attribute.fg,
                         bg: background ?? attribute.bg,
                         style: style,
                         underlineStyle: attribute.underlineStyle,
                         underlineColor: underline ? nil : attribute.underlineColor)
    }
}

/// The text of one visible row, handed to a ``TerminalRowDecorationProvider``.
public struct TerminalRowDecorationRequest: Sendable {
    /// The row's buffer line (scrollback rows first), as `Terminal` numbers them.
    public let row: Int
    /// The row's text, one entry per cell (the second cell of a wide character
    /// contributes nothing), trailing empty cells left out.
    public let text: String
    /// `text.utf16.count + 1` entries: the column of the cell that holds each
    /// UTF-16 unit of `text`, then the column after the last cell. Maps a
    /// match found in `text` back to columns, wide and combining characters
    /// included.
    public let columns: [Int]

    public init (row: Int, text: String, columns: [Int]) {
        self.row = row
        self.text = text
        self.columns = columns
    }

    /// The columns covered by the UTF-16 range `lower..<upper` of `text`.
    public func columnRange (utf16 lower: Int, _ upper: Int) -> Range<Int>? {
        guard lower >= 0, upper > lower, upper < columns.count else { return nil }
        let first = columns[lower]
        let lastStart = columns[upper - 1]
        var end = columns[columns.count - 1]
        var index = upper
        while index < columns.count {
            if columns[index] > lastStart {
                end = columns[index]
                break
            }
            index += 1
        }
        return first < end ? first..<end : nil
    }
}

/// Supplies the decorations of visible rows.
///
/// Called on the render path while the terminal lock is held, possibly off the
/// main thread, once per frame with every visible row whose content changed
/// (or every visible row after ``TerminalView/invalidateRowDecorations()``).
/// It must be fast, must not call back into the terminal or the view, and
/// must return one array per request, in order. Ranges of one row should not
/// overlap; where they do, the first one wins.
public protocol TerminalRowDecorationProvider: AnyObject, Sendable {
    func rowDecorations (for rows: [TerminalRowDecorationRequest]) -> [[TerminalRowDecoration]]
}

extension TerminalView {
    /// Installs the provider of the per-row style overlay, or removes it
    /// (`nil`), and redraws the visible rows with it.
    public func setRowDecorationProvider (_ provider: (any TerminalRowDecorationProvider)?) {
        rowDecorationProvider = provider
        invalidateRowDecorations()
    }

    /// Asks the provider again for every visible row on the next frame (its
    /// rules changed, for instance). Rows that did not change are otherwise
    /// never asked twice.
    public func invalidateRowDecorations () {
        rowDecorationGeneration &+= 1
        withTerminal { $0.updateFullScreen() }
        frameDriver.markDirty()
    }

    /// The decorations each visible row is drawn with, top row first, as of a
    /// frame prepared now. For tests and diagnostics.
    public func visibleRowDecorations () -> [[TerminalRowDecoration]] {
        renderOwner.visibleRowDecorations(viewState: FrameViewState(view: self))
    }
}

extension TerminalSnapshot.Row {
    /// The request for this row's text, read from the snapshot's copy.
    func decorationRequest (row: Int, cols: Int) -> TerminalRowDecorationRequest {
        let limit = min(cols, line.count)
        var last = limit
        while last > 0 && line.packedView(at: last - 1).code == 0 {
            last -= 1
        }
        var text = ""
        var columns: [Int] = []
        columns.reserveCapacity(last + 1)
        var col = 0
        while col < last {
            let cell = line.packedView(at: col)
            let width = max(1, Int(cell.width))
            let cellText = self.text(at: col, cell: cell)
            text.append(cellText)
            for _ in 0..<cellText.utf16.count {
                columns.append(col)
            }
            col += width
        }
        columns.append(min(col, limit))
        return TerminalRowDecorationRequest(row: row, text: text, columns: columns)
    }
}
#endif
#endif // !SWIFTTERM_EMBEDDED
