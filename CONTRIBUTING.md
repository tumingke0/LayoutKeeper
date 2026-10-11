# 参与贡献 / Contributing

谢谢你愿意帮忙！ Thanks for helping out!

## 报告问题

请使用 Issue 模板，并附上 **macOS 版本（含 build 号）** 和 **一键自检报告**（设置 → 诊断）。自检报告和诊断导出不含窗口标题；请不要粘贴布局文件（`Layouts/screens/*.json`）或撤销日志，它们含有你的窗口标题。

## 开发

```sh
./scripts/test.sh     # 单元测试（可用 LAYOUTKEEPER_BUILD_DIR=/tmp/lk-build 把构建缓存放到别处；旧名 SPACEPORT_BUILD_DIR 仍可用）
./scripts/build.sh    # → build-products/LayoutKeeper.app（ad-hoc 签名）
build-products/LayoutKeeper.app/Contents/MacOS/LayoutKeeper --render-ui-snapshots /tmp/lk-shots   # 用示例数据渲染界面截图，不读取真实窗口
```

- 结构：`Sources/LayoutCore`（纯逻辑，可单元测试）、`Sources/MacAdapters`（AX / SkyLight / 屏幕）、`Sources/SpaceProbe`（ObjC 私有接口桥）、`Sources/SpacePort`（应用：菜单栏、界面；目录名沿用旧名）、`Sources/spaceportctl`（`layoutkeeperctl` 命令行）。详见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)。
- 新逻辑请尽量放进 `LayoutCore` 并写单元测试；测试只用内存窗口和临时文件，**不要在测试里移动真实窗口**。
- 安全规则不能放宽：不猜窗口、移动后必须回读确认、失败回滚、布局文件不写窗口 ID / Space ID / 显示器 UUID。
- 每个源文件开头保留 `// SPDX-License-Identifier: GPL-3.0-only`。
- 不要提交个人数据：`Diagnostics/`、`Layouts/screens/`、`Layouts/transactions/`、`build-products/`、`scripts/signing.local` 都已在 `.gitignore` 里。
- 界面文字目前是中文；欢迎帮忙做本地化。

## 许可证

提交贡献即表示你同意以 [GPL-3.0-only](LICENSE) 授权你的代码。如果借鉴了其他项目的代码，请在 PR 里说明来源和许可证，并更新 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

---

**English**: please use the issue templates and include your macOS version (with build number) and a self-test report (Settings → 诊断). Put new logic in `LayoutCore` with unit tests; never move real windows in tests; keep the safety rules (no guessing, read-back verification, rollback, no window/Space IDs in layout files). Contributions are licensed under GPL-3.0-only.
