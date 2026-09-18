# KEYI 英语风格真实试译记录

本轮 15 次真实请求全部成功。按本轮语言审阅，三个原句的核心意思、邀请意图、经常性和兴奋程度均得到保留，没有发现明显误译或生硬的中文句法直搬。英式、黑人英语有自然的表达区别；自然、美国英语、轻松美式在部分样例上重合，不能据此宣称五档在所有场景中都有明显差别。

以下是实际接口输出，未做措辞润色。语言判断由 Codex 审阅，不是真人母语者盲评；样本仅有三个原句，结论仅限本轮。

## 调用证据

| 项目 | 记录 |
| --- | --- |
| 开始时间 | 2026-09-18 12:02:52，Asia/Shanghai |
| 配置提供方 | DeepSeek |
| 请求模型字段 | `deepseek-chat` |
| 响应模型字段 | 15 次均为 `deepseek-flash` |
| 接口 | `https://api.deepseek.com/chat/completions` |
| 温度 | 0.2，与应用这两个场景的配置一致 |
| 数量 | 3 个原句 × 5 种风格 = 15 次，无重试，无额外探测 |
| HTTP / 完成状态 | 15 次 HTTP 200，15 次 `finish_reason=stop` |
| 输入 / 输出 tokens | 11,317 / 134 |
| 总 tokens | 11,451 |
| 输入缓存命中 / 未命中 | 6,016 / 5,301 tokens |
| 各次请求耗时之和 | 10.11 秒，不含本地准备及凭据读取 |

复用了当前工作区编译的 `TranslationPromptBuilder.systemPrompt` 和 `userPrompt`，使用与应用相同的 model/messages/temperature 字段发出真实请求。没有复制人工候选译文作为模型提示。请求模型名与响应模型名分别记录；响应字段不能证明服务端内部的精确模型快照或映射机制。本轮没有查询模型列表或更换提供方。

[原始 JSON](EnglishStyleLiveResults-2026-09-18.json) 保存了每次请求的完整提示词、提示词 SHA-256、输入、输出、响应模型名、响应 ID、状态、用量和耗时，不含 API Key。

## C1：今晚要不要一起吃个饭？

场景：日常聊天。

| 风格 | 实际输出 | 审阅 |
| --- | --- | --- |
| 自然 | Want to grab dinner tonight? | 自然的聊天邀请；一起吃饭的意图可从邀请句式中读出。 |
| 美国英语 | Want to grab dinner tonight? | 日常美式表达，没有书面函件腔。 |
| 轻松美式 | Want to grab dinner tonight? | 简洁口语自然；与前两档重合。 |
| 黑人英语 | You wanna grab dinner tonight? | 非正式邀请自然；`wanna` 本身并非黑人英语独有，不能单凭这个词证明风格真实性。 |
| 英国英语 | Fancy getting dinner tonight? | `Fancy ...?` 用于询问意愿，是自然的英式邀请。 |

本例没有为了显示风格而加称呼、换关系或额外加脏话。前三档相同是实际观察，不作为缺陷强行改写。

## T2：他经常加班。

场景：日常聊天。

| 风格 | 实际输出 | 审阅 |
| --- | --- | --- |
| 自然 | He often works overtime. | 准确保留“经常”。 |
| 美国英语 | He often works overtime. | 自然、准确的普通美式表达。 |
| 轻松美式 | He works overtime a lot. | `a lot` 的句尾表达略偏口语，经常性未变。 |
| 黑人英语 | He be working overtime a lot. | 此处 habitual `be` 表达经常性行为，适合原句；不能因不符合标准书面语而判错，也不能推广为所有黑人英语句子的必备结构。 |
| 英国英语 | He often works overtime. | 普通事实可与其他风格相同，无须刻意改词。 |

本例没有把“经常加班”误译为“此刻正在加班”。尚未真实测试相邻的“他现在在加班”反例，不能把这一条正确输出当作完整的时态、体貌验收。

## P2：我们终于赢了！太爽了！我现在激动得不行！

场景：社交媒体。

| 风格 | 实际输出 | 审阅 |
| --- | --- | --- |
| 自然 | We finally won! That feels amazing! I'm so pumped right now! | 保留胜利、终于获胜以及当下强烈兴奋，表达流畅。 |
| 美国英语 | We finally won! That feels amazing! I'm so pumped right now! | `pumped` 是自然的兴奋表达，不是教科书式逐字翻译。 |
| 轻松美式 | We finally won! That feels amazing! I'm so pumped right now! | 口语自然，但本例与前两档没有区别。 |
| 黑人英语 | We finally won! That feels amazing! I'm so hyped right now! | `hyped` 与兴奋语气吻合；整句自然，但该词也不是黑人英语独有。 |
| 英国英语 | We finally won! That feels amazing! I'm absolutely buzzing right now! | `absolutely buzzing` 自然地传达强烈兴奋，没有把英式误写成克制或冷淡。 |

黑人英语本次没有加脏话。这符合“可以添加、不是必须添加”的设定，只证明本轮没有强塞脏话，不能证明模型一定会在其他合适场景中添加。

## 结论与边界

- 本轮可保留当前提示词，没有发现需要据此修改的明显语义错误或翻译腔。为扩大风格差异而硬加词，会违背用户这次强调的自然表达目标。
- 自然、美国英语、轻松美式仍有较大重合；目前只能说本轮表达自然，不能说风格区分已经全面验证。
- 没有旧提示词的真实 A/B 对照，不能宣称改版提升幅度；也没有真人母语者盲评，不能保证每种语言社区都会采用这些表达。
- 商务、道歉、悲伤、原文已有脏话、语境歧义、当前动作反例以及自动场景的英式普通事实案例，仍只有提示词规则或人工候选用例，未在这 15 次请求中实测。
- 本轮是独立请求程序复用真实提示词的云端测试，未走原生 UI 和完整应用调用链路；没有安装新版本，也没有进行 Windows 原生验收。

后续如扩大真实评测，优先覆盖上述未测场景；当前授权的 15 次调用已全部完成。
