---
id: keyi-ui
type: module-design
title: KEYIUI — macOS 应用层与翻译编排
status: active
parent: keyi-architecture
tags:
  - module
  - macos
---

# KEYIUI — macOS 应用层与翻译编排

## 职责

把「按了一次快捷键」变成「输入框里的文字被替换」：管理常驻生命周期、全局快捷键、翻译状态机、
提供方调用、设置与凭据、以及结果反馈。

它是唯一允许触碰平台框架的地方 —— AppKit、Carbon（全局热键）、ApplicationServices（辅助功能）、
Translation（系统翻译）、Security（Keychain、代码签名）。

## 拥有的东西

- **生命周期**（`AppDelegate`、`KEYIApp`、`KEYI/main.swift`）：`LSUIElement` 式的辅助应用
  （`.accessory` 激活策略）+ 菜单栏项，无 Dock 图标、无主窗口。
- **单实例**（`SingleInstance`）：`KEYILauncher.run()` 在创建任何界面之前抢 `flock`，抢不到即退出。
- **全局快捷键**（`GlobalHotKey`、`HotKeyConfiguration`）：Carbon 热键注册；更换快捷键时先注册新的、
  成功后再注销旧的，避免中途留下无热键的窗口；系统唤醒／会话切换后重新注册。
- **状态机与编排**（`AppModel`）：`ready / permissionRequired / preparing / translating / success /
  failure` 六态；`preparing` 在捕获之前就置位，使重复按键无法插进剪贴板操作中间；按提供方分派到系统
  翻译、云端、本地模型三条路径；完成与失败都回到同一处收口。
- **系统翻译**（`KEYITranslationAppleSession`、`TranslationHostView`）：两条路径。已安装的语言对走
  进程内的非 UI 会话 —— `prepareTranslation()` 约 3–8 ms，同一会话可连续翻译多句，不建窗口；
  只有需要 Apple 资源确认 UI 时才把请求交给主进程的 SwiftUI `translationTask`，那是一个 320×100、
  `.nonactivatingPanel` 的面板，由 `$systemTranslationHostRequestID` 驱动显示与撤下。旧方案是 1×1、
  `alphaValue = 0.01` 的屏幕外窗口，实测会让 `translationTask` 无限挂起，已废弃。
- **伴随翻译服务宿主**（`KEYITranslationServiceHost`）：`startIfNeeded()` 幂等，用
  `--keyi-translation-service` 启动自身子进程跑 socket 服务循环；宿主退出时结束子进程。凭据只在
  子进程里读，调用方从不需要它们。
- **焦点元素恢复**（`FocusedElementResolver`、`FocusedElementProbe`）：每次等待前后都校验请求仍
  有效，再沿有限条焦点路径（systemFocus → focusedApplication → window/focus）找回元素；探针本身
  无副作用，所有平台操作由调用方注入。
- **终端草稿**（`TerminalDraftEditor`、`TerminalDraftObservation`、`ZshDraftProcessClient`）：给不可
  自动化读写的终端提供的草稿窗口（原文不变，译文只替换草稿），以及 zsh 草稿的捕获／条件提交客户端。
  菜单栏「更多」子菜单里两个入口：直接开通用草稿窗口，或打开随包的终端草稿指南（和输入法主流程无关，
  不放在菜单第一层）。见 [keyi-writeback](keyi-writeback)。
- **反馈**（`TranslationIslandController`、`MenuBarContent`）：翻译中的浮层状态与菜单栏菜单。菜单栏菜单（2026-11-04 按设计稿）：
  顶部「KEYI 可译」和状态行（翻译服务运行中 · 本地模型已加载／加载中／未下载／待命），风格直接列出、后面写引擎，
  目标语言子菜单，今天确认汉字与 API 估算费用（`StatisticsModel` 同一份计数），设置…（⌘,）、「更多」、退出（⌘Q）；
  终端恢复命令、本地模型迁移提示、词库有更新、下载进度这些提示照旧插在最上面。词库有更新点开即弹设置窗口里的词库更新对话框。
