# nori: PoC plan

Goal: a niri-like WM prototype for macOS. Columns, vertical workspaces, hotkeys. Animation through WindowServer transforms.

## Structure

- `loader.m` — a copy of the yabai loader (MIT, src/osax). Credit the source and license in the header.
- `payload.m` — our own dylib for Dock. Socket `/tmp/nori_$USER.socket`. Three commands: a batch of transforms per frame, move, alpha/order.
- `main.swift` — the daemon: columns, vertical workspaces, hotkeys through a CGEvent tap, CVDisplayLink sends transforms.

## Steps

1. Build `payload.m` with `-arch arm64e` into a dylib.
2. Build `loader.m`, check that it loads the payload into Dock (only once the system is set up, see below).
3. Write `main.swift`: column model, layout, hotkeys.
4. Connect the daemon to the payload through the socket.
5. Check: one window, then two columns, then switching workspaces.

## Prerequisites (done by the user, not the agent)

- Debugging Restrictions: disabled. Without it `task_for_pid` on Dock doesn't work.
- Filesystem Protections: disabled.
- boot-args `-arm64e_preview_abi`. Without it Dock (arm64e) won't load a foreign dylib.

These steps change system protections and need Recovery. The agent doesn't do them.

## Out of scope

- Signature scanning for Dock's private globals (needed only for native Spaces).
- Replacing yabai's layout. While testing: `yabai -m config layout float` or `yabai --stop-service`.

## Rollback

- `sudo yabai --uninstall-sa`, once our own payload works and it is no longer needed.

## Open

- The SLS calls are taken from yabai; their signatures need checking on the current macOS (27).
- Test only on our own machine, with no third-party windows in critical tasks.
