# 开发与技术说明

> 这是 0.4.0 之前 README 的技术内容（实现细节、测试范围、跨桌面采集、一键自检等），面向开发者。用户向的说明见仓库根目录 [README](../README.md) 和 [使用说明](USABILITY.md)。

## 改名与数据迁移（0.4.0）

- 应用名 `LayoutKeeper`，构建产物 `build-products/LayoutKeeper.app`，bundle ID `local.layoutkeeper.app`（旧为 `local.spaceport.prototype`）。命令行 `build-products/layoutkeeperctl`，`spaceportctl` 是指向它的软链接。URL scheme `layoutkeeper://`，旧的 `spaceport://` 仍可用。
- 数据文件夹：`~/Library/Application Support/LayoutKeeper/`（布局在 `Layouts/`，自检报告在 `SelfTest/`）。
- 第一次启动时，如果新文件夹里还没有屏幕布局，会从旧位置**复制**（不移动、不删除）全部数据：`~/Library/Application Support/SpacePort/`，以及从项目 `build-products` 运行时旧版实际使用的项目内 `Layouts/`。复制包括布局、`.previous.json` 上一版、撤销日志、自检报告。同名文件取修改时间较新的一份。每个文件逐字节比对，原本能解析的布局/日志在副本上也必须能解析，全部通过后才放入新文件夹并写下 `migration-from-spaceport.json` 标记；失败时不写标记，下次启动重试。旧文件夹保持原样。
- 偏好设置（接上屏幕时的模式等）从旧 bundle ID 的偏好域复制一次。
- 设置 → 通用 → 关于 显示数据文件夹和迁移结果。

## 运行与测试

```sh
cd LayoutKeeper   # 克隆后的项目目录
./scripts/test.sh
./scripts/build.sh                     # → build-products/LayoutKeeper.app
./scripts/build.sh --arch arm64        # → build-products/arm64/LayoutKeeper.app（Apple 芯片）
./scripts/build.sh --arch x86_64       # → build-products/x86_64/LayoutKeeper.app（Intel）
./scripts/make-icon.sh                 # 重新生成 Resources/AppIcon.icns 与 docs/images/icon.png（仅改图标时需要）
open build-products/LayoutKeeper.app
./build-products/layoutkeeperctl diagnose
./build-products/layoutkeeperctl simulate
```

普通构建只生成 `build-products/LayoutKeeper.app` 和 `build-products/layoutkeeperctl`，不会覆盖已运行版本，也不会碰旧的 `build-products/SpacePort.app`。`scripts/install-local.py` 默认只预览；显式 `--install` 才部署到 `~/Applications/LayoutKeeper.app`。部署要求已批准的开发签名（团队 ID 与签名身份通过环境变量 `LAYOUTKEEPER_TEAM_ID` / `LAYOUTKEEPER_SIGNING_IDENTITY` 或 gitignored 的 `scripts/signing.local` 提供，不写进源码），拒绝 ad-hoc 候选，拒绝任何 LayoutKeeper/SpacePort GUI 正在运行的情况；指定要求变化须显式接受。已有签名身份和诊断边界见 [授权与稳定构建](AUTHORIZATION.md)。

需要已有 Xcode/Swift 工具链。本机使用 Swift 6.4、macOS 27 SDK、arm64 构建。默认构建采用不使用私钥的 ad-hoc 签名，只用于候选验证；正式部署需另行获准沿用开发签名。没有发布或联网功能；开机自启只在用户于引导或设置中开启时通过 SMAppService 注册。`--disable-sandbox` 仅关闭 SwiftPM 的构建子进程沙箱；不改变 SIP、TCC 或系统安全设置。构建缓存默认在项目 `.build`，可用 `LAYOUTKEEPER_BUILD_DIR=/tmp/spaceport-build` 指定其他路径（旧名 `SPACEPORT_BUILD_DIR` 仍可用）。

## 已实现

