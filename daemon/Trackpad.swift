// Trackpad gestures from raw touches: the strip, Spaces and the overview follow the swipes the gesture keys give them,
// see Config.swift. The event tap swallows macOS's own gesture events on those finger counts as far as it can; Mission
// Control and App Exposé still have to be off in System Settings (App.swift asks, README has the steps).

import Cocoa

// The strip follows the centroid of the fingers. On lift it is thrown by the last finger speed and snaps to the nearest
// rest point (Scroll.snap).
// ponytail: one trackpad at a time; frames from a second trackpad would interleave with the first.
var fingerCount: Int32 = 0

// Mission Control and App Exposé get their swipe as NSEventTypeSwipe (31) after the fingers lift, when fingerCount is
// already 0. Keep swallowing for a moment after a frame of ours, so the end of our gesture reaches nobody else.
let systemGestureLinger: CFTimeInterval = 0.25
var systemGestureUntil: CFTimeInterval = 0
var systemGestureFingers: Int32 = 0  // the fingers of that frame

// macOS keeps the swipes of a finger count no action is on.
func swallowSystemGesture() -> Bool {
    ourGesture(fingerCount) || CACurrentMediaTime() < systemGestureUntil && ourGesture(systemGestureFingers)
}

var swipeScale: CGFloat { CGDisplayBounds(CGMainDisplayID()).width * swipeSpeed }  // points per full trackpad width
let swipeThreshold: CGFloat = 0.02  // trackpad widths before the direction is decided

var gestureActive = false
var swipeIgnored = false  // no action is on this swipe

// Spaces, like niri's workspaces. They follow the fingers (rubber past the first and last);
// on lift the nearest one, or the next one for a flick, slides to the center like windows do, and Dock switches to it.
var spaceSwiping = false
var spaceSwipeFocus: CGFloat = 0     // index of the Space at the center, fractional
var spaceSwipeVelocity: CGFloat = 0  // Spaces per second, smoothed
var spaceSwipeTime: CFTimeInterval = 0
var lastCenter: CGPoint?
var lastSpread: CGFloat = 0
var swipeTravel = CGPoint.zero
var swipePinch: CGFloat = 0  // before the swipe starts, fingers closing in counting up
var swipeVelocity: CGFloat = 0  // points per frame, smoothed

// The overview follows a swipe like niri's, up opens and down closes, or a pinch, closing in opens and spreading closes.
// On lift it springs open or closed, thrown by the finger speed. macOS's own gestures (Mission Control, App Exposé,
// Spaces) are swallowed in the event tap on that finger count and just after, so they don't fire too.
var overviewSwiping = false
var overviewPinch = false  // this one goes by how far apart the fingers are
var overviewSwipeProgress: CGFloat = 0
var overviewSwipeVelocity: CGFloat = 0  // progress per second, smoothed
var overviewSwipeTime: CFTimeInterval = 0
var lastTouchCount: Int32 = 0

func endSwipe() {
    if overviewSwiping {
        overviewSwiping = false
        // A flick decides by its direction; a slow lift by how far the overview is open.
        let open = abs(overviewSwipeVelocity) > 1.5 ? overviewSwipeVelocity > 0 : overviewSwipeProgress > 0.5
        endOverviewSwipe(open: open)
    }
    if gestureActive {
        gestureActive = false
        // ponytail: fixed throw; real momentum would decay over frames
        let rest = scroll(syncColumns().wins).snap(stripOffset - swipeVelocity * 8, focused: focusedIndex())
        focusColumn(at: rest.index, offset: rest.offset)
    }
    if spaceSwiping {
        spaceSwiping = false
        endSpaceSwipe(focus: spaceSwipeFocus, velocity: spaceSwipeVelocity)
    }
}

