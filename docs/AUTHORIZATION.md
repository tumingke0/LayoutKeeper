# 辅助功能授权与稳定构建

> 0.4.0 起应用改名为 LayoutKeeper（原名 SpacePort）。本文中的 SpacePort、`SpacePort.app`、`spaceportctl`、`~/Library/Application Support/SpacePort` 等是当时的名称和路径，记录的是历史证据，未改写；现在分别对应 LayoutKeeper、`LayoutKeeper.app`、`layoutkeeperctl`（`spaceportctl` 仍为软链接）、`~/Library/Application Support/LayoutKeeper`。
>
> 文中引用的 `Diagnostics/` 证据文件包含开发机的路径、硬件和签名信息，公开发布前已移出仓库，不随源码发布；这里只保留结论。

2026-10-10 本机调查；本轮没有触发触控 ID、辅助功能或钥匙串授权，没有使用私钥，没有创建证书、修改信任设置或访问 TCC 数据库。

## 已确认事实

- 固定 bundle：`<项目目录>/dist/SpacePort.app`；规范化路径没有符号链接跳转。
- `CFBundleIdentifier` 和实际签名 identifier 均为 `local.spaceport.prototype`，`CFBundleExecutable` 为 `SpacePort`，真实可执行路径为 `Contents/MacOS/SpacePort`。
- 已部署 GUI 进程 81319 的运行签名与磁盘一致：ad-hoc，证书数量 0，TeamIdentifier 未设置；指定要求为 `cdhash H"9f32a63372cf560ac5d139745d82c6dcf003ef76"`。见 `Diagnostics/live-gui-identity.json`。
- 历史获准测试版本的要求是 `cdhash H"98f6c1d01001409980c7fce726f2237318b2e2f5"`；现在的要求不同，虽然路径与 bundle identifier 相同。历史上标准重新添加当前版本后，GUI trust 从 false 到 true，后续编译再次变为 false。
- 固定路径的 GUI 本轮直接查询自己的 `AXIsProcessTrusted()`，结果仍为 false；不是从 CLI 的结果推测。见 `Diagnostics/auth-installed-gui-readonly.json`，窗口写操作 0 次、权限请求 0 次。
- 本机现有 **1 个 Apple Development 签名身份**。只查询了可用身份和公开指纹；没有访问私钥或测试签名能力。其公开指纹记录在 `Diagnostics/signing-environment.json`。

## 根因与证据范围

旧构建脚本每次直接覆盖 `dist/SpacePort.app`，并执行 `codesign --sign -`。ad-hoc 指定要求绑定二进制 cdhash，因此更新后的应用不再满足旧哈希要求。这是当前反复失配最强且可复现的解释：构建脚本、两个真实签名要求、GUI 回读和重新添加后的历史结果一致。没有读取 TCC 内部记录，因此不宣称看到了系统数据库中保存的具体要求。

