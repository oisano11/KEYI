---
id: keyi-ime-session
type: module-design
title: 输入会话 — 组合所有权、标记文字、按键归属与提交路径
status: draft
parent: keyi-ime
tags:
  - module
  - macos
  - input-method
---

# 输入会话

## 职责

一个 IMK 会话的全部状态：当前组合、当前候选、光标位置、它服务的是哪个输入框，以及画在输入框里的
标记文字。代码在 `IME/Sources/KeyiIMEKit/InputSession.swift`（`public final class InputSession: NSObject`，状态、初始化与 IMK 回调），
按职责分到同目录的 `InputSession+KeyRouting`（按键分流）、`+Engine`（Rime 接线与按 App 学习）、`+Delivery`（上屏收尾）、
`+Preview`（标记文字与面板定位）、`+Translation`（翻译客户端与菜单）、`+Diagnostics`（诊断钩子）；
候选与对照面板、全局热键、偏好同在 `KeyiIMEKit`。

会话决定「这个键归谁」和「标记文字长什么样」；哪些中文暂存、什么时候换英文是
[keyi-ime-autotranslate](keyi-ime-autotranslate)，拼音怎么断词是 librime。

## 标记文字 = 暂存段落 + 拼音

有暂存段落时，会话画的标记文字是「暂存的中文 + Rime 正在编辑的拼音」，应用自己画下划线。
光标和候选窗锚点都偏移暂存文字的 UTF-16 长度。控制器通过 sink（`applyAutomaticRender`）告诉
会话上屏什么、还留什么：上屏用 `insertText(文字, replacementRange: 当前标记范围)`，剩下的
用 `setMarkedText` 重画。按键里只先写上屏部分，标记文字在这一下结束时统一画一次 —— Rime 的拼音
要到那时才确定；按键之外（迟到的英文、⌃⌥T）当场画。`.abandon` 什么都不写，只忘掉状态。

不按应用分支：终端、浏览器、聊天软件走同一套调用，也不读回、不改已上屏的文字。

## 一段组合属于它开始时的输入框

`InputSession` 由 InputMethodKit 按窗口/输入框创建，可以同时存在多个。它自己的身份是
`ownerIdentifier = UUID()`，持有 `weak var activeClient` 与 `weak var compositionClient`。

弱引用不是风格问题：宿主可能在会话存活期间销毁输入框，强引用会让输入法进程替一个已经不存在
的控件保留组合状态，写入时静默失败。组合期间焦点切换走的是「先结算旧组合再切」，不是把组合
搬到新输入框。

候选和中英对照合在光标旁的**一个面板**里（`KeyiCompositionPanel`，11-03 用户看过方案图后要求合并）：
打拼音时上面是候选，下面是对照；没有拼音时只剩对照。面板是**进程所有、不是会话所有**：候选和对照
各带自己的 `owner:`（入口仍是 `KeyiCandidatePanel`、`KeyiTranslationPreviewPanel`，会话代码不变），
一个会话失去焦点时不能收掉接替它的会话的那部分；对照不定时自动收起，收起由控制器决定。

摆放由 `KeyiPanelLayout` 定：面板贴在光标所在行下方，下方放不下（第一次出现时按 150pt 预留）才放上方，
不盖住光标那一行；左边缘让出内边距，使第一个候选的序号对齐正在打的字的开头。同一行里打字时左边缘和上下位置
锁住，候选那一段总在靠光标的一侧，所以候选行出现或收起时面板只朝远离光标的方向伸缩（0.14 秒过渡），
不左右跳；换行、收起后重新决定。出现时直接显示、不淡入（2026-11-05：对照一到就看得见），收起 0.12 秒淡出；系统「减少动态效果」打开时不做尺寸过渡。