// Main thread. center is the normalized (0...1) centroid of the touches, or nil when there are none; spread is how far
// apart they are. time is the trackpad's own (seconds): frames reach the main thread in bunches, which made speeds jump.
func touchFrame(count: Int32, center: CGPoint?, spread: CGFloat = 0, time: CFTimeInterval = 0) {
    defer { lastTouchCount = count }
    // A finger landing or lifting ends the swipe. The centroid jumps then, so the next one counts from the frame after.
    guard ourGesture(count), count == lastTouchCount || lastCenter == nil, let center else {
        endSwipe()
        swipeIgnored = false
        lastCenter = nil
        swipeTravel = .zero
        swipePinch = 0
        swipeVelocity = 0
        return
    }
    defer {
        lastCenter = center
        lastSpread = spread
    }
    guard let last = lastCenter, !swipeIgnored else { return }
    let dx = center.x - last.x, dy = center.y - last.y  // normalized y grows towards the top of the trackpad
    let pinch = lastSpread - spread
    if overviewSwiping {
        let delta = (overviewPinch ? pinch : dy) / overviewSwipeDistance
        overviewSwipeProgress += delta
        overviewSwipeVelocity = overviewSwipeVelocity * 0.5 + delta / CGFloat(max(time - overviewSwipeTime, 1.0 / 240)) * 0.5
        overviewSwipeTime = time
        followOverviewSwipe(progress: overviewSwipeProgress, velocity: overviewSwipeVelocity)
        return
    }
    if spaceSwiping {
        // Fingers up: the Space below comes up into view, so content follows the fingers.
        let delta = dy / spaceSwipeDistance
        spaceSwipeFocus += delta
        spaceSwipeVelocity = spaceSwipeVelocity * 0.5 + delta / CGFloat(max(time - spaceSwipeTime, 1.0 / 240)) * 0.5
        spaceSwipeTime = time
        followSpaceSwipe(focus: spaceSwipeFocus, velocity: spaceSwipeVelocity)
        return
    }
    if !gestureActive {
        swipeTravel.x += dx
        swipeTravel.y += dy
        swipePinch += pinch
        let pinchable = swipeAction(fingers: count, kind: "pinch") != nil
        let moved = max(abs(swipeTravel.x), abs(swipeTravel.y))
        guard moved >= swipeThreshold || pinchable && abs(swipePinch) >= swipeThreshold else { return }
        let kind = pinchable && abs(swipePinch) > moved ? "pinch" : abs(swipeTravel.y) > abs(swipeTravel.x) ? "vertical" : "sideways"
        switch swipeAction(fingers: count, kind: kind) {
        case "gesture-overview":
            overviewSwiping = true
            overviewPinch = kind == "pinch"
            overviewSwipeProgress = overviewOpen ? 1 : 0
            overviewSwipeVelocity = 0
            overviewSwipeTime = time
            beginOverviewSwipe()
            // The travel before the threshold counts too, so the overview moves from the first frame.
            overviewSwipeProgress += (overviewPinch ? swipePinch : swipeTravel.y) / overviewSwipeDistance
            followOverviewSwipe(progress: overviewSwipeProgress, velocity: 0)
            return
        case "gesture-spaces":
            spaceSwiping = true
            spaceSwipeFocus = beginSpaceSwipe() + swipeTravel.y / spaceSwipeDistance  // travel so far counts
            spaceSwipeVelocity = 0
            spaceSwipeTime = time
            followSpaceSwipe(focus: spaceSwipeFocus, velocity: 0)
            return
        case "gesture-strip":
            gestureActive = true
            stripOffset -= (swipeTravel.x - dx) * swipeScale  // the travel before this frame counts too
        default:
            swipeIgnored = true
            return
        }
    }
    // Fingers right: strip right, so content follows the fingers like natural scrolling.
    let delta = dx * swipeScale
    swipeVelocity = swipeVelocity * 0.5 + delta * 0.5
    stripOffset -= delta
    layout(immediate: true)
}

// Touches come from MultitouchSupport (private framework, same as OmniWM). Set macOS horizontal gestures (swipe between
// full-screen apps) to a finger count nori doesn't use, or off, or macOS fires them too.
typealias ContactCallback = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int32, Double, Int32, UnsafeMutableRawPointer?) -> Int32

