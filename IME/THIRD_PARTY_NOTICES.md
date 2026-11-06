# KEYI 输入法第三方组件与许可

本输入法携带语言引擎、输入必需的数据，以及 KEYI 自动翻译的**线协议客户端**。
客户端本身不含 AI 模型、模型权重、自动更新组件，也不在本进程内联网：确认中文后
它通过本机 AF_UNIX socket 调用用户自行安装并配置的「KEYI 可译」伴随应用，
由后者按用户已选的提供方完成翻译。翻译提供方、语言与凭据仍由伴随应用管理，
不在本输入法内。

每个组件保留其原始许可，不统一重许可。逐项来源、固定 commit 与派生关系见同目录
`SOURCES.md`。

## 组件清单

| 组件 | 用途 | 来源与固定版本 | 许可 |
| --- | --- | --- | --- |
| Ni 输入法 | 实际代码改编来源：IMK 生命周期兼容层、Rime 封装、候选窗与光标定位策略 | https://github.com/xiaomaolu/ni-input-method-open-source，commit `7a487b692c5f7f99418fe97a61399094e1035038` | MIT |
| librime | 输入法引擎，随包为 `Contents/Frameworks/librime.1.dylib` | https://github.com/rime/librime 1.17.0，发布档 `rime-33e7814-macOS-universal.tar.bz2`，SHA-256 `11d8dc66…21850` | BSD-3-Clause |
| 雾凇拼音（rime-ice）词库 | KEYI 当前 active 的成熟全拼词库：8105 字表、base、ext、tencent、others | https://github.com/iDvel/rime-ice，commit `99662ba01e3affa6a0f009174ca530b887bac3b6`；词库来源、整理者和逐项许可见随包 `RimeData/CREDITS.rime-ice.md` | 依文件/来源而异；随包保留上游 GPL-3.0 文本及来源声明，另含 Unicode、MIT、Public Domain、LGPL-3.0、CC BY 3.0 等上游条款 |
| SCOWL 英文词表（中英混输） | 10/20/35/40 级常用英文词，生成 `RimeData/english/scowl.dict.yaml` | SCOWL 2020.12.07（Kevin Atkinson），http://wordlist.aspell.net/ | 允许使用、修改、分发、出售，须保留版权声明（随包 `RimeData/english/LICENSE.scowl`） |
| 雾凇拼音英文补充词表 | 缩写与技术词 `RimeData/english/en_ext.dict.yaml` | https://github.com/iDvel/rime-ice，commit 同上 | GPL-3.0 |
| 雾凇拼音配置许可 | 随包 `RimeData/LICENSE.rime-ice-GPL-3.0` | 上游仓库的配置/方案许可原文，版本固定为上述 commit | GPL-3.0 |
| KEYI 自动翻译客户端 | 线协议客户端与自动翻译控制器（`Sources/KeyiIMETranslation/`）：确认中文后经本机 AF_UNIX socket 请求伴随应用翻译 | 本项目编写；协议实现从 KEYI 可译同源复制，未改写 | Apache-2.0（随 KEYI 发布许可） |
| KEYI 自有词库与 schema | `keyi_core.dict.yaml`、`keyi_pinyin*.yaml`、`default.yaml` | 本项目编写，schema 规则改编自 Ni 上游 schema、Rime 官方示例及雾凇拼音输入约定 | Apache-2.0（随 KEYI 发布许可），其中改编部分同时适用上游 MIT/GPL 条款 |

## librime 内静态链接的传递依赖

`librime.1.17.0.dylib` 只动态依赖 `libSystem` 与 `libc++`，下列组件以静态
方式编入同一件二进制并随之分发，各自许可条款独立适用：

| 组件 | 许可 | 角色 |
| --- | --- | --- |
| glog | BSD-3-Clause | 日志 |
| leveldb | BSD-3-Clause | 用户词库存储 |
| marisa-trie | BSD-2-Clause（另有 LGPL-2.1+ 双许可，本项目按 BSD-2-Clause 使用） | 词典 trie |
| OpenCC | Apache-2.0 | 简繁转换 |
| yaml-cpp | MIT | 配置解析 |
| Boost | Boost Software License 1.0 | 通用库 |
| darts-clone | BSD-2-Clause | 双数组 trie |

`utf8proc` 未编入本二进制（`nm -a` 无相关符号），故不在分发范围内；如将来
引入须补其 MIT 全文。

这些组件只以目标代码形式存在于该 dylib 内；如后续需要分发其源码或修改版，
须按各自条款补充源码与声明。

## 许可全文的随包位置

- `Contents/Resources/librime-LICENSE.txt`（librime，BSD-3-Clause）
- `Contents/Resources/ni-input-method-LICENSE.txt`（Ni 上游，MIT）
- `Contents/Resources/RimeData/LICENSE.rime-ice-GPL-3.0`（雾凇拼音上游配置许可，GPL-3.0）
- `Contents/Resources/RimeData/CREDITS.rime-ice.md`（雾凇拼音词库来源与归属）
- `Contents/Resources/RimeData/english/LICENSE.scowl`（SCOWL 英文词表版权与许可）
- `Contents/Resources/KEYI-LICENSE.md`（KEYI 自身，Apache-2.0）
- `Contents/Resources/licenses/`：上表静态传递依赖的逐项许可**原文**，取自各自
  固定 commit（Boost 取官方 BSL-1.0 原文），文件名与来源对照见 `SOURCES.md`

## 雾凇拼音数据许可边界

KEYI 只引入雾凇拼音的全拼词库文件，不引入它的 Lua 插件、OpenCC 配置、英文
方案、双拼方案、拆字方案或语法模型。`rime_ice.dict.yaml` 已按 KEYI 的资源
布局把上游相对路径改写为 `rime_ice/cn_dicts/*`，其余词条内容保持上游快照。

雾凇拼音的合并词库来自多个上游，不能统一标注为 Apache-2.0：`base` 和
`ext` 的上游说明分别引用 THUOCL、华宇野风、腾讯词向量及
`rime-essay-simp`；`tencent` 明确来自 Tencent AI Lab。完整来源和归属以
`RimeData/CREDITS.rime-ice.md` 为准，分发包同时携带 `LICENSE.rime-ice-GPL-3.0`
和现有 Apache/MIT/BSD 许可，KEYI 的外壳不对这些数据重新许可。

## 明确未引入的数据与组件

按任务卡要求，以下上游资源**未**进入本输入法：

- `ni_modern.dict.yaml`（CC BY 4.0）、Ni 的 `essay-zh-hans.txt`（LGPL-3.0）
- `ni_supplement.dict.yaml`、`emoji.dict.yaml`、`symbols.dict.yaml`、
  `candidate_regression.tsv`
- CC-CEDICT 衍生释义（CC BY-SA 4.0）
- 上游 AI 候选、股票、定位、朗读、Sparkle 软件更新与本地模型运行时

`Scripts/verify-bundle.sh` 对上述内容逐项断言不存在于产物中。
