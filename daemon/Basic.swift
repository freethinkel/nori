// Basic mode: nori without its payload in Dock (SIP on, a load that failed, a Dock that restarted). A plain process can
// still move windows, through Accessibility, and send one to another Space through the bridged operation. Fades, borders,
// 3D and Space layouts are dropped; the overview and Space layouts stay off, as they check payloadLost.

import Cocoa

func runWithoutPayload(_ problem: Problem) {
    payloadLost = true
    report(problem)
}

// What the payload would have done with these lines, as far as a plain process can. On the main thread, like send.
func withoutPayload(_ lines: [String]) {
    for line in lines {
        let f = line.split(separator: " ")
        guard f.count >= 3, let id = UInt32(f[1]) else { continue }
        if f[0] == "X", let sid = UInt64(f[2]) { moveBridged(id, to: sid) }
        if f[0] == "H", let width = Double(f[2]) {
            let rgba = f.dropFirst(3).compactMap { Double($0) }
            setBorder(id, width: width, color: rgba.count == 4 ? NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]) : nil)
        }
        guard f[0] == "S" || f[0] == "M", f.count >= 4, let x = Double(f[2]), let y = Double(f[3]), let win = lastSeen[id] else { continue }
        let lo = f.count >= 6 ? Double(f[4]) ?? -.infinity : -.infinity, hi = f.count >= 6 ? Double(f[5]) ?? .infinity : .infinity
        let move = Move(goal: CGPoint(x: x, y: y), lo: lo, hi: hi, parking: parking(win, at: CGPoint(x: x, y: y), lo: lo, hi: hi))
        let eases = f[0] == "S"
        glideQueue.async { glide(win, move, eases: eases) }
    }
}

// Where a window goes: its goal, the real x the payload would keep it in (lo…hi, see moveLimits), and where to park it.
private struct Move {
    var goal: CGPoint
    var lo, hi: CGFloat
    var parking: Parking?
}

// macOS keeps part of a window on screen, so a column past the edge would stay a sliver of it. Past the main display's
// edge it goes to that side's bottom corner instead, a point of it on screen, as AeroSpace hides windows. Only on the
// main display: elsewhere its center would leave every display, and WindowServer hands such a window to the main
// display's Space (place in payload.m). There, and where another display meets that corner, lo…hi keeps it.
private struct Parking {
    var screen: CGRect
    var left, right: CGPoint?
}

private func parking(_ win: Win, at goal: CGPoint, lo: CGFloat, hi: CGFloat) -> Parking? {
    let main = CGDisplayBounds(CGMainDisplayID()), size = win.frame.size
    let center = CGPoint(x: min(max(goal.x, lo), hi) + size.width / 2, y: goal.y + 1)
    guard displays.count == 1 || main.contains(center) else { return nil }
    func free(_ spot: CGPoint) -> CGPoint? {
        let rect = CGRect(origin: spot, size: size)
        return displays.allSatisfy { $0.frame == main || !$0.frame.intersects(rect) } ? spot : nil
    }
    return Parking(screen: main, left: free(CGPoint(x: main.minX - size.width + 1, y: main.maxY - 1)),
                   right: free(CGPoint(x: main.maxX - 1, y: main.maxY - 1)))
}

// Everything below runs on glideQueue: windows on their way, on the payload's curve. "M" lands on the next tick.
private let glideQueue = DispatchQueue(label: "nori.glide", qos: .userInteractive)
private var glides: [UInt32: (win: Win, cur: CGPoint, v: CGPoint, move: Move)] = [:]
private var parkedFrom: [UInt32: CGPoint] = [:]  // where a parked window would be, so the strip brings it back from the edge
private var tick: DispatchSourceTimer?
private var tickAt = 0.0

private func glide(_ win: Win, _ move: Move, eases: Bool) {
    var g = glides[win.id] ?? (win, move.goal, .zero, move)
    if eases && glides[win.id] == nil {
        var real = CGRect.zero
        if let from = parkedFrom[win.id] { g.cur = from } else if CGSGetWindowBounds(cid, win.id, &real) == 0 { g.cur = real.origin }
    }
    if !eases { (g.cur, g.v) = (move.goal, .zero) }
    g.move = move
    glides[win.id] = g
    guard tick == nil else { return }
    tickAt = CACurrentMediaTime()
    let source = DispatchSource.makeTimerSource(queue: glideQueue)
    source.schedule(deadline: .now(), repeating: 1.0 / 60)
    source.setEventHandler(handler: step)
    tick = source
    source.resume()
}

