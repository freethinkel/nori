// Trackpad gestures from raw touches: 3 fingers move the strip (horizontal) or Spaces (vertical), 4 drive the overview.
// macOS's own 3- and 4-finger gestures are swallowed in the event tap, so they can stay on in System Settings.

import Cocoa

// Trackpad: the strip follows the 3-finger centroid. A swipe that starts vertical moves through Spaces instead.
// On lift the strip is thrown by the last finger speed and snaps to the nearest column.
// ponytail: one trackpad at a time; frames from a second trackpad would interleave with the first.
var fingerCount: Int32 = 0
let gestureFingers: Int32 = 3
let swipeSpeed: CGFloat = 1.3  // strip points per point of finger travel; above 1 the strip outruns the fingers
let swipeScale = CGDisplayBounds(CGMainDisplayID()).width * swipeSpeed  // points per full trackpad width
let swipeThreshold: CGFloat = 0.02  // trackpad widths before the direction is decided

var gestureActive = false
var swipeIgnored = false  // this touch went vertical: it moves through Spaces instead

// 3-finger vertical swipe: Spaces, like niri's workspaces. They follow the fingers (rubber past the first and last);
// on lift the nearest one, or the next one for a flick, slides to the center like windows do, and Dock switches to it.
let spaceSwipeDistance: CGFloat = 0.5  // trackpad heights per Space
var spaceSwiping = false
var spaceSwipeFocus: CGFloat = 0     // index of the Space at the center, fractional
var spaceSwipeVelocity: CGFloat = 0  // Spaces per second, smoothed
var spaceSwipeTime: CFTimeInterval = 0
var lastCenter: CGPoint?
var swipeTravel = CGPoint.zero
var swipeVelocity: CGFloat = 0  // points per frame, smoothed

// 4-finger vertical swipe drives the overview like niri's: up opens, down closes, and it follows the fingers.
// On lift it springs open or closed, thrown by the finger speed. macOS's own 4-finger gestures (Mission Control,
// App Exposé, Spaces) are swallowed in the event tap while four fingers are down, so they don't fire too.
let overviewFingers: Int32 = 4
let overviewSwipeDistance: CGFloat = 0.3  // trackpad heights from closed to open
var overviewSwiping = false
var overviewSwipeTravel: CGFloat = 0  // before the swipe starts
var overviewSwipeProgress: CGFloat = 0
var overviewSwipeVelocity: CGFloat = 0  // progress per second, smoothed
var overviewSwipeTime: CFTimeInterval = 0
var lastTouchCount: Int32 = 0

