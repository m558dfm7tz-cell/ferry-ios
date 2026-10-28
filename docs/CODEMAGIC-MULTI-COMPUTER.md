# Ferry iOS：Codemagic 开发分支验证

## 状态与范围

此文档对应 `feat/multi-computer-isolation-20261029`。Codemagic YAML 位于仓库根目录。所有 Codemagic 构建保持 **手动触发**，不会因为每次提交耗用免费 macOS 分钟。原有未签名 IPA 流程保留；额外的开发验证流程不自动部署也不改手机上的正式 Ferry。

* `ferry-ios-multi-computer-validation`：先运行已有 `FerryUITests` 模拟器测试，再用 Xcode 16.4 打 Release 无签名归档并打包 IPA。测试或构建失败会使工作流失败。
* `ferry-ios-sideloadly`：保留原本的 Release 未签名 IPA 流程，在只需检查 iPhone 编译或做独立安装准备时手动运行。它不执行模拟器 UI 测试。

使用 M2 macOS 构建机，目标项目为 `Ferry/Ferry.xcodeproj`，scheme 为 `Ferry`。开发版验证流程生成 `Ferry-MultiComputer-UNSIGNED-UNVERIFIED.ipa`、构建日志、UI 测试日志、Git commit 记录。IPA 仅说明归档打包成功，不代表两电脑实机验收成功。

## 手动在 Codemagic 启动

1. 进入 [Codemagic](https://codemagic.io/) 并找到已连接 GitHub 的 `m558dfm7tz-cell/ferry-ios` 项目。若还没添加仓库，先在 Codemagic 授权并选择该仓库。
2. 点击 **Start new build**，使用 **codemagic.yaml** 配置。
3. Branch 选择 **`feat/multi-computer-isolation-20261029`**，Workflow 选择 **`ferry-ios-multi-computer-validation`**，确认后启动。若列表未出现，检查 Codemagic 项目的仓库权限和从选定分支读取 YAML 的配置。
4. 依次查看 **Confirm development branch and toolchain**、**Run existing iOS simulator UI regressions**、**Archive unsigned iPhone Release build**、**Package and verify unsigned development IPA**。
5. 全部步骤成功后从 Artifacts 下载未签名 IPA 和日志。没有成功的构建记录、测试记录之前，禁止把此候选版本当作通过验收的发布版。

## IPA 安装注意

该 IPA 使用 `CODE_SIGNING_ALLOWED=NO` 构建，**不包含苹果签名**。仅可在外部重新签名（例如 Sideloadly 的受支持流程）后尝试安装。须确保 App ID、Team、Share Extension、App Groups 等签名能力都与设备及签名账号兼容；不能保证任意未签名 IPA 均能成功安装。请先保留手机原有 Ferry 数据与必要的备份，正式实机替换仍需单独批准。

## GitHub Actions 与回滚

本分支已移除新建的 GitHub iOS 验证工作流，并将此前四个 iOS GitHub Actions 工作流改为仅 `workflow_dispatch`（手动）形式，避免在此分支成为基线后自动运行。**`main` 分支尚未合并这些修改，所以 main 上已有的自动 GitHub Actions 触发器仍在；本分支不能替代对 main 的管理。**

构建配置失败时只需修复开发分支的 `codemagic.yaml`；不会影响 Go/Windows/Helper 或生产数据库。若放弃新方案，可从该开发分支恢复 `codemagic.yaml` 的原始 `main` 版本，不需要撤销 iOS 业务代码。


### Side-by-side installation safety (2026-10-29)

The manual multi-computer Codemagic workflow now applies an **ephemeral build-only** bundle-ID and App Group rewrite in its checkout: `com.ferry.test.multi` and `group.com.ferry.test.multi.shared`. This keeps the unsigned test IPA separate from an installed regular Ferry app using `com.ferry.test`; no production project settings are committed. After external signing (e.g. Sideloadly), verify the signed IPA still uses the multi-computer test identifier before installing. The isolated test app has new Keychain, local storage and App Group and therefore must be paired to each test server independently. If the signing utility rewrites the bundle identifier to conflict with production, **do not install it**. Native share-extension capabilities depend on external signing entitlements and must be tested separately.

The workflow deliberately does **not** run iOS UI tests or simulator tests. Its Release IPA archive has not yet been confirmed successful in Codemagic. Build outputs are unsigned and not App Store installable.
