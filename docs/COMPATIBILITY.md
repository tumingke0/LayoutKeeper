# 兼容性证据与下一步

> 0.4.0 起应用改名为 LayoutKeeper（原名 SpacePort）。本文中的 SpacePort、`SpacePort.app`、`spaceportctl`、`~/Library/Application Support/SpacePort` 等是当时的名称和路径，记录的是历史证据，未改写；现在分别对应 LayoutKeeper、`LayoutKeeper.app`、`layoutkeeperctl`（`spaceportctl` 仍为软链接）、`~/Library/Application Support/LayoutKeeper`。
>
> 文中引用的 `Diagnostics/` 证据文件包含开发机的路径、硬件和签名信息，公开发布前已移出仓库，不随源码发布；这里只保留结论。

本记录是 2026-10-10 的本机观察。测试通过、未测、外部问题报告与执行器限制分别记录；不把私有符号存在当成功。

| 项目 | 结果 | 证据或范围 |
| --- | --- | --- |
| macOS | 已核实 | `sw_vers`：27.0 / 26A428 |
| 硬件 | 已核实 | Apple 芯片 MacBook Pro（arm64） |
| 工具链 | 已核实 | Xcode.app / Swift 6.4.0 / SDK 27.0 |
| SIP | 开启 | `csrutil status`；未修改 |
| 构建 | 通过 | Release CLI 与 ad-hoc 签名 SpacePort.app |
| 自动测试 | 通过 | 最新候选 32 个 XCTest，0 失败；原始核心 24 项保留 |
| 正常恢复模拟 | 通过 | 仅内存对象，回读得到目标框和目标 Space |
| 假成功模拟 | 通过 | 写调用未改变成员关系时被报告为 failed，未继续改坐标 |
| 应用启动 | 通过 | 控制窗口可见、菜单栏项创建、自己的窗口 Space 成员关系可读 |
| 显示器 | 只读通过 | 内置 Retina 屏；外接 1920×1080 显示器 |
| 普通桌面枚举 | 只读通过 | 内置屏 2 个、外屏 4 个；独立 Spaces 开启 |
| WindowManager | 进程存在 | 没有在本机打开 Mission Control 或读取其 AX 树 |
| 辅助功能 | 已按批准范围授权 | 标准系统设置流程；刷新当前 `.app` 后进程实际读到 true |
| AX 枚举/尺寸写入 | 隔离用例通过 | 仅自有新建 Fixture 1；改动与规划恢复后 AX/AppKit/CG 三份回读一致 |
| 真实跨桌面移窗 | 隔离用例通过 | `4 → 6 → 4`，AppKit/CG 坐标尺寸不变；通用后端禁用 |
| 两地点换屏完整恢复 | 未测 | 不得把坐标功能称作完整解决方案 |

沙箱内 `NSScreen.screens` 为空、WindowServer 信息不可读。之后在正常桌面会话重跑只读诊断得到真实屏幕和桌面。该差异属于执行器限制，不是 macOS 能力失败。证据见 `Diagnostics/host-readonly.json` 与 `Diagnostics/app-smoke.json`。

## 上游证据