// Main thread. center is the normalized (0...1) centroid of the touches, or nil when there are none.
func touchFrame(count: Int32, center: CGPoint?) {
    defer { lastTouchCount = count }
    if count == overviewFingers, let center {
        // The centroid jumps when a finger lands, so the swipe counts from the first frame with four.
        if lastTouchCount == overviewFingers, let last = lastCenter {
            let dy = center.y - last.y  // normalized y grows towards the top of the trackpad
            if !overviewSwiping {
                overviewSwipeTravel += dy
                if abs(overviewSwipeTravel) >= swipeThreshold {
                    overviewSwiping = true
                    overviewSwipeProgress = overviewOpen ? 1 : 0
                    overviewSwipeVelocity = 0
                    overviewSwipeTime = CACurrentMediaTime()
                    beginOverviewSwipe()
                    // The travel before the threshold counts too, so the overview moves from the first frame.
                    overviewSwipeProgress += overviewSwipeTravel / overviewSwipeDistance
                    followOverviewSwipe(progress: overviewSwipeProgress, velocity: 0)
                }
            } else {
                let now = CACurrentMediaTime()
                let delta = dy / overviewSwipeDistance
                overviewSwipeProgress += delta
                overviewSwipeVelocity = overviewSwipeVelocity * 0.5 + delta / CGFloat(max(now - overviewSwipeTime, 1.0 / 240)) * 0.5
                overviewSwipeTime = now
                followOverviewSwipe(progress: overviewSwipeProgress, velocity: overviewSwipeVelocity)
            }
        }
        lastCenter = center
        return
    }
    if overviewSwiping {
        overviewSwiping = false
        // A flick decides by its direction; a slow lift by how far the overview is open.
        let open = abs(overviewSwipeVelocity) > 1.5 ? overviewSwipeVelocity > 0 : overviewSwipeProgress > 0.5
        endOverviewSwipe(open: open)
    }
    overviewSwipeTravel = 0
    guard count == gestureFingers, lastTouchCount == gestureFingers || lastCenter == nil, let center else {
        if gestureActive {
            gestureActive = false
            stripOffset -= swipeVelocity * 8  // ponytail: fixed throw; real momentum would decay over frames
            focusColumn(at: focusedIndex())
        }
        if spaceSwiping {
            spaceSwiping = false
            endSpaceSwipe(focus: spaceSwipeFocus, velocity: spaceSwipeVelocity)
        }
        swipeIgnored = false
        lastCenter = nil
        swipeTravel = .zero
        swipeVelocity = 0
        return
    }
    defer { lastCenter = center }
    if spaceSwiping, let last = lastCenter {
        // Fingers up: the Space below comes up into view, so content follows the fingers.
        let now = CACurrentMediaTime()
        let delta = (center.y - last.y) / spaceSwipeDistance
        spaceSwipeFocus += delta
        spaceSwipeVelocity = spaceSwipeVelocity * 0.5 + delta / CGFloat(max(now - spaceSwipeTime, 1.0 / 240)) * 0.5
        spaceSwipeTime = now
        followSpaceSwipe(focus: spaceSwipeFocus, velocity: spaceSwipeVelocity)
        return
    }
    guard let last = lastCenter, !swipeIgnored else { return }
    let dx = center.x - last.x, dy = center.y - last.y
    if !gestureActive {
        swipeTravel.x += dx
        swipeTravel.y += dy
        guard max(abs(swipeTravel.x), abs(swipeTravel.y)) >= swipeThreshold else { return }
        if abs(swipeTravel.y) > abs(swipeTravel.x) {
            swipeIgnored = true
            spaceSwiping = true
            spaceSwipeFocus = beginSpaceSwipe() + swipeTravel.y / spaceSwipeDistance  // travel so far counts
            spaceSwipeVelocity = 0
            spaceSwipeTime = CACurrentMediaTime()
            followSpaceSwipe(focus: spaceSwipeFocus, velocity: 0)
            return
        }
        gestureActive = true
        stripOffset -= (swipeTravel.x - dx) * swipeScale  // the travel before this frame counts too
    }
    // Fingers right: strip right, so content follows the fingers like natural scrolling.
    let delta = dx * swipeScale
    swipeVelocity = swipeVelocity * 0.5 + delta * 0.5
    stripOffset -= delta
    layout(immediate: true)
}

// Touches come from MultitouchSupport (private framework, same as OmniWM). Set macOS horizontal 3-finger
// gestures (swipe between full-screen apps) to 4 fingers or off, or macOS fires them too.
typealias ContactCallback = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, Int32, Double, Int32, UnsafeMutableRawPointer?) -> Int32

// Runs on a MultitouchSupport thread. Each touch is a 96-byte MTTouch; the normalized position is two floats at offset 32.
// The list also holds contacts that are hovering, lifting or lingering after a lift (state at offset 20);
// counting those made a quick second swipe look like 5 or 6 fingers. Only MakeTouch (3) and Touching (4) count.
let contactCallback: ContactCallback = { _, touches, contacts, _, _, _ in
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
    let center = count > 0 ? CGPoint(x: CGFloat(x / Float(count)), y: CGFloat(y / Float(count))) : nil
    DispatchQueue.main.async { touchFrame(count: count, center: center) }
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
