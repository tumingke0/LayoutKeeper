# 不使用公司证书的最小试用路径

> 0.4.0 起应用改名为 LayoutKeeper（原名 SpacePort）。本文中的 SpacePort、`SpacePort.app`、`spaceportctl`、`~/Library/Application Support/SpacePort` 等是当时的名称和路径，记录的是历史证据，未改写；现在分别对应 LayoutKeeper、`LayoutKeeper.app`、`layoutkeeperctl`（`spaceportctl` 仍为软链接）、`~/Library/Application Support/LayoutKeeper`。
>
> 文中引用的 `Diagnostics/` 证据文件包含开发机的路径、硬件和签名信息，公开发布前已移出仓库，不随源码发布；这里只保留结论。

本轮仅准备候选文件与校验清单，没有替换安装版、请求辅助功能、使用私钥、改动钥匙串或移动用户窗口。

## 推荐：冻结当前 ad-hoc 候选，授权后先验证真实保存

不使用任何证书，也不需新建身份。候选 `build-products/SpacePort.app` 已包含简单模式、自动识别外接屏、真实窗口只读保存和覆盖数量。它还不提供一般工作窗口跨桌面自动恢复。

冻结清单 `Diagnostics/frozen-trial-manifest.json` 记录候选整个 bundle 的文件哈希；`python3 scripts/frozen-release.py check build-products/SpacePort.app Diagnostics/frozen-trial-manifest.json` 校验。清单只能首次建立，不能静默覆盖。此清单用于防止误更新，不替代系统签名安全验证。

下一步所需用户授权只有：允许把这个冻结版本替换到固定路径，并为该最终版本完成一次标准辅助功能授权。不得承诺一次授权永远有效；macOS 27 上当前没有冻结版本重启后的连续性证据。冻结保证本轮不再因主动重编译改变身份。

获准后开发者正常退出旧 GUI，校验候选，使用已有受控安装脚本的显式身份迁移选项部署，再校验部署文件与冻结清单完全一致。由用户在系统设置处理权限；不访问或重置 TCC，不反复开关。确认 GUI 自身 trust=true 后：

1. 只读保存外接屏各普通桌面的可枚举窗口，报告普通桌面数、涉及桌面数、窗口数及读取失败；不能把有窗口的全部桌面数等同于完整窗口覆盖。
2. 正常重启同一冻结应用，再确认 trust 和记录回读，无需主动弹出授权。
3. 只测试此前批准的 SpacePort 自有空白窗口往返与位置尺寸回读。用户工作窗口保持不动。

真实跨应用/跨屏恢复需要另一项有具体范围的测试授权，优先两个新建空白 TextEdit 窗口。该授权目前没有收到。已有自有窗口成功证据不能外推到其他软件。一般 Spaces 后端仍禁用；未验证前不开放自动恢复。

冻结版用于有限试用：任何新的代码更新都会改变 ad-hoc 身份，不能无缝升级。后续开发继续产出候选，不覆盖冻结安装版。

## 个人本地签名：备选，当前未执行

Apple 官方提供通过“钥匙串访问 → 证书助理”创建自签名证书的流程：https://support.apple.com/guide/keychain-access/create-self-signed-certificates-kyca8916/mac 。可选择个人、本机专用的代码签名身份，避免借用公司证书。它不是 Apple Developer ID，也不提供分发公证。

若将来采用，需要单独批准创建个人密钥/代码签名证书并保存到指定个人钥匙串，以及后续使用私钥签名；可能出现钥匙串确认。本轮没有创建或修改。还必须验证两个不同版本使用同一身份后指定要求是否稳定，以及 macOS 27 的实际权限连续性。不能把通用自签名流程当作已验证的 TCC 解决方案，也不建议为本轮试用增加证书或信任设置。

结论：先冻结候选并做一次最终版本授权，是最少新增系统改动的真实保存验证路径；它解决试用期间身份不断变化的问题，不解决跨应用 Spaces 移动尚未验证的问题。