外观（`KeyiPanelChrome`，Toast 也用；2026-11-04 按设计稿重做，见 PRODUCT_SCOPE 变更记录）：磨砂玻璃、圆角 14.5（只有候选时面板高 29，正好是胶囊），
外圈 line-2 细线加内圈 glass-edge 高光，颜色取 KEYI 主题（青瓷默认、墨蓝、朱砂，共享包 `KEYIAppearance`，照抄设计稿
theme.css；墨蓝、朱砂 11-05 改色：用户说墨蓝像紫、朱砂像橙，「像 Claude 的主题色」，改成墨色深蓝 218° 与正红 4°），亮暗跟随系统外观。
玻璃两层：系统菜单材质只留模糊（自带的 `fill`、`tone`、`Chameleon` 灰底藏掉，否则叠上玻璃色就是实心，11-04 用户实测），`backdrop` 层高斯模糊，
上面叠主题玻璃底色。两层由一个「磨砂」值决定（0 通透–100 厚实，默认 50；11-05 用户：「像苹果的磨砂玻璃那样，只需要一个调节」，原透明度、
模糊度两项合成）：模糊半径 3–48、底色不透明度从下限到 0.96（`KEYIAppearanceSettings.panelGlass`），两样都按几何级数走——
11-05 第二版，用户：「拖了没什么变化…拖的时候要明显」：每拖 10 格，背后透出来的比例约乘 0.8、模糊半径乘 1.32，前后半段一样看得出；
round10 实测黑白分界的过渡宽度 9pt（0）→ 30pt（50）→ 125pt（100），条纹对比 0.31 → 0.10 → 0.03（亮色）。在 KEYI 可译「高级 › 外观」里调，
存 `com.keyi.input-translator` 的 `appearance.glassFrost`，改动经分布式通知送到输入法，面板立即重画。

紧凑（11-05 用户：「我们这个显示框不如苹果输入法的紧凑，又太多的留白空间，要做的和苹果一样紧凑…另外没有必要在汉字上面单独显示拼音了吧」，设计稿第 23 版）：
面板里不再显示拼音，拼音只在输入框的标记文字里看（和苹果一样）。
中英按视觉大小配对（`KeyiMixedType`）：同一磅数下小写拉丁字母只有汉字一半高，所以含小写字母的拉丁串按同处汉字字号的 1.1 倍排、
字重相同，全大写（EN）和数字不放大；竖向位置按实测字形墨迹定，不按字体 ascender 硬凑。
玻璃底色下限亮暗分开：亮色 0.63、暗色 0.73。面板不知道背后是什么颜色，按最坏的背景算（亮色玻璃在黑底网页、暗色玻璃在白底网页），
候选字 ≥ 4.5:1、译文约 3:1；再往下压译文先读不清（亮色 0.55 时译文 2.4:1，暗色 0.64 时候选字 4.0:1）。外框只有一道主题 line 细线，暗色下另加一圈 glass-edge 高光。

候选行的量宽与绘制、中英混排（`KEYICandidateRow`、`KEYIMixedType`）在共享包 KEYITranslationClient，KEYI 可译设置里的磨砂预览也用同一份；
`KeyiCandidateContentView` 只转调。

候选段（11-05 照苹果拼音实测，用户：「…consistent with that of the Apple Input Method, including the spacing…」）：只有一行，
上下各 2.5、左右各 3，行高 29；每页 7 个。第一个候选的序号对齐输入框里这段字的开头（`de08543` 起的对齐，去掉拼音行后按序号）。候选汉字 16pt，选中项 medium、
其余 regular（宽度都按 medium 量，移动高亮不挪位）；序号 8.5pt（墨迹高 6）、ink-3，选中时与汉字同为 on-accent，墨迹中线对齐汉字墨迹中线。
色块高 24、圆角 12、块间 2；水平间距都按字形墨迹排：块边到块内墨迹 7，序号墨迹到汉字墨迹 6，所以上一个字到下一个序号 16、
选中块右边到下一个序号 9。高亮色块填主题强调色。
这一页有纯 ASCII 字母候选（中英混输的英文词）时行尾加一个「英文」小标签。宽度不超过屏幕可见区域，放不下时把最长的候选用
「…」截短到同一上限，短候选保持完整。只有候选、没有对照时，面板就是一条高 29 的胶囊，宽度按内容收缩。
不画翻页箭头（用户 11-05 选每页 7 个、不加展开箭头）。

