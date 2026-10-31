// Which display, and which one next to it. No globals here, so `make test` checks it. Frames are CG coordinates: y
// grows down from the top of the main display, and a display left of or above it has negative ones.

import CoreGraphics

// The display a point is on, or between displays the nearest one.
func displayIndex(at point: CGPoint, in frames: [CGRect]) -> Int? {
    func distance(_ frame: CGRect) -> CGFloat {
        hypot(max(frame.minX - point.x, 0, point.x - frame.maxX), max(frame.minY - point.y, 0, point.y - frame.maxY))
    }
    return frames.firstIndex { $0.contains(point) } ?? frames.indices.min { distance(frames[$0]) < distance(frames[$1]) }
}

// The display `way` of display i, like niri's: left, right, up or down, one that overlaps it across that direction,
// the nearest by center. next and previous go round left to right, then top to bottom.
func neighbour(of i: Int, in frames: [CGRect], _ way: String) -> Int? {
    let here = frames[i]
    let others = frames.indices.filter { $0 != i }
    func nearest(_ near: (CGRect) -> CGFloat, where wanted: (CGRect) -> Bool) -> Int? {
        others.filter { wanted(frames[$0]) }.min { near(frames[$0]) < near(frames[$1]) }
    }
    let beside = { (o: CGRect) in o.minY < here.maxY && here.minY < o.maxY }
    let stacked = { (o: CGRect) in o.minX < here.maxX && here.minX < o.maxX }
    switch way {
    case "left": return nearest({ here.midX - $0.midX }) { $0.midX < here.midX && beside($0) }
    case "right": return nearest({ $0.midX - here.midX }) { $0.midX > here.midX && beside($0) }
    case "up": return nearest({ here.midY - $0.midY }) { $0.midY < here.midY && stacked($0) }
    case "down": return nearest({ $0.midY - here.midY }) { $0.midY > here.midY && stacked($0) }
    case "next", "previous":
        guard !others.isEmpty else { return nil }
        let order = frames.indices.sorted { (frames[$0].minX, frames[$0].minY) < (frames[$1].minX, frames[$1].minY) }
        let at = order.firstIndex(of: i)!
        return order[(at + (way == "next" ? 1 : order.count - 1)) % order.count]
    default: return nil
    }
}

// How far the left edge of a window this wide may go and stay on `display`. WindowServer hands a window over the
// moment its center leaves the display it is on, to the display there or, with none there, to the main one's Space
// (docs/WINDOWSERVER.md). One point in from each edge: a center exactly on it may count for the neighbour.
func keptOn(_ display: CGRect, width: CGFloat) -> ClosedRange<CGFloat> {
    (display.minX - width / 2).rounded(.up) + 1...(display.maxX - width / 2).rounded(.down) - 1
}

// A frame moved as little as it takes to have its center on `display`.
func keptFrame(_ frame: CGRect, on display: CGRect) -> CGRect {
    let across = keptOn(display, width: frame.width)
    let down = keptOn(CGRect(x: display.minY, y: 0, width: display.height, height: 0), width: frame.height)
    return CGRect(x: min(max(frame.minX, across.lowerBound), across.upperBound),
                  y: min(max(frame.minY, down.lowerBound), down.upperBound), width: frame.width, height: frame.height)
}
