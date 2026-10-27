// Where the strip may rest, after niri's and OmniWM's center-focused-column: "always" centers the focused column;
// "never" scrolls only as far as it takes to show it whole, against the left or right padding; "on-overflow" centers
// it when it doesn't fit on screen beside the neighbour on the side focus came from, else acts like "never".
// always-center-single-column centers a lone column whatever the mode. No globals here, so `make test` checks it.
// Offsets are strip points at the center of the usable width, column 0's center at 0 (stripOffset, Strip.swift).

import CoreGraphics

struct Scroll {
    let widths: [CGFloat]  // columns left to right
    let view: CGFloat      // the usable width: screen minus padding
    let gap: CGFloat
    let mode: String       // "always", "never" or "on-overflow"
    let centerSingle: Bool
    let centers: [CGFloat]  // windows keep their own width and sit `gap` apart

    init(widths: [CGFloat], view: CGFloat, gap: CGFloat, mode: String, centerSingle: Bool) {
        (self.widths, self.view, self.gap, self.mode, self.centerSingle) = (widths, view, gap, mode, centerSingle)
        var x = -(widths.first ?? 0) / 2
        centers = widths.map { width in
            defer { x += width + gap }
            return x + width / 2
        }
    }

    var centering: Bool { mode == "always" || widths.count == 1 && centerSingle }
    func left(_ i: Int) -> CGFloat { centers[i] - widths[i] / 2 + view / 2 }   // column i against the left padding
    func right(_ i: Int) -> CGFloat { centers[i] + widths[i] / 2 - view / 2 }  // and against the right one
    func whole(_ i: Int, at offset: CGFloat) -> Bool { right(i) <= offset && offset <= left(i) }

    func overflows(_ i: Int, beside n: Int) -> Bool {
        mode == "on-overflow" && widths.indices.contains(n) && widths[i] + gap + widths[n] > view
    }

    // From the first column to the last, each where the mode rests it.
    var bounds: ClosedRange<CGFloat> {
        guard let last = widths.indices.last else { return 0...0 }
        if centering { return centers[0]...centers[last] }
        let lo = left(0), hi = max(lo, right(last))
        return mode == "never" ? lo...hi : min(lo, centers[0])...max(hi, centers[last])
    }

    // Where the strip rests with column i focused, scrolled to `offset` now, focus coming from column `previous`.
    func rest(_ i: Int, from offset: CGFloat, previous: Int?) -> CGFloat {
        if centering { return centers[i] }
        if let p = previous, p != i, overflows(i, beside: p > i ? i + 1 : i - 1) { return centers[i] }
        if widths[i] >= view { return left(i) }
        if whole(i, at: offset) { return offset }
        return abs(offset - left(i)) <= abs(offset - right(i)) ? left(i) : right(i)
    }

    // Gesture lift: the rest point nearest `offset` and the column it focuses. Centered columns when centering; else
    // each column against either padding, or centered where it doesn't fit beside the neighbour on that side
    // (OmniWM's snap points). Not centering, the focused column keeps focus if it shows whole there.
    func snap(_ offset: CGFloat, focused: Int) -> (offset: CGFloat, index: Int) {
        let b = bounds
        let points = widths.indices.flatMap { i -> [(offset: CGFloat, index: Int)] in
            centering ? [(centers[i], i)]
                : [(overflows(i, beside: i + 1) ? centers[i] : left(i), i), (overflows(i, beside: i - 1) ? centers[i] : right(i), i)]
        }.map { (offset: min(max($0.offset, b.lowerBound), b.upperBound), index: $0.index) }
        guard let best = points.min(by: { abs($0.offset - offset) < abs($1.offset - offset) }) else { return (0, 0) }
        if !centering, widths.indices.contains(focused), whole(focused, at: best.offset) { return (best.offset, focused) }
        return best
    }
}