- 主窗口：检测外接屏的厂商、型号、设备序列号，自动查找对应 JSON 记录。布局只存窗口匹配、逻辑组和归一化坐标；硬件身份单独保存。
- 桌面会话绑定由核心保留；保存自动分组，不要求用户理解桌面绑定。Space ID、运行时显示器 UUID、窗口 ID 不写入布局记录。手动恢复使用本次连接的明确桌面绑定；重连后的原桌面语义仍不自动猜测。
- 只读采集：保存外接屏所有普通桌面上可读取的普通窗口（不只当前桌面），见下方“跨桌面采集”；不启动软件或切换桌面。再次保存会提示覆盖，旧布局进入 `screens/history/<key>/`（最近 5 个，带名字的不清理），版式在 `screens/named/<key>/`，来源与名字记录在同目录的 `.idx` 索引里；明确说明读取数量与覆盖范围。
- 窗口匹配（一键恢复）：bundle ID 必须一致；普通应用优先精确文档路径，其次精确标题；浏览器用去掉未读数和“ - Google Chrome”等后缀的标题，不用网址作主键。重名时按保存的桌面序号和位置大小挑唯一一个，仍不唯一则“需要确认”由用户在候选中选择。规则在 `Sources/LayoutCore/QuickRestore.swift`，有单元测试。
- 桌面对应：保存时记录窗口在第几个普通桌面（序号，不是 Space ID）；恢复时第 N 个对应现在第 N 个；桌面不够时提示“请先在调度中心新建桌面”，不猜不建。
- 写位置/大小：按变大/变小决定先后顺序，写入时临时关闭 AXEnhancedUserInterface，回读不符换顺序再试一次（`FrameWritePlanner`）。
- 接上屏幕/唤醒：`ReconnectWatch` 纯逻辑状态机，3 秒防抖，模式 关闭/先询问/自动（默认先询问；自动只执行唯一匹配、已验证路径的窗口，始终可撤销）。思路参考 SnapBack（Apache-2.0），代码为本项目自写。
- 预览和逐项报告：ready / blocked / skipped；执行后 verified / failed / blocked / skipped。预览过期、身份或位置改变会停止操作。
- 同一普通桌面上的 AX 位置/尺寸恢复，必须先有辅助功能权限，并确认预览中具体窗口。本机空白窗口的实际改动和规划恢复通过，AX、AppKit、WindowServer CG 三份回读一致。
- 全屏/Split View、最小化、非普通窗口、无法读取全屏状态、未知或多桌面成员关系均跳过。
- 可替换 `SpacesBackend`；默认的 `ReadOnlySpaces.canMove` 为 false。默认跨桌面条目被阻止；本次明确启用并确认后才创建窗口专属 ControlledSpaces 许可，源/目标成员关系回读通过后才写几何。不会通过写坐标冒充桌面恢复。
- 自动化验证覆盖布局、权限状态、重连规划、窗口身份、保存版本保留、操作快照和回滚/撤销；另有受控安装测试。测试只用内存窗口和临时文件，不读取真实工作窗口或改变系统授权。

AX 的 `kAXWindows` 只列出当前显示桌面的窗口；跨桌面采集用补充查找弥补，但在时限内没找到的窗口只标记为“状态未知”，不保证全部找回。已经实现外接屏硬件识别与对应记录读回，但没有经过验证的真实自动恢复、桌面创建/删除/重排、软件重开、Z 顺序、标签页。新增手动恢复提供本次会话撤销和失败回滚；身份、位置、拓扑改变或读回失败时禁止猜测，仍可能留下明确报告的部分变化。

## 测试权限与范围

打开应用时只进行只读诊断。**0.5.0 起**，只有在使用引导第 1 步由用户点击“打开系统设置”时，才调用 `AXIsProcessTrustedWithOptions`（prompt=true）弹出系统授权提示并打开辅助功能面板；其他任何地方（启动、设置页的“打开系统设置”）都不弹提示。0.4.0 及以前从不弹提示。主窗口的真实恢复扫描由用户点击触发，必须查看预览并明确确认。

完成最终签名和固定安装后，系统授权只应对应 `~/Applications/LayoutKeeper.app`。应用按钮尝试打开控制权限面板，失败时退回系统设置；macOS 27 的实际面板名是“隐私与安全性 → 设备控制和数据访问”。用户本人完成允许 LayoutKeeper 的系统操作和可能要求的触控 ID/密码。应用自动检查自己的授权，不要求用户复制诊断字段。设置开关不能替代 GUI 查询结果。应用只使用 Accessibility API，不使用邮件、联系人等其他数据接口，不需要屏幕录制或输入监控权限。

（0.6.0 起移除了“高级”页的安全演示和空白窗口实测；诊断页仍保留内存后端验证，`--approved-fixture-test` 仍可用于开发。）

**先前构建已通过**的 macOS 26+ 私有桥接探针保留为已批准的集成测试入口，见 `docs/COMPATIBILITY.md`。它只将自有空白窗口移到同屏另一普通桌面，实际回读后再返回源桌面并再次回读。底层检查当前进程拥有窗口、准确名称、普通状态，以及运行时跨桌面能力（macOS 26+ 且接口齐全，0.3.0 起取代写死的 build 26A428 检查）；拒绝其他应用窗口。简化界面不暴露此专家探针，不启用通用移窗后端。

首次真实测试中，应用进程 `AXIsProcessTrusted()` 为 false 时仍验证了成员关系 `4 → 6 → 4`，AppKit 与 CG 几何数据保持 `(220,354,520×368)`。这只证明该 build 的本应用单一普通窗口往返；不得外推到其他应用、其他 build、多窗口、跨显示器或换屏场景。Space ID 只出现在这次运行的诊断证据中。

已批准测试的自动运行方式与原始证据见 `docs/COMPATIBILITY.md`。普通启动不会运行写测试。ad-hoc 签名随二进制内容改变；本次更新后二进制曾出现设置开关开启但 `AXIsProcessTrusted()` 为 false，标准移除并重新添加同一 `.app` 后恢复可用。以后重编译若复现，请通过系统设置重新添加当前版本，不降低系统保护。

## 文件

