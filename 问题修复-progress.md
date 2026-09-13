# KEYI 问题修复进度

## 审核后修复（2026-09-13）

- 根据本任务的项目审核并行处理 Windows、macOS 回写及本地模型边界；下方 2026-09-08 记录保留为历史。
- Windows：全局复制、全选、粘贴及延迟后验证按键前核对原 HWND/控件；复制结果核对剪贴板拥有者 PID 与读取前后序列，无关写入不接管恢复。
- Windows：回写完成与剪贴板恢复失败分别报告，恢复异常不覆盖原回写错误；已经打开的设置窗口支持服务深链。
- macOS：捕获改读 AX 选区或值范围，不再把任意剪贴板变化当作复制成功；完全不暴露文本的控件会拒绝捕获。这收窄了旧的纯剪贴板兜底兼容范围。
- macOS：浏览器回写完整匹配预期文本；清空剪贴板前登记恢复，粘贴前检查并发更新。
- macOS：终端在删除前准备剪贴板并复验目标，删除期间逐次检查焦点；删除后失败将完整原命令保留在内存，可从菜单复制或明确丢弃后继续翻译，不向失焦窗口自动恢复。退出应用会清除待恢复内容。
- macOS：未配置服务时快捷键打开并定位服务设置；新增设置展示注入边界用于无桌面回归。
- 本地模型：模型探测及每次生成前检查监听进程、已安装签名 LM Studio 应用和同团队签名；关闭代理和重定向，localhost 请求固定为回环 IP。真实假 TCP 服务测试确认探测和生成均在建立连接前拒绝。
- 打包：清洁检查包含未跟踪文件，防止新增源码进入标记为 HEAD 的发布包。

### 本次验证

- `Scripts/test.sh`：Core 98、App 73、Regression 50 项通过，另有真实回环伪监听器检查通过。
- 新增应用流测试曾捕获恢复错误后状态未结束的问题；修正后通过。覆盖未配置服务深链、恢复队列、显式复制/丢弃、系统取消后原命令仍保留。
- Windows CoreChecks：19 组通过；Windows 主程序和 WindowsChecks Release 构建均为 0 warning / 0 error。
- `swift build -c release --product KEYI` 通过；打包脚本语法检查通过，并确认当前非干净工作区在构建前以退出码 2 拒绝打包。
- 源码 whitespace 检查通过；未提交、推送、安装或发布，原有文档修改保留。

### 本次限制

- 未做 Windows 原生 UI、真实终端/浏览器回写或 LM Studio 正常服务实机验收；本次没有使用 Computer Use。
- 本地服务目前限 `/Applications/LM Studio.app` 或用户 Applications 目录中的签名桌面应用内进程，独立/headless 运行时不支持。没有固定官方 Team ID，信任根是已安装的 Apple 签名链应用及同团队进程，不能宣称严格厂商身份钉扎。
- 操作系统全局按键的焦点变化及监听器检查到实际连接之间仍有无法原子化的竞态；这是边界加固，并非完全消除本机恶意进程威胁。

- 日期：2026-09-08（Asia/Shanghai）
- 范围：本次项目分析确认的 7 项问题；不包含界面重设计、安装、发布或 Git 同步。
- 状态：7 项代码修复已完成，定向回归与双端构建通过；真实输入回写和 Windows 窗体交互尚未验收。

## 已完成

1. macOS 浏览器回写：绑定原进程、输入控件及可读取的窗口身份；只有相同窗口、父节点、标识和角色才允许识别重渲染控件。不再因文本相同而向其他输入框降级粘贴；选区不一致时取消。
2. 截断译文：macOS 与 Windows 云端客户端拒绝 `finish_reason=length`；本地模型由 1024 增至 2048 token 重试一次，仍截断就报错，不返回半截译文。缺少 `finish_reason` 的兼容响应仍可使用；未闭合的本地 `<think>` 不作为译文。
3. 终端手动选区：快照保留终端属性，各回写路径统一拒绝换行、Tab 和其他控制字符。键盘降级时属性不可读也保留限制；明确可写的普通查找栏不受终端限制。
4. 辅助功能权限：捕获失败时清理待处理快照并退出 `preparing`，授权后可重新触发翻译。
5. Windows 服务商列表：刷新后仍存储 `ProviderId`，保留选择并继续触发正确的表单加载逻辑。
6. macOS 服务商设置：直接从设置路由读取当前编辑的服务商，打开指定服务商不再回落到 DeepSeek；编辑不等于启用该服务。
7. Windows 剪贴板：翻译粘贴与嵌套复制验证共享一个恢复事务，使用最后一次自身操作的序列号恢复原剪贴板。验证抛错仍恢复；其后用户另行复制时不覆盖用户内容。