对照段：上 6、两行间 2、下 6、左右 10；左列「中」「EN」标签列宽 20、到文字 6，小标 10.5pt semibold，与右列首行竖向居中；原文 13pt ink-2 灰，译文 14.5pt regular 用译文色 `trans`（亮色 accent-strong、暗色 accent，theme.css --trans；用户 11-05：「The colors of English and Chinese should be different.」），「翻译中…」「翻译失败」13pt；
「EN」本机风格用强调色、大模型风格用 API 色。英文还没出来时译文处是三个圆点（不透明度 1、0.6、0.3）加「翻译中…」；翻译失败时
「EN」和「翻译失败」用危险色，下面一行 12pt ink-2 写原因（如「DeepSeek 10 秒没有回应。接着打字会并进这段，下次回车整段重译。」，
原因由控制器随 `.failed(kind)` 带来：超时、连不上 KEYI 可译、服务没配置、空结果、超过 8 KiB、其他）。底部一条浅底提示栏（上 5 下 6、左右 10，12pt），按键画成键帽（高 17、左右内边距 4），文案照契约原文：
「[回车] 换英文（风格名）· [Shift] 保留中文」；等英文和翻译失败时都是「再按 [回车] 或 [Shift] 保留中文」；右端是引擎名
（Hy-MT2、DeepSeek 等）加一个本机色或 API 色圆点，失败时也写，放不下时省略。有对照时面板宽度跟着这次输入的候选行，
候选收起只剩对照时沿用这次输入里候选行的宽度，这次输入一开始就没有候选时用 360 打底；候选行比 360 短时也取 360，免得底栏放不下。
译文在这个宽度里换行，同一次输入里切换等待、失败、预览时不忽宽忽窄。候选与对照之间的分隔线左右各缩进 10。
两段之间一条主题 line 色细分隔线。

按键来自另一个客户端、中间又没有激活回调时，先把原输入框的整个组合结算在原处（暂存中文原样
上屏、拼音以字母上屏），再处理这个键 —— 否则 A 的拼音会被重画进 B。

## 按键归属

ObjC 控制器只实现 `handleEvent:client:`（和鼠须管一样）。只要控制器还实现了 `inputText:key:modifiers:client:` 或 `inputText:client:`，IMK 就改走这些入口、从不调用 `handleEvent`，Shift 的 flagsChanged 事件也就收不到（10-31 真实宿主日志从未出现 “first key down received”）。会话里保留的 `inputText`/命令入口只供诊断使用，与 `handleEvent` 一样走同一个 `routeKey`；回车从哪个入口进来都要拦（10-04 的教训，c6eccc3）。一次按键：

1. 结算另一个客户端的组合；`beginUserInput()`。
2. 没有拼音时，回车/退格/Esc/导航键/组合键先问控制器（`handleKey`）：它吃掉就到此为止，
   否则组合键交给应用、其他键交给 Rime。有暂存时 Rime 不处理的可打印字符（空格、数字、
   大写、符号）并进段落。
3. 有拼音时：⌘/⌃/⌥ 组合键先上屏暂存中文、再把拼音以字母上屏，然后交给应用；例外是有暂存时的
   任何回车组合，当普通回车（字母并进段落、不交给应用）。Home/End 在有暂存时不动。
4. `finishUserInput(pinyin:)`，然后重画标记文字和候选窗。

