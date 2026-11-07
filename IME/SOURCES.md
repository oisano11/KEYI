# 来源、派生关系与版本固定

本文件记录 KEYI 输入法每一项随包内容的确切来源，供许可与安全审查核对。
所有值均为实际使用的固定版本，不是"最新版"。

## 1. Ni 输入法（上游架构与实现参考，MIT）

## 0. 本包标识符（本轮变更）

Bundle ID 由 `com.keyi.input-method` 改为 `com.keyi.inputmethod.keyi`，输入模式
`com.keyi.inputmethod.keyi.pinyin`，连接名
`com.keyi.inputmethod.keyi_Connection`。原因是 macOS 要求第三方输入法的标识符
含非末段的 `.inputmethod.` 组件；旧标识符两条件都不满足，`TISRegisterInputSource`
返回成功但任何 TIS 枚举都查不到。对照 WeType（`com.tencent.inputmethod.wetype`
+ `.pinyin`）确认了这一形态。`verify-bundle.sh` 已断言该结构、签名 Identifier
与 CFBundleIdentifier 一致、以及本地化模式名存在。

Rime 用户数据目录不随 Bundle ID 迁移，仍为
`~/Library/Application Support/com.keyi.input-method/Rime`。

- 上游：https://github.com/xiaomaolu/ni-input-method-open-source
- 固定 commit：`7a487b692c5f7f99418fe97a61399094e1035038`
- 许可：MIT，全文见 `Vendor/ni/LICENSE`（随包提供为
  `Contents/Resources/ni-input-method-LICENSE.txt`）
- 只读研究克隆：`/tmp/keyi-ai-ime-research.tQUMOP/ni-input-method-open-source`
  （未修改）

### 派生文件（属于对 Ni 代码的改编，不是独立创作）

以下文件以 Ni 上游对应文件为基础改写：保留其结构与生命周期处理思路，
删除 AI/翻译/股票/定位/朗读/更新/模型代码，并把引擎与 UI 改为 KEYI 自有
命名空间。按 MIT 要求保留版权与许可声明。

| KEYI 文件 | Ni 上游对应文件 | 改编内容 |
| --- | --- | --- |
| `Sources/KeyiIMECore/RimeEngine.cpp` / `.hpp` | `Sources/AIIMECore/RimeEngine.cpp`、`include/AIIMECore/RimeEngine.hpp` | 命名空间 `aiime`→`keyi`，schema 改为 `keyi_pinyin`，新增 composition cursor 桥接（原样保留 librime 的 UTF-8 字节偏移），删除未用接口 |
| `Sources/KeyiIMEBridge/KeyiIMEBridge.mm` / `.h` | `Sources/AIIMEBridge/AIIMEBridge.mm`、`include/AIIMEBridge.h` | 类名与命名空间改写，新增 `cursorPosition`（UTF-16）导出与 UTF-8 前缀解码换算 |
| `Sources/KeyiIMEInputController/KeyiIMEInputController.m` / `.h` | `Sources/AIIMEInputControllerShim/AIIMEInputControllerShim.m`、`include/*.h` | 保留 MRC 控制器与 IMK 回调转发结构，删除翻译/符号/诊断用例，回调集合缩减到本卡范围 |
| `Sources/KeyiIMEKit/KeyiCandidatePanel.swift` | `Sources/AIIME/CandidateWindowController.swift` | 重写为最小候选条：保留非延迟 `NSPanel`、`.popUpMenu` 层级、进程级共享面板与光标定位策略，删除翻译/玻璃/上下文菜单/鼠标交互 |
| `Sources/KeyiIMEKit/KeyiRimeKeyMapper.swift` | `Sources/AIIME/InputController.swift` 的 `rimeKey`/`rimeModifiers`/`shouldPassThroughToClient` | 抽出为独立映射表，键码表逐项核对，快捷键放行规则收紧到 Command/Control/Option |
| `Sources/KeyiIMEKit/InputSession.swift` | `Sources/AIIME/InputController.swift` | 全新编写的最小会话（标记文本、候选选择、客户端归属），仅沿用 Ni 的 IMK 回调契约与 Rime 结果应用顺序 |

### 未随包的 Ni 内容

Ni 的 AI 候选、翻译、本地模型运行时、Sparkle 更新、股票行情、定位、朗读、
设置窗口，以及 `ni_modern.dict.yaml`（CC BY 4.0）、`essay-zh-hans.txt`
（LGPL-3.0）、`ni_supplement.dict.yaml` 等数据全部排除。

## 2. librime（BSD-3-Clause）

- 上游：https://github.com/rime/librime
- 版本：1.17.0
- 发布档：`rime-33e7814-macOS-universal.tar.bz2`，来自
  https://github.com/rime/librime/releases/download/1.17.0/
