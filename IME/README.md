# KEYI 输入法（macOS 中文拼音输入法）

macOS 原生中文拼音输入法，KEYI 自动翻译的入口：
IMK 输入法外壳 + librime 拼音引擎 + 候选窗 + 自动翻译控制器。确认中文后，
整段中文通过本机 socket 交给 KEYI 可译伴随服务翻译，回车时换成译文
上屏；输入法进程本身不直接联网、不持有凭据，不含 AI 候选、模型或自动更新。
当前 active 词库采用固定版本的雾凇拼音（rime-ice）全拼
词库（8105、base、ext、tencent、others）；早已不在 import 链里的旧
`pinyin_simp` 词表已于 2026-11-04 删除。中英混输的英文词来自 SCOWL 常用词（宽松许可）
与雾凇 `en_ext`，不用雾凇的 Google 两万词主词库。

## 状态

实验版，只在作者本机日常使用，没有公证的安装包，需要从源码构建。自动化检查（引擎、
自动翻译控制器、打包结构、会话诊断）由 `Scripts/run-tests.sh` 覆盖；真实应用里的体验
以 macOS 15 上的微信、浏览器、终端等常用输入框为主，其他宿主可能有光标定位或回写差异。

自动翻译需要同时安装 KEYI 可译（本仓库根目录的 macOS 应用）：输入法确认中文后把这段文字
经本机 socket 交给它，由它按你选的翻译风格完成翻译。伴随应用没运行时输入法会在后台启动它并重试一次；
翻译失败时这段中文保留下划线，再按一次回车或单按 Shift 原样上屏中文。

产物命名为 `KEYIIME`（`KEYIIME.app` / `Contents/MacOS/KEYIIME`），与原
`KEYI.app` 翻译助手互不冲突。

Bundle ID 为 `com.keyi.inputmethod.keyi`，输入模式为
`com.keyi.inputmethod.keyi.pinyin`，连接名
`com.keyi.inputmethod.keyi_Connection`。标识符里的 `.inputmethod.` 段不能是
末段——这是 macOS 注册第三方输入法的硬性要求，旧写法
`com.keyi.input-method` 正是因此从不出现于任何 TIS 枚举。Rime 用户数据仍保留
在原隔离目录 `~/Library/Application Support/com.keyi.input-method/Rime`，
不随 Bundle ID 迁移。

## 构建

```bash
cd IME
Scripts/build-ime.sh debug      # 或 release
```

产物：`IME/.build/KEYIIME-debug.zip` 或
`IME/.build/KEYIIME-release.zip`，解压后为 `KEYIIME.app`。结构校验用的
`KEYIIME.staged` 刻意不使用 `.app` 后缀，避免 LaunchServices 把构建副本
当成第二个输入源。构建脚本不安装、不注册、不启用输入源。

## 安装与启用

```bash
IME/Scripts/install-ime.sh release            # 安装 release 到 ~/Library/Input Methods
IME/Scripts/install-ime.sh --dry-run release  # 只看将要执行的动作
```

安装脚本不自动启用或切换输入源。安装后完成以下操作：

1. 系统设置 → 键盘 → 文字输入 → 输入源 → 编辑…
2. 添加输入源 → 简体中文 → KEYI 输入法／KEYI 拼音；只需添加一次，已添加则跳过。
3. 从菜单栏输入法菜单选择 KEYI 拼音（英文界面显示 KEYI Pinyin）。

卸载：

```bash
IME/Scripts/uninstall-ime.sh           # 仅移除输入法本体
IME/Scripts/uninstall-ime.sh --purge   # 同时移除用户词库与缓存
```

## 使用

- 输入拼音，候选窗跟随光标显示；数字键 1–7 选词，空格选首选。
- `=` / `-` 或 PageDown/PageUp 翻页，Tab/↑/↓ 移动高亮。

自动翻译（默认开启，输入法菜单或 ⌃⌥T 暂停/恢复）：

