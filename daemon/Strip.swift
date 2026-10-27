// The strip: windows of the current Space as columns left to right, the focused one centered on screen.
// New windows open right of the focused column, like niri. Closed ones drop out. Every Space has its own strip.
// ponytail: one window per column, no column resize.

import Cocoa

// How far the strip is scrolled, in points. Column i is centered on screen when stripOffset == columnCenters[i].
var stripOffset: CGFloat = 0

// Column centers on the strip in points, column 0 at 0. Windows keep their own width and sit `gap` apart.
func centers(of wins: [Win]) -> [CGFloat] {
    var x = -(wins.first?.frame.width ?? 0) / 2
    return wins.map { win in
        defer { x += win.frame.width + gap }
        return x + win.frame.width / 2
    }
}

// Window ids left to right, and their centers as of the last layout.
var columns: [UInt32] = []
var columnCenters: [CGFloat] = []

func focusedIndex() -> Int {
    columnCenters.indices.min { abs(columnCenters[$0] - stripOffset) < abs(columnCenters[$1] - stripOffset) } ?? 0
}

// Each Space keeps its own strip; the one in use lives in the globals above.
var currentSpace: UInt64 = 0
var savedStrips: [UInt64: (columns: [UInt32], centers: [CGFloat], offset: CGFloat)] = [:]

// Windows of every Space as of the last real look at them, for while a Space layout runs.
// ponytail: entries of closed windows stay, like sizedTo's.
var lastSeen: [UInt32: Win] = [:]

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

// immediate: "M" moves right away (used while the finger is down). Otherwise "S" sets a target and the payload eases there.
func layout(immediate: Bool) {
    let screen = CGDisplayBounds(CGMainDisplayID())
    // Between the menu bar and the Dock, minus padding. CG y grows down from the top of the main display.
    let visible = NSScreen.screens.first.map { (top: $0.frame.maxY - $0.visibleFrame.maxY, bottom: $0.visibleFrame.minY - $0.frame.minY) } ?? (0, 0)
    let top = screen.minY + visible.top + paddingTop
    let height = screen.maxY - visible.bottom - paddingBottom - top
    let centerX = screen.minX + paddingLeft + (screen.width - paddingLeft - paddingRight) / 2
    let wins = syncColumns().wins
    columnCenters = centers(of: wins)
    let maxOffset = columnCenters.last ?? 0
    let clamped = min(max(0, stripOffset), maxOffset)
    // Finger down: past the first or last column the strip stretches like rubber; the lift snaps it back.
    // Otherwise the offset is clamped for good.
    let offset = immediate ? clamped + rubberBand(stripOffset - clamped, screen.width) : clamped
    if !immediate { stripOffset = clamped }
    send(wins.enumerated().map { index, win in
        let x = centerX + columnCenters[index] - offset - win.frame.width / 2
        return "\(immediate ? "M" : "S") \(win.id) \(x) \(top)"
    })
    guard !immediate else { return }
    saveStrips()
    var resized = false
    for win in wins where sizedTo[win.id] != height {
        sizedTo[win.id] = height
        if abs(win.frame.height - height) >= 1 { setHeight(win, height); resized = true }
    }
    // An app that resizes may commit its frame at the position it last knew; put it back in its column.
    if resized { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { layout(immediate: false) } }
}

func focusColumn(at index: Int) {
    let wins = syncColumns().wins
    guard !wins.isEmpty else { return }
    let i = min(max(0, index), wins.count - 1)
    stripOffset = centers(of: wins)[i]
    layout(immediate: false)
    focus(wins[i])
}

// Keyboard: one column left or right from the column the strip is closest to.
func focusColumn(by delta: Int) {
    focusColumn(at: focusedIndex() + delta)
}
