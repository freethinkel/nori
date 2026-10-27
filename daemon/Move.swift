// Option+Shift+H/L (config: move-left, move-right): the focused window swaps places with its neighbour, keeps focus.
// Option+Shift+1…9 (config: move-to-space-N) and Option+Shift+J/K (move-to-space-down, move-to-space-up): the focused
// window goes to Desktop N or the neighbouring one; focus stays on this Space and the window joins that Space's strip
// when it is shown. A `space` rule (Rules.swift) sends a new window the same way, placeByRules below.
// The Space move runs in the payload ("X"): from the daemon's own connection neither SLSMoveWindowsToManagedSpace
// nor yabai's compat-ID trick (SLSSetWindowListWorkspace) moves a window on macOS 27.

import Cocoa

func moveColumn(by delta: Int) {
    _ = syncColumns()
    let i = focusedIndex(), j = i + delta
    guard columns.indices.contains(i), columns.indices.contains(j) else { return }
    columns.swapAt(i, j)
    focusColumn(at: j)
}

// Windows just sent to another Space, kept out of the strip until CGWindowList stops showing them here.
var movedAway: Set<UInt32> = []

func moveFocused(toDesktopBy delta: Int) {
    if let number = neighbourDesktop(delta) { moveFocused(toDesktop: number) }
}

func moveFocused(toDesktop number: Int) {
    let wins = syncColumns().wins
    let i = focusedIndex()
    guard wins.indices.contains(i), let sid = spaces().first(where: { $0.number == number })?.id, sid != currentSpace else { return }
    let moving = wins[i].id
    // Its column closes right away and the neighbour takes focus first: if the moved window's app were still
    // frontmost when the window leaves, macOS would follow it to the other Space.
    movedAway.insert(moving)
    focusColumn(at: i)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { send(["X \(moving) \(sid)"]) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { publishSoon() }  // the window on its new Space, for subscribers
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { movedAway.remove(moving) }
}

// Windows the space rules have looked at. A rule places a window once, when nori first sees it,
// so it can still be moved elsewhere by hand. That includes the windows already open when nori starts.
// ponytail: ids of closed windows stay; window ids are not reused within a session.
var placed: Set<UInt32> = []

// New windows of the current Space whose rule has a space go to that Desktop, like moveFocused does;
// returns the windows that stay. The strip's focused window takes focus back first, or macOS would
// follow the moved window to its Space (it still does when the strip is empty).
func placeByRules(_ wins: [Win], on space: UInt64) -> [Win] {
    let fresh = wins.filter { !placed.contains($0.id) }
    guard !fresh.isEmpty else { return wins }
    placed.formUnion(fresh.map(\.id))
    let current = rules
    guard current.contains(where: { $0.space != nil }) else { return wins }
    let desktops = spaces()
    let leaving: [(id: UInt32, sid: UInt64)] = fresh.compactMap { win in
        guard let number = rule(for: win, in: current)?.space,
              let sid = desktops.first(where: { $0.number == number })?.id, sid != space else { return nil }
        return (win.id, sid)
    }
    guard !leaving.isEmpty else { return wins }
    movedAway.formUnion(leaving.map(\.id))
    DispatchQueue.main.async {
        focusColumn(at: focusedIndex())
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { send(leaving.map { "X \($0.id) \($0.sid)" }) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { movedAway.subtract(leaving.map(\.id)) }
    }
    return wins.filter { win in !leaving.contains { $0.id == win.id } }
}
