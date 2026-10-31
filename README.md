<p align="center"><img src="docs/images/icon.png" width="128" alt="LayoutKeeper icon"></p>

# LayoutKeeper

**English** · [简体中文](README.zh-CN.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Tiếng Việt](README.vi.md)

**Your windows go back where they were when you plug your external monitor back in, on the same desktop (Space) as before.**

<p align="center"><img src="docs/images/main-window.png" width="720" alt="Main window: shared layout, named layouts and version history"></p>

<p align="center">
  <img src="docs/images/menu.png" width="300" alt="Menu bar: brightness and volume sliders, save and restore">
  <img src="docs/images/brightness-hud.png" width="520" alt="Brightness indicator at the top of the screen">
</p>

## The problem it solves

You use an external monitor at the office and another one at home. Every time you unplug, macOS piles all your windows onto the laptop screen. When you plug in again, you drag every window back by hand, desktop by desktop.

LayoutKeeper lives in the menu bar. It remembers where each window was on your external monitor, **including which desktop (Mission Control Space) it was on**. When you plug the monitor back in, it puts everything back with one click, or automatically.

> Screenshots show sample data. The app is available in English and Simplified Chinese and follows your system language.

## Features

- **A layout per monitor.** Each monitor is recognized by its hardware (EDID: maker, model, serial number). Your home and office monitors each get their own layout, with nothing to pick by hand.
- **Or one shared layout.** If you only ever use one external monitor at a time, switch to "all external monitors share one layout". Office or home, you get the same desktops and windows. Positions are stored relative to the screen, so different resolutions still line up.
- **Puts windows back on the right desktop** (macOS 26 or later). Windows that shared a desktop go back onto one desktop, in their original order, and two groups are never piled onto the same desktop. Older systems still get position and size restored on the current desktop.
- **Adds missing desktops for you** (shared mode, on by default). When you plug in, it adds any missing desktops in Mission Control. It never deletes desktops. It stops and asks you to finish by hand if anything doesn't look right. No need to disable SIP.
- **Brightness and volume keys for external monitors.** The brightness keys adjust the screen your mouse is on, built-in or external, and show a translucent indicator at the top of the screen. You can also turn on **Sync external brightness with built-in display** so external monitors automatically change by the same amount when the MacBook's built-in screen adjusts to ambient light, while keeping each screen's relative brightness offset. The volume keys change your Mac's system volume (the current sound output) in 3% steps, wherever the mouse is. With **Volume keys control the display's speakers when sound plays through it** turned on in Settings → Displays → Keyboard (experimental, off by default), when sound plays through an external monitor's HDMI or DisplayPort audio and macOS can't change its volume, the volume and mute keys control that monitor's speakers over DDC instead. Hardware brightness control (DDC) works on **Apple Silicon Macs only**. If a monitor doesn't respond, LayoutKeeper falls back to software dimming. If BetterDisplay, MonitorControl or Lunar is running, LayoutKeeper leaves the keys alone.
- **Switch a monitor's input from the menu bar (experimental, off by default).** After you turn it on in Settings → Displays → Menu Bar, **Input Source** in the menu sends the monitor a DDC input command (DisplayPort 1/2, HDMI 1/2 and USB-C by default). In Settings → Displays you can rename or hide inputs, enter the value from the monitor's manual, or use the LG alternate command. The first switch on each monitor asks for confirmation, and switching the Mac's only active screen always does. Many monitors stop taking commands from an inactive input, so you may need the monitor's own buttons to switch back.
- **Several named layouts per monitor**, for example "Coding" and "Meeting". You can switch between them from the menu bar.
- **Version history.** It keeps the last 5 versions of each monitor's layout, so you can go back.
- **Preview first, undo anytime.** You can see how each window will move before you restore, and any restore can be undone in one click.
- **No guessing.** After moving each window, LayoutKeeper checks that it really arrived and rolls back if it didn't. If it can't tell two windows with the same name apart, it asks you.
- **Display arrangement.** If the same monitor sometimes sits above your MacBook and sometimes beside it, pick **Monitor directly above / right / below / left** from the menu bar instead of dragging screens around in System Settings. Other positions (left-aligned, offset…) can be saved as custom positions. You can also bind an arrangement to a physical port on your Mac (such as the left or right USB-C port, or HDMI) so plugging the monitor into that port switches its arrangement automatically. After a manual switch you have 15 seconds to click **Keep**; otherwise it switches back. The main display and the resolution stay the same, and no window restore is triggered.
- **Keep Awake.** Pick from 4 modes in the menu bar, each with a short note showing when the Mac will sleep or stay awake: **Off**, **Keep System Awake** (lets the screen turn off while staying awake on battery with the lid open, or with the lid closed on power/monitor), **Keep Screen & System Awake** (keeps the screen on), and **Keep Awake Even Closed on Battery** (stays running even with the lid closed on battery and no monitor, and automatically restores normal sleep when turned off or when quitting LayoutKeeper).
- **Global shortcuts:** ⌃⌥⌘S save, ⌃⌥⌘R restore, ⌃⌥⌘Z undo. You can change or turn them off.
- **Automatic updates** via Sparkle. Updates are signed and keep your Accessibility permission.

