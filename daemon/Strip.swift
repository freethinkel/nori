// The strip: windows of the current Space as columns left to right, the focused one centered on screen, or just
// on screen whole (center-focused-column, Scroll.swift).
// New windows open right of the focused column, like niri. Closed ones drop out. Every Space has its own strip.
// ponytail: one window per column.

import Cocoa

// How far the strip is scrolled, in points. Column i is centered on screen when stripOffset == columnCenters[i].
var stripOffset: CGFloat = 0

// Column geometry and rest points of these windows with the current settings, see Scroll.swift.
func scroll(_ wins: [Win]) -> Scroll {
    Scroll(widths: wins.map(\.frame.width), view: usableWidth, gap: gap, mode: centerFocusedColumn, centerSingle: alwaysCenterSingleColumn)
}

// Window ids left to right, and their centers as of the last layout.
var columns: [UInt32] = []
var columnCenters: [CGFloat] = []

// The window focus last went to on each Space's strip. Off center unless center-focused-column is "always".
var stripFocus: [UInt64: UInt32] = [:]

// Its column, or the one nearest the center when it is gone.
func focusedIndex() -> Int {
    if let id = stripFocus[currentSpace], let i = columns.firstIndex(of: id) { return i }
    return columnCenters.indices.min { abs(columnCenters[$0] - stripOffset) < abs(columnCenters[$1] - stripOffset) } ?? 0
}

// Each Space keeps its own strip; the one in use lives in the globals above.
var currentSpace: UInt64 = 0
var savedStrips: [UInt64: (columns: [UInt32], centers: [CGFloat], offset: CGFloat)] = [:]

// Windows of every Space as of the last real look at them, for while a Space layout runs.
// ponytail: entries of closed windows stay, like sizedTo's.
var lastSeen: [UInt32: Win] = [:]

// Frame of each strip window when nori first saw it, for restoreWindows.
// ponytail: entries of closed windows stay, like sizedTo's; a crash loses them.
var originalFrames: [UInt32: CGRect] = [:]

// Drops closed windows and inserts new ones right of the focused column.
// Returns live windows in column order, where the last new window went, and the frontmost window.
// While the overview or a Space slide is on, CGWindowList reports frames after the Space transform (scaled,
// moved, other Spaces' windows on screen), so the strip keeps the frames it saw last and changes nothing.
func syncColumns() -> (wins: [Win], inserted: Int?, front: UInt32?) {
    // The active Space id is right even mid-slide, so the strip follows it first: keeping the old Space's strip
    // there made Option+H/L focus a window of the old Space, and macOS switched back to it.
    let space = CGSGetActiveSpace(cid)
    if space != currentSpace {
        savedStrips[currentSpace] = (columns, columnCenters, stripOffset)
        (columns, columnCenters, stripOffset) = savedStrips[space] ?? ([], [], 0)
        currentSpace = space
    }
    guard !spaceLayoutBusy else { return (withPendingWidths(columns.compactMap { lastSeen[$0] }), nil, nil) }
    let live = placeByRules(windows(on: space), on: space).filter { !movedAway.contains($0.id) }
    let byId = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    lastSeen.merge(byId) { _, new in new }
    for win in live where originalFrames[win.id] == nil { originalFrames[win.id] = win.frame }
    columns.removeAll { byId[$0] == nil }
    var at = min(focusedIndex() + 1, columns.count)
    var inserted: Int?
    for id in byId.keys.sorted() where !columns.contains(id) {
        columns.insert(id, at: at)
        inserted = at
        at += 1
    }
    // CGWindowList is ordered front to back, so the first window is the focused one.
    return (withPendingWidths(columns.compactMap { byId[$0] }), inserted, live.first?.id)
}

// Height each window was last resized to. One try per window and height, so a window that refuses
// (fixed size, min/max limits) or that the user resized by hand is left alone.
// ponytail: entries of closed windows stay; window ids are not reused within a session.
var sizedTo: [UInt32: CGFloat] = [:]

// How far the strip shows when dragged `over` points past its end: the further, the less it moves (UIScrollView's curve).
func rubberBand(_ over: CGFloat, _ dimension: CGFloat) -> CGFloat {
    let pulled = dimension * (1 - 1 / (abs(over) / dimension * 0.55 + 1))
    return over < 0 ? -pulled : pulled
}

var instantMoves = false  // a `--instant` request is being handled: "M" instead of "S", with the usual bookkeeping

// immediate: "M" moves right away (used while the finger is down). Otherwise "S" sets a target and the payload eases there.
func layout(immediate: Bool) {
    let screen = CGDisplayBounds(CGMainDisplayID())
    // Between the menu bar and the Dock, minus padding. CG y grows down from the top of the main display.
    let visible = NSScreen.screens.first.map { (top: $0.frame.maxY - $0.visibleFrame.maxY, bottom: $0.visibleFrame.minY - $0.frame.minY) } ?? (0, 0)
    let top = screen.minY + visible.top + paddingTop
    let height = screen.maxY - visible.bottom - paddingBottom - top
    let centerX = screen.minX + paddingLeft + (screen.width - paddingLeft - paddingRight) / 2
    let wins = syncColumns().wins
    let strip = scroll(wins), bounds = strip.bounds
    columnCenters = strip.centers
    let clamped = min(max(bounds.lowerBound, stripOffset), bounds.upperBound)
    // Finger down: past the first or last column the strip stretches like rubber; the lift snaps it back.
    // Otherwise the offset is clamped for good.
    let offset = immediate ? clamped + rubberBand(stripOffset - clamped, screen.width) : clamped
    if !immediate { stripOffset = clamped }
    send(wins.enumerated().map { index, win in
        let x = centerX + columnCenters[index] - offset - win.frame.width / 2
        return "\(immediate || instantMoves ? "M" : "S") \(win.id) \(x) \(top)"
    })
    guard !immediate else { return }
    saveStrips()
    publishSoon()
    var resized = false
    for win in wins where sizedTo[win.id] != height {
        sizedTo[win.id] = height
        if abs(win.frame.height - height) >= 1 { setHeight(win, height); resized = true }
    }
    // An app that resizes may commit its frame at the position it last knew; put it back in its column.
    if resized { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { layout(immediate: false) } }
}

// offset: where the strip comes to rest, if not where center-focused-column puts column `index` (a gesture's snap).
func focusColumn(at index: Int, offset: CGFloat? = nil) {
    let wins = syncColumns().wins
    guard !wins.isEmpty else { return }
    let i = min(max(0, index), wins.count - 1)
    stripOffset = offset ?? scroll(wins).rest(i, from: stripOffset, previous: focusedIndex())
    stripFocus[currentSpace] = wins[i].id
    layout(immediate: false)
    focus(wins[i])
}

// Keyboard: one column left or right from the column the strip is closest to.
func focusColumn(by delta: Int) {
    focusColumn(at: focusedIndex() + delta)
}

// Quit: strip windows go back to the frames they had before nori. The payload puts every one back in place (and drops
// its ease); Accessibility reaches only the current Space, so windows on other Spaces keep the size nori gave them.
func restoreWindows() {
    let open = Set(listWindows([]).map(\.win.id))
    let back = originalFrames.filter { open.contains($0.key) }
    send(back.map { "M \($0.key) \($0.value.minX) \($0.value.minY)" })
    for (id, frame) in back {
        guard let win = lastSeen[id], let element = axElement(win) else { continue }
        var size = frame.size, origin = frame.origin
        if let value = AXValueCreate(.cgSize, &size) { AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) }
        if let value = AXValueCreate(.cgPoint, &origin) { AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) }
    }
}
