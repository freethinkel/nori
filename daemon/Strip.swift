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

// Each Space keeps its own strip; the one in use lives in the globals above. That is the focused display's, unless
// onStrip has put another one there.
var currentSpace: UInt64 = 0
var savedStrips: [UInt64: (columns: [UInt32], centers: [CGFloat], offset: CGFloat)] = [:]
var stripSpace: UInt64?  // set by onStrip

func swapStrip(to space: UInt64) {
    guard space != currentSpace else { return }
    savedStrips[currentSpace] = (columns, columnCenters, stripOffset)
    (columns, columnCenters, stripOffset) = savedStrips[space] ?? ([], [], 0)
    currentSpace = space
}

// Runs body with the strip of a Space on another display in use. It must be on screen: syncColumns goes by the
// on-screen windows, and would empty a strip that isn't.
func onStrip<T>(_ space: UInt64, _ body: () -> T) -> T {
    let outer = stripSpace
    stripSpace = space
    swapStrip(to: space)
    defer {
        stripSpace = outer
        swapStrip(to: outer ?? CGSGetActiveSpace(cid))
    }
    return body()
}

// What the displays without focus show.
func otherStrips() -> [UInt64] {
    guard displays.count > 1 else { return [] }
    let active = CGSGetActiveSpace(cid)
    return displays.map(\.current).filter { $0 != active }
}

// Every strip on screen, after something that may have moved windows on any display.
func layoutAll() {
    refreshDisplays()
    layout(immediate: false)
    for space in otherStrips() { onStrip(space) { layout(immediate: false) } }
}

// Animations run on the vsync of one display ("L"): the one a Space layout is on, or else the one that has focus.
var timedTo: CGDirectDisplayID = 0

func timeAnimations(to display: CGDirectDisplayID) {
    guard display != timedTo else { return }
    timedTo = display
    send(["L \(display)"])
}

// With separate Spaces off the payload hears nothing, and Dock keeps its own slide: its hooks only know one display
// at a time.
func tellPayload() { if separateSpaces { send(["P \(getpid())", "L \(timedTo)"] + displayLines()) } }

// Windows that came or went on the displays without focus. Nothing takes focus there: a new window is just shown.
func pollDisplays() {
    refreshDisplays()
    timeAnimations(to: display(of: CGSGetActiveSpace(cid)).id)
    for space in otherStrips() {
        onStrip(space) {
            let before = columns
            let sync = syncColumns()
            if let index = sync.inserted {
                stripFocus[space] = sync.wins[index].id
                stripOffset = scroll(sync.wins).rest(index, from: stripOffset, previous: nil)
            }
            if columns != before { layout(immediate: false) }
        }
    }
}

// Windows of every Space as of the last real look at them, for while a Space layout runs.
// ponytail: entries of closed windows stay, like sizedTo's.
var lastSeen: [UInt32: Win] = [:]

// Frame of each strip window when nori first saw it, for restoreWindows. Kept in strips.json (Persist.swift), so a
// nori started after a crash still knows where the windows were before nori.
// ponytail: entries of closed windows stay, like sizedTo's.
var originalFrames: [UInt32: CGRect] = [:]

