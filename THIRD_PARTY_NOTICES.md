# Third-party notices

LayoutKeeper is licensed under the GNU General Public License v3.0 only (`GPL-3.0-only`, see `LICENSE`),
matching AltTab's license. It has no third-party runtime dependencies; it links only Apple system frameworks
(AppKit, SwiftUI, ApplicationServices, ServiceManagement, Carbon) and resolves some private SkyLight /
HIServices symbols dynamically at run time.

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