**空格保留中文**（2026-11-23 用户「mac和windows现在输出中文是用shift,改为空格」，代替 2026-10-31 起的单按 Shift，
Esc 照旧可用）：`KeyiRimeKeyMapper.automaticKey` 把空格（含 ⇧+空格）归成 `.space`。没有拼音时 `routeKey` 先交给控制器：
有暂存（含回车后等英文、翻译失败）就和 Esc 一样 `commitAllAsChineseLocked` 整段原样上屏、吞掉；没有暂存时控制器交还，
空格照常交给 Rime / 应用。打拼音时 `.space` 不走组合键那条路，照旧交给 Rime 选高亮候选，转出的中文并进暂存，
再按一下空格才上屏。所以暂存段里打不进空格（同 Android）。安全输入刚结算掉暂存时，空格交给应用（只有回车、Esc 吞掉）。
单按 Shift 不再有作用（`KeyiShiftTap` 已删）；`flagsChanged` 只给按住说话键用，永远返回 false、从不交给 Rime。

`⌘`/`⌃` 放行是显然的；`⌥` 也放行，尽管 Option 在 Rime 里是合法的拼音分隔符 ——
应用把 ⌥ 组合当快捷键用的频率远高于用户想用它输入分隔符。同理 `⌥⌫`、`⌥⌦` 这类应用编辑快捷键
放行，不降级成普通退格。

组合期间按回车提交原始拼音并**消耗该回车**（有暂存时字母并进段落）；数字 1–7 选词（每页 7 个）、空格
选首选（有暂存时并进段落，再按一下空格才保留中文上屏）、PageUp/PageDown 翻页、Tab/↑/↓ 移动高亮、←/→ 在拼音内移动、Escape 取消。

## 中英混输与英文联想（2026-11-04、2026-11-11）

英文词表 `keyi_english`（`table_translator@keyi_english`）和拼音候选合在一页。英文候选有两种：正好是打的字母的
单词（`model`、`GitHub`，SCOWL 常用词与雾凇 `en_ext`），和以打的字母开头的常用词联想（`english/hint`，用户
2026-11-11「应该打到第三个或者第二字母，软件就能联想到他打什么英文了」）。联想不用 librime 的
`enable_completion`（它把短词排前面，`wo` 先出 won、woe）：`Scripts/generate-english-hints.py` 给每个两个字母以上的
前缀单独写几条，按 wordfreq 词频排，只从现有英文词表里挑每百万词至少出现一次的词。Rime 把英文排在一页前面，
`mixedEnglishOrder` 按打的字母重新摆（比较时去掉符号、统一小写）：

- 整段能拼成拼音（`wo`、`men`、`change`）：中文在前，完整单词、联想放这一页末尾；这样的前缀联想最多 2 个。
- 拼不成拼音、三个字母以上（`wou`、`bec`、`model`）：完整单词第一，联想紧跟着，中文在后；联想最多 4 个。
- 拼不成拼音、只有两个字母（`sh`）：完整单词第一，中文其次，联想放末尾（简拼的中文不被挤走）。

之后再按 App 学习重排、插入网址那一项。选联想和选单词一样：第一个汉字之前直接上屏，之后并进暂存段一起翻译。
检查：`keyi-smoke` 11d（真实 Rime 第一页有联想），`--diagnose-session` (14)（`wo`、`wou`、`bec`、`gith`、`model`、
`sh` 的摆放，`bec` 空格上屏 because）；Windows/Android 共用 C# 检查的 english hints 组。

## 英文后面的标点（2026-11-08）

用户：“When you type in English, any punctuation you add after it should be English punctuation.” 标点键
（ASCII 可见字符里除字母、数字以外的，只带 Shift/Caps Lock）前面是英文时，直接出键上的原字符，不经 Rime 的
中文标点（`InputSession+Punctuation`，判断规则在 `KeyiPunctuationContext`）；前面是中文、或看不出来时照旧
交给 Rime，出 `keyi_pinyin.schema.yaml` 里的中文标点。出来的英文标点和中文标点一样只是普通文字：有暂存段就
并进去（不打断、不触发翻译），没有就直接上屏。自动翻译开关、安全输入都不影响这条规则。

