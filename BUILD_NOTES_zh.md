# Ferry iOS：打包须知与注意事项

> 整理日期：2026-11-09（Asia/Tokyo）。本仓库是**公开仓库**，本文不含任何密码、token、内网地址。

## 简介与状态

Ferry 的 iPhone 端：和电脑上的 Ferry Go 服务互传文字/图片/视频/文件，AI 助手聊天，收藏、搜索、按日期跳转、OCR、图片编辑，iOS 分享扩展（FerryShare），局域网发现与多台电脑切换。

- 默认分支 `main`，最新提交 `5188e68`「Fix keyboard show/hide chat bounce; bump to build 23」（2026-10-31 05:24 JST）。版本 `MARKETING_VERSION 1.0`、`CURRENT_PROJECT_VERSION 23`，Bundle ID `com.ferry.test`。
- 注意：根目录 `README.md` 还是最早「只验证流水线的空壳 App」的描述，已过时，以代码为准（待更新）。
- 手机端截图/文件浏览等功能需连接已升级的电脑；真机验收待局长确认。
- 项目整体介绍和状态见 Ferry 主仓库（私有）的 `PROJECT_INTRO_zh.md`，所有程序总览见 `FERRY_ALL_PROJECTS_zh.md`。

## 环境

- macOS + Xcode 16.4（iOS 18 SDK），部署目标 iOS 18.0
- 项目 `Ferry/Ferry.xcodeproj`，scheme `Ferry`
- 首次构建前生成图标：`tools/make-icon.ps1`（读取 `C:\temp\ferry-icons\plane3-R3-256.png`）

## 构建无签名 IPA

```bash
xcodebuild -project Ferry/Ferry.xcodeproj -scheme Ferry -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -archivePath build/Ferry.xcarchive archive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
mkdir -p build/Payload && cp -R build/Ferry.xcarchive/Products/Applications/Ferry.app build/Payload/
cd build && zip -r -y Ferry-unsigned.ipa Payload
```

- GitHub Actions：`build-ipa.yml`（手动，或推送 `fix/chat-spacing-txt` 时自动）出 `Ferry-unsigned-ipa`；其他三个 verify 工作流只能手动触发。
- Codemagic：`codemagic.yaml` 两个工作流都是手动触发（`events: []`），不会自动发布。说明见 `docs/CODEMAGIC-MULTI-COMPUTER.md`。

## 注意事项

1. IPA **没有苹果签名**，需用 Sideloadly 等工具重新签名安装；App ID、Team、Share Extension、App Groups 要与签名账号兼容。
2. 替换手机上已有 Ferry 前先备份手机数据；正式替换需局长批准。
3. 不要把签名证书、描述文件、Apple 账号信息提交到仓库。
4. 只改文档的提交加 `[skip ci]`。
