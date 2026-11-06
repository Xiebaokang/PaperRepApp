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
- 轻点 PDF 隐藏顶部工具栏和底部页码栏，再次轻点恢复；双击缩放、滚动和文字选择保留原有操作。
- 点击阅读器「完成」会保存并同步批注。切到后台会先本地保存；如果系统终止后台运行，下次启动或手动同步会继续处理本地更改。

## GitHub / Gitee 同步

在「资料库设置」输入论文仓库地址、分支（留空使用默认分支）和 GitHub 访问令牌。细粒度令牌只需授权该论文仓库的 **Contents: Read and write**。Gitee 地址使用 `https://gitee.com/用户名/仓库.git`，令牌需有 `projects` 权限。GitHub 与 Gitee 令牌分别按仓库存入钥匙串。令牌保存至设备钥匙串，不写入论文目录、配置 JSON 或源码，不会从 Mac 的凭据管理器迁移。

iOS 不执行命令行 Git，通过 GitHub Git Database REST API 读取、创建 blob/tree/commit，并以 `force: false` 更新分支。非论文文件通过 base tree 原样保留。完全空仓库通过 Contents API 初始化。

同步只在启动、导入、创建、删除、批注保存和手动操作时触发，不做定时远程拉取。所有列表均支持下拉同步，包括年份、月份、所有论文以及空列表；未配置仓库时提示先连接仓库。iOS 挂起后不保证持续上传，因此使用另一设备前先确认同步完成。每个 PDF 限制 95 MB，与桌面端相同。

同步保存上次成功状态，通过三方比较合并彼此独立的更改；同一文件同时修改、删除与修改冲突、大小写同名会中止，保留本地文件，不强制覆盖远端。失败后手动重试。切换仓库会保留本地论文、备份旧同步配置并清空旧基线，以新增文件与新仓库合并；同名且内容不一致会停止，不覆盖。切换时可清空分支以自动识别新仓库默认分支。旧仓库不会被修改。

Gitee 使用官方 v5 的目录/Blob 读取与 Contents 创建、更新、删除接口；更新和删除附带旧 Blob SHA，不强制覆盖。批量操作逐文件提交，中断后本地文件与基线保留，可重试；已提交且内容相同的文件不重复上传。Gitee 账号与 API 的文件大小/配额限制仍然适用。

## 验证

```sh
xcodebuild -project ios/PaperRep.xcodeproj -scheme PaperRep \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath ios/DerivedData CODE_SIGNING_ALLOWED=NO test
```

单元测试覆盖 Git blob 哈希、路径及文件名校验、原子批量导入、删除恢复、多端冲突、PDF 批注保存，以及模拟 GitHub API 的非强制提交与拒绝保护。UI 测试覆盖列表、多层及空列表下拉刷新、阅读工具栏隐藏恢复、翻页、全文搜索和年月创建。测试只使用生成的 PDF 与虚拟令牌，不连接真实仓库。

2026-11-05 已在 iPhone 16 Pro（iOS 26.5.2）完成真机验证：12 项核心/API 模拟测试和 2 项界面测试通过，包括搜索、多选删除和撤销、各层及空列表下拉刷新、阅读工具栏隐藏与恢复。测试 host 与界面测试都使用独立临时资料库；正常运行不带测试参数。首次真机安装后需在「设置 → 通用 → VPN 与设备管理」信任自己的开发者证书，并保持手机解锁以启动测试。签名团队通过本机 Xcode 或构建参数配置，不提交个人签名信息。

API 依据：[Apple PDFKit](https://developer.apple.com/documentation/pdfkit)、[GitHub Git Database](https://docs.github.com/en/rest/guides/using-the-rest-api-to-interact-with-your-git-database)。真实令牌同步与第三方文件提供方行为仍需在相应账号和设备上验证。

Gitee API 依据：[官方 v5 文档](https://gitee.com/api/v5/swagger)。模拟接口测试覆盖新建、更新、删除、下载和部分提交后重试；真实账号同步需要在 App 内填写令牌后验证。

2026-11-06 Gitee 支持已在 iPhone 16 Pro 编译安装并验证：15 项核心/API 模拟测试及 2 项界面回归通过。已只读核实 Gitee 空仓库的实际 404 响应并覆盖初始化测试；未使用用户真实令牌执行上传。
