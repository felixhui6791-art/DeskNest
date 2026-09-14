# 栖桌发布指南

## 两个版本

日常开发默认构建“栖桌 测试版”。它的 Bundle ID 是 `com.hui.desknest.beta`，不会覆盖正式版的设置。发布版保持 `com.hui.desknest` 和原有 `DeskNest` 工作区。

`config/release.json` 只允许 `1.2.3` 形式的版本号；`config/beta.json` 只允许 `1.2.3-beta.1`。每个渠道内 `build` 必须严格递增。发布版配置、正式 Release 和 `updates/release.xml` 仅在明确发布时更新，测试版对应独立的配置、Pre-release 和 `updates/beta.xml`。

测试版可以供本人下载验证，但公开仓库中的测试版附件也是公开可见的。两个版本只接收各自渠道更新；测试功能通过验证后，再作为新的正式版本发布。

## 本地构建与检查

需要 macOS、Swift 6.0+、Python 3。发布还需要 GitHub CLI 登录仓库所有者账号。

```sh
swift test
./scripts/build-app.sh beta
DESKNEST_UNIVERSAL=1 ./scripts/build-app.sh release
```

构建使用固定版本及 SHA-256 校验的 Sparkle 二进制依赖。脚本会复制框架、签名嵌套工具并检查整个应用的签名。CI 负责测试和通用测试版构建，不存放发布密钥，也不会自动发布。

## 更新签名

本项目的 EdDSA 私钥仅保存在维护者 Mac 的登录钥匙串中，账号名为 `desknest-felixhui6791-art`。公钥放在两个 JSON 配置中，属于可公开内容。新电脑需要安全迁移原私钥；不要重新生成不同的密钥然后覆盖配置，否则已安装用户无法验证更新。

请通过 Sparkle 的 `generate_keys` 工具自行将私钥备份到安全位置。不要放进仓库、构建附件、聊天或版本说明。无 Developer ID 签名时，丢失此密钥将无法给已安装版本推送受信任的更新。

更新归档和 appcast 都有 EdDSA 签名，客户端在解压前校验更新，两个渠道的 Bundle ID 和 feed 配置也会校验。生成后的 XML 不可手工修改；修改后须重新签名。参见 [Sparkle 官方发布文档](https://sparkle-project.org/documentation/publishing/)。

## 发布步骤

1. 修改相应 `config/*.json` 的版本及递增的 `build`，添加 `docs/notes/v版本号.md`。
2. 完成功能验证、提交代码并将待发布内容合并到 `main`，推送 GitHub。保持工作区干净。
3. 运行相应命令：

```sh
./scripts/publish.sh beta
# 正式给普通用户更新时使用：
./scripts/publish.sh release
```

脚本先运行测试，构建通用应用，生成 ZIP、SHA-256 清单与签名更新列表。随后创建 GitHub Release 草稿并上传附件，正式公开下载后才推送对应 feed，避免提醒用户安装尚未上传的包。测试版标为 Pre-release，且不改变发布版的 latest 指向。

若 `gh` 不在 PATH 中，可用 `DESKNEST_GH=/绝对路径/gh ./scripts/publish.sh beta`。也可仅执行 `./scripts/package-release.sh beta` 打包供本地检查。

每份包附有本地 `source-commit.txt`，发布时必须和当前提交一致；源码改动后应移走 `build/distribution/渠道/版本` 下的旧构建，再重新打包。只有 ZIP 和 SHA256SUMS 上传，工作区、日志和本地校验材料不会上传。

如果上传中断，先在 GitHub 检查该 tag 的草稿和附件，不要盲目覆盖已有公开版本。若 Release 已公开但 feed 推送失败，确认下载与签名有效后，将已生成的 `appcast.xml` 复制到相应 `updates/*.xml`，提交并推送 main。不要重新打包覆盖已经公开的版本；后续修复使用新版本号。

## Apple 发行签名与公证

当前构建默认临时签名，未公证。首次下载可能触发 macOS 拦截，系统权限也可能需要重新授权。EdDSA 更新签名不能代替 Apple Developer ID 身份与公证。

取得 Developer ID Application 证书并配置 `notarytool` 的钥匙串凭据后，可设置：

```sh
export DESKNEST_SIGN_IDENTITY='Developer ID Application: 你的发行证书名称'
export DESKNEST_NOTARY_PROFILE='你的公证钥匙串配置名'
./scripts/publish.sh release
```

脚本开启 Hardened Runtime，按从内到外顺序签名，提交公证并等待，装订成功后再生成发布包。公证失败会停止，不更新 feed。

## 手动回归

- 使用独立测试版检查更新入口、自动提醒开关、关闭后重开是否保持设置。
- 确认发布版不会看到 beta 更新，beta 不读取正式工作区。
- 从上个可下载版本验证发现更新、安装、重新打开和保留布局。
- 检查文件拖放、移除引用、菜单栏权限、折叠、睡眠唤醒和桌面组件。
- macOS 14+ 和 Intel 已覆盖构建目标；实际兼容性仍需对应设备验证。