Apple 的 [TN2206 指定要求说明](https://developer.apple.com/library/archive/technotes/tn2206/_index.html#//apple_ref/doc/uid/DTS40007919-CH1-TNTAG205) 解释，系统通过 designated requirement 识别一个程序及其更新；仅保持 identifier 不足以保持当前这种哈希身份。这是通用签名规则，macOS 27 的实际 TCC 跨构建连续性仍需后续实测。

## 进程归属

| 组件 | 实际作用 | 权限判断 |
| --- | --- | --- |
| `dist/SpacePort.app` GUI | 直接调用 AX、窗口采集与自有空白测试 | 在此进程查询 trust，才代表当前 GUI 的判断 |
| `spaceportctl` | 只读诊断、模拟和配置校验 | 独立可执行文件；诊断中的 trust 属于调用进程/其责任链，不能作为 GUI 权限结论 |
| `probe-live-identity.swift` | 仅读取指定 SpacePort GUI 的代码签名元数据 | 可查目标签名，但其中 probeAXTrusted 只代表探针；不是目标 GUI 的 trust |
| helper / XPC / 登录服务 | **没有实现或安装** | 不存在授权应迁移到 helper 的情况 |

新诊断在 `authorizationIdentity` 明确输出 PID、完整可执行路径、bundle identifier、签名 identifier、TeamIdentifier、cdhash、指定要求及已部署 GUI / 候选 GUI / CLI 分类。见 `Diagnostics/candidate-cli-identity.json`。没有借用 CLI 权限执行 GUI 操作。

## 已完成保护

1. `scripts/build.sh` 只生成 `build-products/SpacePort.app` 和候选 CLI。普通编译不再覆盖已部署 GUI。
2. `scripts/install-local.py --check-only` 比较真实指定要求。本轮候选要求变化，被拒绝；`dist` 二进制 SHA-256 保持 `c527b2b831d280f0f8f0bae63adea48286a8edd4fa3fde86267c3f3c3bd6f880`。
3. 正式本地替换必须在 GUI 正常退出后进行；脚本不会杀进程。签名身份变更还要求明确的 `--accept-identity-change`，保留旧 bundle 备份。该更新本轮未执行。
4. 选用证书私钥签名必须显式设置 `SPACEPORT_ALLOW_KEYCHAIN_SIGNING=1`；否则在构建和任何钥匙串操作前拒绝。本轮门槛测试退出 3。没有自动选择现有证书，也没有无声回退。
5. 未使用仅凭 identifier 的弱自定义要求；未修改 TCC、钥匙串 ACL、证书信任或系统保护。

构建、32 个 XCTest、真实身份变更保护和私钥门槛检查均通过。见 `Diagnostics/auth-build.log`、`auth-tests.log`、`promotion-guard-check.*` 和 `private-key-guard-check.txt`。这些保护防止继续制造失配，**尚未恢复当前 GUI 的既有权限**。

## 可持续方案与精确剩余步骤

推荐使用本机**已有** Apple Development 身份进行本地签名，不必创建或安装新证书。先由用户确认可将此身份用于 SpacePort；可能需要系统允许本次私钥操作，本轮避免该弹窗而没有调用。

获准后，由开发者完成：

1. 对两个代码不同的候选版本使用同一已确认身份签名，验证指定要求稳定，并检查签名有效、TeamIdentifier 与固定 bundle identifier 一致。若签名失败即停止，不修改钥匙串权限。
2. 正常退出 GUI，通过受控本地更新部署到唯一固定 `dist/SpacePort.app`。从 ad-hoc 换成证书身份会改变指定要求，预计仍需一次由用户完成的标准系统授权迁移；不能承诺旧授权无缝继承。
3. 仅在签名和版本最终稳定后处理这一次迁移，随后实际验证新 GUI 的 trust，并用已经批准的自有空白窗口核实后续更新是否继续有效。
4. 若 macOS 27 仍不保持授权，保留证据并停止反复开关，不自动重置授权或替换签名要求。

准备好的签名命令（本轮未执行）：

```sh
SPACEPORT_SIGNING_IDENTITY='<已确认身份的公开 SHA-1 指纹>' \
SPACEPORT_ALLOW_KEYCHAIN_SIGNING=1 ./scripts/build.sh
python3 scripts/install-local.py --check-only
```

这是待确认的既有私钥使用与签名迁移方案，不是新证书、信任安装、权限绕过或公开发布。

## 外接屏多个原生桌面的保存范围

扫描向每个普通软件查询其 `AXWindows`，对返回的窗口读取实际桌面成员关系，随后筛选目标外接屏。没有按“活动桌面”过滤，所以**能保存来自多个原生普通桌面的可枚举窗口**；新增测试同时包含外屏活动桌面和非活动桌面上的普通窗口，二者都被保存。

记录新增 `coverage`：可见普通桌面总数量、保存窗口涉及的桌面数量、可读取窗口数量，以及“仅可枚举窗口，不保证完整”的范围声明。旧记录无 coverage 仍可读。不保存 Space ID、桌面序号或窗口 ID；数量是采集统计，不是持久标识。

但是系统和各应用可能不在 `AXWindows` 返回非当前桌面的全部窗口。属性读取失败或超过每应用 100 个窗口时也会报告遗漏。**当前 macOS 27 的真实跨桌面枚举范围仍未实测**，因为 GUI trust=false；模拟与源码检查不能替代它。当前既不能说“只支持当前桌面”，也不能声称已完整保存整个外屏的所有桌面。

稳定签名并完成一次权限迁移后，可继续获准的真实布局只读保存，按运行时桌面计数核实范围；不移动工作窗口。跨应用移窗、跨屏与完整自动恢复仍保持未开放，两个新建空白 TextEdit 窗口的测试范围仍待批准。
# 0.1.1 修复与新的证据边界

2026-10-10T07:01:09Z 的 GUI 自诊断已确认：PID 70020，运行于 `build-products/SpacePort.app`，CDHash `886bb996738047d0f19a806d147ff7052d3619f2`，Team ID（公开版已省略），证书数 3，`liveCodeStatus=0`，当前 GUI 自己的 AX trust=false。因此这次现象不能归因于启动了旧 dist。旧设置记录不匹配仍是解释之一，未读取 TCC 数据库，未证明系统层原因。

0.1.1 将 GUI 授权状态改为每两秒只读采样；保存失败按窗口读取、屏幕变化、布局采集和文件写入分类；AX 属性及窗口回读保留操作名和原始错误码。未授权文案不再宣称编译或签名变化是原因。界面显示版本和测试候选/固定安装入口标识，提供用户点击的系统设置入口，不调用请求授权 API。

正式入口计划固定为 `~/Applications/SpacePort.app`。受控安装默认只预览，明确部署才写入；仅接受已批准的开发签名，保留前版本，拒绝替换运行实例，迁移布局时不覆盖已有记录。当前修复在隔离开发副本中完成，仅交付测试通过的 Debug ad-hoc 候选，未部署或调用私钥。应用能够检查授权，不能代替用户完成系统允许、触控 ID 或密码。

以下是先前构建的历史诊断，不应外推到上述新样本。