## 本轮验证

- `swift run KEYICoreChecks`：98 项通过。
- `swift run KEYIRegressionChecks`：40 项通过。使用隔离偏好、假输入边界和本地响应桩，不读取桌面、不调用真实翻译服务。
- 权限状态和不透明终端控件测试均确认过修复前失败、修复后通过。
- `.tools/dotnet/dotnet run --project Windows/KEYI.CoreChecks/KEYI.CoreChecks.csproj -c Release --no-restore`：17 组通过，包含截断结果与剪贴板嵌套恢复、用户新复制、无写入、验证异常路径。
- `swift build -c release --product KEYI`：通过。
- `swift build --product KEYIAppChecks`：编译通过；未运行其真实钥匙串往返和旧凭据迁移测试，因此未声称完整 `Scripts/test.sh` 通过。
- Windows 应用与 `KEYI.WindowsChecks` Release 交叉编译均为 0 错误、0 警告；新增窗体检查已接入 Windows CI，但本轮未在 Windows 执行、也未触发远端 CI。
- `zsh -n Scripts/test.sh` 与 `git diff --check`：通过。

## 剩余验证与边界

- 需要真实 macOS 输入框验证同文不同控件、浏览器重渲染、终端手动选区及权限重新授权；这些不是纯逻辑检查能够替代的。
- 无法证明仍是原输入框或原选区时会取消。部分缺少稳定辅助功能标识的编辑器，重渲染后可能需要重新触发翻译。
- 需要 Windows 运行 `KEYI.WindowsChecks` 并检查微信等剪贴板降级场景，尤其是粘贴后验证及用户另行复制时的表现。
- 已按用户授权调用 Computer Use，但尚未完成交互验收；未修改已安装应用，未提交、推送、同步远端或发布。开始时已有的工作区改动保留。

## 下一步

用户已同意本轮使用 Computer Use，不需要重复询问授权。2026-09-08 已通过原生 CUA 进入设置和翻译服务页面，并成功取得设置窗口独立截图；下一步完成服务商切换与编辑检查，再验证真实输入回写。设置窗口截图成功不代表屏幕外翻译宿主的捕获问题已经修复。Windows 仍需可用的真实运行环境；安装和发布另行确认。

## 实机验证准备（2026-09-07）

