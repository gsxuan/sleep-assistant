# 休眠助手 · Sleep Assistant

A tiny macOS **menu-bar** utility that keeps your Mac awake — including when the
lid is closed — so long-running tasks (downloads, builds, remote sessions,
renders) don't get interrupted by sleep.

A single click on the crescent-moon menu-bar icon toggles "no-sleep" on/off.
Built with **Swift + AppKit**, no third-party dependencies.

Released under the [MIT License](LICENSE).

> macOS 菜单栏常驻小工具：一键让 Mac **合盖也不休眠**，任务不被睡眠打断。
> Swift + AppKit 编写，零第三方依赖，MIT 协议开源。

---

## Features / 功能

- 🌙 **One-click toggle** — crescent-moon icon: amber = no-sleep on, gray = normal sleep.
- 💤 **Works with the lid closed** (`caffeinate -i -m -s` → idle + disk + system sleep assertions).
- 👀 **Shows other processes holding sleep assertions** (e.g. remote-desktop tools) so you know
  why the machine isn't sleeping even when this app is off.
- 🕒 **Recent sleep/wake info** — last sleep, last wake, and the last several sleep events
  (parsed from `pmset -g log`).
- 🔋 **Power / battery / lid status** at a glance.
- 🚀 **One-tap release** of other processes' sleep assertions (kill to release).
- ▶️ **Optional launch-at-login** toggle (off by default).
- 🔒 **Passwordless after one-time setup** — installs a tightly-scoped `sudoers` rule so
  toggling never prompts again. Falls back to an in-app child process (zero authorization)
  if `sudo` is unavailable.

## How it works / 原理

macOS sleep prevention is unified under IOKit power-management assertions
(`IOPMAssertion`); `caffeinate` is just the CLI wrapper. The differences people see
("some tools work, some still sleep, some freeze the system") come down to **which
assertion type** is held, **AC vs battery**, and **whether it's released**:

| Assertion | Blocks idle sleep | Blocks lid-close sleep |
|---|---|---|
| `PreventUserIdleSystemSleep` | ✅ | ❌ (lid close still sleeps) |
| `PreventSystemSleep` (`caffeinate -s`) | ✅ | ✅ (on AC; battery lid-close is firmware-forced) |

This app uses `caffeinate -i -m -s` (idle + disk + system) — the strongest sensible combo.
On battery, lid-close sleep is enforced by Apple Silicon firmware and cannot be bypassed.

The task is registered as a **launchd system job** so it survives terminal/SSH logout and
app quit. Because this macOS build forbids ordinary users from bootstrapping their own
`gui` domain, a one-time `sudoers` rule lets the app run a fixed helper via `sudo -n`
(no password prompt ever again).

## Build & install / 编译与安装

Requirements: macOS 13+, Xcode / Swift toolchain (`swiftc`).

```sh
./build.sh          # compiles, renders the icon, assembles Sleep Assistant.app, signs it
open "/Applications/休眠助手.app"   # or: open -a "Sleep Assistant"
```

`build.sh` does everything end-to-end:
1. `swiftc -O` compiles `app/main.swift` → app binary.
2. Compiles `icon/main.swift`, renders the 1024×1024 icon, converts to `AppIcon.icns`
   (`sips` + `iconutil`).
3. Assembles `休眠助手.app` (Info.plist + binary + `AppIcon.icns` + helper + launchd plist).
4. Ad-hoc code-signs it and installs to `/Applications`.

On first toggle the app installs `/usr/local/bin/caffeinate-toggle-helper` and
`/etc/sudoers.d/caffeinate-toggle` (one password prompt, then never again).

## Repository layout / 目录

```
app/main.swift                  # the whole menu-bar app (status item, menu, logic)
app/caffeinate-toggle-helper    # root helper invoked via `sudo -n` (launchd system job)
app/com.think.caffeinate.plist  # launchd job definition (caffeinate -i -m -s)
icon/main.swift                 # renders the 1024x1024 app icon
icon/menubar.swift              # renders the menu-bar crescent (8x preview)
Info.plist                      # bundle metadata (LSUIElement accessory app)
AppIcon.icns / AppIcon_1024.png # app icon
build.sh                        # one-shot build + install script
```

## Notes / 说明

- Not added to login items by default (matches "re-open after reboot"). Toggle it in the menu if you want.
- The crescent uses `flipped: true` (menu-bar buttons draw in a flipped context) and is drawn as
  "fill outer disk, then `.clear`-erase the offset inner disk" — `even-odd`/reversed subpaths get
  normalized by AppKit and don't cut a clean crescent.
- Heavy commands (notably `pmset -g log`, ~6s) run on a **background thread** with caching —
  never on the main thread, or the menu won't render.

## License

MIT — see [LICENSE](LICENSE).
