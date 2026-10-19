<p align="center"><img src="docs/images/icon.png" width="128" alt="LayoutKeeper 图标"></p>

# LayoutKeeper

[English](README.md) · **简体中文** · [日本語](README.ja.md) · [한국어](README.ko.md) · [Tiếng Việt](README.vi.md)

**接回外接显示器，窗口自动回到原来的位置，连原来在第几个桌面都一样。**

<p align="center"><img src="docs/images/main-window.png" width="720" alt="主窗口：共用布局、版式和历史版本"></p>

<p align="center">
  <img src="docs/images/menu.png" width="300" alt="菜单栏：亮度和音量滑块、保存和恢复">
  <img src="docs/images/brightness-hud.png" width="520" alt="屏幕上方的亮度提示">
</p>

## 解决什么问题

公司一块外接屏，家里一块。每次拔掉，macOS 就把所有窗口挤到笔记本屏幕上；再插上时，你只能一个桌面一个桌面地把窗口拖回去。

LayoutKeeper 常驻菜单栏，记住外接屏上每个窗口的位置，**包括它在第几个桌面（调度中心的 Space）**。插上屏幕时一键或自动放回原处。

> 截图均为示例数据。界面支持英文和简体中文，跟随系统语言。

## 功能

- **每块屏一份布局**：按显示器硬件（EDID：厂商、型号、序列号）识别，家里和公司的屏幕各存各的，不用手动选择。
- **或者所有外接屏共用一套**：如果你每次只接一块外接屏，可以选择「所有外接屏共用一套」，公司和家里用同一套桌面和窗口。位置按相对比例保存，分辨率不同也能对上。
- **放回原来的桌面**（需要 macOS 26 及以上）。原来在同一个桌面上的窗口放回同一个桌面，顺序不变，不会把两组窗口挤到同一个桌面上。更早的系统也能在当前桌面恢复位置和大小。
- **自动补齐桌面**（共用模式，默认开启）：插上时在调度中心补齐缺的桌面，不会删除任何桌面。核对不上就停下，提示你手动处理。不需要关闭 SIP。
- **亮度和音量键**：亮度键调节鼠标所在的屏幕（内置屏或外接屏），屏幕上方会显示半透明提示；音量键按 3% 一档调节 Mac 的系统音量（当前的声音输出设备），不管鼠标在哪块屏上。硬件调亮度（DDC）**仅支持 Apple 芯片的 Mac**，显示器不响应时改用软件调暗。检测到 BetterDisplay、MonitorControl 或 Lunar 在运行时会自动让出按键。
- **版式**：同一块屏幕可以存多套命名布局（如「写代码」「开会」），在菜单栏一键切换。
- **历史版本**：每块屏幕保留最近 5 个版本，随时回退。
- **先预览、可撤销**：恢复前能看到每个窗口怎么动，每次恢复都能一键撤销。
- **不乱猜**：每个窗口移动后都会回读确认，没到位就回滚；分不清同名窗口时会问你。
- **全局快捷键**：⌃⌥⌘S 保存、⌃⌥⌘R 恢复、⌃⌥⌘Z 撤销，可自定义或关闭。
- **自动更新**（Sparkle）：更新包有签名校验，更新后辅助功能权限不会丢。

<p align="center">
  <img src="docs/images/settings-general.png" width="440" alt="设置：共用布局模式和桌面管理">
  <img src="docs/images/settings-display.png" width="440" alt="设置：显示器、亮度和音量键">
</p>

## 安装