- 用户已明确允许本轮使用 Computer Use。
- `Scripts/build-app.sh` 已完成，测试包位于 `.build/KEYI 可译.app`，使用现有 `Codex++ Local Signing` 本机开发签名；未覆盖 `/Applications/KEYI 可译.app`。
- 此前曾在用户当时允许的脚本阶段启动测试应用并打开设置；用户随后指定只使用 Computer Use，本轮未再使用 AppleScript、JXA、System Events 或合成键盘事件替代界面操作。
- 原生 Computer Use 曾成功读取测试版设置窗口。普通 Node 会话的 `cua is not defined` 只说明该会话不是 CUA 运行环境，不能据此认定 Computer Use 入口不存在。
- 2026-09-07 21:35 左右，通过原生 CUA 调用 `cua.getApp("/Users/oisano/Documents/输入法/.build/KEYI 可译.app")` 再次失败：服务错误 `-10005`，底层 `com.apple.ScreenCaptureKit.SCStreamErrorDomain Code=-3811`，提示音频/视频捕捉失败。
- 只读进程检查确认测试版 KEYI 仍运行于上述 `.build` 路径（PID 10516），Computer Use 服务 `SkyComputerUseService` 也在运行（PID 25693）；这些 PID 仅代表检查时状态。
- 同次请求的系统日志在 21:35:49 显示 `TCC Allow`，随后为 `failed display lookup for windowBounds ... found=0` 和 `Error in creating screenshot`。故障发生在窗口显示器查找及截图环节，不支持“用户尚未授权”的判断；窗口不可见、位置异常或捕获服务内部问题等具体原因仍未确定。
- 已读取 [OpenAI 官方 Computer Use 文档](https://learn.chatgpt.com/docs/computer-use)，确认系统权限与应用授权是两层独立控制，且 Computer Use 不能操作终端应用或批准系统隐私权限提示。终端和权限重新授权场景仍需人工配合验收。
- 没有修改系统权限或重启捕获服务，没有发起真实翻译请求。输入框回写、服务商设置和权限恢复的实机验证仍未完成。
- `git diff --check` 通过；未提交、推送或发布。

## Computer Use 继续验证（2026-09-08）

- `cua.getApp("/Users/oisano/Documents/输入法/.build/KEYI 可译.app")` 成功返回测试版的辅助功能树，包含无标题窗口、KEYI 菜单、Edit、View、Window 和 Help。
- `keyi.click(2); keyi.getAXState()` 成功打开 KEYI 应用菜单，返回“设置…”（本次索引 4）、About 与 Quit 等菜单项。由此确认原生 AX 读取和一次菜单点击实际成功；不是仅列出进程或工具。
- 本次还没有点击“设置…”、执行服务商切换或发起翻译；真实回写仍未验收。也没有取得独立截图，不能认定此前的 `-3811` 已消失。
- 上轮进一步核对代码与日志发现：`AppDelegate.installTranslationHost()` 在 `(-10000, -10000)` 创建并显示 `1×1` 翻译宿主窗口；失败截图日志中的窗口 15952 为 `(-10000, 10981, 1, 1)`，与坐标系转换一致，且不落在任何记录的显示器内。此前建议反复确认权限或移动设置窗口未针对这个触发点。宿主窗口代码尚未修改。

## 原生 CUA 设置检查补充（2026-09-08 11:30 起）

- 已先阅读本进度及项目总览，检查工作树：`main`，HEAD `1dbea36`，相对 `origin/main` ahead 46 / behind 9。原有修改、删除和未跟踪文件全部保留。
- `cua.getApp("/Users/oisano/Documents/输入法/.build/KEYI 可译.app")` 成功。只读进程检查显示唯一 KEYI 进程为该测试包路径、PID 10516；未启动或覆盖 `/Applications` 版本。
- 实际点击应用菜单中的“设置…”，进入“翻译”页：目标语言 `English`，显示“系统翻译会使用所选语言，并由系统决定表达方式”。随后实际点击“翻译服务”侧栏。
- DeepSeek 页面实际显示：`DeepSeek（未配置）`、Endpoint `https://api.deepseek.com/chat/completions`、模型 `deepseek-chat`，API Key 为空且“用于翻译”按钮禁用。这一页面默认字段显示通过。
- 原生 `keyi.getScreenshot()` 成功取得完整设置窗口截图，内容与 AX 树一致。此次设置窗口未复现 `-3811`，但未证明屏幕外宿主窗口截图已恢复；没有修改 `AppDelegate.swift`，也没有重建。
- 服务商选择器的一次 AX 点击后，工具报告辅助功能树未变化，未取得其他服务商页面。尚未执行字段编辑、保存或翻译快捷键；本轮没有真实翻译请求和输入回写结果。
- 未验收：服务商切换/深链、编辑不自动启用、普通选区翻译、全文回写、同文不同输入框切换、浏览器重渲染。这里只完成设置页面的部分检查，不能计为完整交互验收；下拉框未展开也不足以判断应用存在缺陷。
- 终端手动选区与系统隐私重新授权仍需人工验收；Windows 仍需真实 Windows 环境。没有使用 AppleScript/JXA/System Events，没有重置系统权限，没有提交、推送、同步或发布。

## 原生 CUA 设置继续检查（2026-09-08 14:20 起）

- 重新连接 `.build/KEYI 可译.app` 并进入设置的“翻译服务”页面。通过截图坐标实际展开服务商选择器，列表显示：DeepSeek、通义千问、火山方舟、Grok、自定义服务、本地模型。
- 实际选择“通义千问（未配置）”后，页面显示 Endpoint `https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`、模型 `qwen-plus`，字段与服务商匹配。
- 实际编辑模型字段为临时值 `qwen-plus-edit-check`，未点击“用于翻译”、未保存 API 配置；编辑动作本身没有触发服务商启用。由于尚未回到应用菜单读取当前选中服务，当前服务“不变”的独立 AX 证据仍待补齐。
- 本段操作没有发起外部翻译请求、没有写入凭据、没有覆盖 `/Applications` 版本。