- **前面是什么**：从光标往前跳过空格、数字、英文标点和 emoji，碰到的第一个字是拉丁字母（含 é 等）就是英文，
  是汉字、全角标点或其他文字就是中文；碰到换行或什么都没有就是看不出来。所以 `Python3,`、`Hello."`、
  `git commit -` 是英文的，`价格20，`、`你好/，` 是中文的。
- **看哪段文字**：有暂存段时看暂存段（从汉字开始，总能定下来）；没有时先看本会话刚写进这个输入框的文字
  （`typedTail`：`commitToClient` 和译文上屏写进去的，加上交给应用直接打出的可见字符，留最后 32 个），
  定不了再读输入框光标前最多 32 个 UTF-16 单元。终端一类读不回文字的宿主只靠前两样。交给应用的回车、
  方向键、Tab、组合键和离开输入框（deactivate）之后 `typedTail` 清空，换了输入框就只认新的，退格删掉最后一个；
  写完之后点过鼠标（`CGEventSource`，与单按 Shift 同一个判据）也不再用它。
- **正在打拼音时按标点**（`'` 是拼音分隔符、`=`/`-` 是翻页键，除外）：先按面板上高亮的候选把拼音转成字
  （`confirmCompositionAsShown`，与单按 Shift 共用：选不下去时按 Rime 显示的样子、剩下的字母照打的样子），
  再按转出来的字判断：`hello,` → `hello,`，`nihao,` → `你好，`。以前这一步由 Rime 用它自己的第一个候选，
  与面板顺序（中英混输、按 App 学习）不一致时会上屏面板上没排第一的词（`women,` 出 `women，`），现在出 `我们，`。
- 只有数字时不算英文，照旧交给 Rime（librime 自己会把数字后面的 `.` `:` 留成半角，3.14、12:30）。
- **网址和邮箱**（2026-11-11，用户报告打网址时按了符号，前面的字母就变成了中文：`www.baidu.com` 出
  `万维网。百度。com`，`oisano@icloud.com` 出 `哦isano@iCloud.com`）：`keyi_pinyin.schema.yaml` 打开 librime 的
  `recognizer`/`matcher`，`www.`、`http:`、`https:`、`ftp.`、`ftp:`、`mailto:`、`file:` 开头，或小写字母开头、
  接着 `@`（前面只有小写字母、数字和 `-_.`）时，整段照打的样子留在输入里，没有候选。会话按同一套规则
  （`KeyiPunctuationContext.isAddressInput`）：正在打拼音时按的标点能接成网址或邮箱，就交给 Rime 并进输入，
  不先按候选转字；输入已经是网址或邮箱时，数字、`=`、`-`、`'` 和其他符号都照打进输入（不选候选、不翻页），
  空格和回车一样把整段照打的样子上屏，有暂存段时并进去。退格删到不再是网址（如回到 `www`）就照常出拼音候选。
  `@` 前面打数字照旧选候选。