1. 从 [Releases](https://github.com/tumingke0/LayoutKeeper/releases/latest) 下载 `.dmg`：Apple 芯片（M 系列）选 **AppleSilicon**，Intel 芯片选 **Intel**。
2. 把 LayoutKeeper 拖进「应用程序」。
3. **第一次打开**：右键点应用选「打开」，或在「系统设置 → 隐私与安全性」点「仍要打开」。应用是自签名的，没有经过 Apple 公证，所以需要这一步。
4. 跟着三步引导走：授权「辅助功能」→ 选择是否开机自启 → 保存第一份布局。

**更新**：菜单栏 →「检查更新…」，默认每天自动检查一次。每个版本都用同一个证书签名，更新后不用重新授权。
如果你还在用 0.6.0 或更早版本，需要最后手动装一次新版，并重新授权辅助功能。如果开关已打开但不生效，先用「−」删掉 LayoutKeeper 再重新添加。

## 怎么用

1. 把外接屏各个桌面上的窗口摆好。
2. 菜单栏图标 →「保存当前布局」（⌃⌥⌘S）。
3. 下次插上这块屏幕，会弹出系统通知，点「恢复布局」就行（或按 ⌃⌥⌘R）。
4. 不满意就按 ⌃⌥⌘Z 撤销。

插上屏幕时怎么做（设置 → 通用）：
- **先询问**（默认）：弹出系统通知，你点了「恢复布局」才恢复；向右划掉即可关闭。
- **自动恢复**：等屏幕和窗口稳定后自动恢复。
- **关闭**：只手动恢复。

详细说明见 [docs/USABILITY.md](docs/USABILITY.md)。

## 系统要求

- macOS 14 或更新。放回原来的桌面需要 **macOS 26 及以上**，已在 macOS 27.0 上测试。
- 需要「辅助功能」权限，不需要屏幕录制、输入监控等权限。
- 同时只支持**一块**外接屏。
- 需要开启「系统设置 → 桌面与程序坞 → 显示器具有单独的空间」（系统默认开启）。

## 局限

- 跨桌面移动窗口用到 macOS 私有接口，系统更新后可能失效。应用启动时会自动检测，必要时关闭这项功能，同一桌面内的恢复不受影响。
- 访达（Finder）窗口不能跨桌面移动，位置和大小照常恢复。
- 不会启动或退出应用，也不恢复标签页和窗口叠放顺序。全屏、分屏和最小化的窗口会跳过。
- 硬件调亮度只支持 Apple 芯片。部分显示器、转接头、扩展坞和 HDMI 口不支持 DDC。

## 常见问题

**会收集数据吗？** 不会。唯一的网络访问是检查更新，只连接 GitHub，可以在设置里关掉。布局只保存在你的 Mac 上：`~/Library/Application Support/LayoutKeeper/`。

**为什么有的窗口显示「需要确认」？** 同一个应用有多个同名窗口，LayoutKeeper 不会乱猜，请在预览里选。

**为什么 macOS 14/15 不能跨桌面恢复？** 旧的系统接口从 macOS 14.5 起被拦截，新接口从 macOS 26 才有。

**怎么卸载？** 退出应用，删掉 `LayoutKeeper.app` 和 `~/Library/Application Support/LayoutKeeper/`，运行 `defaults delete local.layoutkeeper.app`，再到系统设置的「登录项」和「辅助功能」里移除它。

**以前叫 SpacePort？** 是的，0.4.0 改名，首次启动会自动复制旧数据。

## 从源码构建

需要 Xcode 16 或更新（Swift 6）。

```sh
git clone https://github.com/tumingke0/LayoutKeeper.git
cd LayoutKeeper
./scripts/test.sh     # 可选：运行测试
./scripts/build.sh    # 生成 build-products/LayoutKeeper.app
open build-products/LayoutKeeper.app
```

钥匙串里有「LayoutKeeper Self-Signed」证书时，构建会用它签名；没有就用 ad-hoc 签名，这时每次重新构建后都要到「辅助功能」里删掉旧条目再重新添加。技术细节见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。

## 参与贡献

欢迎提 Issue 和 PR，见 [CONTRIBUTING.md](CONTRIBUTING.md)。报告问题时请附上 macOS 版本（含 build 号）和「设置 → 诊断 → 一键自检」的报告。报告里不含窗口标题。

## 致谢

- [AltTab](https://github.com/lwouis/alt-tab-macos)（GPL-3.0）：查找其他桌面窗口的思路，本项目独立实现。
- [yabai](https://github.com/koekeishiya/yabai)（MIT）：WindowServer 窗口标记位的含义。
- [MonitorControl](https://github.com/MonitorControl/MonitorControl)（MIT）：DDC 控制的参考。
- SnapBack：插上屏幕后恢复的交互思路。

详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 许可证

[GPL-3.0-only](LICENSE)。Copyright (C) 2026 LayoutKeeper contributors.
