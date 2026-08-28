**重要时间节点：** 
历经几年功能迭代的纯打字纯净版 xmjd6 在今天正式划上句号。
纯打字版本已更新到无可再更，发布后即为最后一版，后续作为独立分支，大概率不再更新，留给纯喜欢打字的人使用。

作者喜好更偏娱乐性质，后续主版本会放新更新，内容偏杂偏多，包括但不限于：整句回归与自造词优化、i 键英文联想、等号工具集加强、花体回归、辫子 `/` 文本加工等。
详细内容可从内置教程查看。

---

## 🐈星猫键道溯源 ⭐➡🐱

**授权信息：** 本方案已获得正式授权，基于吅吅大山老师开发的星空键道6.2版本修改改进。适用于 PC 和手机。

**版本溯源：** 星空键道6.2 → 🐈星猫键道6.3

**主要修改：**
1. 增加百万词库，让输入法从单字回归打词：>双简 >三简词 >四简词。
2. 可以输入更多单字。临时需要繁体或生僻字时使用 `o` 键即可输入全字集。例如：`omp茻` `ompu狵` `oly隴`。
3. 遇到不会读的字，使用 `v` + 二分编码。例：`vkhhl烎` `vxjtg𨽕` `vjbmp鋩` `vlklk竝`。
4. `ej` 快速时间、`rq``eo` 快速日期、`=` 计算器/工具集、内置转繁体、转火星文、`\` 花体英文、聊天 emoji、快人快语。

---

## 🐈星猫键道初衷

词库维护者最初使用全拼方案，后来转向各种音码和形码方案。
作者使用经历：
全拼→xxx双拼→xx双拼→xx双拼→xx音形→x笔→x码→xx石码→x码→xx声笔→星空系列三款输入方案。

一系列尝试后，个人对当前一些输入法方案有以下感受：

- **双拼：** 大引擎支持下提供优秀简拼和词语输入体验。缺点是无法精准定位单个字符或词组；打长段上屏后返回修改时，经常发现其中某个字/词需要修改。
- **音码：** 1. 依赖发音，不知道发音无法输入。2. 很多音码缺乏合适词库，有些音形词库甚至不如某些形码词库丰富；本体既没享受到双拼便利，也没享受到形码精准，拆字往往属于连蒙带拆。
- **形码：** 1. 可在不知道读音时输入字符，但不知道字的读音或意思。2. 优势在于识别字符，但脱离视觉识别比纯音码多了一个步骤。3. 词库方面，形码主输入单字，字根越多码长越短词库容量越大，但带来单字/词组手感不连贯以及空码问题。

经过长时间多方案体验，作者尝试寻找结合这些方案优点的输入法，结果：`没有找到`。
甚至对比一般方案，大引擎智能输入法可能更适合日常生活。
既然没有完美方案，换个思路：选择`相对合理`的方案然后`修改优化`。

## 为何选择键道

1. **键道特点：** 键道是音码两分输入法，采用"音+韵+辅助码"方案。
   - 辅助码基础：`v横-  i竖|  u撇丿  o捺丶  a钩乛`。
   - 无论用字根还是声调，本质上与数字编码无异——都是用规则定位字符，笔画和字根本质相同，差异仅在筛选码规则。
2. **3-6码出词：** 键道支持4-6码出词，`常用单字`既有简码也有全码（6码）。
3. **词库容量：** 基于键道飞键功能左右互击的手感前提下，能容纳更多词语上限。

---

## 🐈星猫键道优化细节

1. **词库扩展：** 实现 130 万大词库扩充。之前尝试 30万/50万/80万规模总有缺失；当前方案基于 1200 万语料词库 + 词频提取一百万词，专注优化 23456 词语输入体验。因程序无法正确匹配词语顺序，目前使用手动优化排序和权重，使打出声母简拼后通过辅助码更准确检索对应词语。
2. **630规则调整：** 对原始 `630` 规则改进，更换其中高频词。
3. **新增功能：**
   - **`v` 键：** 二分反查（基于 `liangfen` 词典，通过拆分文字查全码打全字集）。遇到不会读的字也可随时随地打出。
   - **`o` 键：** GBK 字集反查（基于 `xmjd6.gbk` 词典），让繁体字/特殊字不再属于形码专利。
   - **`u` 键：** 全拼反查（基于 `pinyin_simp` 词典，拼音查全码，附笔画提示）。
4. **内置工具与模式：**
   - 计算器、金额大写、进制/单位换算
   - 花体英文文字转换
   - 生僻字畅打模式
   - 问候词库、诗词歌赋
   - 整句连打模式、自造词
   - 快捷日期/时间/节气、英文联想
   - 词库模糊查询、打字统计

这些优化和新增功能旨在提升🐈星猫键道输入方案的实用性和用户体验，使之更贴合日常输入需求。

---

## 功能速查

### 输入模式

| 触发键 | 功能 | 说明 |
|--------|------|------|
| `a` 前缀 | 整句连打 | 空码时按 `a` 进入；空格分词，双空格整句上屏；回车上屏原编码 |
| `i` 前缀 | 英文联想 | 纯字母输入，空格分词，双空格/回车上屏 |
| `'` | 自造词 | `'词'编码` 添加；`''词` 删除（分号 `;` 也可作为执行后缀） |
| `i`（无前缀） | 重复上屏 | 输入 `i` 显示最近 5 条上屏内容 |
| `;f` | 重复上屏 | 输入 `;f` 显示最近 6 条上屏内容 |