- 确认的中文先作为带下划线的文字留在输入框里，光标旁的面板同时显示候选和中英对照预览。
- 整段写完按**回车**，整段换成译文上屏；回车只换英文、不发送，再按一次才交给应用发送或换行。
- 想保留中文就**单按 Shift**（或 Esc），中文原样上屏、不翻译。
- 点到别处或切换窗口时，面板上已有这整段的译文就上屏译文，否则上屏中文。
- 密码框与安全输入里不翻译、不发任何请求。

普通拼音行为：

- 退格删除拼音，←/→ 在拼音内部移动，Escape 取消本次输入。
- 组合期间按回车会提交原始拼音，并消耗这次回车，不触发应用换行或提交；
  组合结束后再按回车，才交给当前应用处理。
- Command / Control / Option 组合键一律交给当前应用；组合未结束时会先结算，
  不会把半截拼音留在文档里。
- 词级删除（`⌥⌫`/`⌥⌦`）等应用编辑快捷键同样放行，不会降级成普通退格。

## 验证

```bash
IME/Scripts/run-tests.sh
```

包含四层：

| 检查 | 内容 |
| --- | --- |
| 引擎 smoke | 真实 librime 会话：组句、候选、翻页、退格、取消、实时双会话隔离、光标随左右与中间插入、标点收尾、前向删除不与退格混淆 |
| 自动翻译检查 | 用替身客户端驱动生产 `KeyiAutomaticTranslationController`：停顿/句末触发、连续提交合并、迟到结果拒绝、失败保留、退格重译等 |
| 打包校验 | `.app` 结构、Info.plist、动态依赖、rpath、许可与数据白名单、名称不与 `KEYI.app` 冲突 |
| 会话诊断 | 用模拟 IMK 文本客户端驱动真实 InputSession：标记文本、上屏、取消、快捷键放行、清空 marked、客户端归属、提交次数恰为 1 |

## 目录

| 路径 | 说明 |
| --- | --- |
| `Sources/KeyiIMECore` | librime C++ 封装，每个实例一个 Rime 会话 |
| `Sources/KeyiIMEBridge` | C++/Objective-C++ 桥接 |
| `Sources/KeyiIMEInputController` | InputMethodKit 的 Objective-C MRC 控制器外壳 |
| `Sources/KeyiIMEKit` | Swift 输入会话、候选窗、对照浮层、⌃⌥T 开关、按键映射、偏好 |
| `Sources/KeyiIMETranslation` | 自动翻译控制器与伴随服务 socket 客户端 |
| `Sources/KeyiAutomaticTranslationChecks` | 自动翻译检查（驱动生产控制器） |
| `Sources/KeyiIME` | 输入法可执行入口与诊断入口 |
| `Sources/KeyiSmokeTest` | 离线引擎诊断工具 |
| `resources/rime` | 随包词库与 schema |
| `Scripts` | 构建、校验、安装、卸载、测试 |

## 词库来源与许可

雾凇拼音词库来自固定 commit `99662ba01e3affa6a0f009174ca530b887bac3b6`，
文件级来源、SHA-256、许可和未引入的上游组件见 `SOURCES.md` 与
`THIRD_PARTY_NOTICES.md`。雾凇词库合并了多个上游数据，不能统一标为
Apache-2.0；随包带有 `CREDITS.rime-ice.md` 和 `LICENSE.rime-ice-GPL-3.0`，
并保留各来源条款。KEYI 只引入全拼词库文件，不引入雾凇的 Lua、OpenCC、双拼、
拆字、英文方案或语法模型。

## 许可与范围

见 `THIRD_PARTY_NOTICES.md`（组件与许可对照）与 `SOURCES.md`（逐项来源、
固定 commit、派生文件清单、静态传递依赖符号证据）。本输入法携带
librime（BSD-3-Clause）、Ni 上游代码改编（MIT）和雾凇拼音的多来源词库；明确排除雾凇之外的 AI/更新/模型组件。