- 发布档 SHA-256：`11d8dc663c6ec06d5ccb6111ba664a9e7b631b703ac6acd07cffbac664021850`
- 随包二进制：`Vendor/librime/lib/librime.1.17.0.dylib`
  SHA-256 `1adb725a081b0accc1451034f6f1bb78cbfe8252a65245f1511f4b3f2038c487`
- 架构：universal（arm64 minOS 11.0，x86_64 minOS 10.15）
- 许可全文：`Vendor/librime/LICENSE`（随包为
  `Contents/Resources/librime-LICENSE.txt`）

### 静态链接的传递依赖（编译进 librime 二进制）

`otool -L` 显示 librime 只动态依赖 `libSystem` 与 `libc++`；下列组件以静态
方式编入该 dylib，因此随这一件二进制一并分发。它们各自的许可条款同样适用。

| 组件 | 许可 | 在 librime 中的角色 |
| --- | --- | --- |
| glog | BSD-3-Clause | 日志 |
| leveldb | BSD-3-Clause | 用户词库存储（`*.userdb`） |
| marisa-trie | BSD-2-Clause / LGPL-2.1+ 双许可（本项目按 BSD-2-Clause 使用） | 词典 trie |
| OpenCC | Apache-2.0 | 简繁转换数据 |
| yaml-cpp | MIT | schema / 配置解析 |
| Boost | Boost Software License 1.0 | 通用库 |
| darts-clone | BSD-2-Clause | 双数组 trie |

上述清单以符号检查核对（`nm -a librime.1.17.0.dylib`）：glog 16、leveldb 686、
marisa 251、OpenCC 389、yaml-cpp 682、Boost 1376、darts-clone 74 个符号。

`utf8proc` 未出现在符号或源码路径中（`nm -a` 计数为 0，`strings` 无
`utf8proc`），因此本二进制不含该组件，其 MIT 许可不适用于本次分发；
若将来重建的 librime 引入了它，需要按同一规则补入。

说明：上述组件不单独随包发布独立二进制或源码树，只以静态链接形式存在于
`librime.1.17.0.dylib` 内；分发该 dylib 即分发这些组件的目标代码。若后续
需要分发源码形式或修改这些组件，须按各自条款补充源码与声明。

### 逐项许可全文（已随包）

每个静态组件都随包附上取自**固定版本**的许可原文，存放于
`Vendor/librime/licenses`（随包为 `Contents/Resources/licenses`）。文本为
上游原文，未经改写。

| 组件 | 版本固定 | 许可全文文件 | 来源 |
| --- | --- | --- | --- |
| glog | `7b134a5c82c0c0b5698bb6bf7a835b230c5638e4` | `glog-BSD3.txt` | 该 commit 的 `COPYING` |
| leveldb | `99b3c03b3284f5886f9ef9a4ef703d57373e61be` | `leveldb-BSD3.txt` | 该 commit 的 `LICENSE` |
| marisa-trie | `3e87d53b78e15f2f43783d5e376561a8c9722051` | `marisa-trie-dual.txt` | 该 commit 的 `COPYING.md`（BSD-2-Clause 与 LGPL-2.1+ 双分支原文均保留） |
| OpenCC | `556ed22496d650bd0b13b6c163be9814637970ae` | `opencc-Apache2.txt` | 该 commit 的 `LICENSE` |
| yaml-cpp | `2f86d13775d119edbb69af52e5f566fd65c6953b` | `yaml-cpp-MIT.txt` | 该 commit 的 `LICENSE` |
| Boost | 见下方说明 | `boost-BSL1.txt` | Boost 官方 `LICENSE_1_0.txt`（BSL-1.0） |
| darts-clone | 0.32（经 OpenCC `deps/darts-clone-0.32` 编入） | `darts-clone-BSD2.txt` | darts-clone 上游 `v0.32h` 的 `COPYING.md` |

前五项 commit 来自 librime 1.17.0 的 `.gitmodules` 所固定的子模块版本。
Boost 不是子模块：它以头文件与预编译库形式参与链接，本 dylib 中可见
`re_detail_60010` 一类的 Boost 1.60 世代符号（`nm -a`），但精确小版本无法
从二进制反推，故按 BSL-1.0 的通用原文提供——该许可文本在各版本间一致。
darts-clone 同样不以子模块固定，而是随 OpenCC 的
`deps/darts-clone-0.32` 源码一起编入，dylib 内 `strings` 可确认该路径前缀，
故取其上游 `v0.32h` 的许可原文。

## 3. pinyin_simp 词库（已删除）

