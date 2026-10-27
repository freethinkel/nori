// Option+Shift+H/L (config: move-left, move-right): the focused window swaps places with its neighbour, keeps focus.
// Option+Shift+1…9 (config: move-to-space-N): the focused window goes to Desktop N; focus stays on this Space and
// the window joins that Space's strip when it is shown.
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

func moveFocused(toDesktop number: Int) {
    let wins = syncColumns().wins
    let i = focusedIndex()
    guard wins.indices.contains(i), let sid = spaces().first(where: { $0.number == number })?.id, sid != currentSpace else { return }
    send(["X \(wins[i].id) \(sid)"])
    // Once the move lands the window is gone from this Space: the next sync drops its column, the neighbour takes focus.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focusColumn(at: i) }
}
