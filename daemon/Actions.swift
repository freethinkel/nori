// The actions behind the key bindings ([bindings] in the config, Config.swift) and the CLI (Control.swift), by
// binding name. A key press runs the action its binding names; `nori <verb> <noun>` runs the one cliActions maps it to.

import Cocoa

let actions: [String: () -> Void] = [
    "focus-left": { focusColumn(by: -1) },
    "focus-right": { focusColumn(by: 1) },
    "focus-first": { focusColumn(at: 0) },
    "focus-last": { focusColumn(at: .max) },  // clamped to the last column
    "focus-space-down": { switchSpace(by: 1) },
    "focus-space-up": { switchSpace(by: -1) },
    "center-column": centerColumn,
    "overview": toggleOverview,
    "show-floating": showFloating,
    "grow-width": { resizeFocused(by: resizeStep) },
    "shrink-width": { resizeFocused(by: -resizeStep) },
    "cycle-width-forward": { cycleWidth(forward: true) },
    "cycle-width-backward": { cycleWidth(forward: false) },
    "toggle-full-width": toggleFullWidth,
    "move-left": { moveColumn(by: -1) },
    "move-right": { moveColumn(by: 1) },
    "move-to-space-down": { moveFocused(toDesktopBy: 1) },
    "move-to-space-up": { moveFocused(toDesktopBy: -1) },
].merging((1...9).map { n in ("move-to-space-\(n)", { moveFocused(toDesktop: n) }) }) { a, _ in a }

// Toggles: a held key must not flip them back and forth.
let noRepeat: Set<String> = ["overview", "toggle-full-width"]

// CLI words to action names. "focus space N", "focus column N", "focus window WID" and "move space N" take a number
// and are handled in Control.swift.
let cliActions = [
    "focus left": "focus-left", "focus right": "focus-right", "focus first": "focus-first", "focus last": "focus-last",
    "focus space down": "focus-space-down", "focus space up": "focus-space-up",
    "move left": "move-left", "move right": "move-right", "move space down": "move-to-space-down", "move space up": "move-to-space-up",
    "width grow": "grow-width", "width shrink": "shrink-width", "width next": "cycle-width-forward", "width previous": "cycle-width-backward",
    "width toggle-full": "toggle-full-width", "center": "center-column", "overview": "overview",
    "show floating": "show-floating",
]
