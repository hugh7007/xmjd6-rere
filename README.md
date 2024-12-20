## 🐈星猫键道溯源⭐➡🐱：
**授权信息：** 本方案已获得正式授权。它是基于吅吅大山老师开发的星空键道6.2版本进行的修改和改进。此方案适用于PC和手机。

**主要修改：** 
1. 增加百万词库，让输入法从单字回归打词。>双简 > 三简词  > 四简词 。
2. 可以输入更多的单字。在临时有需要繁体或者生僻字时使用o键，即可输入繁体。例如：omp茻   ompu狵  oly隴 。
3. 如果遇到不会读的字，使用 v+键道双拼 键。  例：烎 vkhhl，𨽕 vxjtg，鋩 vjbmp，竝 vlklk。
4. ej→快速时间、rq→快速日期、=→计算器、内置转繁体、转火星文、\转化粗体英文、聊天emoji、快人快语。


## 🐈星猫键道初衷：
词库维护者最初使用全拼方案，后来转向了各种音码和形码方案。  
作者使用经历：  
全拼→xxx双拼→xx双拼→xx双拼→xx音形→x笔→x码→xx石码→x码→xx声笔→星空系列三款输入方案。  
一系列尝试后，个人对当前一些输入法方案有以下感受：

- **双拼：** 在大引擎支持下，提供优秀的简拼和词语输入体验。缺点是无法精准定位单个字符或词组。即使大引擎输入法提供诸如tab键的功能，多个字符的输入仍会影响体验，而且词语无法更精准修改，特别是打了一长段需要上屏后返回修改，经常打字后发送后，才发现其中有某个字，某个词需要修改。
- **音码：** 1. 音码依赖于发音，不知道发音无法输入。2. 很多音码本身缺乏合适的词库，有些音形词库甚至不如某些形码词库丰富，也有些本体即没享受到双拼的便利，也没享受到形码的精准，拆字往往属于连蒙带拆，因为拆字规则往往属于作者自定义，所以拆字属于拆作者的思想用意。
- **形码：** 1. 形码可以在不知道读音的情况下输入字符，但不知道字的读音或意思。2. 形码的优势在于能够识别字符，但脱离视觉识别，形码输入比纯音码输入多了一个步骤。3. 词库方面，因为形码主要用于输入单字，所以字根越多，码长越短，词库容量越大。但这也带来了一些缺点，比如在输入单字和词组时会有手感上的不连贯感，以及空码的情况。

经过长时间的几个方案体验。作者尝试寻找的能够结合这些方案优点的输入法，但结果是：`没有找到`。  
甚至对比一般的方案，大引擎智能输入法可能更适合日常生活。   
既然发现没有完美解决方案，那换个思路看能不能选择`相对合理`的方案然后`修改优化`。

## 为何选择键道：
1. **键道的特点：** 键道是一种音码两分输入法，采用“音+韵+辅助码”的方案。
   - 其中辅助码的基础是：`v横-  i竖|  u撇丿  o捺丶  a钩乛`。
   - 对于使用“音+笔划”的直观性问题，其实无论是用字根还是声调，本质上与数字编码无异。都是用一种规则去定位和找到对应的字符，因此笔画和字根在本质上是相同的，差异仅在于筛选码的规则。
2. **3-6码出词：** 键道支持4-6码出词，`常用单字`既有简码也有全码（6码）。
3. **词库容量：**  在基于键道拥有的飞键功能左右互击的手感前提下，能够容纳更多的词语上限。

## 🐈星猫键道的优化细节：
1. **词库扩展：** 实现了130万大词库的扩充。尽管之前尝试过增加30万、50万、80万词的规模，却总有词汇缺失。目前的方案基于1200万语料词库+词频提取了一百万词，专注优化23456的词语输入体验。但因为程序无法正确匹配词语顺序，目前不得不使用手动优化排序和权重，以便在打出声母简拼后，通过辅助码更准确地检索到对应词语。
2. **630规则调整：** 对原始的`630`规则进行了改进，更换了其中的高频词。
3. **新增功能：**
   - **`a`键：** 增加了自造词功能。
   - **`v`键：** 实现了两分规则，V键开启二分反查功能（通过键道双拼拆分文字可打全字集）。遇到不会读的字也可以随时随地打出全字集。
   - **`o`键：** O键超级繁体(全字集)，让繁体字特殊字不再属于形码专利。
   - **`u`键：** 内置全拼功能，用于临时需要时找到对应文字。
4. **以词定字：** 如果遇到不知如何输入的字，可以通过输入相关词语，然后使用< [ ] >键来精准定位。
5. **内置工具和模式：**
   - 内置计算器。
   - 转换为花体英文文字功能。
   - 生僻字畅打模式。
   - 问候词库、诗词歌赋。
   - 长句慢打模式等。
   - 快捷日期/时间/节气/大写/英文联想

这些优化和新增功能旨在提升🐈星猫键道输入方案的实用性和用户体验，使之更加贴合用户的日常输入需求。