- **不带前缀的网址**（2026-11-11，用户「把 baidu.com 这种不带前缀的也修好」，`InputSession+BareDomain`）：按 `.` 时
  还不知道是句号还是网址（`haode.` 要出 `好的。`），所以照旧先按候选转字，同时记下这一段（照打的 `baidu.`、转出的
  `百度。`、在暂存段里还是已经上屏——第一个汉字之前的英文 `GitHub.` 直接上屏）。接着打的字母正好是常见后缀
  （`KeyiPunctuationContext.bareDomainSuffixes`：com、cn、net、org、io、ai…）时，候选里多一项整段网址（面板顺序记作
  `domainOfferSlot`，不是 Rime 的候选）：排第一并高亮；整段都能拼成拼音时（`woaini.ai`）排第二，空格照旧出
  `我爱你。爱`。它高亮时下划线里就画成选了它之后的样子（`你好mail.sina.com`，`domainOfferMarkedText`），挪到别的候选上
  又画回 `百度。com`（用户 11-11 截图：已经打出 `.com` 还显示「是那。com」，看不出是网址）。选它——空格、回车、数字、单按 Shift、接着打 `. / : ? #`（网址留在输入里接着打）或别的标点（先上屏网址，
  再按英文标点）——就把暂存段末尾转出来的字删掉（控制器 `dropHeldSuffix`），整段照打的样子经 librime `set_input`
  放进输入，方案的 `domain` 规则让它和 `www.` 开头的网址一样照打的样子留着。已经上屏的开头（`GitHub.`）留在输入框里不动，
  Rime 输入里的这部分（`addressShownPrefix`）不画、不再上屏，结果是 `GitHub.com`；退格删进这部分时输入整段作废。
  按完还在打拼音（打后缀、在候选上挪）或是打拼音时的退格，都接着记下的几段；拼音结束了（空格选字、回车、Esc、
  组合键…）、点过鼠标、换了输入框、暂存段末尾已不是转出来的字就作废。前面几段接不接得上要在按下一个 `.` 之前核对
  （按完之后暂存段末尾已经是这一段转出的字）：11-11 截图里 `mail.` 就是因为核对晚了被丢掉，候选只剩 `sina.com`。关了自动翻译时转出的中文已经直接上屏，改不回去，照旧是 `百度。com`。

检查：`KeyiAutomaticTranslationChecks` 的 punctuation after English 组（规则、网址判断与并进暂存段）；
`KEYIIME --diagnose-session-translation` 的 punctuation 1–8 组与 `--diagnose-session` 的 punctuation
（translation off）组（真实 Rime，替身客户端可设成读不回文字）。

## 提交路径

Rime 确认的文字和回车上屏的拼音字母先交给控制器（`takeCommit`）。它接下（并进暂存段落）就
不上屏；不接（关闭、安全输入、第一个汉字之前的非汉字）才由会话照常 `insertText` 上屏。

输入框要不再归我们时 —— IMK `commitComposition`（点走、点进暂存文字）、`deactivate`、切换客户端 ——
先结算暂存（`settleHeldForLeaving` → 控制器 `commitHeldForLeaving`：浮层正显示这一整段的英文就上屏
英文，否则原样上屏中文），再把拼音以字母上屏；所有清除标记文字的路径都先结算暂存，不能直接清空。
有拼音时的 ⌘/⌃/⌥ 组合键仍走 `commitHeldAsChinese`，只上屏中文。

## 语音输入：按住说话键说话

PRODUCT_SCOPE「2026-11-07 语音输入最小版授权」；说话键可自定见变更记录 2026-11-08。代码在 `InputSession+Dictation.swift`（会话）与
`KeyiDictation.swift`（引擎接口、现在的说话键、文字整理、逐字流出）、`KeyiLiveDictation.swift`（一次录音：选云端或本机）、
`KeyiSenseVoice.swift`（本机识别器、麦克风）、`KeyiCloudDictationDiagnostics.swift`（选路诊断）。

- **说话键**：存在 KEYI 可译偏好域（共享包 `KEYIDictationShortcut` / `KEYIDictationShortcutSettings`，默认右 ⌥），
  KEYI 可译改了发 `com.keyi.dictation-shortcut.changed`，`KeyiDictationKey` 当场重读；每次 `activate` 和
  `recognizedEvents` 也重读。存的值不能用（缺字段、⇧、单独的普通键、⌃⌥T、⌘ 加一个键）时按右 ⌥。
- **触发（单个修饰键）**：flagsChanged 里只认这个键的键码（左右分开，有设备位时看 `NX_DEVICE*` 位，没有时看
  这类修饰键的标志），按下时不能有别的修饰键，没在打拼音、不是安全输入。事件照常交给应用，从不吞。宿主重复送的按下仍是同一次。