// Runs on a MultitouchSupport thread. Each touch is a 96-byte MTTouch; the normalized position is two floats at offset 32.
// The list also holds contacts that are hovering, lifting or lingering after a lift (state at offset 20);
// counting those made a quick second swipe look like 5 or 6 fingers. Only MakeTouch (3) and Touching (4) count.
let contactCallback: ContactCallback = { _, touches, contacts, time, _, _ in
    var count: Int32 = 0
    var x: Float = 0, y: Float = 0
    if let touches {
        for i in 0..<Int(contacts) {
            let state = touches.load(fromByteOffset: i * 96 + 20, as: Int32.self)
            guard state == 3 || state == 4 else { continue }
            count += 1
            x += touches.load(fromByteOffset: i * 96 + 32, as: Float.self)
            y += touches.load(fromByteOffset: i * 96 + 36, as: Float.self)
        }
    }
    fingerCount = count
    if count >= 3 {  // not asking ourGesture: the config is the main thread's
        systemGestureUntil = CACurrentMediaTime() + systemGestureLinger
        systemGestureFingers = count
    }
    let center = count > 0 ? CGPoint(x: CGFloat(x / Float(count)), y: CGFloat(y / Float(count))) : nil
    // Twice the fingers' mean distance from the center, so a pinch counts about as far as a swipe of that travel.
    var spread: Float = 0
    if let touches, let center {
        for i in 0..<Int(contacts) where [3, 4].contains(touches.load(fromByteOffset: i * 96 + 20, as: Int32.self)) {
            spread += hypot(touches.load(fromByteOffset: i * 96 + 32, as: Float.self) - Float(center.x),
                            touches.load(fromByteOffset: i * 96 + 36, as: Float.self) - Float(center.y))
        }
        spread *= 2 / Float(count)
    }
    let distance = CGFloat(spread)
    DispatchQueue.main.async { touchFrame(count: count, center: center, spread: distance, time: time) }
    return 0
}

// The device list is read once per call: a Magic Trackpad that connects later (Bluetooth, after sleep) is a new
// device, so startMultitouch runs again whenever a multitouch device appears and after wake, as MiddleClick does.
var multitouchDevices: CFArray?
var multitouchNotify: IONotificationPortRef?

func startMultitouch() {
    guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
          let createList = dlsym(lib, "MTDeviceCreateList"),
          let start = dlsym(lib, "MTDeviceStart"),
          let stop = dlsym(lib, "MTDeviceStop"),
          let register = dlsym(lib, "MTRegisterContactFrameCallbackWithRefcon"),
          let unregister = dlsym(lib, "MTUnregisterContactFrameCallback")
    else {
        fputs("MultitouchSupport unavailable: trackpad swipe disabled\n", stderr)
        return
    }
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias Start = @convention(c) (OpaquePointer, Int32) -> Int32
    typealias Stop = @convention(c) (OpaquePointer) -> Int32
    typealias Register = @convention(c) (OpaquePointer, ContactCallback, UnsafeMutableRawPointer?) -> Int32
    typealias Unregister = @convention(c) (OpaquePointer, ContactCallback) -> Int32

    func each(_ list: CFArray?, _ body: (OpaquePointer) -> Void) {
        guard let list else { return }
        for index in 0..<CFArrayGetCount(list) {
            if let device = OpaquePointer(CFArrayGetValueAtIndex(list, index)) { body(device) }
        }
    }
    each(multitouchDevices) { device in
        _ = unsafeBitCast(unregister, to: Unregister.self)(device, contactCallback)
        _ = unsafeBitCast(stop, to: Stop.self)(device)
    }
    fingerCount = 0
    touchFrame(count: 0, center: nil)  // a gesture cut off by the restart ends here
    multitouchDevices = unsafeBitCast(createList, to: CreateList.self)()?.takeRetainedValue()
    each(multitouchDevices) { device in
        _ = unsafeBitCast(register, to: Register.self)(device, contactCallback, nil)
        _ = unsafeBitCast(start, to: Start.self)(device, 0)
    }

    guard multitouchNotify == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
    multitouchNotify = port
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
    var iterator: io_iterator_t = 0
    let added: IOServiceMatchingCallback = { _, iterator in
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
        restartMultitouchSoon()  // the port's source is on the main run loop
    }
    IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"), added, nil, &iterator)
    while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }  // arms the notification
    NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
        restartMultitouchSoon()
    }
}

// The device is matched before its driver is ready: restart a moment later, once for a burst of devices.
var multitouchRestartQueued = false
func restartMultitouchSoon() {
    guard !multitouchRestartQueued else { return }
    multitouchRestartQueued = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        multitouchRestartQueued = false
        startMultitouch()
    }
}