### 反查模式

| 触发键 | 功能 | 词典 |
|--------|------|------|
| `u` | 全拼反查（含笔画提示） | `pinyin_simp` |
| `v` | 二分反查 | `liangfen` |
| `o` | GBK 字集反查 | `xmjd6.gbk` |

### 工具与快捷

| 输入 | 功能 |
|------|------|
| `=` + 表达式 | 计算器（如 `=1+2*3`） |
| `=10kg>lb` | 单位换算 |
| `=uuid` | 生成 UUID |
| `=pw` | 生成随机密码 |
| `=mem` | 查看内存信息 |
| `=时间戳` | 当前时间戳 |
| `=tj` | 打字统计（字数/码长/退格/连打占比） |
| `=wrap` | 文本加工面板（包裹/格式转换） |
| `=join` | 文本拼接 |
| `=o` + 字母 | 应用启动：`=oc` 计算器 / `=ol` 日历 / `=os` 设置 / `=on` 记事本 / `=ot` 终端 / `=of` 文件管理器 |
| `ej` | 快速时间 |
| `rq` | 快速日期 |
| `?` | 词库模糊查询（键道码 + `?` 触发，流式扫描所有词库） |
| `0` | 动态调频（提高当前高亮候选到首位） |
| `/` | 文本加工（有候选时按 `/` 进入加工面板） |
| `\` | 花体英文（add_ge） |
| `\|` | 辫子模式（bianzi） |

### 快捷符号（`;` 前缀）

`;q` → `~`，`;a` → `!`，`;w` → `?`，`;d` → `、`，`;e` → `。`，`;g` → `<`，`;h` → `>` 等。完整列表见 `xmjd6.fuhao.dict.yaml`。

### 开关键位

| 键 | 切换功能 |
|----|----------|
| `$` | 简繁切换 |
| `&` | Emoji 开关 |
| `%` | 逐码提示开关 |
| `*` | 火星文开关 |
| `#` | 内嵌候选开关 |
| `Ctrl+\` | Emoji 开关（PC） |
| `Ctrl+.` | 中西文标点切换 |
| `F6` | 切换方案 |

### 选词与翻页

- `[` 选首选，`]` 选末选
- `Tab` 次选
- `-` 上翻页，`=` 下翻页

---

## 如何查看学习及相关链接

1. **飞书笔记：** [飞书笔记 - 🐈星猫键道6](https://hu0w1jn4xq.feishu.cn/docx/ZgQ8deGPlozhWCxOyeucBvHJnPe)
2. **GitHub 仓库：** [🐈星猫键道6 - GitHub](https://github.com/hugh7007/xmjd6-rere)
3. **天行键仓库：** [📖天行键 - GitHub](https://github.com/wzxmer/rime-txjx)
4. **星空键道仓库：** [📖星空键道6 - GitHub](https://github.com/xkinput/Rime_JD)

---

## 如何使用

将 [GitHub Release](https://github.com/hugh7007/xmjd6-rere/releases/) 中的 [xmjd6.zip](https://github.com/hugh7007/xmjd6-rere/releases/latest/download/xmjd6.zip) 导入至 librime ≥ 1.9.0 的 Rime 输入法的用户文件夹中使用。

- **Windows：**
  - 小狼毫
    - [小狼毫输入法测试版](https://github.com/rime/weasel/releases/tag/latest)
    - [小狼毫输入法 水龙月 Fork 版](https://github.com/Techince/weasel/releases/latest)，需要卸载原版后重启再安装。
    - 默认用户文件夹路径：`%APPDATA%\Rime`
  - 小小输入法[星猫键道6绿色便携版](https://github.com/hugh7007/xmjd6-rere/releases/latest/download/yong-xmjd6-full.zip)，无需导入方案即可在 Windows 系统上轻量使用。使用 Ctrl + 空格激活输入法。
  - [玉兔毫](https://github.com/amorphobia/rabbit)
    - 玉兔毫[星猫键道6绿色便携版](https://github.com/hugh7007/xmjd6-rere/releases/latest/download/Rabbit-xmjd6.zip)，无需导入方案即可在 Windows 系统上轻量使用。注意目录中不能有空格。
- **macOS：**
  - [鼠须管输入法测试版](https://github.com/rime/squirrel/releases/tag/latest)
    - 默认用户文件夹路径：`~/Library/Rime`
  - [小企鹅输入法 macOS 版【中州韵版】](https://github.com/fcitx-contrib/fcitx5-macos-installer/blob/master/README.zh-CN.md)
    - 默认用户文件夹路径：`~/.local/share/fcitx5/rime`
- **Android：**
  - [同文输入法](https://github.com/osfans/trime/releases/latest)
    - 默认用户文件夹路径：`/storage/emulated/0/rime/`
    - 需要在设置里点配置管理，点用户文件夹，再点默认后再导入方案至文件夹，再进行部署。
  - [小企鹅输入法 Android 版](https://github.com/fcitx5-android/fcitx5-android)：
    - [主程序](https://jenkins.fcitx-im.org/job/android/job/fcitx5-android/)
    - [Rime 插件](https://jenkins.fcitx-im.org/job/android/job/fcitx5-android-plugin-rime/)
    - [更新器](https://jenkins.fcitx-im.org/job/android/job/fcitx5-android-updater/)
    - 默认用户文件夹路径（在小企鹅中添加中州韵输入法后出现）：`/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/data/rime/`
    - 推荐使用系统内置文件管理器（通过 DocumentsUI）来管理小企鹅输入法5的数据文件。在 DocumentsUI 的侧边栏中选择"小企鹅输入法5"，即可直接访问 `/sdcard/Android/data/org.fcitx.fcitx5.android/files/` 目录中的文件，不需要借助第三方文件管理器，也不需要使用 adb 或者 root 权限。
    - 参考：<https://github.com/Mintimate/oh-my-rime/issues/96/>
- **iOS：**
  - [仓输入法](https://apps.apple.com/app/id6446617683)
    - 可使用内置在线方案下载导入

---

## 细节补充

### 核心文件

| 文件 | 作用 |
|------|------|
| `xmjd6.schema.yaml` | 主方案文件（引擎/开关/反查/顶功/工具集配置） |
| `xmjd6.custom.yaml` | 常用功能集中配置（修改后需重新部署） |
| `xmjd6.extended.dict.yaml` | 词库开关（控制各子词库加载） |
| `xmjd6.fjcy.dict.yaml` | 扩展附加词库（百万词库主体） |
| `symbols.yaml` | 符号配置 |
| `xmjd6.fuhao.dict.yaml` | 快捷符号码表（`;` 前缀触发） |
| `xmjd6.user.dict.yaml` | 个人高权限词库（权重最高，谨慎添加） |
| `xmjd6.cizu.dict.yaml` | 词组词库 |
| `xmjd6.danzi.dict.yaml` | 单字词库 |
| `xmjd6.wxw.dict.yaml` | 525 声笔笔词组 |
| `xmjd6.chaojizici.dict.yaml` | 超级字词 |
| `xmjd6.gbk.dict.yaml` | GBK 字集（`o` 键反查） |
| `xmjd6.cx.dict.yaml` | 反查其码词典 |
| `xmjd6.candidate_order.dict.yaml` | 调频固化词库 |
| `xmjd6.same_code_short_first.dict.yaml` | 同码候选短词优先 |

### Lua 脚本目录

Lua 脚本位于 `lua/xmjd6/`，按功能模块组织。主要模块：

| 模块 | 功能 |
|------|------|
| `sentence_buffer` | 整句连打暂存/双空格上屏 |
| `dynamic_phrase_processor` | `'`/`''` 自造词添加/删除 |
| `eng_quick_processor` | `i` 前缀英文联想 |
| `candidate_order_processor` | `0` 调频 |
| `quick_symbol` | `;` 前缀快捷符号唯一候选上屏 |
| `direct_ascii` | 空码数字/英文符号直接上屏 |
| `text_transform` | `Ctrl+G`/`/` 文本加工面板 |
| `app_launcher` | `=o` 应用启动器 |
| `xmjd6_jisuanqi` | 计算器 |
| `number_tools` | 金额大写/进制/单位换算 |
| `xmjd6_shijian` | 日期时间工具 |
| `dict_search_trigger` | `?` 词库模糊查询 |
| `typing_stats_processor` | 打字统计 |
| `auto_fallback` | 空码自动上屏首选 |
| `xmjd6_topup_processor` | 顶功处理 |
| `lazy_simplifier` | 按需加载 emoji/火星文/异体字替换 |
| `xmjd6_embeded_cands` | 输入框内嵌候选 |
| `for_hint` | 简码提示 |
| `cx_pinyin_hint` | 反查/单字候选追加拼音提示 |

