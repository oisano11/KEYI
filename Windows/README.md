# KEYI 可译 Windows 版

## 安装与使用

首次公开版仅提供源码。Windows 安装包将在代码签名和 Windows 原生验收完成后单独发布。

构建后，在 Windows 10/11 x64 运行 `KEYI-Setup.exe`，并在系统托盘右键 KEYI 可译图标。
1. 打开“添加/管理模型 API”，配置 DeepSeek、通义千问、火山引擎或 xAI Grok。
2. 将焦点留在输入框：选中文本时只翻译选区；未选中时翻译全文。
3. 按默认快捷键 `Alt+T`，英文结果会原地写回。
4. “版本与发布说明”只说明公开版发布边界，不下载或执行安装器。

API Key 保存在 Windows Credential Manager；Endpoint、模型名、提供方、场景、风格和快捷键保存在 `%LocalAppData%\KEYI\settings.json`。首次从 HanYi 升级时，若 KEYI 设置文件尚不存在，会自动导入 `%LocalAppData%\HanYi\settings.json`；已有 KEYI 设置始终优先。旧 Credential Manager 目标名不会自动迁移，需重新输入一次 API Key。

## 微信草稿区 HITL 验收

微信使用 Qt 自绘编辑控件，当前版本不暴露可读的 Windows UI Automation 文本模式。KEYI 可译仅在用户已有选区且 UIA 读取不可用时，临时执行复制读取并恢复剪贴板；没有选区时不会尝试复制全文。

1. 只打开“文件传输助手”或用户指定的安全草稿区，不发送消息。
2. 输入非敏感中文，选中其中一部分，按 `Alt+T`，等待结果期间不切换焦点。
3. 确认仅选区被替换、草稿未发送、焦点仍留在微信；检查原剪贴板内容是否恢复。
4. 清空选区后再次触发，确认 KEYI 可译显示“请先选中要翻译的文本”且不改变草稿。
5. 翻译过程中切换焦点或改写草稿，确认 KEYI 可译取消写回且不覆盖新内容。

## 本地构建

在 macOS 或已安装 .NET 8 SDK、NSIS 与 7-Zip 的环境执行：

```sh
Scripts/build-windows.sh
```

产物：

- `.build/windows/app/KEYI.exe`：Windows x64 自包含单文件程序（内部兼容文件名）。
- `.build/windows/KEYI-Setup.exe`：当前用户级 Windows 安装器。
- `.build/windows/KEYI-Setup.exe.sha256`：安装器完整性校验文件。

构建脚本会读取程序和安装器的 PE 文件版本、产品版本，解包安装器后比较内外 `KEYI.exe` 的 SHA-256；任一版本不是项目目标版本或 SHA-256 不一致时构建失败，不得发布。

## 发布边界

首次公开版不包含自动更新，也不绑定任何旧发布仓库。未来提供二进制前，必须完成 Authenticode 签名、发布者验证和 Windows 10/11 原生安装/升级验收。

## 支持边界

- Windows 版使用模型 API，不提供 Apple 系统翻译。
- 输入框需支持 Windows UI Automation 的 TextPattern 或 ValuePattern。
- KEYI 可译与目标应用权限级别必须一致；Windows 默认禁止普通权限进程向管理员权限窗口发送输入。