// Drops closed windows and inserts new ones right of the focused column.
// Returns live windows in column order, where the last new window went, and the frontmost window.
// While the overview or a Space slide is on, CGWindowList reports frames after the Space transform (scaled,
// moved, other Spaces' windows on screen), so the strip keeps the frames it saw last and changes nothing.
func syncColumns() -> (wins: [Win], inserted: Int?, front: UInt32?) {
    // The Space id is right even mid-slide, so the strip follows it first: keeping the old Space's strip there made
    // Option+H/L focus a window of the old Space, and macOS switched back to it.
    let space = stripSpace ?? CGSGetActiveSpace(cid)
    swapStrip(to: space)
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

// Strip windows keep the strip's height. Per window: the height it was last asked for, and the height it took then
// (read back; nil until the app answers). A window at another height is asked again, so one resized by hand goes
// back; one that refuses or clamps (fixed size, min/max limits, a terminal's cell steps) stays at what it took and
// isn't asked over and over. The first ask also sets the width a `width` rule asks for, counted like the presets
// so 50 + 50 fill the usable width exactly.
// ponytail: entries of closed windows stay; window ids are not reused within a session.
var sizedTo: [UInt32: (height: CGFloat, took: CGFloat?)] = [:]

func needsHeight(_ win: Win, _ height: CGFloat) -> Bool {
    guard let asked = sizedTo[win.id], asked.height == height else { return true }
    guard let took = asked.took else { return false }  // the app hasn't answered yet
    return abs(win.frame.height - height) >= 1 && abs(win.frame.height - took) >= 1
}

func ruleWidth(_ win: Win) -> CGFloat? {
    let current = rules
    guard current.contains(where: { $0.width != nil }), let percent = rule(for: win, in: current)?.width else { return nil }
    return (usableWidth + gap) * percent / 100 - gap
}

// How far the strip shows when dragged `over` points past its end: the further, the less it moves (UIScrollView's curve).
func rubberBand(_ over: CGFloat, _ dimension: CGFloat) -> CGFloat {
    let pulled = dimension * (1 - 1 / (abs(over) / dimension * 0.55 + 1))
    return over < 0 ? -pulled : pulled
}

var instantMoves = false  // a `--instant` request is being handled: "M" instead of "S", with the usual bookkeeping

// With another display around, a window must not really cross the edge of its own (keptOn in Scroll.swift): " lo hi"
// for "S" and "M" says how far it may go, and the payload draws the rest. Nothing with one display: no limit.
func moveLimits(_ width: CGFloat, on frame: CGRect? = nil) -> String {
    guard displays.count > 1 else { return "" }
    let range = keptOn(frame ?? display(of: currentSpace).frame, width: width)
    return " \(range.lowerBound) \(range.upperBound)"
}

// Where a window drawn at x really is. CGWindowList gives the drawn x, Accessibility moves the real window.
func realX(_ x: CGFloat, width: CGFloat) -> CGFloat {
    guard displays.count > 1 else { return x }
    let range = keptOn(display(of: currentSpace).frame, width: width)
    return min(max(x, range.lowerBound), range.upperBound)
}

// Between the menu bar and the Dock, minus padding, on the strip's display. Each display has its own menu bar, the
// Dock is on one. CG y grows down from the top of the main display.
func stripArea() -> CGRect {
    let shown = display(of: currentSpace)
    let screen = shown.frame
    let visible = nsScreen(of: shown).map { (top: $0.frame.maxY - $0.visibleFrame.maxY, bottom: $0.visibleFrame.minY - $0.frame.minY) } ?? (0, 0)
    let top = screen.minY + visible.top + padding("padding-top", on: shown.name)
    return CGRect(x: screen.minX + padding("padding-left", on: shown.name), y: top, width: paddedWidth(of: shown),
                  height: screen.maxY - visible.bottom - padding("padding-bottom", on: shown.name) - top)
}

// immediate: "M" moves right away (used while the finger is down). Otherwise "S" sets a target and the payload eases there.
func layout(immediate: Bool) {
    let wins = syncColumns().wins
    let screen = display(of: currentSpace).frame
    let area = stripArea()
    let top = area.minY, height = area.height, centerX = area.midX
    let strip = scroll(wins), bounds = strip.bounds
    columnCenters = strip.centers
    let clamped = min(max(bounds.lowerBound, stripOffset), bounds.upperBound)
    // Finger down: past the first or last column the strip stretches like rubber; the lift snaps it back.
    // Otherwise the offset is clamped for good.
    let offset = immediate ? clamped + rubberBand(stripOffset - clamped, screen.width) : clamped
    if !immediate { stripOffset = clamped }
    send(wins.enumerated().map { index, win in
        let x = centerX + columnCenters[index] - offset - win.frame.width / 2
        return "\(immediate || instantMoves ? "M" : "S") \(win.id) \(x) \(top)\(moveLimits(win.frame.width))"
    })
    guard !immediate else { return }
    saveStrips()
    publishSoon()
    dimUnfocused(wins)
    var resized = false
    for win in wins where needsHeight(win, height) {
        let width = sizedTo[win.id] == nil ? ruleWidth(win) ?? win.frame.width : win.frame.width
        guard abs(win.frame.height - height) >= 1 || abs(win.frame.width - width) >= 1 else {
            sizedTo[win.id] = (height, height)
            continue
        }
        sizedTo[win.id] = (height, nil)
        pendingWidths[win.id] = width
        let x = realX(win.frame.minX, width: width)
        axQueue.async {  // off the main thread: a hung app must not stall the strip
            let took = setFrame(win, CGRect(x: x, y: top, width: width, height: height))
            // No answer: the height it had counts as taken, so a hung app isn't asked on every layout.
            DispatchQueue.main.async { if sizedTo[win.id]?.height == height { sizedTo[win.id]?.took = took?.height ?? win.frame.height } }
        }
        resized = true
    }
    // An app that resizes may commit its frame at the position it last knew; put it back in its column.
    if resized {
        let space = currentSpace
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            refreshDisplays()
            if otherStrips().contains(space) { onStrip(space) { layout(immediate: false) } } else { layout(immediate: false) }
        }
    }
}

