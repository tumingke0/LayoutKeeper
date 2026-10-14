# Third-party notices

LayoutKeeper is licensed under the GNU General Public License v3.0 only (`GPL-3.0-only`, see `LICENSE`),
matching AltTab's license. Its only third-party runtime dependency is Sparkle (MIT, below) for in-app updates; otherwise it links only Apple system frameworks
(AppKit, SwiftUI, ApplicationServices, ServiceManagement, Carbon) and resolves some private SkyLight /
HIServices symbols dynamically at run time.

## Sparkle

LayoutKeeper embeds Sparkle 2 (`Contents/Frameworks/Sparkle.framework`, added via Swift Package Manager) to check for and
install updates. Sparkle's full license, including the notices for code it bundles, ships in its release archive.

Project: https://github.com/sparkle-project/Sparkle

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

=================
```

## yabai

LayoutKeeper (formerly SpacePort) does not include yabai source code. The window-candidate heuristic in
`Sources/LayoutCore/WindowDiscovery.swift` (`WindowServerTraits.looksLikeDocumentWindow`,
`isOrderedIn`, `minimizedHint`) re-expresses WindowServer tag/attribute bit meanings
observed by yabai (`src/space.c`, window list filtering). The notice is reproduced to credit that work.

Project: https://github.com/koekeishiya/yabai

```
The MIT License (MIT)

Copyright (c) 2019 Åsmund Vikane

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## AltTab (GPL-3.0)

Project: https://github.com/lwouis/alt-tab-macos

- Reading `kAXFocusedWindow` / `kAXMainWindow` in addition to `kAXWindows`, and locating
  windows on other Spaces through `_AXUIElementCreateWithRemoteToken`, follow techniques
  publicly documented by AltTab and others. LayoutKeeper's implementation
  (`Sources/MacAdapters/RemoteWindowLocator.swift`, `AXWindows.swift`) was written
  independently; no AltTab source code was copied or adapted.
- Since LayoutKeeper is now GPL-3.0 as well, the licenses are compatible should code ever be
  adapted from AltTab in the future; any such adaptation must keep AltTab's copyright notices
  and be listed here.

## SnapBack (Apache-2.0) — ideas only

- The reconnect behaviour (debounce after display changes, then offer or perform a restore) was
  inspired by the publicly described behaviour of SnapBack. No SnapBack source code is included;
  `Sources/LayoutCore/ReconnectWatch.swift`, `ReconnectPolicy.swift` and `FrameSettle.swift` are
  original.

## MonitorControl (MIT) — approach only

- Project: https://github.com/MonitorControl/MonitorControl
- License: MIT
- What LayoutKeeper uses: the general technique of sending DDC/CI (VESA MCCS) commands to external monitors on Apple
  Silicon through `IOAVServiceCreateWithService` / `IOAVServiceWriteI2C` / `IOAVServiceReadI2C` (I2C address 0x37,
  sub-address 0x51), and the idea of falling back to gamma-based software dimming. LayoutKeeper's implementation
  (`Sources/MacAdapters/DisplayHardware.swift`, `Sources/LayoutCore/Brightness.swift`) was written independently from the
  MCCS specification; no MonitorControl source code is included. Credit to the MonitorControl authors for documenting
  the approach.

## BetterDisplay — design inspiration only

The on-screen brightness HUD layout is inspired by BetterDisplay. No BetterDisplay code, images or other assets are used.