- **设置与凭据**（`SettingsWindow`、`StatisticsPage`、`DictionaryUpdateSheet`、`KEYIPalette`、`TranslationSettingsStore`、
  `CredentialStore`、`InterfaceLocalization`）：2026-11-04 按 Claude Design 设计稿重做。左侧栏「翻译风格」「统计」「高级」三栏，
  底部一行小字（版本或「只存计数和用量」），右边内容；栏目跟着 `AppModel.settingsSection` 走（`.translation` → 翻译风格，
  `.statistics` → 统计，`.providers`/`.general`/`.hotKey` → 高级）。配色 `KEYIPalette` 取当前主题 token 的动态色（青瓷、墨蓝、
  朱砂，亮暗跟随系统），换主题时根视图 `.id(theme)` 整页重建。
  2026-11-05 收紧并改成磨砂（用户：「要合理安排位置以及留白……要紧凑高效，另外设置页面的也要磨砂和透明」）：窗口默认 780 宽
  （最小 720，原 900），侧栏 164，不写窗口标题，每页标题写在红绿灯那一行；整窗是磨砂玻璃（`SettingsGlass`：和光标旁面板同一做法，
  系统模糊层去掉自带灰底，叠主题玻璃底色；模糊半径和底色与光标旁面板同一套映射（`windowGlass`：页标题、分组小标题、提示行直接写在窗口底色上，
  最通透时也要读得清，11-05 第二版实测 0.4 的底色在黑底上读不出），拖滑块时设置窗口当场跟着变），
  卡片和侧栏再叠一层半透明 surface / side（`KEYIPalette.card(frost:)`、`sidePane(frost:)`），不透明度也跟磨砂走（0.2–0.85，经环境值
  `keyiGlassFrost` 传下去），拖滑块时卡片底下透出来的也跟着变，不只是卡片之间的缝；侧栏另叠主题浅色。卡片里一项一行（最小高 38），名称后可跟一句灰色短注，
  长说明放悬停提示，第二行只留状态和出错。主题色用在字上：组标题、统计数字、快捷键、本机模型名；主题按钮的名字用各自的颜色。
  核对界面时本机进程可发分布式通知 `com.keyi.input-translator.settingsPreview`（object 为页名或 close），设置窗口落到那一页、
  摆到最前但不激活，不抢正在打字的输入框；`--open-settings` 后面也可跟 statistics、advanced。
  「翻译风格」：「想要什么样的英文？」加示例原文胶囊；「本机翻译 · Hy-MT2 · 文字不出本机」「大模型 API · DeepSeek · 只发送这一段
  待译文字」两组，组名旁写引擎（本机强调色、大模型 API 色），没就绪时组名下一行写缺什么、暂时怎么翻并给「下载」「填写 API Key…」；
  每组三张风格卡片：名字、同一句中文「这事我今天真搞不定了，明天再说吧。」的**手写示例译文**（衬线斜体，打开设置不调用引擎）、
  一句用途，点卡片即选用。页底提示条写目标语言并链到「高级」。不做自动翻译开关（契约只允许输入法菜单和 ⌃⌥T 切换）。
  「统计」：标题旁写日期；今天四个数（确认汉字、上屏英文词、大模型 tokens、API 估算费用）合在一张卡里、细竖线隔开，数字用主题色、
  费用用大模型色；近 7 天确认汉字柱状图与费用表各占一半、等高（只按比例分宽，不再按量出来的宽度写死——窗口窄时右边被裁，11-05 用户截图）；
  费用表只列今天用过的服务和正在用的那个，本机与苹果翻译合成一行写「免费」，末行「今天合计」按币种分开写、不折算，没有费用时写「¥0」，
  「改单价」展开全部服务的单价编辑；用户词库一行（短注「本机自学习，不联网」，「学到 N 个词」「按 App 记住 N 个词，分在 N 个 App」，
  读输入法的 `app-candidates.json`，右边「导出…」「清空…」，清空用危险色，详细说明在悬停提示）；每日明细可展开，隐私说明跟在它后面一行。
  三页侧栏底部都是应用名和版本。
  「高级」按关系分三组：**翻译**（目标语言；本机模型 Hy-MT2 档位：轻量、标准两个按钮，在用的那档描边并标「正在使用」，删除与许可在「更多」菜单；
  大模型服务与 API Key 各一行，自定义服务再多 Endpoint、模型两行，没有「测试连接」；个人术语表一行：条数、查看、清空、ⓘ 说明和开关）；
  **外观**（主题三选一，按钮上的名字用各自的颜色；「磨砂」一个滑块，左「通透」右「厚实」，0–100 默认 50，光标旁面板和设置窗口共用——
  11-05 用户：「像苹果的磨砂玻璃那样，只需要一个调节」，原透明度、模糊度两项合成；滑块松手才写共享偏好并发通知，已显示的面板立即重画，
  没显示的下次出现前也重读一次；滑块右边一个小预览：彩色条纹上一个候选胶囊，和光标旁面板同一套映射，拖动时当场变——
  拖滑块时光标面板不在屏幕上，靠它看出面板会变成什么样，只是展示。胶囊里的候选行用共享包 `KEYICandidateRow` 量宽和绘制，
  和输入法面板同一份代码、同样大小（第一版另用 SwiftUI 小字号排，选中块里的「你」右半被裁掉））；**通用**（界面语言、
  旧桌面快捷键（已是默认时不显示「恢复默认」）、辅助功能权限（已授权用系统绿勾，不用主题色）、拼音词库（「雾凇拼音 10月31日版 · 随包」、
  立即检查、退回随包版本、有新版时「查看新版…」；上次检查时间在悬停提示里，检查、下载、装好或出错时才多写一行））。中英并排处用 `KEYIMixedText` 按视觉大小配对（含小写的拉丁串放大 1.1 倍、字重相同），
  中文标点在 `KEYIMixedText` 里用 PingFang SC 排（界面字体会把它们压成半角宽）。中文界面里目标语言写「英语」。
  雾凇版本不露提交号。侧栏与内容区之间一条 line 色细线（画在侧栏 overlay 上）。
  风格卡片：名称 14 semibold、示例 12.5pt 衬线斜体用译文色 `KEYIPalette.trans`、说明 11 ink-2，最小高 96。词库更新对话框是设置窗口的 sheet：新旧版本日期、新增／删除词条数、示例词、
  上游说明，「暂不」「更新」。窗口高度贴合右边内容，最高到屏幕可用高度，宽度可拖（最小 720）。偏好存 `UserDefaults`
  （主题与玻璃存共享偏好域），密钥存 Keychain，两者分开。