private func step() {
    let now = CACurrentMediaTime(), dt = min(now - tickAt, 1.0 / 30)
    tickAt = now
    for (id, var g) in glides {
        spring(&g.cur.x, &g.v.x, g.move.goal.x, dt)
        spring(&g.cur.y, &g.v.y, g.move.goal.y, dt)
        let settled = abs(g.move.goal.x - g.cur.x) < 0.5 && abs(g.move.goal.y - g.cur.y) < 0.5
            && abs(g.v.x * dt) < 0.5 && abs(g.v.y * dt) < 0.5
        if settled { g.cur = g.move.goal }
        place(g.win, at: g.cur, g.move)
        glides[id] = settled ? nil : g
    }
    if glides.isEmpty {
        tick?.cancel()
        tick = nil
    }
}

// payload/glide.h in Swift: a critically damped spring, solved exactly over dt. Keep the stiffness the same as there.
private func spring(_ x: inout CGFloat, _ v: inout CGFloat, _ goal: CGFloat, _ dt: Double) {
    let w = sqrt(800.0), e = exp(-w * dt), d = x - goal, c = v + w * d
    x = goal + (d + c * dt) * e
    v = (v - w * c * dt) * e
}

private func place(_ win: Win, at point: CGPoint, _ move: Move) {
    var real = CGPoint(x: min(max(point.x, move.lo), move.hi).rounded(), y: point.y.rounded())
    if let p = move.parking, let spot = point.x + win.frame.width <= p.screen.minX ? p.left : point.x >= p.screen.maxX ? p.right : nil {
        parkedFrom[win.id] = point
        real = spot
    } else {
        parkedFrom[win.id] = nil
    }
    let mover = movers[win.pid] ?? Mover(win.pid)
    movers[win.pid] = mover
    mover.pending[win.id] = real
    flush(mover)
}

// One serial queue per app: Accessibility waits up to 0.25 s for a hung app, and that holds only its own windows. While
// an app is busy its frames pile up as one, the last: it skips what it missed instead of catching up.
// ponytail: every app moves its own window, so neighbours can be a frame apart; the payload moves them in one transaction.
private var movers: [pid_t: Mover] = [:]

private func flush(_ mover: Mover) {
    guard !mover.busy, !mover.pending.isEmpty else { return }
    let batch = mover.pending
    mover.pending = [:]
    mover.busy = true
    mover.queue.async {
        mover.apply(batch)
        glideQueue.async {
            mover.busy = false
            flush(mover)
        }
    }
}

private final class Mover {
    let pid: pid_t
    let queue: DispatchQueue
    var busy = false                          // glideQueue's
    var pending: [UInt32: CGPoint] = [:]      // glideQueue's
    var elements: [UInt32: AXUIElement] = [:] // the rest is queue's
    var checked = false, enhancedOff = false
    var putBackWork: DispatchWorkItem?

    init(_ pid: pid_t) {
        self.pid = pid
        queue = DispatchQueue(label: "nori.ax.\(pid)", qos: .userInteractive)
    }

    // AXEnhancedUserInterface (on for Chromium and Electron apps while assistive tech is around) makes an app animate each
    // move it is told, on top of the spring. Off while windows move, back on half a second after the last move, as
    // yabai and AeroSpace do.
    func apply(_ batch: [UInt32: CGPoint]) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if !checked {
            checked = true
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, enhancedUI, &value) == .success, (value as? Bool) == true {
                enhancedOff = AXUIElementSetAttributeValue(app, enhancedUI, kCFBooleanFalse) == .success
            }
        }
        putBackWork?.cancel()
        let work = DispatchWorkItem { [self] in putBack() }
        putBackWork = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
        if batch.keys.contains(where: { elements[$0] == nil }) {  // a fresh list drops the closed ones too
            elements = [:]
            for element in axWindows(pid) ?? [] {
                guard let id = axID(element) else { continue }
                AXUIElementSetMessagingTimeout(element, 0.25)
                elements[id] = element
            }
        }
        for (id, point) in batch {
            var origin = point
            guard let element = elements[id], let value = AXValueCreate(.cgPoint, &origin) else { continue }
            if AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .invalidUIElement { elements[id] = nil }
        }
    }

    func putBack() {
        checked = false
        guard enhancedOff else { return }
        enhancedOff = false
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), enhancedUI, kCFBooleanTrue)
    }
}

private let enhancedUI = "AXEnhancedUserInterface" as CFString

// Quitting: apps get AXEnhancedUserInterface back now, not after a delay the exit would cut short.
func putBackEnhancedUI() {
    glideQueue.sync {
        for mover in movers.values {
            mover.queue.sync {
                mover.putBackWork?.cancel()
                mover.putBack()
            }
        }
    }
}