### 开关默认值

| 开关 | 默认 | 说明 |
|------|------|------|
| Emoji | 开 | `&` 或 `Ctrl+\` 切换 |
| 630 简码提示 | 开 | `%` 切换 |
| 逐码候选 | 开 | `%` 切换 |
| 动态调频 | 开 | `0` 触发调频 |
| 快符 | 开 | `;` 前缀符号候选模式 |
| 英文加空格 | 开 | 英文上屏后自动加空格 |
| 连打模式 | 开 | `a` 前缀整句连打 |
| 符号直接上屏 | 开 | `$/&/` 等符号直接上屏 |
| 等号直接上屏 | 开 | `=` 直接上屏 |
| 顶功 | 开 | 默认启用 |
| 流式输入 | 关 | 需在 `xmjd6.custom.yaml` 手动开启 |

### 注意事项

- 关于流式输入、关闭 emoji、关闭提示词、候选项数等功能，请查看 `xmjd6.custom.yaml` 配置文件，其中包含详细注释说明。
- 流式输入与顶功互斥：启用 `enable_sentence` 后顶功自动禁用，`;` `'` 号只作为分隔符。
- 自造词存储在 `dynamic_phrases.txt`，调频记录存储在 `candidate_order.txt`，改文件后无需重新部署。
- `repeat_history`（`i` 键重复上屏）与 `eng_quick_mode`（`i` 前缀英文）共用 `i` 键：空码时 `i` 触发重复上屏，有后续字母时进入英文联想。

**方案来源：** Proud丶Cat、热热佬、仰望星空、一生浮生