<p align="center">
  <img src="docs/images/settings-general.png" width="440" alt="Settings: shared layout mode and desktop management">
  <img src="docs/images/settings-display.png" width="440" alt="Settings: displays, brightness and volume keys">
</p>

<p align="center">
  <img src="docs/images/display-arrangement-menu.png" width="520" alt="Menu bar: display arrangement">
  <img src="docs/images/display-arrangement-confirm.png" width="380" alt="Keep this arrangement? Switches back after 15 seconds">
</p>

## Install

1. Download the `.dmg` for your Mac from [Releases](https://github.com/tumingke0/LayoutKeeper/releases/latest): **AppleSilicon** for M-series chips, **Intel** for Intel Macs.
2. Drag LayoutKeeper into Applications.
3. **The first time you open it**, right-click the app and choose **Open**. You can also click "Open Anyway" in System Settings → Privacy & Security. You need this step because the app is self-signed rather than notarized by Apple.
4. Follow the 3-step guide: allow **Accessibility** access, choose whether to start at login, and save your first layout.

**Updates:** use menu bar → **检查更新…** (Check for Updates). By default it checks once a day. Every version is signed with the same certificate, so you don't have to grant permission again after updating.
If you are on 0.6.0 or earlier, install the new version by hand one last time and grant Accessibility again. If the switch is on but nothing works, remove LayoutKeeper with "−" and add it again.

## How to use

1. Arrange your windows on the external monitor's desktops.
2. Menu bar icon → **保存当前布局** (Save current layout), or press ⌃⌥⌘S.
3. Next time you plug in that monitor, a macOS notification asks whether to restore. Click **恢复布局** (Restore layout), or press ⌃⌥⌘R.
4. Don't like the result? Press ⌃⌥⌘Z to undo.

What happens when you plug in a monitor (Settings → General):
- **Ask first** (default): a macOS notification appears, and nothing moves until you click **恢复布局** (Restore layout) on it. Swipe it away to dismiss it.
- **Restore automatically**: waits until the screen and windows have settled, then restores.
- **Off**: you restore by hand only.

More details: [docs/USABILITY.md](docs/USABILITY.md) (Chinese).

## Requirements

- macOS 14 or later. Moving windows back to their original desktop needs **macOS 26 or later**. Tested on macOS 27.0.
- Accessibility permission. No Screen Recording or Input Monitoring is needed.
- **One external monitor** at a time.
- "Displays have separate Spaces" turned on (System Settings → Desktop & Dock). This is the default.

## Limitations

- Moving windows between desktops uses private macOS APIs, which may stop working after a system update. LayoutKeeper checks for this at launch and turns the feature off if needed. Restoring position and size on the current desktop keeps working.
- Finder windows can't be moved to another desktop. Their position and size are still restored.
- It doesn't launch or quit apps, and it doesn't restore tabs or stacking order. Full-screen, Split View and minimized windows are skipped.
- Hardware brightness works on Apple Silicon only, and some monitors, adapters, docks and HDMI ports don't support DDC. Input switching and display speaker volume need DDC too, and some monitors ignore those commands.

## FAQ

**Does it collect data?** No. The only network access is the update check, which talks to GitHub only. You can turn it off in Settings. Layouts are stored on your Mac in `~/Library/Application Support/LayoutKeeper/`.

**Why are some windows marked "needs confirmation"?** An app has several windows with the same title, and LayoutKeeper won't guess which is which. Pick the right one in the preview.

**Why not cross-desktop restore on macOS 14/15?** The old system interface has been blocked since macOS 14.5, and the new one only exists from macOS 26.

**How do I uninstall?** Quit the app. Delete `LayoutKeeper.app` and `~/Library/Application Support/LayoutKeeper/`, then run `defaults delete local.layoutkeeper.app`. Finally remove it from Login Items and Accessibility in System Settings.

**Was it called SpacePort?** Yes. It was renamed in 0.4.0, and your old data is copied over on first launch.

## Build from source

You need Xcode 16 or later (Swift 6).

```sh
git clone https://github.com/tumingke0/LayoutKeeper.git
cd LayoutKeeper
./scripts/test.sh     # optional: run tests
./scripts/build.sh    # creates build-products/LayoutKeeper.app
open build-products/LayoutKeeper.app
```

If a "LayoutKeeper Self-Signed" certificate is in your keychain, the build uses it. Otherwise it is ad-hoc signed, and you need to remove and re-add the app under Accessibility after each rebuild. Technical details: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## Contributing

Issues and pull requests are welcome, see [CONTRIBUTING.md](CONTRIBUTING.md). When reporting a bug, please include your macOS version (with build number) and the report from Settings → 诊断 → 一键自检 (self-test). The report doesn't include window titles.

## Credits

- [AltTab](https://github.com/lwouis/alt-tab-macos) (GPL-3.0): the idea for finding windows on other desktops. Our implementation is independent.
- [yabai](https://github.com/koekeishiya/yabai) (MIT): what the WindowServer window flags mean.
- [MonitorControl](https://github.com/MonitorControl/MonitorControl) (MIT): reference for DDC control.
- [m1ddc](https://github.com/waydabber/m1ddc) (MIT): reference for matching displays to their DDC channel and for the LG input command.
- SnapBack: the idea for restoring when a monitor is connected.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

[GPL-3.0-only](LICENSE). Copyright (C) 2026 LayoutKeeper contributors.