// Borders ("H") without Dock: a window of nori's at level -1, under every app's, so the stroke shows in the strip's gap
// as the payload's does from Dock. On every Space, and shown while its target is on screen. A timer follows the target's
// frame whatever moved it (a glide, the app, the user), as border_poll does in the payload. On the main thread.
// ponytail: one CGWindowList read per border per tick; with border-inactive on many windows, read them in one call.
private var borders: [UInt32: NSWindow] = [:]
private var borderTimer: Timer?
private let borderGap: CGFloat = 1.5  // BORDER_GAP in payload.m

private func setBorder(_ id: UInt32, width: CGFloat, color: NSColor?) {
    guard width > 0, let color else {
        borders.removeValue(forKey: id)?.orderOut(nil)
        return
    }
    let window = borders[id] ?? {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: -1)
        window.collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .fullScreenNone]
        window.contentView?.wantsLayer = true
        return window
    }()
    borders[id] = window
    let ring = window.contentView!.layer!
    ring.borderWidth = width
    ring.borderColor = color.cgColor
    ring.cornerCurve = .continuous
    ring.cornerRadius = cornerRadius(id) + width + borderGap
    followBorders()
    guard borderTimer == nil else { return }
    borderTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in followBorders() }
}

private func followBorders() {
    let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
    for (id, window) in borders {
        guard let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
              let bounds = info[kCGWindowBounds as String] as? NSDictionary, let frame = CGRect(dictionaryRepresentation: bounds) else {
            borders.removeValue(forKey: id)?.orderOut(nil)  // closed
            continue
        }
        // Parked in a corner (place) or on another Space: no border.
        let shown = info[kCGWindowIsOnscreen as String] as? Bool == true
            && displays.contains { let part = $0.frame.intersection(frame); return part.width > 40 && part.height > 40 }
        let outset = window.contentView!.layer!.borderWidth + borderGap
        let outer = frame.insetBy(dx: -outset, dy: -outset)
        let cocoa = CGRect(x: outer.minX, y: mainHeight - outer.maxY, width: outer.width, height: outer.height)
        if window.frame != cocoa { window.setFrame(cocoa, display: false) }
        if shown != window.isVisible { shown ? window.orderFront(nil) : window.orderOut(nil) }
    }
    if borders.isEmpty {
        borderTimer?.invalidate()
        borderTimer = nil
    }
}

// The payload is back and draws its own: nori's go.
func dropBasicBorders() {
    borders.values.forEach { $0.orderOut(nil) }
    borders = [:]
}

// WindowServer's corner radius of a window; works from a plain process for any app's window (docs/WINDOWSERVER.md).
// Looked up at run time: SkyLight isn't linked into the daemon.
private func cornerRadius(_ id: UInt32) -> CGFloat {
    typealias Query = @convention(c) (Int32, CFArray, Int32) -> Unmanaged<CFTypeRef>?
    typealias Copy = @convention(c) (CFTypeRef) -> Unmanaged<CFTypeRef>?
    typealias Count = @convention(c) (CFTypeRef) -> Int32
    typealias Radii = @convention(c) (CFTypeRef, Int) -> Unmanaged<CFArray>?
    guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let q = dlsym(sky, "SLSWindowQueryWindows"), let c = dlsym(sky, "SLSWindowQueryResultCopyWindows"),
          let n = dlsym(sky, "SLSWindowIteratorGetCount"), let r = dlsym(sky, "SLSWindowIteratorGetCornerRadii"),
          let query = unsafeBitCast(q, to: Query.self)(cid, [id] as CFArray, 0)?.takeRetainedValue(),
          let iterator = unsafeBitCast(c, to: Copy.self)(query)?.takeRetainedValue(),
          unsafeBitCast(n, to: Count.self)(iterator) > 0,
          let radii = unsafeBitCast(r, to: Radii.self)(iterator, 0)?.takeRetainedValue() as? [Double]
    else { return 0 }
    return radii.first ?? 0
}

// Works from a plain process on another process's window, see "Moving a window to another Space" in docs/WINDOWSERVER.md.
// Raw pointers keep ARC out of alloc/init, which hand over ownership as Swift doesn't expect.
func moveBridged(_ id: UInt32, to sid: UInt64) {
    typealias Init = @convention(c) (UnsafeMutableRawPointer, Selector, NSArray, UInt64) -> UnsafeMutableRawPointer?
    let initWith = NSSelectorFromString("initWithWindows:spaceID:")
    guard let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
          let method = class_getInstanceMethod(cls, initWith),
          let allocated = (cls as AnyObject).perform(NSSelectorFromString("alloc"))?.toOpaque(),
          let made = unsafeBitCast(method_getImplementation(method), to: Init.self)(allocated, initWith, [id] as NSArray, sid)
    else { return }
    _ = Unmanaged<AnyObject>.fromOpaque(made).takeRetainedValue().perform(NSSelectorFromString("performWithWMBridgeDelegate"))
}
