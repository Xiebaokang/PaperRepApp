# PaperRep

简洁的 macOS / Windows 论文资料库。PDF 直接保存在本地 Git 仓库，按 `年份/月份/文件名.pdf` 组织；文件名就是论文名。

原生 iPhone 版本位于 [`ios/`](ios/README.md)，使用 Xcode 打开 `ios/PaperRep.xcodeproj`，内置 PDF 阅读器，与桌面版同步同一论文仓库。

## 开发

需要 Node.js 22+ 和 Git。macOS 可使用 Xcode Command Line Tools 提供的 Git；Windows 安装 Git for Windows。

```sh
npm ci
npm start
```

## 在 Windows 继续开发

安装 Node.js 22+ 和 Git for Windows 后，在 PowerShell 中运行：

```powershell
git clone https://github.com/Xiebaokang/PaperRepApp.git
cd PaperRepApp
npm ci
npm start
```

生成 Windows 安装包：

```powershell
npm run build:win
```

安装包位于 `release/`。`node_modules/`、`.tools/`、`release/`、测试截图和本机环境配置不提交；`package-lock.json` 保留，用于安装一致的依赖版本。本仓库仅保存应用源码，论文仓库在应用设置中单独配置。

## 第一次使用

点击「设置资料库」，选择空文件夹或已存在的论文 Git 仓库。可填入 GitHub 或 Gitee HTTPS / SSH 地址，也可先离线使用。远程仓库需要事先创建，建议设为私有。应用使用系统 Git 的现有认证，不收集或保存托管平台密码、令牌。

HTTPS 使用系统凭据管理器；SSH 请事先配置相应平台的 SSH 密钥，并确认系统 `git fetch` / `git push` 可用。另一设备选择新的空文件夹并连接相同仓库即可克隆。

## 操作

- 文件夹模式：年份 → 月份 → PDF。新建文件夹只能选择年月。
- 在展示年份文件夹的根页面添加 PDF，自动归档至今天所在月份。在展示月份文件夹的年份页面，按钮添加会选择归档年月，拖拽可直接放到月份文件夹上。在月份内部添加，归档至当前月份。所有论文模式添加时选择年月。
- 导入支持多选和拖拽，完成校验和持久化后将源文件移走，不覆盖同名文件。为兼容 GitHub 和 Windows，单文件上限 95 MB，并检查跨平台文件名。
- 双击 PDF 使用系统默认阅读器。外部修改停止约 3–5 秒后自动提交并推送；启动时同步远程更改，之后空闲时不自动同步。其他设备的新更改可点击「立即同步」获取。
- 支持单选、⌘/Ctrl 多选、Shift 连选、全选。选中后右键移至废纸篓；删除文件夹会删除其内容。实际删除前有系统确认。
- 右键论文或年月文件夹，选择「在资源管理器中查看」（Windows）或「在 Finder 中查看」（macOS），可在系统文件管理器中定位选中项目；支持多选。
- 搜索只检查当前列表中的论文文件名，停止输入 1 秒后更新；全库搜索请切换「所有论文」。
- 点击窗口关闭按钮会隐藏到 Windows 右下角系统托盘 / macOS 顶部菜单栏，应用继续在后台运行。Windows 点击托盘图标可恢复窗口；两端都可从图标菜单选择「打开 PaperRep」。真正退出请在图标菜单选择「退出 PaperRep」；同步或导入期间会等待当前操作结束后退出。
- 同步期间禁止操作文件和文件夹，可以关闭窗口隐藏到托盘。网络失败保留本地文件和 Git 提交，恢复后点击重试。不会强制推送。多端同一 PDF 冲突时保留本地版本并中止合并，需在 Git 中解决后重试。

应用管理专用论文仓库，不建议与源代码或其他文档混用。空月份使用 `.gitkeep` 保留。设置保存在 Electron 的用户数据目录，论文不会写入安装目录。

## 验证与打包

```sh
npm test
npm run test:ui
npm run pack
npm run build:mac
npm run build:win
```

核心测试使用临时本地 bare Git 仓库，验证双设备同步、阅读器修改、冲突回滚和断网恢复；不访问用户 GitHub。界面测试在隔离的 Electron 用户目录运行，截图输出到 `test-results/`。

macOS 与 Windows 安装包建议分别在对应系统构建。`scripts/github-build.example.yml` 是可选的 GitHub Actions 构建模板，默认不启用；需要时可放入 `.github/workflows/build.yml`（提交工作流需要对应 GitHub 写入权限）。未配置发行签名和 Apple 公证，正式分发前需设置相应签名。Windows 的系统阅读器、凭据管理器和废纸篓行为需要在 Windows 真机验收。

技术依据：[Electron 安全指南](https://www.electronjs.org/docs/latest/tutorial/security/)、[webUtils 文件拖拽 API](https://www.electronjs.org/docs/latest/api/web-utils)。渲染进程使用沙箱、上下文隔离、严格 CSP 和白名单 IPC。

## 切换到 Gitee

桌面端在资料库设置中选择新的空文件夹，再填写 Gitee 仓库地址。旧 GitHub 资料库原样保留；如需所有历史论文，可先在 Gitee 导入原 GitHub 仓库，再连接新文件夹。不会自动修改旧仓库 origin 或上传到其他地址。iPhone 可直接在设置中更换地址和令牌，保留手机本地已有论文并与新仓库合并，分支可留空。源码仓库继续保留在 GitHub。

Windows 和 macOS 共用桌面同步代码，都支持 Gitee HTTPS 和 SSH 地址。Windows 已有源码目录可在 PowerShell 中运行 `git pull`、`npm ci`、`npm run build:win`，安装 `release/` 中的新安装包后，在资料库设置中连接 Gitee。桌面版使用系统 Git 凭据或 SSH 密钥，手机内保存的令牌不会自动同步到 Windows。
