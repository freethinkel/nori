// Events instead of waiting for the poll: WindowServer's word that a window came or went, Accessibility notifications of
// every app (window created, focus moved, window minimized, app hidden) and NSWorkspace ones (app launched, quit,
// activated; Space changed) run poll() at once. WindowServer's don't depend on the app answering: see docs/WINDOWSERVER.md.
// Each window also reports its own destruction, so a window closing without a focus change is seen at once too.
// ponytail: the poll stays, once a second, for whatever these still miss.

import Cocoa

var axObservers: [pid_t: AXObserver] = [:]
var pollQueued = false

// A burst of notifications runs one poll.
func pollSoon() {
    guard !pollQueued else { return }
    pollQueued = true
    DispatchQueue.main.async {
        pollQueued = false
        poll()
    }
}

let axNotifications = [
    kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
    kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    kAXApplicationHiddenNotification, kAXApplicationShownNotification,
]

// Kept only once the app accepts the notifications; a just-launched app may not yet, so launches retry.
func observe(_ app: NSRunningApplication) {
    let pid = app.processIdentifier
    guard app.activationPolicy == .regular, axObservers[pid] == nil else { return }
    var observer: AXObserver?
    let created = AXObserverCreate(pid, { observer, element, notification, _ in
        pollSoon()
        // A new window may reach CGWindowList a little after its notification.
        if notification as String == kAXWindowCreatedNotification {
            AXObserverAddNotification(observer, element, kAXUIElementDestroyedNotification as CFString, nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pollSoon() }
        }
    }, &observer)
    guard created == .success, let observer else { return }
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 0.25)  // a hung app must not stall the daemon
    guard axNotifications.map({ AXObserverAddNotification(observer, element, $0 as CFString, nil) }).first == .success else { return }
    var windows: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows) == .success {
        for window in windows as? [AXUIElement] ?? [] {
            AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, nil)
        }
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    axObservers[pid] = observer
}

// 1325: a window was added to a Space, 1326: one left it. On the main run loop, 12 bytes: the Space id, then the window id.
// A cue to look, as a new window may not be listed yet. Menus and tooltips come through here too: those run no poll, as
// a title rule makes a poll an Accessibility round trip per window.
let windowAddedEvent: UInt32 = 1325, windowRemovedEvent: UInt32 = 1326

let windowServerEvent: SkyLight.NotifyProc = { type, data, length, _ in
    let id = data != nil && length >= 12 ? data!.loadUnaligned(fromByteOffset: 8, as: UInt32.self) : 0
    DispatchQueue.main.async {
        if type == windowAddedEvent {
            var level: Int32 = 0
            if SkyLight.windowLevel?(cid, id, &level) == 0, level != 0 { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pollSoon() }
        } else if id != 0, lastSeen[id] == nil {
            return  // a menu closing
        }
        pollSoon()
    }
}

// A display came, went or changed size, or the main display changed. macOS goes on moving windows for a while after
// that, so every strip is laid out once it has stopped: windows of a removed display are on a Desktop of another one
// by then, and join that strip when it is next shown.
var displaysSettling: DispatchWorkItem?

func displaysChanged() {
    displaysSettling?.cancel()
    let work = DispatchWorkItem {
        layoutAll()
        tellPayload()
        settingsModel.refresh()  // its cards of displays
    }
    displaysSettling = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
}

func startEvents() {
    for event in [windowAddedEvent, windowRemovedEvent] { _ = SkyLight.registerNotify?(cid, windowServerEvent, event, nil) }
    NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in displaysChanged() }
    NSWorkspace.shared.runningApplications.forEach(observe)
    let center = NSWorkspace.shared.notificationCenter
    func app(_ note: Notification) -> NSRunningApplication? { note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
    center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { note in
        guard let launched = app(note) else { return }
        for delay in [0, 0.5, 2] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { observe(launched) } }
        pollSoon()
    }
    center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
        if let pid = app(note)?.processIdentifier {
            appNamesCache[pid] = nil
            if let observer = axObservers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
        }
        pollSoon()
    }
    for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                 NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in pollSoon() }
    }
    // Apps quit one by one on the way down: strips.json keeps the strips as they were before that. A cancelled shutdown
    // ends the hold.
    center.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { _ in
        poweringOff = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { poweringOff = false }
    }
}