- **触发（组合键或 F1–F20）**：`handle` 在 flagsChanged 之后、进 `routeKey` 之前先看 `handleDictationKeyEvent`：
  键码相同且 ⌃⌥⇧⌘ 正好是要求的那几个（Fn、Caps Lock 不算）的按下开始录音；按下、自动重复和松开都返回 true，
  不进拼音也不交给应用（打拼音时、密码框里按也只吞掉、不录）。`recognizedEvents` 此时多要 keyUp，别的键的
  keyUp 原样还给应用。松开主键结束；主键还按着时松开了要求的修饰键也结束，之后主键的重复和松开照样吞掉；
  多按了别的修饰键取消。`dictationKeyIsDown` 只用来认重复：松开在别的应用里没送到时，下一次新的按下照常开始。
- **说话中**：识别中的文字（整理掉汉字旁的空格）接在暂存段后面画成标记文字，
  `compositionClient` 指向它所在的输入框。文字一个字一个字流出来（`KeyiDictationReveal`）：会话记住最新的
  整段和已露出的字数，识别改了已露出的字就原地换掉（字数不变），新来的字按积压匀速露出，每字 0.02–0.12
  秒、赶在约 0.5 秒后的下一次识别前露完；面板「中」行是暂存 + 识别中的文字，下一行「正在听…」，底栏
  「说完松开 <说话键> · 按其他键取消」。期间自动翻译的预览不上面板（`presentPreview` 跳过），说完再由
  控制器 `restoreOverlay()` 交还，没有可显示的就收起。
- **松开**：`finish` 识别整段（10 秒的话约 0.1 秒，3 秒没回就按已识别的文字定稿），剩下没露出的字在
  约 0.25 秒内流完，再和确认的候选走同一条 `takeCommit`：并进暂存段；控制器不接（关闭、安全输入、没有汉字）就直接上屏。
- **丢弃**：按住时任何按键（`routeKey` 开头）或别的修饰键都当组合键，取消录音、去掉识别中的文字；
  `deactivate`、`commitComposition`、换了客户端的 `activate` 同样丢弃。松开后、定稿前（或字还没流完）来了按键：先按
  已识别的整段（含没露出的字）定稿，再处理这个键，说的话不丢；迟到的定稿按代次（`dictationGeneration`）丢弃。
- **选路**（2026-11-07，`KeyiLiveDictationEngine`）：麦克风一开就经本机 socket 问 KEYI 可译的翻译服务
  （`TranslationServiceSpeechStream`，见共享包 SPEC「语音识别」）。回 `transcriptStarted`：走云端，每 0.05 秒把新录的
  声音按 100 毫秒一帧（16 位小端 PCM）送去，云端的整段文字就是实时文字，松开后送完余下的声音、发 `finishAudio` 等定稿；
  面板底栏写服务给的引擎名（大模型 API 色）。回 `error`、socket 不在、0.5 秒没回应：用本机 SenseVoice（底栏「本机
  SenseVoice」）。云端中途出错（Key 被拒、额度用完、断网、云端报错、提前结束）：这次改用本机，已录的声音整段交本机识别，提示一行
  「<原因>，这次改用本机识别」。松开时还没定路：定了再收尾。诊断 `--diagnose-cloud-dictation` 用临时 socket 上的替身
  服务和 8 倍速的文件声音跑这四种情况。
- **引擎**：KEYI 自带的 SenseVoice-Small int8（普通话与中英混说，带标点与数字规整），经 sherpa-onnx
  在本机运行（PRODUCT_SCOPE 同一授权的「补充」）。运行库 `Contents/Frameworks/libsherpa-onnx-c-api.dylib`
  （依赖同目录的 `libonnxruntime.dylib`）第一次按住说话键时用 `dlopen` 加载，不在编译时链接，所以编译、
  其他测试都不需要它；模型 `Contents/Resources/SenseVoice/model.int8.onnx` 同时在后台加载（约 0.3 秒），
  之后常驻，闲置 10 分钟卸载。SenseVoice 不是流式模型：说话中按已说的整段反复识别（两次开始之间至少
  0.45 秒、且不短于上次识别用时的 2 倍，每 0.05 秒看一次到没到），松开后识别整段定稿；所有识别在同一条串行队列上。麦克风转成 16 kHz
  单声道只放内存，最长约 130 秒，不写盘、不联网。麦克风未授权时第一次按下弹系统授权、这次不录；
  运行库或模型缺失时提示一行。单次最长 120 秒。