- `Sources/LayoutCore`：纯布局模型、保存/规划/执行回读验证、内存模拟。
- `Sources/MacAdapters`：NSScreen、AX、动态解析的 SkyLight **只读**接口。
- `Sources/SpaceProbe`：仅允许本进程 Fixture 1 的私有桥接实验入口。
- `Sources/SpacePort`：应用目标（产物名 LayoutKeeper；目录名沿用旧名以降低改动风险）：菜单栏、全局快捷键、轻提示、主窗口、设置。
- `Sources/LayoutCore/MonitorLayout.swift` / `Sources/MacAdapters/MonitorRecognition.swift`：硬件匹配与只读外屏采集。
- `Layouts`：旧版（≤0.3.0 从 build-products 运行时）的数据位置；0.4.0 起只作为迁移来源，新数据在 `~/Library/Application Support/LayoutKeeper/Layouts`。
- `Sources/spaceportctl`：`layoutkeeperctl` 只读诊断、模拟、配置校验 CLI；没有真实移窗命令。
- `Diagnostics/`（gitignored，不随源码发布）：本机诊断、启动测试和自动测试记录。
- `docs/COMPATIBILITY.md`：本机与上游证据、未测项目和批准后的最小步骤。

配置文件可能包含本地窗口标题和文档路径，仅写入用户选择的本地文件。诊断只导出屏幕和桌面信息、符号可达性及窗口数量，不导出用户窗口标题、文档内容或截图。没有禁用 SIP、Dock 注入、sudoers 修改、未知 fork、自启或推送。

## 跨桌面采集

保存/“检查可保存窗口”对每个普通应用依次读取：`kAXWindows`（只含当前桌面）、`kAXFocusedWindow`、`kAXMainWindow`，按窗口 ID 去重。随后用公开的窗口列表加 Space 归属算出该应用在各桌面的“候选窗口”，对 AX 没给出的候选，用远程元素令牌（`_AXUIElementCreateWithRemoteToken`，动态解析）逐个查找；只接受 role 为 AXWindow 且窗口 ID 正是所需候选的元素，并照常校验 pid 与 CG 归属。每个应用最多约 1.5 秒、每次扫描合计约 8 秒、元素编号上限 20 万；超时的应用在本次运行内记住进度，下次接着找。没找到的窗口计为“状态未知”，采集标记为可能不完整，绝不当作已关闭。

候选窗口要求：普通层级、无父窗口、至少 100×50、不透明、属于某个桌面，并且 WindowServer 标记为文档窗口且已显示（或已最小化）。最后一条用于排除 Chrome 地址栏/气泡等弹出窗口和已关闭但仍保留的窗口，其位含义参考 yabai（MIT，见 `THIRD_PARTY_NOTICES.md`）；读不到这些标记时一律保留为候选（宁可报未知，不会漏报）。是否保存仍只看 AX：标准窗口 subrole、非最小化、非全屏、标识唯一。

设置 → 诊断 里有“逐窗口追踪”（窗口 ID、尺寸、桌面槽位、来源与结果），只在本次运行中显示，不写入布局文件。命令行只读诊断：`build-products/layoutkeeperctl capture-coverage`。

## 一键自检（设置 → 诊断）

“一键自检（会临时移动真实窗口）”用当前真实窗口走一遍生产代码路径：只读采集（不覆盖已保存布局）→ 同桌面微调后恢复 → 跨桌面用恢复功能移出、撤销、再移出并测试后台桌面写位置/大小、恢复回原位 → 最终复位（无论成功、失败、停止或超时都会执行）。开始前弹出一次确认框，列出要动的窗口；不点确认不会移动任何窗口。运行中浮动面板可“停止并复位”，总时限约 60 秒。不切换当前桌面、不启动/退出应用、不动内置屏窗口。

报告写到 `~/Library/Application Support/LayoutKeeper/SelfTest/selftest-<时间>.json/.txt`，含窗口/Space ID、读回值、执行器和 `SPDispatchVerifiedWindow` 的原始结果，不含窗口标题（只有应用 ID 和标题短哈希）。自检的恢复日志在同目录 `transactions/`（日志本身含标题，不需要发送）。

也可用 `open build-products/LayoutKeeper.app --args --self-test`（应用未运行时）或 `open layoutkeeper://self-test`（旧的 `spaceport://self-test` 仍可用）直接弹出确认框；仍必须用户点击确认。

## 界面截图（不移动窗口）

`LayoutKeeper --render-ui-snapshots <目录>` 用示例数据在屏幕外渲染：主窗口三种状态（未保存 / 有差异 / 已是保存的布局）、菜单（普通 / 按住 Option / 未接屏）、自动恢复后的轻提示、“只问一次”提示、恢复预览面板（收起 / 展开详情 / 结果）、设置各页，输出 PNG 后退出；不读取真实窗口、不调用辅助功能、不移动任何窗口，也不做数据迁移。示例：`/tmp/spaceport-build/release/LayoutKeeper --render-ui-snapshots /tmp/spaceport-shots`。菜单截图由与真实菜单相同的 `StatusMenuModel` 画出。