## 如何查看学习及相关链接
1. **飞书笔记链接：** [飞书笔记 - 🐈星猫键道6](https://hu0w1jn4xq.feishu.cn/docx/ZgQ8deGPlozhWCxOyeucBvHJnPe)
2. **GitHub 仓库链接：** [🐈星猫键道6 - GitHub](https://github.com/hugh7007/xmjd6-rere)
3. **天行键 GitHub 仓库链接：**[📖天行键 - GitHub](https://github.com/wzxmer/rime-txjx)
4. **星空键道 GitHub 仓库链接：**[📖星空键道6 - GitHub](https://github.com/xkinput/Rime_JD)

## 如何使用

将 [GitHub Release](https://github.com/hugh7007/xmjd6-rere/releases/) 中的 [xmjd6.zip](https://github.com/hugh7007/xmjd6-rere/releases/latest/download/xmjd6.zip) 导入至 librime ≥ 1.9.0 的 Rime 输入法的用户文件夹中使用。
  - Windows： 
    - 小狼毫
      - [小狼毫输入法测试版](https://github.com/rime/weasel/releases/tag/latest)
      - [小狼毫输入法 水龙月 Fork 版](https://github.com/Techince/weasel/releases/latest)，需要卸载原版后重启再安装。
      - 默认用户文件夹路径：`%APPDATA%\Rime`
    - 小小输入法[星猫键道6绿色便携版](https://github.com/hugh7007/xmjd6-rere/releases/latest/download/yong-xmjd6-full.zip)，无需导入方案即可在 Windows 系统上轻量使用。使用 Ctrl + 空格激活输入法。
    - [玉兔毫](https://github.com/amorphobia/rabbit)
      - 玉兔毫[星猫键道6绿色便携版](https://github.com/hugh7007/xmjd6-rere/releases/latest/download/Rabbit-xmjd6.zip)，无需导入方案即可在 Windows 系统上轻量使用。注意目录中不能有空格。
  - macOS: 
    - [鼠须管输入法测试版](https://github.com/rime/squirrel/releases/tag/latest)
      - 默认用户文件夹路径：`~/Library/Rime` 
    - [小企鹅输入法 macOS 版【中州韵版】](https://github.com/fcitx-contrib/fcitx5-macos-installer/blob/master/README.zh-CN.md)
      - 默认用户文件夹路径：`~/.local/share/fcitx5/rime`
  - Android: 
    - [同文输入法](https://github.com/osfans/trime/releases/latest)
      - 默认用户文件夹路径：`/storage/emulated/0/rime/`
      - 需要在设置里点配置管理，点用户文件夹，再点默认后再导入方案至文件夹，再进行部署。
    - [小企鹅输入法 Android 版](https://github.com/fcitx5-android/fcitx5-android)：
      - [主程序](https://jenkins.fcitx-im.org/job/android/job/fcitx5-android/)
      - [Rime 插件](https://jenkins.fcitx-im.org/job/android/job/fcitx5-android-plugin-rime/)
      - [更新器](https://jenkins.fcitx-im.org/job/android/job/fcitx5-android-updater/)
      - 默认用户文件夹路径（在小企鹅中添加中州韵输入法后出现）：`/storage/emulated/0/Android/data/org.fcitx.fcitx5.android/files/data/rime/`
      - 推荐使用系统内置文件管理器（通过 DocumentsUI）来管理小企鹅输入法5的数据文件。 在 DocumentsUI 的侧边栏中，选择“小企鹅输入法5”，即可直接访问 /sdcard/Android/data/org.fcitx.fcitx5.android/files/ 目录中的文件，不需要借助第三方文件管理器，也不需要使用 adb 或者 root 权限。
      - 参考：https://github.com/Mintimate/oh-my-rime/issues/96/
  - iOS: 
    - [仓输入法](https://apps.apple.com/app/id6446617683)
      - 可使用内置在线方案下载导入

## 细节补充

- **主方案文件：** `xmjd6.schema.yaml`  
- **快捷功能配置：** `xmjd6.custom.yaml`  
- **英文快捷：** `xmjd6.yingwen.dict.yaml`  
- **词库开关：** `xmjd6.extended.dict.yaml`  
- **扩展词库补充：** `xmjd6.fjcy.dict.yaml`  
- **符号修改：** `xmjd6.symbols.yaml`  
- **630规则文件：** `xmjd6.wxw.dict.yaml` 和 `xmjd6.buchong.dict.yaml`  
- **快速索引：** `xmjd6.fuhao.dict.yaml`  
- **自定义词库：** `xmjd6.zidingyi.dict.yaml`  
- **个人高权限词库：** `xmjd6.user.dict.yaml`（权重最高，请谨慎添加）

**注意事项：**
- 关于流式输入、关闭emoji表情、关闭提示词、候选项数等功能，请查看`xmjd6.custom.yaml`配置文件，其中包含详细的注释说明。

#### 拓展功能一览：
- **流式输入：** 支持连续句子输入，自动调频。
- **a键：** 自造词功能。
- **u键：** 全拼反查功能（拼音查全码，新增笔画提示）。
- **i键：** 开启英文联想输入。
- **v键：** 二分反查功能（通过键道双拼拆分文字可查全码）。
- **o键：** 超级繁体输入（基于键道规则的词库扩展）。
- **注意：** 默认顶功开启，流式输入关闭。

**方案来源：** Proud丶Cat、热热、浮生、千年蟲
