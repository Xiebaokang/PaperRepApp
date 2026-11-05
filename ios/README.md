# PaperRep for iPhone

原生 SwiftUI + PDFKit 应用，最低 iOS 17，无第三方依赖。与桌面版使用相同的 `年份/月份/PDF` 仓库结构。

## 运行

1. 用 Xcode 打开 `PaperRep.xcodeproj`，选择 `PaperRep` scheme。
2. 选择 iPhone 模拟器，按 ⌘R。
3. 真机运行时，在 app target 的 Signing & Capabilities 中选择自己的开发团队，并启用设备开发者模式。项目没有预置个人签名或账号。

工程已经生成并提交。只有新增或删除 Swift 源文件时才需要运行 `python3 ios/generate-project.py` 重新生成工程；普通代码修改不需要。

## 文件与阅读

- 文件夹 / 所有论文视图、年月创建、名称或日期排序、当前列表 1 秒延迟搜索。
- 单击打开论文。长按文件或文件夹打开菜单，多选后可批量删除。
- 文件选择器支持多选 PDF；年月归档规则与桌面端一致，月份文件夹支持拖入。经校验后尝试移动源文件。iCloud、第三方文件提供方或分享附件可能不允许删除源文件，此时会保留源文件并明确提示。
- 删除使用应用内回收目录，可撤销最近一批删除；不依赖 iOS 系统「最近删除」。资料库位于 Documents/Library，可在「文件」App 的 PaperRep 中访问。
- 阅读器支持缩放、连续阅读、页面缩略图、记忆页码、全文搜索、选中文字高亮、文字批注和分享。
- 点击阅读器「完成」会保存并同步批注。切到后台会先本地保存；如果系统终止后台运行，下次启动或手动同步会继续处理本地更改。

## GitHub 同步

在「资料库设置」输入论文仓库地址、分支（留空使用默认分支）和 GitHub 访问令牌。细粒度令牌只需授权该论文仓库的 **Contents: Read and write**。令牌保存至设备钥匙串，不写入论文目录、配置 JSON 或源码，不会从 Mac 的凭据管理器迁移。

iOS 不执行命令行 Git，通过 GitHub Git Database REST API 读取、创建 blob/tree/commit，并以 `force: false` 更新分支。非论文文件通过 base tree 原样保留。完全空仓库通过 Contents API 初始化。

同步只在启动、导入、创建、删除、批注保存和手动点击时触发，不做定时远程拉取。iOS 挂起后不保证持续上传，因此使用另一设备前先确认同步完成。每个 PDF 限制 95 MB，与桌面端相同。

同步保存上次成功状态，通过三方比较合并彼此独立的更改；同一文件同时修改、删除与修改冲突、大小写同名会中止，保留本地文件，不强制覆盖远端。失败后手动重试。更换已使用的论文仓库暂不支持，以免错误地把一个仓库的删除同步到另一个仓库。

## 验证

```sh
xcodebuild -project ios/PaperRep.xcodeproj -scheme PaperRep \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath ios/DerivedData CODE_SIGNING_ALLOWED=NO test
```

单元测试覆盖 Git blob 哈希、路径及文件名校验、原子批量导入、删除恢复、多端冲突、PDF 批注保存，以及模拟 GitHub API 的非强制提交与拒绝保护。UI 测试覆盖列表、阅读翻页、全文搜索和年月创建。测试只使用生成的 PDF 与虚拟令牌，不连接真实仓库。

2026-11-05 已在 iPhone 16 Pro（iOS 26.5.2）完成真机验证：12 项核心/API 模拟测试和 1 项完整界面测试通过，包括搜索、多选删除和撤销。测试 host 与界面测试都使用独立临时资料库；正常运行不带测试参数。首次真机安装后需在「设置 → 通用 → VPN 与设备管理」信任自己的开发者证书，并保持手机解锁以启动测试。签名团队通过本机 Xcode 或构建参数配置，不提交个人签名信息。

API 依据：[Apple PDFKit](https://developer.apple.com/documentation/pdfkit)、[GitHub Git Database](https://docs.github.com/en/rest/guides/using-the-rest-api-to-interact-with-your-git-database)。真实令牌同步与第三方文件提供方行为仍需在相应账号和设备上验证。
