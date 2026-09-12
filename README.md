# Kite

A native macOS terminal with vertical tabs, split panes, and sessions that survive closing the app. Built with Swift/AppKit and Ghostty's terminal core, without tmux or a web UI.

**Work in progress.** This is a source-built project, not a polished or notarized release. The current build has been exercised on Apple Silicon with macOS 26 and Xcode 26.6.

## What works

- Multiple sessions in a vertical sidebar, with rename and drag-to-reorder.
- Horizontal and vertical splits, pane focus, divider resizing, and moving panes into new sessions.
- A separate daemon that owns shell processes and starts automatically when you open Kite.
- Reconnection with bounded scrollback and reconstructed normal/alternate terminal screens.
- Saved session order, layouts, selection, titles, and working directories.
- Font, shell, theme, and keyboard shortcut settings.
- Native keyboard input, IME composition, clipboard, mouse input, and Ghostty's Metal renderer.

## Build from source

You need an Apple Silicon Mac, Python 3, Git, full Xcode with its command-line tools, the Metal Toolchain component, and **Zig 0.15.2**. Command Line Tools alone are not enough.

If Xcode is not configured yet, select it and finish setup:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license
sudo xcodebuild -runFirstLaunch
xcodebuild -downloadComponent metalToolchain
```

Clone Kite and install the pinned Zig compiler locally:

```sh
git clone https://github.com/bgar324/kite.git
cd kite
mkdir -p .tools
curl -fL https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz -o .tools/zig.tar.xz
tar -xf .tools/zig.tar.xz -C .tools
```

Build and open the app:

```sh
python3 build.py app
open build/Kite.app
```

The build script downloads pinned Ghostty 1.3.1 sources and builds the native library, daemon, relay, and app bundle. Build output, downloaded toolchains, and dependency checkouts are excluded from Git.

To use an existing Zig installation:

```sh
python3 build.py app --zig /absolute/path/to/zig
```

The build currently prefers the macOS 15.4 SDK from Command Line Tools when it is installed, to work around pinned-toolchain compatibility issues. You can choose a compatible SDK explicitly:

```sh
python3 build.py app --ghostty-sdk /absolute/path/to/MacOSX.sdk
```

These overrides apply to the build subprocesses, not your global Xcode selection. Builds on other SDK combinations are not yet broadly tested.

## Use Kite

Create sessions with the sidebar **+** button. Double-click a session or use its context menu to rename it. Drag sidebar rows to change their order.

Click a terminal pane to focus it. Drag a divider to resize a split. Each pane's **Pane** menu provides move, restart, and close actions. Open **Settings…** to change fonts, theme, shell, or shortcuts. Shell changes apply to new or restarted panes.

**Closing the window or pressing Command-Q leaves your shells running. Closing a session or pane terminates its processes after confirmation.**

Default shortcuts:

| Action | Shortcut |
| --- | --- |
| New session | Command-T |
| Close session and its processes | Command-W |
| Select session 1–9 | Command-1 through Command-9 |
| Previous / next session | Command-Shift-[ / Command-Shift-] |
| Split left/right | Command-D |
| Split top/bottom | Command-Shift-D |
| Focus next pane | Command-Option-Right |
| Close focused pane | Command-Shift-W |
| Copy / paste | Command-C / Command-V |

## Persistence and limits

The daemon keeps PTYs and terminal state alive independently of the GUI. Reopening Kite reconnects to it. It stores workspace metadata under:

```text
~/Library/Application Support/Kite/workspace.json
```

The local socket is `session-v2.sock` in the same private directory. Terminal history stays in daemon memory rather than a disk log.

- Persistence covers **GUI restarts**, not daemon death, logout, or machine reboot. Lost processes are shown as exited; restarting them is explicit.
- Scrollback is bounded to 2 MiB per pane, plus Ghostty's active-grid storage. Reconstructed snapshots have a 16 MiB cap.
- Kitty graphics/APC images are not restored by the current snapshot implementation.
- Some uncommon terminal bookkeeping states produce an explicit restoration error rather than a potentially corrupted screen.
- There is no signed/notarized distribution or automatic updater yet.

## How it is built

```text
AppKit window + Ghostty renderer
              |
       per-pane byte relay
              |
        private Unix socket
              |
   session daemon + Ghostty state
              |
         PTYs and shells
```

The GUI controls sessions and layouts through a versioned protocol. Each terminal uses a disposable relay. The daemon owns the real shell PTY and a canonical Ghostty terminal instance, which it uses to reconstruct screen state without replaying historical clipboard operations or terminal queries.

| Code | Responsibility |
| --- | --- |
| `Sources/Kite.swift`, `TerminalView.swift` | Native window, sidebar, split layout, settings, and terminal interaction |
| `Sources/SessionClient.swift` | GUI connection, requests, and daemon startup |
| `Sources/SessionDaemon.swift`, `PTY.c` | Process ownership, lifecycle, metadata, and persistence |
| `Sources/Workspace.swift`, `Wire.swift` | Shared state model and protocol |
| `Sources/kite-relay.c` | Per-pane terminal byte transport |
| `Sources/kite-terminal.zig` | Ghostty state and snapshot bridge |

## Verify a build

Run the complete verification sequence:

```sh
python3 verify.py
```

After building, skip the rebuild with:

```sh
python3 verify.py --skip-build
```

The checks cover protocol fragmentation, terminal-state restoration, session/pane lifecycle, malformed output, backpressure, checkpoint failures, large workspaces, transport latency, and native interaction. The native scenario opens test windows and exercises keyboard/IME input, clipboard, splits, settings, hidden-tab rendering, Vim reconnect, and GUI relaunch.

Tests use isolated temporary workspaces. Native clipboard checks temporarily replace and then restore clipboard contents. Machine-readable results and captures are written under `build/`; they are not committed. [verification.json](verification.json) records the current verification scope and known limits, not a guarantee across all Macs or terminal programs.

## Acknowledgments

Kite uses [Ghostty](https://github.com/ghostty-org/ghostty) for terminal emulation and rendering. Its native adapter draws on Ghostty's macOS integration. Ghostty is MIT-licensed; see [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) for attribution and its license notice.
