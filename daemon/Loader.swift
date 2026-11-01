// Dock loses the payload with every reboot, and getting it back takes root: task_for_pid on Dock. So the first load
// puts the loader and the payload where only root can change them, with a sudoers rule for exactly that command, and
// later loads run it without a password (loadPayload, App.swift). Copies, because a rule on the bundle's own files,
// which the user can write, would give root to any process of theirs. A build that changes them asks once more.
// See "Loading the payload without a password" in docs/WINDOWSERVER.md.

import Foundation

let installFolder = "/usr/local/libexec/nori"
let installedLoader = installFolder + "/loader"
let installedPayload = installFolder + "/payload.dylib"
let sudoersFile = "/etc/sudoers.d/nori-\(getuid())"  // one per user, so a second account doesn't replace the first's rule

func sudoersRule(uid: uid_t) -> String { "#\(uid) ALL=(root) NOPASSWD: \(installedLoader) \(installedPayload)" }

// Root's part of a first load; the paths come shell-quoted. visudo checks the rule before it goes in place, as a bad file
// in /etc/sudoers.d stops sudo for the whole machine. sudo skips a file with a dot in its name until then.
func installLoaderScript(loader: String, payload: String) -> String {
    let staged = "/etc/sudoers.d/.nori-\(getuid())"
    return "mkdir -p \(installFolder) && install -o root -g wheel -m 755 \(loader) \(payload) \(installFolder)/"
        + " && echo '\(sudoersRule(uid: getuid()))' > \(staged) && chmod 440 \(staged)"
        + " && visudo -cqf \(staged) && mv -f \(staged) \(sudoersFile)"
}