- **写回**：见 [keyi-writeback](keyi-writeback)。
- **本地模型**：见 [keyi-local-model](keyi-local-model)。

## 边界

- 只依赖 `KEYICore`、`KEYITranslationClient`（socket 客户端）与系统框架；不复制核心层的语言、场合、
  风格枚举 —— 那些类型直接来自核心层，否则菜单可用性与提示词会各说一套。`KEYITranslationService`
  只用于启动自己那个子进程，不直接调它的服务循环。
- 不实现翻译语义：如何措辞、如何判断截断，属于 [keyi-core](keyi-core)。
- **与本机其他进程只通过伴随服务通信。** AF_UNIX socket 监听在
  `~/Library/Application Support/com.keyi.input-translator/` 下，不开放任何网络端口，也不做服务
  发现 —— 调用方（输入法、`KEYITerminal`）只连这一条已知路径。
- 不监听除快捷键以外的全局输入；AX 变更通知只订阅捕获时认准的那一个元素。

## 已知约束

- 辅助功能权限由用户在系统设置里授予；未授权时状态机进入 `permissionRequired` 并引导授权，而不是静默失败。
- 系统翻译（`Translation` 框架）只接受文本与目标语言：场合与英文风格照常写进请求，但系统翻译那条分支
  不读这两个字段，所以对结果无效。设置里 `supportsTranslationCustomization` 对 `appleSystem` 返回
  false，界面因此不显示这两项。