## 开关：菜单与热键是同一条路

偏好键 `KEYIAutomaticTranslationEnabled`（`UserDefaults.standard`，默认开）。菜单项「自动翻译 ⌃⌥T」在
`KeyiIMEInputController.m` 里，每次弹出菜单重新读当前值；热键 ⌃⌥T 走 Carbon 全局热键
（`KeyiHotKeyManager`）。

两者都只调 `toggle()`，再由同一条通知同步所有会话 —— 菜单勾选与热键不可能互相矛盾。

用 Carbon 而且**只在有 KEYI 会话激活时注册**，有两个理由：IMK 只把 `recognizedEvents` 里的键
交给输入法，⌃⌥ 组合被放行了，拿不到；而全局热键在切走输入法后仍然生效，会抢走其他应用的 ⌃⌥T。
注册判据用 IMK 的 `activateServer`/`deactivateServer`，**不查系统「当前输入源」** —— 10-04 实测
输入法进程查到的当前输入源会与用户正在打字的应用不一致，导致切回 KEYI 拼音后快捷键没有重新注册。
激活/停用回调在切换时会抖动，所以注册更新延迟 `settleDelay = 0.3` 秒再落定。

## 诊断

`KEYIIME --diagnose-session` 用替身文本客户端（`KeyiDiagnosticTextClient`）逐项断言组合、提交、
取消、选词、放行与退格，全在主线程同步完成。它要求隔离的 Rime 目录（`KEYI_IME_USER_DATA_DIR`
或临时目录），否则拒绝运行 —— 诊断绝不写进用户真实词典。这一组里自动翻译被
`KEYI_IME_DISABLE_AUTOMATIC_TRANSLATION=1` 关掉，验证普通拼音。

`--diagnose-session-translation` 用同一替身客户端加真实 Rime，配一个同步返回 `EN(原文)` 的假翻译，
验证整段暂存、回车、退格、切换客户端等走真实会话的路径。假翻译和安全输入替身只在
`KEYI_IME_DIAGNOSTIC_FAKE_TRANSLATION=1` 时可用（只有 `IME/Scripts/run-tests.sh` 设置它），正常运行的输入法
碰不到。锁屏时 `IsSecureEventInputEnabled()` 会变真，所以这组固定安全输入为关。
同一组还用识别替身（`dictation:` 诊断命令，替掉麦克风和识别器）检查按住说话键说话的各条路径（先把说话键钉成右 ⌥）；voice key 1–8 组换成右 ⌘、⌃⌥V、F5、Fn 再查一遍。

`--diagnose-dictation-file <音频> <应含文字>` 用包里真实的 SenseVoice 转写一个文件（替掉的只是麦克风），
`run-tests.sh` 用 `say` 合成一句中文喂给它；没有中文系统语音可合成样本时跳过。

## 已知边界（已确认）

- 会话只观察得到按键、提交、会话切换这些事件；鼠标点击不经过它。点走时暂存中文的上屏依赖应用
  调用 `commitComposition`；按键之外上屏前靠标记范围长度核对归属，见
  [keyi-ime-autotranslate](keyi-ime-autotranslate)。
- 很长的标记文字可能换行，候选窗锚点可能不准；各宿主怎么递送 Home/End 未实测。
- 一个窗口里多个输入框共用 IMK 会话时，输入框身份由 `hostBundleIdentifier` 加客户端变更计数
  近似，不保证区分到控件级。