- 2026-11-04 起不再随包：它早已不在 `keyi_pinyin` 的 import 链里，词表与
  `LICENSE.pinyin-simp` 一并删除。来源记录（Rime 官方 `rime-pinyin-simp`，经 Ni 上游
  规范化，commit `0c6861ef7420ee780270ca6d993d18d4101049d0`）见 git 历史。

## 4. 雾凇拼音词库（rime-ice，混合上游许可）

- 上游：https://github.com/iDvel/rime-ice
- 固定 commit：`99662ba01e3affa6a0f009174ca530b887bac3b6`
- 本输入法只引入全拼词库链：`8105`、`base`、`ext`、`tencent`、`others`；
  未引入 Lua、OpenCC、英文/双拼/拆字方案或语法模型。
- 上游 index 已做路径适配：`resources/rime/rime_ice/rime_ice.dict.yaml`
  将 `cn_dicts/*` 改为 `rime_ice/cn_dicts/*`，以适配 KEYI 随包资源根目录；
  各词条文件保持上游快照。
- 随包文件及 SHA-256：
  - `rime_ice/rime_ice.dict.yaml`：
    `f777f39e9a234c22f547f014731160c0a9297aaaa93958e907b55362f8553437`
  - `rime_ice/cn_dicts/8105.dict.yaml`：
    `1f9a42b91dea6982baee2551981780271aeffd78876662b9c9f324e56b37b120`
  - `rime_ice/cn_dicts/base.dict.yaml`：
    `551cad93c2e74c7325599e0d23afbf71c2d2e57df9af3f8f6fa16d87e60290a3`
  - `rime_ice/cn_dicts/ext.dict.yaml`：
    `d2d52bf75f7bcdd8a4afb036ab879415a7e620e529a4ecebc71780fe7ccdf648`
  - `rime_ice/cn_dicts/tencent.dict.yaml`：
    `3e5609a29ee8385c9de244893ead97ce48ad6dc61298c2180201b247025d4a48`
  - `rime_ice/cn_dicts/others.dict.yaml`：
    `c7475d773e619f61b88d47fa8ec789aba02aa0d1c98edaed309e53487b048b32`
- `resources/rime/CREDITS.rime-ice.md` 保留上游汇总来源。词库不是单一许可：
  上游 credits 涉及 Public Domain、Unicode License、MIT、LGPL-3.0 与 CC BY 3.0；
  `resources/rime/LICENSE.rime-ice-GPL-3.0` 随包提供雾凇拼音配置许可原文。

## 4b. 中英混输英文词表（2026-11-04 引入）

- SCOWL（Spell Checker Oriented Word Lists），作者 Kevin Atkinson：
  发布档 `scowl-2020.12.07.tar.gz`（https://sourceforge.net/projects/wordlist/files/SCOWL/2020.12.07/），
  SHA-256 `5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc`。
  取 `final/english-words` 与 `final/american-words` 的 10/20/35/40 级，经
  `Scripts/generate-english-dict.py` 生成 `resources/rime/english/scowl.dict.yaml`
  （只留两个字母以上的纯 ASCII 字母词，按级别给权重，同词大小写并存时只留小写），
  SHA-256 `898b469dbf6e23b48dcd729b262c42a3f739fc95d8a666e4405e506c600123ed`。
  许可：允许使用、复制、修改、分发和出售，须保留版权与许可声明；所用级别的来源
  （Moby Words II、Brian Kelk 词频表、12Dicts 等）为公共领域，词形库用到的 WordNet 为宽松许可；
  只有 80 级以上的词表另附 UKACD 条款，本项目未用。版权全文随包为
  `resources/rime/english/LICENSE.scowl`（发布档 `Copyright` 原文，SHA-256
  `283326a422e29c510e2ba6805518c418ce3c35ed1fadc3eec83d2da4f6c5a055`）。
- 雾凇拼音 `en_dicts/en_ext.dict.yaml`（缩写与技术词），commit 同第 4 节
  `99662ba01e3affa6a0f009174ca530b887bac3b6`，原样随包为 `resources/rime/english/en_ext.dict.yaml`，
  SHA-256 `c8648c1dc1ad691c77ef29525244d42482b2e8bcabe08355baec241f563306a2`，GPL-3.0（同第 4 节）。
- 未引入雾凇英文主词库 `en_dicts/en.dict.yaml`：其主要来源 google-10000-english 的许可只允许
  教育、个人与研究用途，作者不建议未经 LDC 授权商用。也未引入 `cn_en` 中英夹杂词表与 Lua。
- `resources/rime/keyi_english.schema.yaml`、`keyi_english.dict.yaml` 为 KEYI 自己编写。

## 5. KEYI 自有内容（Apache-2.0）

