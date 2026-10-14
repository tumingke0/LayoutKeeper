# LayoutKeeper 亮度 / 音量控制 — 方案（设计稿阶段）

## 可行性（2026-10-14 在用户 Mac 上只读探测，macOS 27.0 / Apple Silicon）
- DELL S2421HSX：DDC/CI 读取 VCP 0x10 成功（IOAVService，第 1 次即成功），当前亮度 38 / 最大 100。未做任何写入。
- 内建屏：DisplayServicesGetBrightness 可读，返回 0.419（约 42%）。
- 同时在运行：BetterDisplay（pid 737）。

## 功能
1. 菜单栏「显示器」区：每块屏一组滑块。外接屏：DDC 亮度 + 音量（VCP 0x10 / 0x62，静音 0x8D）；DDC 不响应时标「软件调暗」（gamma 表或覆盖层），音量隐藏。内建屏：DisplayServices 亮度。
2. 亮度键（F1/F2、媒体键）调节鼠标所在屏幕，显示 HUD（屏幕名、百分比胶囊、内建屏可显示尼特、滑条 + 太阳图标 + 刻度点）。音量键可选（仅当鼠标所在外接屏支持 DDC 音量时接管，否则交给系统）。
3. 步进 1/16（与刻度点一致），按住 ⌥⇧ 微调 1/64。

## 设置（新「显示器」页，全部默认关闭/保守）
- 在菜单栏显示亮度/音量滑块（默认开）
- 亮度键调节鼠标所在的屏幕（默认关）
- 音量键调节外接显示器音量（默认关）
- DDC 失败时使用软件调暗（默认开）
- 每块屏：禁用 DDC（遇到兼容问题时）

## 按键拦截与权限
- 亮度/音量是 NX_SYSDEFINED 媒体键事件，需 CGEventTap（.cgSessionEventTap，可拦截）。需要“辅助功能”权限——LayoutKeeper 已有，且 0.6.1 起签名稳定，更新不丢权限。不需要“输入监控”（tap 拦截媒体键在辅助功能授权下可用；实现时实测确认）。
- 只在开关打开时安装 tap；tap 被系统禁用（超时）时自动重启。
- DDC/DisplayServices 不需要额外权限；均为私有/未公开接口，需动态加载、失败即降级。

## 与 BetterDisplay / MonitorControl 同时运行
- 两个程序同时写 DDC 会互相打架（数值跳动、I2C 冲突导致读失败）；同时拦截按键会出现两个 HUD 或一次按键调两次。
- 方案：启动时检测这些 App 是否在运行（bundle id），在运行时：默认不接管按键，并在设置里提示；菜单滑块仍可用但标注“可能与 BetterDisplay 冲突”。DDC 写入做节流（≥50 ms 间隔、合并连续写入），读失败重试 3 次。

## 实现
- MacAdapters/DDC.swift：Apple Silicon 用 IOAVService（DCPAVServiceProxy，按 EDID/位置匹配 CGDisplay），Intel 用 IOFramebuffer I2C（IOI2CSendRequest）。思路参考 MonitorControl（MIT）；若改编其代码，在 THIRD_PARTY_NOTICES.md 注明 MIT 版权与许可。不使用 BetterDisplay 的任何资源或代码。
- MacAdapters/BuiltInBrightness.swift：DisplayServicesGet/SetBrightness（动态加载）。
- 软件调暗：CGSetDisplayTransferByFormula（gamma），退出时恢复。
- SpacePort：BrightnessHUD（NSPanel，非激活、忽略鼠标、所有桌面可见、显示在鼠标所在屏底部中央，1.5 s 渐隐）、菜单区、设置页、KeyTap。
- 纯逻辑（步进、映射、节流、冲突判断）放 LayoutCore 并写单元测试。

## 工作量估计
- DDC（Apple Silicon）+ 内建亮度 + 菜单滑块：1.5–2 天
- 按键拦截 + HUD：1–1.5 天
- 软件调暗、音量/静音、冲突检测、设置页：1 天
- Intel I2C（无真机，只能编译）：0.5 天
- 测试与打磨：1 天
合计约 5–6 天。

## 风险
- 部分显示器/转接头/扩展坞不支持 DDC；HDMI 口在某些 Apple Silicon 机型上 DDC 不可用。
- DisplayServices 是私有接口，系统升级可能变化。
- 与 BetterDisplay 并存冲突（见上）。
- Intel 版无法真机测试。