- [yabai 官方支持列表](https://github.com/asmvik/yabai#requirements-and-caveats) 当前列出支持到 macOS 26，不能把 26 的支持承诺外推到 27。
- [7.1.25 变更](https://github.com/asmvik/yabai/blob/master/CHANGELOG.md) 记录 SIP 开启下移窗能力恢复；[issue 2788](https://github.com/asmvik/yabai/issues/2788) 的实际验证范围是 26.4 / 26.4.1。
- [issue 2800](https://github.com/asmvik/yabai/issues/2800) 是 27 beta build 26A5353q 的报告，主要描述版本检测和 Dock 注入偏移不匹配；它不能直接证明本机桥接方法失败。没有采用其安全保护绕过或 fork。
- [Hammerspoon issue 3897](https://github.com/Hammerspoon/hammerspoon/issues/3897) 的系统 build **也是 26A428**。报告 Mission Control AX 树改在 WindowManager，旧移窗路径可能返回成功而不移动。其作者的测试也报告合成鼠标点击/拖动不生效。这里只把它当兼容性风险证据，没有在本机复现这些写操作。
- [yabai 原始桥接提交 ce798b7](https://github.com/asmvik/yabai/commit/ce798b7) 使用桥接操作对象和私有本地函数。当前原型没有复制其隐藏符号扫描实现。

## 本机发现的候选路径

正常会话动态解析得到：`SLSMainConnectionID`、`SLSCopyManagedDisplaySpaces`、`SLSCopySpacesForWindows` 可达；桌面与本应用窗口成员关系只读查询成功。

`SLSBridgedMoveWindowsToManagedSpaceOperation` 类存在，但 `SLSPerformAsynchronousBridgedWindowManagementOperation` 的导出名及已知本地函数修饰名均不能用普通 `dlsym` 得到。**这只说明普通动态符号查找不可达，不说明该功能不存在。**

类运行时还显示：

| 类 / 方法 | 本机类型编码 |
| --- | --- |
| 移窗操作 `initWithWindows:spaceID:` | `@32@0:8@16Q24` |
| 基类 `performWithWMBridgeDelegate` | `v16@0:8` |
| `invokeFallback` | `v16@0:8` |

因此使用替代实验：经 ABI 检查后直接调用对象的 `performWithWMBridgeDelegate`，不扫描隐藏函数地址、不注入进程。**本机 27.0 / 26A428、SIP 开启、应用 AX trust 为 false 的实际运行中，单一自有空白普通窗口往返已回读通过。** 该结果来自成员关系和几何数据，不来自方法存在或调用返回值。其他应用、多窗口、跨显示器与异步边界行为仍未测。

通用后端始终 `canMove=false`。实验底层只允许当前进程名为 `SpacePort Fixture 1` 的普通窗口，且限定 27.0 / 26A428；不会尝试旧兼容 ID 路径、Dock 注入、CGEvent 拖拽或 Mission Control AXPress。

## 授权与实测记录

2026-10-10 03:16 UTC，用户明确批准辅助功能，以及只对新建 Fixture 1 的普通桌面往返、位置尺寸测试。没有扩大至工作窗口。系统触控 ID 由用户完成，未接触密码。

- `Diagnostics/fixture-real-first.json`：真实窗口 19181，进程 11908，AX trust=false。Space 成员关系 `4 → 6 → 4`，AppKit 与 CG 坐标尺寸均为 `(220,354,520×368)`。两次调用返回 0 仅表示已派发；实际回读决定通过。此运行 AX 阶段因权限不可用而阻止，没有写 AX。
- `Diagnostics/fixture-real-ax.json`：刷新签名对应的授权后，进程 15634 的 AX trust=true。Fixture 1 从 `(220,354,520×368)` 改到 `(280,394,600×418)`，规划恢复后 AX/AppKit 回到原值，但即时 CG 样本还显示上一帧。保留此中间证据，没有把它用作最终三方回读通过的依据。
- `Diagnostics/fixture-real-final.json`：03:42:44 UTC 开始，进程 19679、窗口 19558；AX trust=true。最终版本等待 CG 数据收敛。桌面 `4 → 6 → 4` 真实往返通过；AX 改动与规划恢复后，AX/AppKit/CG 三份位置尺寸完全一致，仍位于原普通桌面。测试进程已退出，空白窗口已关闭。通用移窗后端没有启用。

权限面板实际为“隐私与安全 → 设备控制和数据访问”。本地 ad-hoc 签名的指定要求是二进制 cdhash；本次重新编译后出现 UI 开关 on 而应用 trust=false。通过标准面板移除并重新添加同一路径的当前应用后得到 trust=true。没有读取/修改 TCC 数据库，没有创建签名证书、修改 sudoers 或关闭 SIP。

## 复现已批准的隔离测试

只在明确批准上述范围后运行。普通启动不会运行它；`spaceportctl` 不含真实移窗命令。

```sh
open -n -W dist/SpacePort.app --args --approved-fixture-test "$PWD/Diagnostics/fixture-real.json" --test-phase all
python3 scripts/verify-fixture-report.py Diagnostics/fixture-real.json
```

也可用 `--test-phase spaces` 或 `ax` 单独运行阶段。只创建当前进程名为 `SpacePort Fixture 1` 的一个空白窗口；自动选择同屏另一个已有普通桌面，不创建/删除桌面，不触碰其他应用。每次写操作前保存阶段，最多回读 20 次、每次约 150 毫秒；测试结束后退出该测试进程。报告只含自有窗口和运行时桌面引用，不含工作窗口标题或文档。

## 最小下一步

隔离测试通过后，可另行讨论多窗口、跨显示器、拔插显示器和一个明确指定的真实应用窗口的验收范围。当前通用 `SpacesBackend.canMove` 仍为 false；完整家/公司恢复没有通过验收。不能读出目标/源成员关系、普通桌面类型或窗口身份时停止，不以写坐标冒充跨桌面成功。