`keyi_core.dict.yaml`、`keyi_pinyin.dict.yaml`、`keyi_pinyin.schema.yaml`、
`default.yaml` 由本项目编写。其中 schema 的拼音代数规则、`punctuator`
标点表与 `speller` 容错派生规则改编自 Ni 上游同名 schema 与 Rime 官方示例，
因此按"改编自 MIT 上游 + 本项目修改"处理，不宣称完全原创。KEYI 自身许可为
Apache-2.0（见仓库根 `LICENSE.md`）。

## 6. 明确未引入

- CC BY 4.0 的 `ni_modern.dict.yaml`
- Ni 上游 LGPL-3.0 的独立 `essay-zh-hans.txt` 文件（雾凇词库自身的来源声明
  另见第 4 节，不与该文件混同）
- CC BY-SA 4.0 的 CC-CEDICT 衍生释义
- Sparkle 及任何自动更新组件
- 翻译用的本地模型运行时与权重，以及在本进程内直接发起的网络或翻译调用（语音输入的
  SenseVoice 是唯一随包的模型，见第 8 节）

## 7. KEYI 自动翻译客户端（本项目，Apache-2.0）

自动翻译接入层由 `Sources/KeyiIMETranslation/` 与仓库共享包 `../Packages/KEYITranslationClient`
组成：

- 线协议客户端与薄封装（`KEYITranslationClient.swift`、`KEYITranslationAdapter.swift`）：
  在共享包 `Packages/KEYITranslationClient`，与 KEYI 可译伴随应用共用同一份源码，作为
  SwiftPM 包依赖编入输入法（2026-10-05 起，此前为逐字节复制）。
- 从 `KEYITranslationCommand.swift` 提取的最小接口集合（`KeyiTranslationSurface.swift`）：
  客户端文本能力协议、真实 `IMKTextInput` 适配、可取消句柄、输入会话身份、范围自检。
  旧版「选区 + 快捷键」控制器与事件策略未带入。
- 自动翻译控制器（`KeyiAutomaticTranslation.swift`）：停顿/句末触发、连续提交合并、
  取消重排、回写前多重校验、防循环。行为逻辑与集成工作区一致。

它不在输入法进程内加载模型、不持有凭据、不直接联网；确认中文后经本机 AF_UNIX socket
请求用户已安装的「KEYI 可译」伴随应用，由后者按其已配置的提供方完成翻译与日志。

`Scripts/verify-bundle.sh` 对上述数据与组件逐项断言"不存在于产物中"。

## 8. 语音输入的本地识别（2026-11-07 引入）

PRODUCT_SCOPE「2026-11-07 语音输入最小版授权」及其补充。`Scripts/fetch-sensevoice.sh` 在构建时按下列
固定版本下载、校验 sha256 并解压到 `.build/vendor`，`build-ime.sh` 再拷进包里；源码仓库只放头文件和许可原文。

- **SenseVoice-Small int8**：`https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2`，
  SHA-256 `7d1efa2138a65b0b488df37f8b89e3d91a60676e416f515b952358d83dfd347e`。由 sherpa-onnx 从
  https://github.com/FunAudioLLM/SenseVoice 转换（包内 README 写明）。只取 `model.int8.onnx`、`tokens.txt`，
  放在 `Contents/Resources/SenseVoice/`。同一发布里的 `…-int8-2025-09-09` 是粤语微调版（来自 ASLP-lab/WSYue-ASR），
  普通话与英文更差，**不用**。
- **模型协议**：FunASR Model Open Source License Agreement 1.1，原文取自
  https://github.com/modelscope/FunASR/blob/main/MODEL_LICENSE （blob `d5cc52aad23a88da10b8cffbd9b56d43ac7398fa`），
  存于 `Vendor/sensevoice/MODEL_LICENSE`，随包为 `SenseVoice/MODEL_LICENSE`。
- **sherpa-onnx v2.0.1**：`https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.1/sherpa-onnx-v2.0.1-osx-arm64-shared.tar.bz2`，
  SHA-256 `5e874d3c9b3d6b8c71f7c09e3a9fb9ae846c3009129d302b398d1f7aedb69f84`。只取 `lib/libsherpa-onnx-c-api.dylib`
  与 `lib/libonnxruntime.dylib`（ONNX Runtime 1.28.2），重新签名后放进 `Contents/Frameworks/`；最低 macOS 11、仅 arm64。
  C API 头文件 `include/sherpa-onnx/c-api/c-api.h` 原样放在 `Vendor/sherpa-onnx/include/`，`Vendor/sherpa-onnx/module.modulemap`
  只导出类型（不链接）。许可原文：`Vendor/sherpa-onnx/LICENSE`（Apache-2.0，取自 v2.0.1 标签）、
  `Vendor/sherpa-onnx/onnxruntime-LICENSE`（MIT，取自 microsoft/onnxruntime v1.28.2）。