// inactive-opacity: the strip's unfocused windows are translucent, the focused one opaque, so the focus shows.
// Alpha is set in WindowServer, the app never knows: the payload fades it ("E"), quitting sets it back at once ("A").
// A window that left the strip gets its alpha back.
// ponytail: a window the app itself made translucent is set back to 1 when focused.
var alphaSet: [UInt32: Float] = [:]

func dimUnfocused(_ wins: [Win]) {
    let focused = wins.indices.contains(focusedIndex()) ? wins[focusedIndex()].id : nil
    var wanted = Dictionary(wins.map { ($0.id, $0.id == focused ? 1 : inactiveOpacity) }, uniquingKeysWith: { a, _ in a })
    let elsewhere = Set(savedStrips.values.flatMap(\.columns))
    for (id, alpha) in alphaSet where alpha != 1 && wanted[id] == nil && !elsewhere.contains(id) { wanted[id] = 1 }
    // While it is on, a window nori hasn't set yet gets its alpha once too: after a crash it may still be dimmed.
    let changes = wanted.filter { alphaSet[$0.key] ?? (inactiveOpacity < 1 ? nil : 1) != $0.value }
    guard !changes.isEmpty else { return }
    send(changes.map { "E \($0.key) \(alphaSet[$0.key] ?? 1) \($0.value)" })  // the payload fades on vsync
    alphaSet.merge(changes) { _, new in new }
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

// Keyboard: one column left or right from the column the strip is closest to; past either end with wrap-around,
// the other end.
func focusColumn(by delta: Int) {
    let i = focusedIndex() + delta
    focusColumn(at: wrapAround && !columns.isEmpty ? (i + columns.count) % columns.count : i)
}

// Option+C (config: center-column), niri's center-column: the focused column scrolls to the center whatever
// center-focused-column says. ponytail: within the strip's bounds, so in "never" the first and last column stay put.
func centerColumn() {
    let wins = syncColumns().wins, i = focusedIndex()
    guard wins.indices.contains(i) else { return }
    focusColumn(at: i, offset: scroll(wins).centers[i])
}

// Option+Shift+V (config: toggle-floating), niri's toggle-window-floating: the focused window leaves the strip, its
// neighbours close the gap, and it floats in the middle of the screen at 2/3 of the strip's width and height. The next
// press, on that window, puts it back right of the focused column at the width it had there. Kept in strips.json.
var floatingByHand: [UInt32: CGFloat] = [:]  // window → its column width

func toggleFloating() {
    guard let id = focusedWindowID() else { return }
    if let width = floatingByHand.removeValue(forKey: id) {
        sizedTo[id] = nil  // the layout stretches it to the strip's height again
        pendingWidths[id] = width
        if let i = syncColumns().inserted { focusColumn(at: i) }
        return
    }
    guard let win = syncColumns().wins.first(where: { $0.id == id }) else { return }  // out of the strip already
    floatingByHand[id] = win.frame.width
    layout(immediate: false)
    lastFront = syncColumns().front  // the strip has a new front window, but focus stays on this one: not poll's to follow
    let area = stripArea()
    let frame = CGRect(x: area.midX - area.width / 3, y: area.midY - area.height / 3, width: area.width * 2 / 3, height: area.height * 2 / 3)
    send(["M \(id) \(frame.minX) \(frame.minY)"])  // drops the payload's ease toward its old column
    axQueue.async { setFrame(win, frame) }
}

// Quit: strip windows go back to the frames they had before nori. The payload puts every one back in place (and drops
// its ease); Accessibility reaches only the current Space, so windows on other Spaces keep the size nori gave them.
func restoreWindows() {
    refreshDisplays()
    let open = Dictionary(listWindows([]).map { ($0.win.id, $0.spaces[0]) }, uniquingKeysWith: { a, _ in a })
    var back: [UInt32: CGRect] = [:]
    for (id, frame) in originalFrames {
        // A frame saved mid-scroll can lie past every display, and macOS would hand the window to the main one.
        if let space = open[id] { back[id] = displays.count > 1 ? keptFrame(frame, on: display(of: space).frame) : frame }
    }
    send(back.map { "M \($0.key) \($0.value.minX) \($0.value.minY)" } + alphaSet.filter { $0.value != 1 }.map { "A \($0.key) 1" })
    for (id, frame) in back {
        if let win = lastSeen[id] { setFrame(win, frame) }
    }
}
