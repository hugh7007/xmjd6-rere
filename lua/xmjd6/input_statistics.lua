-- 挂载： xmjd6.schema.yaml
--   engine.translators 最后一行  - lua_translator@*xmjd6/input_statistics
--   engine.processors  第一行    - lua_processor@*xmjd6/key_counter
--
--  面板指令（全部以 = 触发，无 o 前缀别名）：
--  =tj  今日        =qb  全部        =yf  7天
--  =yy  30天        =yn  365天       =jq  本设备
--  =wx  查某天 20260801（也支持 202608、2026、20260101t20260201）
--  =wk  查看/切换【文字皮肤】（一款皮肤 = 一整套面板文案）
--  =wk+字母        切换皮肤：a 键道修仙 / b 末世求生 / c 江湖侠客 /
--                  d 秘境探险 / e 魔法学院 / f 卡牌收集 /
--                  h 码人修仙 / i 吃鸡战报 / j 峡谷排位 / k 万妖图录
--                  （g 空位；完整列表见 =wk 或文件顶部 TEXT_SKINS）
--  （旧的 =wkd 段位 / =wkp 进度条皮肤已删除：=wkd 现在就是切到 d 款皮肤）
--
-- 数据：LevelDB（input_stats/db_name，默认 stats），按「天 × 设备」聚合。
-- 计键：key_counter.lua 内存通道，每键 0 次磁盘 IO。
-- ══════════════════════════════════════
local AUTO_COMMIT_CODE_LEN = 4
-- 键道6 是「变长顶功」（topup_with: auvio;，min_length 4 / 单字 2），
-- 2 码简码、4 码单字、5~6 码全码都可能被下一个编码键顶上去，不存在固定的顶屏码长。
-- 这里保留非 0 值只用于启用「顶功 / 非顶」判定；新版面板已不再用它开关分布区。
--   四码固定顶屏方案 = 4     三码顶屏方案 = 3     全拼/双拼 = 0
local TOPUP_MODE = true
-- ══════════════════════════════════════
--★★★这里修改默认文字皮肤；输入框里 =wk 查看、=wk+字母 切换（重新部署后回到这里的默认值）。
local DEFAULT_TEXT_SKIN = "a"
local TEXT_SKIN_FILE = "lua/text_skin.txt"

-- ══════════ 【文字皮肤表】══════════
-- 一款皮肤 = 一整套面板文案：图标 / 标题 / 时段词 / 境界名 + 评语（默认 10 档）/ 标签 / 进度条字符。
-- 新增一款：在下面数组里追加一块（letter 顺延 g、h…），其余代码不用动。
--   面板行序（第 8 版版式）：
--     <icon> <title_name>·<title_metric>N字
--     【<时段>】<period_word> → <境界名>
--     评语｜<境界评语>
--     均速 …｜峰速 …
--     上屏 …｜字数 …
--     <code_label>　码长 x · 击键 y/s
--     <mode_label>　非顶 x% · 顶功 y%
--     比例　单 x % ▰▰▱▱▱▱ y % 词
--     —  <方案名> —
-- realms 十档的**阈值与顺序固定**（15/30/…/150），只换名字与评语：
--   ①15~29 ②30~44 ③45~59 ④60~74 ⑤75~89 ⑥90~104 ⑦105~119 ⑧120~134 ⑨135~149 ⑩≥150
--   （阈值写在下方 REALM_THRESHOLDS，改它会影响所有皮肤，慎动。）
local TEXT_SKINS = {
    {   -- a：键道修仙（原版面板，默认）
        letter = "a", label = "键道修仙",
        icon = "📖", title_name = "键盘之道", title_metric = "总修炼",
        period_word = "修炼数据",
        code_label = "心法", mode_label = "功法",
        no_realm = "【未入道】", no_realm_comment = "以文字为道｜击字炼心方能入道",
        realms = {
            { "识符境", "初识字符，辨认字根" },
            { "运指境", "熟悉布局，缓慢敲出文字" },
            { "缀文境", "连贯打出，单字不卡顿" },
            { "顺章境", "整句流畅，指法初养成" },
            { "凝心境", "眼到手到，心神专注" },
            { "御字境", "节奏稳定，持续输入" },
            { "通章境", "整篇文稿，一气呵成" },
            { "合契境", "心神与文字相融" },
            { "化文境", "念头一动文字即出" },
            { "道成境", "字道圆满，随心而输，快慢由心" },
        },
    },
    {   -- b：末世求生
        letter = "b", label = "末世求生",
        icon = "⚔️💀", title_name = "末世求生", title_metric = "总求生",
        period_word = "求生异能",
        code_label = "能耗", mode_label = "储备",
        no_realm = "【未觉醒】", no_realm_comment = "以文字为矛｜击字求生方能觉醒",
        realms = {
            { "拾荒", "废土拾字，辨认残卷" },
            { "辨字", "熟悉残文，缓慢敲出" },
            { "缀码", "字块拼缀，单字不卡" },
            { "顺句", "整句成形，指法初稳" },
            { "凝神", "心手合一，专注戒备" },
            { "御字", "节奏稳定，持续输入" },
            { "通录", "一气录完，废土成篇" },
            { "合流", "指尖铸字，废土求生" },
            { "化废", "念头一动，文字即出" },
            { "火种", "火种不灭，随心而输，快慢由心" },
        },
    },
    {   -- c：江湖侠客
        letter = "c", label = "江湖侠客",
        icon = "🗡️📃", title_name = "侠笔录字", title_metric = "总誊写",
        period_word = "笔墨修为",
        code_label = "内息", mode_label = "剑招",
        no_realm = "【未入门】", no_realm_comment = "以文字为剑｜落字成招方能入门",
        realms = {
            { "识帖", "初识笔帖，辨认字根" },
            { "运笔", "熟悉笔路，缓慢落墨" },
            { "缀文", "字字相连，单字不滞" },
            { "顺招", "整句如招，笔势初成" },
            { "凝神", "眼到手到，心神专注" },
            { "御笔", "落笔稳定，持续书写" },
            { "通篇", "一气誊成，行云流水" },
            { "合璧", "落字如剑，笔墨行江湖" },
            { "化墨", "念动笔随，文字即出" },
            { "剑心", "笔墨通神，随心而输，快慢由心" },
        },
    },
    {   -- d：秘境探险
        letter = "d", label = "秘境探险",
        icon = "🗺️🔦", title_name = "秘境手记", title_metric = "总记录",
        period_word = "探索等级",
        code_label = "体能", mode_label = "行囊",
        no_realm = "【未探明】", no_realm_comment = "以文字为图｜笔录成路方能探明",
        realms = {
            { "识文", "初识符号，辨认线条" },
            { "运图", "熟悉地图，缓慢前行" },
            { "缀记", "线索相连，单字不停" },
            { "顺迹", "整句成图，指法初成" },
            { "凝神", "眼到手到，心神专注" },
            { "御录", "记录稳定，持续探索" },
            { "通探", "一气记完，秘境在握" },
            { "解密", "笔录线索，破解秘境玄机" },
            { "化境", "念动文成，线索自现" },
            { "寻宝", "秘境尽览，随心而录，快慢由心" },
        },
    },
    {   -- e：魔法学院
        letter = "e", label = "魔法学院",
        icon = "🪄📖", title_name = "咒文典籍", title_metric = "总诵录",
        period_word = "咒文修为",
        code_label = "魔力", mode_label = "咒式",
        no_realm = "【未入学】", no_realm_comment = "以文字为咒｜书咒成式方能入学",
        realms = {
            { "识咒", "初识咒符，辨认魔文" },
            { "运杖", "熟悉杖势，缓慢吟出" },
            { "缀文", "咒字相连，单字不滞" },
            { "顺典", "整句成咒，指法初成" },
            { "凝神", "眼到手到，心神专注" },
            { "御咒", "吟诵稳定，持续施术" },
            { "通篇", "一气诵完，典籍通明" },
            { "合鸣", "指尖书咒，唤文字魔力" },
            { "化法", "念动咒成，文字即出" },
            { "大魔导", "咒法圆满，随心而书，快慢由心" },
        },
    },
    {   -- f：卡牌收集
        letter = "f", label = "卡牌收集",
        icon = "🃏🪙", title_name = "字卡图鉴", title_metric = "总收录",
        period_word = "卡牌等级",
        code_label = "牌能", mode_label = "卡组",
        no_realm = "【未成套】", no_realm_comment = "以文字为卡｜组字成牌方能成套",
        realms = {
            { "识卡", "初识卡面，辨认字根" },
            { "运筹", "熟悉牌序，缓慢出牌" },
            { "缀组", "卡牌相连，单卡不滞" },
            { "顺局", "整局顺畅，指法初成" },
            { "凝神", "眼到手到，心神专注" },
            { "御牌", "出牌稳定，持续构筑" },
            { "通鉴", "一气打完，图鉴渐满" },
            { "合击", "组字成卡，构筑手牌" },
            { "化金", "念动牌出，文字即现" },
            { "收藏家", "图鉴圆满，随心而收，快慢由心" },
        },
    },
    -- ═════ [0915] 合并自旧版的主题皮肤（h~k）：标题 / 评语 / 格式文案 一整套随皮肤切换 ═════
    -- （g 为原版打字空位；h 码人修仙 / i 吃鸡战报 / j 峡谷排位 三款十档用默认阈值，
    --   k 万妖图录 十六档自带 realm_thresholds）
    {   -- h：码人修仙（旧「修仙」主题，按用户要求扩为十档）
        letter = "h", label = "码人修仙",
        icon = "☯️", title_name = "码人修仙", title_metric = "总修行",
        period_word = "修行数据",
        code_label = "心法", mode_label = "功法",
        no_realm = "【未入道】", no_realm_comment = "以文字为引｜炼字修心方能入道",
        realms = {
            { "炼气期", "🔥 引气入体，指法初成" },
            { "筑基期", "🌿 经脉渐通，运指渐顺" },
            { "金丹期", "💧 心境渐平，字由心生" },
            { "元婴期", "⚡ 气随意动，指落成章" },
            { "化神期", "🔮 化神之境，人键合一" },
            { "炼虚期", "🌀 虚实相生，指下有风" },
            { "合体期", "🛡️ 形神相合，键随心动" },
            { "大乘期", "🌟 大乘在望，字字生辉" },
            { "金仙期", "☀️ 罡气护体，键盘生风" },
            { "天人合一", "☯️ 天人合一，键与道合" },
        },
    },
    {   -- i：吃鸡战报（旧「吃鸡」主题，按用户要求扩为十档）
        letter = "i", label = "吃鸡战报",
        icon = "🪂", title_name = "吃鸡战报", title_metric = "总战绩",
        period_word = "战报数据",
        code_label = "身法", mode_label = "压枪",
        no_realm = "【未跳伞】", no_realm_comment = "以文字为枪｜压稳每一键方能跳伞",
        realms = {
            { "热血青铜", "🐣 落地成盒，下把再战" },
            { "人体描边", "🎯 枪法随缘，描边未中" },
            { "白银段位", "🥈 稳中有进，渐入佳境" },
            { "黄金段位", "🥇 稳扎稳打，决赛圈见" },
            { "尊贵铂金", "🏅 压枪渐稳，火力全开" },
            { "璀璨钻石", "💎 枪枪爆头，键无虚发" },
            { "荣耀皇冠", "🏆 决赛圈收割机" },
            { "王牌选手", "🎖️ 定点架枪，弹无虚发" },
            { "超级王牌", "✈️ 空投落点，皆我猎场" },
            { "无敌战神", "🍗 大吉大利，今晚吃鸡" },
        },
    },
    {   -- j：峡谷排位（旧「LOL」主题，十档用默认阈值）
        letter = "j", label = "峡谷排位",
        icon = "⚔️", title_name = "峡谷排位", title_metric = "总对局",
        period_word = "排位数据",
        code_label = "走位", mode_label = "补刀",
        no_realm = "【未出泉水】", no_realm_comment = "以文字为刃｜补好每一刀方能出战",
        realms = {
            { "坚韧黑铁", "🚪 刚出泉水，先熟悉按键" },
            { "英勇青铜", "🧱 走位生涩，小心塔下送" },
            { "不屈白银", "🔪 补刀不稳，经济落后" },
            { "荣耀黄金", "🗡️ 对线稳住，发育为主" },
            { "华贵铂金", "🛡️ 防线稳固，支援及时" },
            { "流光翡翠", "⚔️ 团战切入，伤害拉满" },
            { "璀璨钻石", "🏹 走位风骚，收线拿塔" },
            { "超凡大师", "🔥 节奏起飞，全场游走" },
            { "傲世宗师", "👑 超神时刻，carry 全场" },
            { "最强王者", "🏆 五杀超神，全场最佳" },
        },
    },
    {   -- k：万妖图录（旧「万妖图录传」主题，丹青绘妖十六境，保留十六档）
        letter = "k", label = "万妖图录",
        icon = "📜", title_name = "万妖图录", title_metric = "总图录",
        period_word = "妖录数据",
        code_label = "笔法", mode_label = "画法",
        no_realm = "【未开卷】", no_realm_comment = "以文字为墨｜落笔千行方能开卷",
        realm_thresholds = { 15, 24, 33, 42, 51, 60, 69, 78, 87, 96, 105, 114, 123, 132, 141, 150 },
        realms = {
            { "凡境", "🖌️ 墨未磨开，妖还没影" },
            { "闻弦境", "📜 空卷未落笔，妖气不来" },
            { "鸣骨境", "🦴 骨鸣清越，妖纹初显" },
            { "成丹境", "🌕 丹成如月，笔意渐圆" },
            { "点墨境", "🖊️ 笔锋打颤，妖形未成" },
            { "种莲境", "🪷 落笔生莲，渐有章法" },
            { "观山境", "⛰️ 笔下有山河，妖气初聚" },
            { "燃灯境", "🏮 挑灯画妖，笔走龙蛇" },
            { "登楼境", "🏯 登楼远眺，万妖在卷" },
            { "执棋境", "♟️ 执笔如执棋，落子镇妖" },
            { "成画境", "🎨 丹青点染，万妖入卷" },
            { "落墨境", "🖋️ 落墨生辉，妖形跃然" },
            { "流丹境", "🌠 流丹如星，笔下生辉" },
            { "游虚海", "🌊 墨染沧海，山海为图" },
            { "万象天", "🌌 万象归卷，天图将成" },
            { "太上京", "🏛️ 一卷通神，万妖俯首" },
        },
    },
}
-- 默认十档阈值（未自带 realm_thresholds 的皮肤共用；改这里会让它们的第 N 档一起挪）
local REALM_THRESHOLDS = { 15, 30, 45, 60, 75, 90, 105, 120, 135, 150 }
-- 比例条字符（所有皮肤共用；旧版那 9 款进度条皮肤已随 =wkp 一并删除）
local BAR_FIELD, BAR_EMPTY = "▰", "▱"
-- 字母 → 皮肤（a→第 1 款、b→第 2 款 …）
local function skin_by_letter(letter)
    for _, s in ipairs(TEXT_SKINS) do
        if s.letter == letter then return s end
    end
    return nil
end

-- [0914] 「机器文本」识别（on_commit 用）：面板/提示的首字符一律算机器文本——
--   即使被误上屏也不记成一次真实打字。皮肤图标会换（⚔️💀 / 🗡️📃 …），
--   所以不能只写死 📖，这里把每款皮肤的图标前缀一并收进来，按前缀逐个比对。
--   （不用 Lua 字节字符类 [※📖…]：那个按字节匹配，会把所有同首字节的字都误判。）
local MACHINE_PREFIXES = { "※", "◉", "🏆", "📊", "⚡", "📈" }
for _, s in ipairs(TEXT_SKINS) do
    MACHINE_PREFIXES[#MACHINE_PREFIXES + 1] = s.icon
end
local function is_machine_text(text)
    if not text or text == "" then return true end
    for _, p in ipairs(MACHINE_PREFIXES) do
        if text:sub(1, #p) == p then return true end
    end
    return false
end
-- ═════════════════════════════════════
-- ═════════════════════════════════════
-- 【可修改】速度统计参数（改这里即可）
-- 改完保存 → 重新部署生效；若 schema 里配了 input_stats/xxx，则以 schema 为准。
-- ═════════════════════════════════════
-- 会话间隔（毫秒）：两次上屏间隔超过它 = 上一个会话结束，之后算新会话。
--   调大 → 均速更稳（想一下再打不会切断会话）；调小 → 更敏感。
--   范围：连续判定值 ~ 30000，默认 5000（5秒）
local AVERAGE_GAP_MS = 5000

-- 峰速窗口（毫秒）：一段「连续输入」累计到这么长，才结算出一个峰速样本。
--   调大 → 峰值更稳（更接近"持续速度"，短促爆发被抹平）；调小 → 更偏爆发力。
--   当前 10000（10 秒）。这个数字同时决定 UserDb 里峰速桶的后缀
--   （speed_peak_window_10s）——见下面的 peak_key_prefix()。
--   改这里会自动换后缀，并让 migrate_database 清掉旧后缀的桶，不会新旧混桶同算。
local PEAK_WINDOW_MS = 10000
-- 峰速窗口切断间隙（毫秒）：停顿超过它 = 这段输入结束，窗口结算（不足 PEAK_WINDOW_MS 则作废）。
--   必须与 AVERAGE_GAP_MS 取同一个值：全模块只允许存在一个「连续输入」的定义，
--   否则会出现「均速把这一段算作一个会话、峰速却把它切成两半」的口径打架。
--   注意与 PEAK_WINDOW_MS 语义不同：窗口 = 一段样本要多长，间隙 = 停多久算断。
local PEAK_GAP_MS = 5000

-- 连续输入判定（毫秒）：间隔超过它视为"不连续"输入（影响会话质量）。
--   范围：200 ~ 5000，默认 1000（1 秒）
local CONTINUOUS_GAP_MS = 1000

-- 最短会话（毫秒）：单次会话不足此时长不计入均速（排除碎片输入）。
--   范围：500 ~ 10000，默认 1000（1 秒）
local MINIMUM_AVERAGE_SESSION_MS = 1000

-- 最少总时长（毫秒）：所有会话累计不足此时长，均速显示 "--"。
--   范围：3000 ~ 120000，默认 15000（15 秒）
local MINIMUM_AVERAGE_TOTAL_MS = 15000

-- 速度统计单次上屏最大字数：超过不参与速度计算（排除粘贴大段文本）。
--   范围：1 ~ 10，默认 10
local MAX_SPEED_COMMIT_LENGTH = 10

-- 速度统计窗口（天）：=qb「全部」面板在这么长的窗口里算 均速 / 峰速 / 击键。
--   0 = 不限（用全部历史）。
--   **它只决定"统计多少天"，不会删除任何记录**——原始数据一直在 stats.userdb 里，
--   调大/调小随时能看回来。（旧注释写的"更早自动清理"是错的，代码里没有任何按日期删除的逻辑。）
--   注意：=tj/=yf/=yy/=yn/=wx 各有自己的区间，不受这个值影响。
--   范围：0 ~ 3650，默认 0（不限）
local SPEED_HISTORY_DAYS = 0

-- [0913] 峰速桶的键后缀，由窗口长度推导，保证「窗口长度」和「桶名」永远不会再漂移。
--   历史上这里就是漂的：窗口早改成 15 秒，桶名却一直写着 _10s，导致
--   光看键名根本对不上真实口径。现在窗口多长，桶名就写多长。
--   换窗口后旧后缀的桶会在 migrate_database() 里被清掉，新旧样本不会混在一个桶里算。
local function peak_key_prefix(window_ms)
    return string.format("speed_peak_window_%ds", math.floor(window_ms / 1000 + 0.5))
end
-- [0914] userdb 包装器原为独立文件，现并入此处（唯一消费者就是本模块）
local META_KEY_PREFIX = "\001" .. "/"

-- UserDb 缓存，使用弱引用表，不阻止垃圾回收并能自动清理
local db_pool = setmetatable({}, { __mode = "v" })

---@class WrappedUserDb: UserDb
---@field meta_query fun(self: self, prefix: string): DbAccessor
---@field meta_fetch fun(self: self, key: string): string|nil
---@field meta_update fun(self: self, key: string, value: string): boolean
---@field meta_erase fun(self: self, key: string): boolean
---@field query_with fun(self: self, prefix: string, handler: fun(key: string, value: string))
---@field empty fun(self: self, include_metafield?: boolean) -- 清空数据库

-- 用于存放包装器对象的自定义方法
local extends = {}

--- @param key string
--- @return string|nil
function extends:meta_fetch(key)
  return self._db:fetch(META_KEY_PREFIX .. key)
end

--- @param key string
--- @param value string
--- @return boolean
function extends:meta_update(key, value)
  return self._db:update(META_KEY_PREFIX .. key, value)
end

--- @param key string
--- @return boolean
function extends:meta_erase(key)
  return self._db:erase(META_KEY_PREFIX .. key)
end

--- @param prefix string
--- @return DbAccessor
function extends:meta_query(prefix)
  return self._db:query(META_KEY_PREFIX .. prefix)
end

function extends:query_with(prefix, handler)
  local da = self._db:query(prefix)
  if da then
    for key, value in da:iter() do
      handler(key, value)
    end
  end
  da = nil
  collectgarbage()
end

--- @param include_metafield boolean 是否也清理元数据。
function extends:empty(include_metafield)
  self:query_with("", function(key, _)
    local is_metafield = key:find(META_KEY_PREFIX, 1, true) == 1
    if include_metafield or not is_metafield then
      self._db:erase(key)
    end
  end)
end

local mt = {
  __index = function(wrapper, key)
    -- 优先使用自定义方法
    if extends[key] then
      return extends[key]
    end

    -- 不是自定义方法，委托给真实的 UserDb 对象
    local real_db = wrapper._db
    local value = real_db[key]

    if type(value) == "function" then
      return function(_, ...)
        return value(real_db, ...)
      end
    end

    return value
  end,
}

local userdb = {}

--- @param db_name string
--- @param db_class "userdb" | "plain_userdb" | nil
--- @return WrappedUserDb
function userdb.UserDb(db_name, db_class)
  db_class = db_class or "userdb"
  local key = db_name .. "." .. db_class

  ---@type UserDb
  local db = db_pool[key]
  if not db then
    db = UserDb(db_name, db_class)
    db_pool[key] = db
  end

  local wrapper = {
    _db = db,
    _pool_key = key,
  }

  return setmetatable(wrapper, mt)
end

function userdb.LevelDb(db_name)
  return userdb.UserDb(db_name, "userdb")
end

function userdb.TableDb(db_name)
  return userdb.UserDb(db_name, "plain_userdb")
end
-- 击键器（可选，未挂载 processor 时会自动退回码长统计）
-- 这里拿到的只是「模块句柄」，用来看 key_counter 能不能用。**真正的数据共享不靠它**：
-- librime-lua 每个组件创建时都会清模块缓存，processor 与 translator 各自 require 一次，
-- 必然拿到两份不同的模块副本；key_counter.lua 把 pending / total_keys / commit_handler
-- 全部放在 _G.__xmjd6_key_counter_state 这张状态表里，所以哪份副本都行。
-- 取用顺序：_G 上的句柄 → require → dofile 兜底（部分发行版 package.path 不含用户目录 lua/）。
local key_counter = _G.__xmjd6_key_counter
local ok_key_counter = type(key_counter) == "table"
if not ok_key_counter then
    ok_key_counter, key_counter = pcall(require, "xmjd6.key_counter")
    if ok_key_counter and type(key_counter) ~= "table" then ok_key_counter = false end
end
-- 电脑 Rime 兼容：部分发行版的 librime-lua package.path 不含用户目录 lua/，
-- require 会失败（手机元书正常）。processor 按文件名加载不受影响、照常计数，
-- 但 ok_key_counter=false 会让指令键清理（reset）全部失效 → 指令键残留污染码长。
-- 兜底：require 失败时按绝对路径 dofile 加载同一份 key_counter.lua。
if not ok_key_counter and rime_api and rime_api.get_user_data_dir then
    local ok_dir, dir = pcall(rime_api.get_user_data_dir)
    if ok_dir and dir then
        if dir:sub(-1) ~= "/" then dir = dir .. "/" end
        ok_key_counter, key_counter = pcall(dofile, dir .. "lua/xmjd6/key_counter.lua")
        if ok_key_counter and type(key_counter) ~= "table" then ok_key_counter = false end
    end
end
key_counter = _G.__xmjd6_key_counter or key_counter
-- 模块私有数据库池：同名数据库共享包装器和生命周期。
local DB_POOL = {}

local RECORD_SEPARATOR = " \t"
local STATS_C_MAX = 2147483000
local BATCH_INTERVAL = 5
local MAX_PENDING_CHARACTERS = 200
local STATISTICS_PREFIX = "statistics/"
local DAY_PREFIX = STATISTICS_PREFIX .. "day/"
local MIGRATION_KEY = "metadata/readable_statistics_migrated"
local DAY_FIELDS = {
    ["text/characters"]="characters",
    ["text/commits"]="commits",
    ["text/keystrokes"]="keystrokes",
    ["commit_length/1"]="length_1",
    ["commit_length/2"]="length_2",
    ["commit_length/3"]="length_3",
    ["commit_length/4"]="length_4",
    ["commit_length/5_plus"]="length_5_plus",
    ["text/code_len_without_space"]="code_len_without_space",
    ["text/auto_commits"]="auto_commits",
    ["text/backspaces"]="backspaces",
}
local LEGACY_FIELDS = {
    _len="text/characters",
    _cnt="text/commits",
    _code="text/keystrokes",
    _l1="commit_length/1",
    _l2="commit_length/2",
    _l3="commit_length/3",
    _l4="commit_length/4",
    _l_gt4="commit_length/5_plus",
}
local function read_text_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end
local function write_text_file(path, content)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end
local function user_data_dir()
    return rime_api.get_user_data_dir() .. "/"
end
local FINGER_STYLE_MAP = {
    pinyin="全拼", zrm="自然码", flypy="小鹤双拼", mspy="微软双拼",
    sogou="搜狗双拼", abc="智能ABC", ziguang="紫光双拼",
    pyjj="拼音加加", gbpy="国标双拼", zrlong="自然龙",
    hxlong="汉心龙", ltsp="蓝天双拼", lxsq="乱序17",
    sdpy="首道双拼", t9="九键",
}

-- [内联] 原 wanxiang.lua 的 get_input_method_type（万象公共库唯一依赖，已独立）
local INPUT_METHOD_MARKERS = {
    ["Ⅰ"] = "pinyin",   ["Ⅱ"] = "zrm",      ["Ⅲ"] = "flypy",    ["Ⅳ"] = "mspy",
    ["Ⅴ"] = "sogou",    ["Ⅵ"] = "abc",      ["Ⅶ"] = "ziguang",  ["Ⅷ"] = "pyjj",
    ["Ⅸ"] = "gbpy",     ["Ⅺ"] = "zrlong",   ["Ⅻ"] = "hxlong",   ["Ⅿ"] = "ltsp",
    ["Ⅼ"] = "lxsq",     ["Ⅽ"] = "dnsp",     ["Ⅾ"] = "sdpy",     ["ⅲ"] = "ⅲ",
    ["ⅱ"] = "t9",
}
local INPUT_METHOD_MARKER_ORDER = {
    "Ⅰ", "Ⅱ", "Ⅲ", "Ⅳ", "Ⅴ", "Ⅵ", "Ⅶ", "Ⅷ",
    "Ⅸ", "Ⅹ", "Ⅺ", "Ⅻ", "Ⅿ", "Ⅼ", "Ⅽ", "ⅱ",
}
local INPUT_METHOD_MD_MARKER = "ⅲ"
local function get_input_method_type(env)
    local config = env.engine.schema.config
    local algebra = config:get_list("speller/algebra")
    if not algebra then return "unknown" end
    local result_id = "unknown"
    local md = nil
    for i = 0, algebra.size - 1 do
        local value = algebra:get_value_at(i)
        local rule = value and value:get_string()
        if rule then
            if not md and rule:find(INPUT_METHOD_MD_MARKER, 1, true) then
                md = INPUT_METHOD_MD_MARKER
            end
            if result_id == "unknown" then
                for j = 1, #INPUT_METHOD_MARKER_ORDER do
                    local symbol = INPUT_METHOD_MARKER_ORDER[j]
                    if rule:find(symbol, 1, true) then
                        result_id = INPUT_METHOD_MARKERS[symbol]
                        break
                    end
                end
            end
            if result_id ~= "unknown" and md then break end
        end
    end
    if md then return result_id, md end
    return result_id
end

local function normalize_device_id(value)
    return tostring(value or ""):lower():gsub("[^0-9a-f]", ""):sub(1, 8)
end

local function is_device_id(value)
    return type(value) == "string" and value:match("^%x%x%x%x%x%x%x%x$") ~= nil
end

local function get_device_id(config)
    local id = normalize_device_id(config:get_string("input_stats/device_id"))
    if #id == 8 then return id end
    local user_dir = rime_api.get_user_data_dir()
    if not user_dir or user_dir == "" then return "00000000" end
    local file = io.open(user_dir:gsub("[/\\]+$", "") .. "/installation.yaml", "r")
    if not file then return "00000000" end
    for line in file:lines() do
        local value = line:match("^%s*installation_id%s*:%s*(.-)%s*$")
        if value then
            value = value:gsub("%s+#.*$", ""):gsub('^"(.*)"$', "%1")
                :gsub("^'(.*)'$", "%1")
            file:close()
            id = normalize_device_id(value)
            return #id == 8 and id or "00000000"
        end
    end
    file:close()
    return "00000000"
end

local function acquire_db(env)
    if env.stats_db then return env.stats_db end

    local entry = DB_POOL[env.stats_db_name]
    if not entry then
        local db = userdb.LevelDb(env.stats_db_name)
        if not db or not db:loaded() and not db:open() then
            env.stats_db_error = true
            return nil
        end
        entry = {db=db, refs=0}
        DB_POOL[env.stats_db_name] = entry
    elseif not entry.db or not entry.db:loaded() and not entry.db:open() then
        DB_POOL[env.stats_db_name] = nil
        env.stats_db_error = true
        return nil
    end

    entry.refs = entry.refs + 1
    env.stats_db = entry.db
    env.stats_db_error = nil
    return entry.db
end

local function get_db(env)
    return env.stats_db or acquire_db(env)
end

local function release_db(env)
    local db, db_name = env.stats_db, env.stats_db_name
    env.stats_db = nil

    local entry = db_name and DB_POOL[db_name]
    if not db or not entry or entry.db ~= db then return end

    entry.refs = math.max(0, entry.refs - 1)
    if entry.refs > 0 then return end

    DB_POOL[db_name] = nil

    -- DbAccessor 没有显式析构接口。所有局部访问器先置空，再执行一次
    -- 完整垃圾回收，确保其先于所引用的 LevelDb 释放。
    collectgarbage()

    if db:loaded() then db:close() end
    entry.db = nil
end

local function make_raw_key(key, device_id)
    if not key or key == "" or not is_device_id(device_id) then return nil end
    return key .. RECORD_SEPARATOR .. device_id
end

local function parse_raw_key(raw_key)
    if type(raw_key) ~= "string" then return nil, nil end
    local split = raw_key:find(RECORD_SEPARATOR, 1, true)
    if not split then return nil, nil end
    local key = raw_key:sub(1, split - 1)
    local device_id = raw_key:sub(split + #RECORD_SEPARATOR)
    if key == "" or not is_device_id(device_id) then return nil, nil end
    return key, device_id
end

local function to_integer(value)
    value = tonumber(value) or 0
    if value ~= value or value == math.huge or value == -math.huge then value = 0 end
    value = value < 0 and math.ceil(value) or math.floor(value)
    return math.max(0, math.min(STATS_C_MAX, value))
end

local function parse_tail(tail)
    if type(tail) ~= "string" then return 0 end
    local c, d, t = tail:match("^c=([^%s\t]+) d=([^%s\t]+) t=([^%s\t]+)$")
    c, d, t = tonumber(c), tonumber(d), tonumber(t)
    if not c or c < 0 or c ~= math.floor(c) or d ~= 0
        or not t or t < 0 or t ~= math.floor(t)
    then
        return 0
    end
    return to_integer(c)
end

local function db_get(db, key, device_id)
    local raw_key = make_raw_key(key, device_id)
    return raw_key and parse_tail(db:fetch(raw_key)) or 0
end

local function db_set(db, key, device_id, value)
    local raw_key = make_raw_key(key, device_id)
    return raw_key and db:update(raw_key,
        string.format("c=%d d=0 t=0", to_integer(value))) or false
end

local function db_add(db, key, device_id, amount)
    return db_set(db, key, device_id, db_get(db, key, device_id) + amount)
end

local function scan_prefix(db, prefix, device_id, handler)
    local accessor = db:query(prefix)
    if not accessor then return end

    do
        for raw_key, tail in accessor:iter() do
            if raw_key:sub(1, #prefix) ~= prefix then break end

            local key, record_device = parse_raw_key(raw_key)
            if key and (not device_id or record_device == device_id) then
                handler(key, record_device, parse_tail(tail), raw_key)
            end
        end
    end

    accessor = nil
end

local function monotonic_ms()
    if rime_api and rime_api.get_time_ms then
        return math.floor(rime_api.get_time_ms())
    end
    return os.time() * 1000
end

local function day_id(timestamp)
    local date = os.date("*t", timestamp or os.time())
    return string.format("%04d%02d%02d", date.year, date.month, date.day)
end

local function is_chinese(code)
    return (code >= 0x4E00 and code <= 0x9FFF)
        or (code >= 0x3400 and code <= 0x4DBF)
        or (code >= 0x20000 and code <= 0x2A6DF)
        or (code >= 0x2A700 and code <= 0x2B73F)
        or (code >= 0x2B740 and code <= 0x2B81F)
        or (code >= 0x2B820 and code <= 0x2CEAF)
        or (code >= 0x2CEB0 and code <= 0x2EBEF)
        or (code >= 0x30000 and code <= 0x3134F)
        or (code >= 0x31350 and code <= 0x323AF)
        or (code >= 0x2EBF0 and code <= 0x2EE5F)
        or (code >= 0xF900 and code <= 0xFAFF)
        or (code >= 0x2F800 and code <= 0x2FA1F)
        or (code >= 0x2E80 and code <= 0x2EFF)
        or (code >= 0x2F00 and code <= 0x2FDF)
end

local function chinese_length(text)
    local count = 0
    for _, code in utf8.codes(text) do
        if is_chinese(code) then count = count + 1 end
    end
    return count
end

local function new_stats()
    return {
        characters=0, commits=0, keystrokes=0,
        average_characters=0, average_milliseconds=0, average_sessions=0,
        peak_speed=nil,
        length_1=0, length_2=0, length_3=0, length_4=0, length_5_plus=0,
        lifetime_characters=0,
        code_len_without_space=0, auto_commits=0,
        backspaces=0,
        speed_keystrokes=0,
        average_keystrokes=0,
    }
end

local function pending_add(env, key, amount)
    local db = get_db(env)
    if env.stats_db_error or not db or not db:loaded() then return false end
    env.pending_stats[key] = (env.pending_stats[key] or 0) + amount
    return true
end

local function flush_pending(env)
    if not next(env.pending_stats) then return true end
    local db = get_db(env)

    if db and db:loaded() then
        for key, amount in pairs(env.pending_stats) do
            if not db_add(db, key, env.device_id, amount) then
                db = nil
                break
            end
        end
    end

    if not db then
        env.pending_stats = {}; env.pending_characters = 0
        env.stats_db_error = true
        return false
    end

    env.pending_stats = {}
    env.pending_characters = 0
    env.last_flush_ts = os.time()
    return true
end

local function try_flush(env)
    if next(env.pending_stats)
        and (env.pending_characters >= MAX_PENDING_CHARACTERS
            or os.time() - env.last_flush_ts >= BATCH_INTERVAL)
    then
        flush_pending(env)
    end
end

local function reset_sample(sample)
    sample.started = nil
    sample.last_activity = nil
    sample.last_commit = nil
    sample.characters = 0
    sample.keystrokes = 0
    sample.day = nil
end

local function start_sample(sample, day, timestamp_ms)
    sample.started = timestamp_ms
    sample.last_activity = timestamp_ms
    sample.last_commit = nil
    sample.characters = 0
    sample.keystrokes = 0
    sample.day = day
end

local function sample_values(sample, minimum_ms)
    if not sample.started or not sample.last_commit or sample.characters < 2 then
        return nil
    end
    local milliseconds = sample.last_commit - sample.started
    if milliseconds < minimum_ms then return nil end
    return sample.day, sample.characters, milliseconds, sample.keystrokes
end

local function finish_average(env)
    local day, characters, milliseconds, keystrokes = sample_values(
        env.average_sample, env.minimum_average_session_ms
    )
    reset_sample(env.average_sample)
    if not day then return false end
    local prefix = DAY_PREFIX .. day .. "/speed_average/"
    pending_add(env, prefix .. "characters", characters)
    pending_add(env, prefix .. "milliseconds", milliseconds)
    pending_add(env, prefix .. "keystrokes", keystrokes)
    pending_add(env, prefix .. "sessions", 1)
    return true
end

local function peak_speed(characters, milliseconds)
    return math.max(0, math.min(2000,
        math.floor(characters * 60000 / milliseconds + 0.5)))
end

local function finish_peak(env)
    local window_ms = env.peak_window_ms or PEAK_WINDOW_MS
    local day, characters, milliseconds = sample_values(
        env.peak_sample, window_ms
    )
    reset_sample(env.peak_sample)
    if not day then return false end
    -- 桶名后缀由窗口长度推导（env.peak_key_prefix），不写死，避免"键名和口径对不上"
    local prefix = env.peak_key_prefix or peak_key_prefix(window_ms)
    pending_add(env, string.format("%s%s/%s/%04d",
        DAY_PREFIX, day, prefix, peak_speed(characters, milliseconds)), 1)
    return true
end

local function ensure_sample(sample, day, timestamp_ms, gap_ms, finish)
    if sample.started then
        local gap = timestamp_ms - (sample.last_activity or sample.started)
        if gap >= 0 and gap <= gap_ms and sample.day == day then return end
        finish()
    end
    start_sample(sample, day, timestamp_ms)
end

local function finish_stale(env, timestamp_ms)
    local peak = env.peak_sample
    if peak.started and timestamp_ms - (peak.last_activity or peak.started)
        > env.continuous_gap_ms
    then
        finish_peak(env)
    end
    local average = env.average_sample
    if average.started and timestamp_ms - (average.last_activity or average.started)
        > env.average_gap_ms
    then
        finish_average(env)
    end
end

local function observe_input_activity(env, input)
    local timestamp_ms = monotonic_ms()
    -- "=" 开头的输入是指令（=tj/=qb/…），不是打字节奏，不参与速度采样
    if not input or input == "" or input:sub(1, 1) == "=" then
        finish_stale(env, timestamp_ms)
        env.last_observed_input = input or ""
        return
    end
    if input == env.last_observed_input then return end
    env.last_observed_input = input
    local day = day_id()
    ensure_sample(env.average_sample, day, timestamp_ms, env.average_gap_ms,
        function() finish_average(env) end)
    -- 峰速窗口：与均速共用同一个「连续输入」间隙（env.peak_gap_ms == average_gap_ms），
    -- 累计满 env.peak_window_ms 才结算；不足的窗口作废——长停顿不稀释速度。
    ensure_sample(env.peak_sample, day, timestamp_ms,
        env.peak_gap_ms or PEAK_GAP_MS,
        function() finish_peak(env) end)
    env.average_sample.last_activity = timestamp_ms
    env.peak_sample.last_activity = timestamp_ms
end

local function commit_to_speed(env, day, timestamp_ms, characters, keystrokes)
    -- 会话内键数累计：击键速度分子与分母同一批会话（口径一致）
    env.average_sample.keystrokes = (env.average_sample.keystrokes or 0)
        + (keystrokes or 0)
    ensure_sample(env.average_sample, day, timestamp_ms, env.average_gap_ms,
        function() finish_average(env) end)
    ensure_sample(env.peak_sample, day, timestamp_ms,
        env.peak_gap_ms or PEAK_GAP_MS,
        function() finish_peak(env) end)
    local average, peak = env.average_sample, env.peak_sample
    average.last_activity = timestamp_ms
    average.last_commit = timestamp_ms
    average.characters = average.characters + characters
    peak.last_activity = timestamp_ms
    peak.last_commit = timestamp_ms
    peak.characters = peak.characters + characters
    local window_ms = env.peak_window_ms or PEAK_WINDOW_MS
    if peak.last_commit - peak.started >= window_ms then finish_peak(env) end
    env.last_observed_input = ""
end

local function is_valid_speed_commit(env, characters, code_length)
    if code_length <= 0 or characters > env.max_speed_commit_length then
        return false
    end

    return characters <= math.max(4, code_length * 2)
end

local function record_stats(env, characters, code_length, speed_code_length,
        code_len_without_space, is_auto_commit, backspaces)
    local timestamp_ms = monotonic_ms()
    local day = day_id()
    local prefix = DAY_PREFIX .. day .. "/"
    if not pending_add(env, prefix .. "text/characters", characters) then return end
    pending_add(env, prefix .. "text/commits", 1)
    pending_add(env, prefix .. "text/keystrokes", code_length)
    if backspaces and backspaces > 0 then
        pending_add(env, prefix .. "text/backspaces", backspaces)
    end
    if code_len_without_space and code_len_without_space > 0 then
        pending_add(env, prefix .. "text/code_len_without_space", code_len_without_space)
    end
    if is_auto_commit then pending_add(env, prefix .. "text/auto_commits", 1) end
    env.pending_characters = env.pending_characters + characters
    local field = characters == 1 and "commit_length/1"
        or characters == 2 and "commit_length/2"
        or characters == 3 and "commit_length/3"
        or characters == 4 and "commit_length/4"
        or "commit_length/5_plus"
    pending_add(env, prefix .. field, 1)
    if is_valid_speed_commit(env, characters, speed_code_length) then
        commit_to_speed(env, day, timestamp_ms, characters, speed_code_length)
    else
        finish_peak(env)
        finish_average(env)
        env.last_observed_input = ""
    end
end

local function in_day_range(day, start_day, end_day)
    return (not start_day or day >= start_day) and (not end_day or day <= end_day)
end

-- [0913] 峰速 = 当日所有窗口样本里的**最高**字/分。
--   抗噪不靠对结果做手脚，靠窗口本身：必须连续输入满 PEAK_WINDOW_MS 才结算一个样本，
--   短促爆发凑不满窗口就已经作废了。
--
--   沿革：上游 4.2 曾在这里写死"取次高"（样本 ≥2 时 rank 从 2 起算）且无注释，
--   害得峰速常年偏低、还会跟均速打架。中途试过"要求复现 = 取第 N 高（N=3）"，
--   用户实测后判定不必要，已回退到取最高。**不要再引入任何"跳过最高值"的逻辑。**
local function calculate_peak(peaks)
    local best
    for speed, count in pairs(peaks) do
        if count > 0 and (best == nil or speed > best) then
            best = speed
        end
    end
    return best
end

local function aggregate_statistics(env, start_day, end_day, device_id,
        speed_start_day, speed_end_day)
    speed_start_day = speed_start_day or start_day
    speed_end_day = speed_end_day or end_day
    local db = get_db(env)
    if not db or not db:loaded() then return nil end
    local stats, peaks = new_stats(), {}

    scan_prefix(db, STATISTICS_PREFIX, device_id,
        function(key, record_device, value)
        local day, field = key:match("^statistics/day/(%d%d%d%d%d%d%d%d)/(.+)$")
        if not day then return end
        if field == "text/characters" then
            stats.lifetime_characters = stats.lifetime_characters + value
        end

        if field == "text/keystrokes"
            and in_day_range(day, speed_start_day, speed_end_day)
        then
            stats.speed_keystrokes = stats.speed_keystrokes + value
        end

        local target = DAY_FIELDS[field]
        if target then
            if in_day_range(day, start_day, end_day) then
                stats[target] = stats[target] + value
            end
            return
        end

        if not in_day_range(day, speed_start_day, speed_end_day) then return end

        local average_field = field:match("^speed_average/([^/]+)$")
        if average_field == "characters" then
            stats.average_characters = stats.average_characters + value
        elseif average_field == "milliseconds" then
            stats.average_milliseconds = stats.average_milliseconds + value
        elseif average_field == "keystrokes" then
            stats.average_keystrokes = stats.average_keystrokes + value
        elseif average_field == "sessions" then
            stats.average_sessions = stats.average_sessions + value
        else
            -- 只认「当前窗口长度」对应的桶名，别的后缀（历史遗留/改过窗口的）一律不算，
            -- 否则不同窗口长度测出来的速度会被混进同一个峰速里比大小。
            local prefix = env.peak_key_prefix or peak_key_prefix(
                env.peak_window_ms or PEAK_WINDOW_MS)
            local speed = field:match("^" .. prefix .. "/(%d%d%d%d)$")
            if speed then
                speed = tonumber(speed)
                peaks[speed] = (peaks[speed] or 0) + value
            end
        end
    end)
    local day, characters, milliseconds, keystrokes = sample_values(
        env.average_sample, env.minimum_average_session_ms
    )
    if day and in_day_range(day, speed_start_day, speed_end_day)
        and (not device_id or device_id == env.device_id)
    then
        stats.average_characters = stats.average_characters + characters
        stats.average_milliseconds = stats.average_milliseconds + milliseconds
        stats.average_keystrokes = stats.average_keystrokes + (keystrokes or 0)
        stats.average_sessions = stats.average_sessions + 1
    end
    day, characters, milliseconds = sample_values(env.peak_sample,
        env.peak_window_ms or PEAK_WINDOW_MS)
    if day and in_day_range(day, speed_start_day, speed_end_day)
        and (not device_id or device_id == env.device_id)
    then
        local speed = peak_speed(characters, milliseconds)
        peaks[speed] = (peaks[speed] or 0) + 1
    end
    if stats.average_milliseconds < env.minimum_average_total_ms then
        stats.average_characters = 0
        stats.average_milliseconds = 0
        stats.average_keystrokes = 0
        stats.average_sessions = 0
        stats.speed_keystrokes = 0
    end
    stats.peak_speed = calculate_peak(peaks)
    return stats.commits > 0 and stats or nil
end

local function migrate_database(env)
    local db = get_db(env)
    if not db or not db:loaded() then return end
    local additions, old_keys = {}, {}
    scan_prefix(db, "d_", nil, function(key, device_id, value, raw_key)
        old_keys[#old_keys + 1] = raw_key
        local day, suffix = key:match("^d_(%d%d%d%d%d%d%d%d)(_.+)$")
        local target = day and LEGACY_FIELDS[suffix]
        if target and value > 0 and db_get(db, MIGRATION_KEY, device_id) == 0 then
            local device = additions[device_id] or {}
            additions[device_id] = device
            local new_key = DAY_PREFIX .. day .. "/" .. target
            device[new_key] = (device[new_key] or 0) + value
        end
    end)
    scan_prefix(db, "total_", nil, function(_, _, _, raw_key)
        old_keys[#old_keys + 1] = raw_key
    end)
    for device_id, values in pairs(additions) do
        local success = true
        for key, value in pairs(values) do
            if value > db_get(db, key, device_id)
                and not db_set(db, key, device_id, value)
            then
                success = false
                break
            end
        end
        if success then db_set(db, MIGRATION_KEY, device_id, 1) end
    end
    for _, raw_key in ipairs(old_keys) do db:erase(raw_key) end
    local obsolete = {}
    local current_peak_prefix = env.peak_key_prefix or peak_key_prefix(
        env.peak_window_ms or PEAK_WINDOW_MS)
    scan_prefix(db, STATISTICS_PREFIX, nil, function(key, _, _, raw_key)
        if key:match("^statistics/day/%d%d%d%d%d%d%d%d/speed/[^/]+$")
            or key:match("^statistics/day/%d%d%d%d%d%d%d%d/average_speed/[^/]+$")
            or key:match("^statistics/day/%d%d%d%d%d%d%d%d/peak_speed/[^/]+$")
            or key:match("^statistics/day/%d%d%d%d%d%d%d%d/speed_peak/")
            or key:match("^statistics/day/%d%d%d%d%d%d%d%d/speed_peak_window/")
            or key:match("^statistics/hour/") then
            obsolete[#obsolete + 1] = raw_key
        else
            -- [0913] 峰速桶用的是「窗口长度」当后缀：只保留与当前窗口一致的那一种。
            -- 这样改过 PEAK_WINDOW_MS 之后，旧后缀的样本会自动出局，
            -- 不会出现"10 秒窗口测的"和"15 秒窗口测的"被当成同一个峰速来比。
            local bucket = key:match(
                "^statistics/day/%d%d%d%d%d%d%d%d/(speed_peak_window_[^/]+)/")
            if bucket and bucket ~= current_peak_prefix then
                obsolete[#obsolete + 1] = raw_key
            end
        end
    end)
    for _, raw_key in ipairs(obsolete) do db:erase(raw_key) end
end

-- [0914] 已删除的死代码（随「文字皮肤」改造一并清掉，均无调用点）：
--   platform_info() / SOFTWARE_NAME（末行早已只留方案名，不再显示设备与前端）
--   ensure_titles() / user_title()（段位主题 =wkd 已取消；面板的境界改用 TEXT_SKINS[].realms）
--   draw_bar()（10 格旧版进度条）、speed_level() / SPEED_LEVELS / SPEED_CN（金山十级，0913 弃用）

-- [0913] 比例条（新版面板专用）：固定 6 格
local function draw_bar6(percent)
    local filled = math.floor(percent * 6 / 100 + 0.5)
    if filled < 0 then filled = 0 elseif filled > 6 then filled = 6 end
    return string.rep(BAR_FIELD, filled) .. string.rep(BAR_EMPTY, 6 - filled)
end

-- [0914] 打字境界：只看「峰速」，峰速每多 15 字/分 进一境（原本是 10，用户改为 15）。
--   阈值默认在文件顶部 REALM_THRESHOLDS（15/30/…/150）；皮肤可用 realm_thresholds 自带
--   阈值表覆盖（[0915] 合并 h~k 皮肤时新增，两表与自身 realms 同长即可，档数不限）。
--   名字与评语**按皮肤给**：TEXT_SKINS[i].realms[j] = { 第 j 档的境界名, 该档评语 }。
--   峰速不足最低一档（含峰速未出数 "--"）→ 该皮肤的 no_realm / no_realm_comment。
--   例：a 皮肤峰速 47 → 缀文境；峰速 140 → 化文境。
-- ⚠️ 阈值只改 REALM_THRESHOLDS / skin.realm_thresholds；境界名/评语只改 TEXT_SKINS[].realms。
-- 返回：境界名 + 该境界的评语（峰速为 nil / 不足最低一境 → 未入道）
local function realm_of(peak, skin)
    local realms = (skin and skin.realms) or TEXT_SKINS[1].realms
    local thresholds = (skin and skin.realm_thresholds) or REALM_THRESHOLDS
    local no_name = (skin and skin.no_realm) or TEXT_SKINS[1].no_realm
    local no_comment = (skin and skin.no_realm_comment) or TEXT_SKINS[1].no_realm_comment
    if not peak or peak < thresholds[1] then
        return no_name, no_comment
    end
    for i = #thresholds, 1, -1 do
        if peak >= thresholds[i] then
            local item = realms[i]
            if item then return item[1], item[2] end
            return no_name, no_comment
        end
    end
    return no_name, no_comment
end

-- 数值右对齐到 width 个半角宽（"　"=2、" "=1）。
-- 面板前四行是「标签 + 定宽数值 ｜ 标签 + 定宽数值」的 2×2 格子，
-- 数值必须右对齐，两行的 ｜ 才会上下对齐：
--   均速　　24　｜　峰速　　47      ← "24" 补成 6 宽 → "　　24"
--   上屏　2145　｜　字数　3033      ← "2145" 补成 6 宽 → "　2145"
local function pad_val(s, width)
    local w = 0
    local i = 1
    while i <= #s do
        local b = s:byte(i)
        if b < 128 then w = w + 1; i = i + 1
        else
            local l = 1
            if b >= 240 then l = 4 elseif b >= 224 then l = 3 elseif b >= 192 then l = 2 end
            w = w + 2; i = i + l
        end
    end
    local out = s
    while w + 2 <= width do out = "　" .. out; w = w + 2 end
    if w < width then out = " " .. out end
    return out
end

local function format_summary(title, subtitle, data, env)
    if not data or data.commits == 0 then return "※ " .. title .. "暂无数据" end
    -- [0913] 旧版这里的「◉ 键数：累计 N 键」行已随面板改版去掉
    --（新版版式固定，不显示累计键数；数据仍在库里，只是不上面板）
    local average_code = data.characters > 0 and data.keystrokes / data.characters or 0
    -- 击键速度 = 会话键数 ÷ 会话时长（分子分母同一批会话，口径一致）
    -- 旧数据兼容：升级前的库无 speed_average/keystrokes 字段 → 回退旧口径
    local session_keys = data.average_keystrokes or 0
    if session_keys <= 0 then
        session_keys = data.speed_keystrokes or 0
    end
    local kps = data.average_milliseconds > 0
        and session_keys * 1000 / data.average_milliseconds or nil
    local kps_str = kps and string.format("%.2f", kps) or "--"
    -- [0812] 空格上屏次数 = 上屏总次数 − 自动顶屏次数（与四码上屏互补，合计≈100%）
    local space_commits = data.commits - (data.auto_commits or 0)
    if space_commits < 0 then space_commits = 0 end
    local space_ratio = data.commits > 0 and 100 * space_commits / data.commits or 0
    local auto_commits = data.auto_commits or 0
    local auto_ratio = data.commits > 0 and 100 * auto_commits / data.commits or 0
    local average_speed = data.average_milliseconds > 0
        and math.floor(data.average_characters * 60000
            / data.average_milliseconds + 0.5) or nil
    -- [0913] 峰速为 0 说明那个窗口里一个字都没打（等同未出数）→ 统一显示 "--"，
    -- 也让第 2 行的境界落到「未入道」，不会出现「峰速 0 却是某境」的怪组合。
    -- [0913] 峰速只做「有没有数据」这一道校验，不再做「低于均速就隐藏」的相对判断。
    --   峰速 = 最快的那一段连续输入，均速 = 全部会话的加权平均；段短但快（打完一句就停手）
    --   时 peak < average 是**完全正常**的。旧守卫把这种正常情况当成异常藏掉，
    --   叠加上「取次高」就出现了"桶里明明有 136，面板却显示 --"。
    local peak_speed = data.peak_speed
    if not peak_speed or peak_speed <= 0 then peak_speed = nil end
    -- [0913] 单字/词组占比改用「字数」口径（单字次数 × 1 字）
    local chars_n = data.characters or 0
    local single_n = data.length_1 or 0
    local single_pct = chars_n > 0 and (100 * single_n / chars_n) or 0
    local word_pct = 100 - single_pct

    -- [0913] 境界 + 评语：只看峰速（峰速未出数 / 不足最低一境 → 该皮肤的未入道条目）
    local skin = (env and env.text_skin) or TEXT_SKINS[1]
    local realm_name, realm_comment = realm_of(peak_speed, skin)
    local zwsp = "\226\128\139"

    -- [0914] 用户指定版式（第 8 版）：标题带「总修炼」累计字数；时段与境界**合并成一行**
    --   「【xx】修炼数据 → <境界名>」（第 7 版是「【xx】修炼数据」+「已步入 → <境界名>」两行，
    --   用户 0914 修订稿把境界并进时段行，物理行 14 → 13）。
    --   N = 累计上屏字数（data.lifetime_characters，不受区间限制的全量累计）。
    --   例外：subtitle 非空的 =jq / =wx 仍把设备号 / 日期接在该行行尾，否则查了哪天根本看不出来。
    local xx = title
    local lifetime = math.floor(data.lifetime_characters or 0)
    local day_tail = ""
    if subtitle and subtitle ~= "" then day_tail = " · " .. subtitle end

    -- [0914] 面板版式（第 8 版）：**5 组、9 个内容行 + 4 个空行 = 13 物理行**。
    --   组1 标题（<皮肤标题> N 字） / 组2 【xx】<皮肤时段词> → 境界 + 评语 /
    --   组3 均速峰速 + 上屏字数 + <皮肤码长标签> + <皮肤顶功标签> / 组4 比例 / 组5 方案名；
    --   组间空一行（空行只放零宽空格，防止被候选窗折叠）。
    --   ⚠️ 沿革：第 3 版 6 组 / 5 空行 → 第 4 版全去掉空行（用户反馈"太紧凑了"）
    --   → 第 5 版 5 组 / 4 空行 → 第 6 版沿用 5 组 / 4 空行（标题带【时段】、境界行带累计字数）
    --   → 第 7 版 5 组 / 4 空行：累计字数挪到标题、时段独立成行、境界行改「已步入 →」（14 物理行）
    --   → 第 8 版：境界并入时段行「【xx】修炼数据 → <境界名>」，14 → 13 物理行。
    --   → 第 9 版（0914）：文案改由「文字皮肤」给（TEXT_SKINS），行序与空行位置**未动**。
    --   ⚠️ 第 3 版起：评语由「均速/上屏之后」提到「境界之后」（按用户交付稿的行序）。
    local groups = {
        {
            skin.icon .. " " .. skin.title_name .. "·" .. skin.title_metric .. lifetime .. "字",
        },
        {
            "【" .. xx .. "】" .. skin.period_word .. " → " .. realm_name .. day_tail,
            -- 用户指定：评语行的分隔符是「｜」（不是 心法/功法 那样的全角空格），
            -- 且不带 📜 图标；未入道的评语本身也含一个 ｜。
            "评语｜" .. realm_comment,
        },
        {
            -- 左列值补到 6 个半角宽，"　｜　" 分隔，两行的 ｜ 才会对齐
            "均速" .. pad_val(average_speed and tostring(average_speed) or "--", 6)
                .. "　｜　峰速"
                .. pad_val(peak_speed and tostring(peak_speed) or "--", 6),
            "上屏" .. pad_val(tostring(math.floor(data.commits)), 6)
                .. "　｜　字数"
                .. pad_val(tostring(math.floor(data.characters)), 6),
            skin.code_label .. "　码长 " .. string.format("%.2f", average_code)
                .. " · 击键 " .. kps_str .. "/s",
            -- [0913] 「空格 / 顶屏」改口径名「非顶 / 顶功」：
            --   非顶 = 按空格或数字选字上屏（原「空格」），顶功 = 被下一个编码键顶上去
            -- [0914] 标签（心法 / 功法）由皮肤给，口径名不变。
            string.format(skin.mode_label .. "　非顶 %d%% · 顶功 %d%%",
                math.floor(space_ratio + 0.5), math.floor(auto_ratio + 0.5)),
        },
        {
            string.format("比例　单 %d %% %s %d %% 词",
                math.floor(single_pct + 0.5), draw_bar6(single_pct),
                math.floor(word_pct + 0.5)),
        },
        {
            -- [0913] 用户要求去掉设备/前端，末行只留方案名
            "—  " .. env.schema_name .. " —",
        },
    }
    -- 组间插空行；每行行尾补零宽空格（沿用旧面板习惯，防止候选窗把行长当换行处理）。
    -- 面板首字符是皮肤图标（默认 📖）；on_commit 的「机器文本」识别串必须含它。
    local out = {}
    for gi = 1, #groups do
        if gi > 1 then out[#out + 1] = zwsp end     -- 组间空行（只有零宽空格，不显示字符）
        for li = 1, #groups[gi] do
            out[#out + 1] = groups[gi][li] .. zwsp
        end
    end
    return table.concat(out, "\n")
end

local function yield_msg(seg, text, icon)
    yield(Candidate("stat", seg.start, seg._end, text, icon or "🕰️"))
end

local function prepare_report(env)
    finish_stale(env, monotonic_ms())
    flush_pending(env)
end

-- 指令一律以 "=" 触发（键道6 的 "o" 已被 recognizer/patterns/xmjd6gbk 占用为五笔画查询，
-- 4.2 那套 o + 去斜杠 的别名机制在本方案会把 ortj 抢成 O 模式查询，已整体删除）
local function standard_report(input, env)
    -- 所有统计指令均以 = 开头（=tj/=qb/=yf/=yy/=yn/=jq/=wx…）。
    -- 普通打字直接短路返回，避免每个输入码都白跑 day_id/os.time。
    if type(input) ~= "string" or input:sub(1, 1) ~= "=" then return nil end
    local today = day_id()
    -- 「30天」窗口：固定 30 天，**与速度统计窗口无关**。
    -- 原先这里和下面共用同一个 recent，是个耦合错误：一旦把 speed_history_days 调成 0（不限），
    -- =yy 的 start_day 也会变成 nil，30天面板会跟着塌成"全部"。
    local month_start = day_id(os.time() - 29 * 86400)
    -- 速度统计窗口：只作用于「均速 / 峰速 / 击键」的聚合范围。
    -- speed_history_days <= 0 → speed_start = nil → aggregate_statistics 不限下限，从最早一天算起。
    local speed_start = nil
    if (env.speed_history_days or 0) > 0 then
        speed_start = day_id(os.time() - (env.speed_history_days - 1) * 86400)
    end

    if input == env.triggers.local_total then
        return "本设备", "设备 " .. env.device_id, nil, nil, env.device_id,
            speed_start, today
    elseif input == env.triggers.today then
        return "今日", "", today, today, nil, today, today
    elseif input == env.triggers.week then
        local start_day = day_id(os.time() - 6 * 86400)
        return "7天", "", start_day, today, nil, start_day, today
    elseif input == env.triggers.month then
        return "30天", "", month_start, today, nil, month_start, today
    elseif input == env.triggers.year then
        local start_day = day_id(os.time() - 364 * 86400)
        return "365天", "", start_day, today, nil, start_day, today
    elseif input == env.triggers.total then
        return "全部", "", nil, nil, nil, speed_start, today
    end
end

local function history_report(input, env)
    local trigger = env.triggers.history
    if input:sub(1, #trigger) ~= trigger then return nil end
    local query = input:sub(#trigger + 1)
    if query == "" then
        return false, "※ 请输入日期或区间（例 " .. trigger .. "2026、" ..
            trigger .. "202601、" .. trigger .. "20260101t20260201）", "⌨️"
    end
    local sy, sm, sd, ey, em, ed =
        query:match("^(%d%d%d%d)(%d%d)(%d%d)t(%d%d%d%d)(%d%d)(%d%d)$")
    if sy then
        prepare_report(env)
        return aggregate_statistics(env, sy .. sm .. sd, ey .. em .. ed),
            "区间", string.format("%s.%s.%s - %s.%s.%s", sy, sm, sd, ey, em, ed),
            "※ 该区间内没有留下打字记录哦"
    end
    local y, m, d = query:match("^(%d%d%d%d)(%d%d)(%d%d)$")
    if y then
        prepare_report(env)
        local day = y .. m .. d
        return aggregate_statistics(env, day, day), "当日",
            string.format("%s.%s.%s", y, m, d), "※ 这一天没有留下打字记录哦"
    end
    y, m = query:match("^(%d%d%d%d)(%d%d)$")
    if y then
        prepare_report(env)
        return aggregate_statistics(env, y .. m .. "01", y .. m .. "31"),
            "当月", string.format("%s年%s月", y, m), "※ 该月没有留下打字记录哦"
    end
    y = query:match("^(%d%d%d%d)$")
    if y then
        prepare_report(env)
        return aggregate_statistics(env, y .. "0101", y .. "1231"),
            "当年", string.format("%s年", y), "※ 该年没有留下打字记录哦"
    end
    return false, query:find("t", 1, true) and "※ 正在输入区间查询..."
        or "※ 正在查询中... 请继续输入完整的年/月/日", "⏳"
end

local function on_commit(context, env)
    -- [增强] 先取走真实击键数（含空格/数字选字/退格等），无论是否统计都清零防残留
    -- take() 返回 (总键数, 退格数)；退格数用于平均键准统计
    local real_keystrokes, backspaces, last_type = nil, 0, nil
    if ok_key_counter then
        local a, b, c = key_counter.take()
        real_keystrokes = a or 0
        backspaces = b or 0
        last_type = c
    end
    local text = context:get_commit_text()
    -- 当前编码串：上屏瞬间还带着 "=" 前缀 = 这是工具类提交（=123→壹佰贰拾叁、
    -- =1+1→3、=uuid…），不是在打字，一律不记账。
    local raw_input = context.input or ""
    if not text or text == "" or text:sub(1, 1) == "="
        or raw_input:sub(1, 1) == "="
        or is_machine_text(text) then
        -- 指令/面板文本上屏：清空待取击键防残留（take 已取走，这里双保险）
        if ok_key_counter and key_counter.reset then key_counter.reset() end
        return
    end
    local characters = chinese_length(text)
    if characters == 0 then return end
    local code = raw_input
    if code == "" then code = env.last_observed_input or "" end
    local code_length = #code
    -- 不含空格的编码长度（空格上屏计算的基础）
    local code_len_without_space = code_length
    -- ══════════════════════════════════════
    -- 顶屏判定
    --
    -- TOPUP_MODE（键道6 / 变长顶功）：不看固定码长，只看「本次上屏的末键类型」。
    --   topup/topup_with: "avuio;"  min_length: 4  min_length_danzi: 2
    --   → 2 码简码、4 码单字、5~6 码全码都可能被下一个编码键顶上去，
    --     根本不存在"第 N 码直接顶屏"这回事，所以固定码长模型必须废掉。
    --
    --   末键 = "1"（编码键）→ 被下一个字的编码键顶上（顶功上屏，全程没按空格）。
    --       最后那 1 键是下一个字的第一个码，必须还回去，本次码长要减 1。
    --   末键 = "4"（选字/提交键）→ 空格 / 数字 / 回车 / [] 主动上屏（非顶功）。
    --
    -- 非 TOPUP_MODE：保留「码长击键计数器 4.2」的「真实击键数 vs 固定顶屏码数」模型。
    -- ══════════════════════════════════════
    local is_auto_commit
    if real_keystrokes and real_keystrokes > 0 then
        local raw = real_keystrokes          -- 本次上屏的原始真实击键数
        if TOPUP_MODE then
            if last_type == "1" and raw >= 2 then
                is_auto_commit = true                       -- 顶功上屏
                if ok_key_counter and key_counter.restore_last then
                    key_counter.restore_last()              -- 最后 1 键还给下一个字
                end
                code_length = raw - 1
                code_len_without_space = raw - 1
            else
                is_auto_commit = false                      -- 空格 / 数字选字上屏
                code_length = raw                           -- 含那个上屏键
                code_len_without_space = raw > 1 and (raw - 1) or raw
            end
        else
            -- 4.2 原模型：diff = real - 顶屏码数（默认4）
            --   0  且末键是编码键 → 纯顶屏
            --   1  且末键是编码键 → 次选顶屏（含下一字首码）/顶屏时序
            --   2  且末键是编码键 → 桌面 repeat/时序宽容（多余键丢弃）
            --   末键是选字键(4)   → 空格/数字选字上屏（非顶屏）
            local ac = env.auto_commit_code_len or 0
            if ac > 0 then
                local diff = raw - ac
                if diff == 0 and last_type == "1" then
                    is_auto_commit = true
                elseif diff == 1 and last_type == "1" then
                    is_auto_commit = true
                    if ok_key_counter and key_counter.restore_last then
                        key_counter.restore_last()
                    end
                    raw = ac
                elseif diff == 2 and last_type == "1" then
                    is_auto_commit = true
                    if ok_key_counter and key_counter.reset then key_counter.reset() end
                    raw = ac
                else
                    is_auto_commit = false
                end
            end
            code_length = raw
        end
    else
        -- 无计数器回退：码长命中顶屏码数即视为顶屏
        is_auto_commit = (env.auto_commit_code_len or 0) > 0
            and code_len_without_space == env.auto_commit_code_len
        -- 无击键器时回退码长统计：非顶屏上屏补 1 键（空格键）；顶屏不加（少计一键）
        if not is_auto_commit then code_length = code_length + 1 end
    end
    record_stats(env, characters,
        code_length > 0 and code_length or characters * 2, code_length,
        code_len_without_space, is_auto_commit, backspaces)
    try_flush(env)
end

local function bounded_int(config, key, default, minimum, maximum)
    return math.max(minimum, math.min(maximum, config:get_int(key) or default))
end

-- [0813] 兜底初始化：部分桌面 Rime（小狼毫等）的 librime-lua 可能不调用 translator 的
-- init，导致 auto_commit_code_len/triggers 等缺失：顶屏判定恒为"空格上屏"，
-- =tj 等指令也不识别（指令键残留进码长）。
-- ensure_env 幂等：translator 首次运行时补齐全部关键配置；init 也调用它。
-- [0813] 配置读取：空串视为未配置（部分 Rime 发行版 get_string 返回 "" 而非 nil）
local function cfg_str(config, key, default)
    local v = config:get_string(key)
    if v == nil or v == "" then return default end
    return v
end

local function ensure_env(env)
    -- 逐字段补全（幂等）：init 已设的字段不动，缺失的补齐——比整体跳过更健壮
    if not env.engine or not env.engine.schema then return end
    local config = env.engine.schema.config
    if env.schema_name == nil then
        -- [0913] 面板末行要的是「方案显示名」（custom 里的 schema/name，如 🌟🐈），
        -- 不是 schema_id（xmjd6）。取不到再退回 schema_id，最后兜底。
        env.schema_name = cfg_str(config, "schema/name", nil)
            or env.engine.schema.schema_name
            or "星猫键道6"
    end
    if env.stats_db_name == nil then
        env.stats_db_name = config:get_string("input_stats/db_name") or "stats"
        if env.stats_db_name == "" then env.stats_db_name = "stats" end
    end
    if env.device_id == nil then env.device_id = get_device_id(config) end
    if env.continuous_gap_ms == nil then
        env.continuous_gap_ms = bounded_int(config, "input_stats/continuous_gap_ms",
            CONTINUOUS_GAP_MS, 200, 5000)
    end
    if env.average_gap_ms == nil then
        env.average_gap_ms = bounded_int(config, "input_stats/average_gap_ms",
            AVERAGE_GAP_MS, env.continuous_gap_ms, 30000)
    end
    if env.minimum_average_session_ms == nil then
        env.minimum_average_session_ms = bounded_int(config,
            "input_stats/minimum_average_session_ms",
            MINIMUM_AVERAGE_SESSION_MS, 500, 10000)
    end
    if env.minimum_average_total_ms == nil then
        env.minimum_average_total_ms = bounded_int(config,
            "input_stats/minimum_average_total_ms",
            MINIMUM_AVERAGE_TOTAL_MS, 3000, 120000)
    end
    if env.max_speed_commit_length == nil then
        env.max_speed_commit_length = bounded_int(config,
            "input_stats/max_speed_commit_length",
            MAX_SPEED_COMMIT_LENGTH, 1, 10)
    end
    -- [0718] 顶屏码数：脚本顶部 AUTO_COMMIT_CODE_LEN（默认4），schema 可覆盖
    if env.auto_commit_code_len == nil then
        env.auto_commit_code_len = config:get_int("input_stats/code_len_of_auto_commit")
            or AUTO_COMMIT_CODE_LEN
    end
    if env.speed_history_days == nil then
        -- 0 = 不限（用全部历史）；它只决定「统计多少天」，不删除任何记录。
        env.speed_history_days = bounded_int(config,
            "input_stats/speed_history_days", SPEED_HISTORY_DAYS, 0, 3650)
    end
    -- [0913] 峰速窗口长度/切断间隙：原先写死在 lua 里、schema 改不动，现开放。
    if env.peak_window_ms == nil then
        env.peak_window_ms = bounded_int(config, "input_stats/peak_window_ms",
            PEAK_WINDOW_MS, 3000, 60000)
    end
    if env.peak_gap_ms == nil then
        env.peak_gap_ms = bounded_int(config, "input_stats/peak_gap_ms",
            PEAK_GAP_MS, 1000, 30000)
    end
    if env.peak_key_prefix == nil then
        env.peak_key_prefix = peak_key_prefix(env.peak_window_ms)
    end
    -- 以下仅在首次初始化时执行（避免每键重置速度窗口/flush 计时）
    if not env.initialized then
        env.pending_stats = env.pending_stats or {}
        env.pending_characters = env.pending_characters or 0
        env.stats_db_error = nil
        env.last_flush_ts = os.time()
        if env.last_observed_input == nil then env.last_observed_input = "" end
        if not env.average_sample then env.average_sample = {} end
        if not env.peak_sample then env.peak_sample = {} end
        reset_sample(env.average_sample)
        reset_sample(env.peak_sample)
        env.initialized = true
    end
    -- ── 面板指令：一律 "=" 触发（key_binder / punctuator / recognizer 均已放行 "="）
    -- =tj 今日   =qb 全部   =yf 7天   =yy 30天   =yn 365天   =jq 本设备
    -- =wx 查某天（=wx20260801 / =wx202608 / =wx2026 / =wx20260101t20260201）
    -- =wk 查看段位与皮肤   =wkd[a~b] 切段位   =wkp[a~h] 切皮肤
    if env.triggers == nil then
        env.triggers = {
            today=cfg_str(config, "input_stats/triggers/today", "=tj"),
            total=cfg_str(config, "input_stats/triggers/total", "=qb"),
            week=cfg_str(config, "input_stats/triggers/week", "=yf"),
            month=cfg_str(config, "input_stats/triggers/month", "=yy"),
            year=cfg_str(config, "input_stats/triggers/year", "=yn"),
            local_total=cfg_str(config, "input_stats/triggers/local_total", "=jq"),
            history=cfg_str(config, "input_stats/triggers/history", "=wx"),
        }
    end
    -- 上屏回调注册（幂等）：key_counter 的 processor 侧负责转接 commit_notifier，
    -- 这里只把「on_commit + translator 的 env」交给它。translator 的 env 与 processor
    -- 的 env 不是同一张表，所以必须走这套转接，不能各挂各的通知（会同一次上屏通知两遍）。
    if ok_key_counter and key_counter.set_commit_handler and not env._kc_bound then
        env._kc_bound = true
        key_counter.set_commit_handler(function(context) on_commit(context, env) end)
    end
    -- 文字皮肤：状态文件 lua/text_skin.txt 存一个字母（=wk+字母 切换，重部署后回默认）。
    if env.text_skin == nil then
        local saved = read_text_file(user_data_dir() .. TEXT_SKIN_FILE)
        local letter = saved and saved:match("^%s*(%a)%s*$") or DEFAULT_TEXT_SKIN
        env.text_skin = skin_by_letter(letter) or skin_by_letter(DEFAULT_TEXT_SKIN)
            or TEXT_SKINS[1]
    end
end

local function init(env)
    ensure_env(env)
    if acquire_db(env) then migrate_database(env) end
    -- 上屏通知的挂载点：优先由 key_counter 的 processor 侧转接（见 key_counter.M.init）。
    -- 只有在 key_counter 不可用（未挂载 processor）时，才由 translator 自己连一条，
    -- 否则同一次上屏会收到两次通知 → 计数翻倍。
    if ok_key_counter and key_counter.set_commit_handler then
        if env.stat_notifier then
            env.stat_notifier:disconnect()
            env.stat_notifier = nil
        end
    else
        if env.stat_notifier then env.stat_notifier:disconnect() end
        env.stat_notifier = env.engine.context.commit_notifier:connect(
            function(context) on_commit(context, env) end
        )
    end
end

local function fini(env)
    finish_peak(env)
    finish_average(env)
    flush_pending(env)
    env.last_observed_input = ""
    if env.stat_notifier then
        env.stat_notifier:disconnect()
        env.stat_notifier = nil
    end
    env.pending_stats = nil
    env.average_sample, env.peak_sample = nil, nil
    release_db(env)
end

-- ===== 文字皮肤切换指令（全部以 "=" 触发）=====
--   =wk            查看当前文字皮肤，并列出全部可选编号
--   =wk + 字母     切换：a = 第 1 款、b = 第 2 款 …（顺序即 TEXT_SKINS 数组顺序）
-- 旧的两条指令 =wkd（段位）/ =wkp（进度条皮肤）已删除：
--   现在 "=wk" 后面跟的字母就是皮肤编号，所以 =wkd 会切到第 4 款（字母 d），不再是段位指令；
--   =wkp 因 p 不在可用皮肤字母内 → 回一句"无此皮肤编号"。
-- 为什么用字母而不是数字：数字会与「数字键转大写」和 selector 选字打架。
local function text_skin_command(input, env)
    if input == "=wk" then
        -- 面板统一以 "※" 开头：on_commit 靠它识别"这是机器生成的文本"，
        -- 即使被误上屏也直接丢弃，不会记成一次真实上屏。
        local cur = (env.text_skin and env.text_skin.letter) or DEFAULT_TEXT_SKIN
        local cur_label = (skin_by_letter(cur) or {}).label or ""
        local parts = {}
        for _, s in ipairs(TEXT_SKINS) do
            parts[#parts + 1] = string.format("%s %s%s",
                s.letter, s.label, (s.letter == cur) and "◀" or "")
        end
        local lines = { "※ 文字皮肤（=wk+字母）：当前 → " .. cur .. " " .. cur_label }
        for i = 1, #parts, 3 do
            local chunk = {}
            for j = i, math.min(i + 2, #parts) do
                chunk[#chunk + 1] = parts[j]
            end
            lines[#lines + 1] = "   " .. table.concat(chunk, "　")
        end
        return table.concat(lines, "\n")
    end
    local letter = input:match("^=wk([a-z])$")
    if letter then
        local skin = skin_by_letter(letter)
        if not skin then
            return "※ 无此皮肤编号，输入 =wk 查看全部可用编号"
        end
        env.text_skin = skin
        write_text_file(user_data_dir() .. TEXT_SKIN_FILE, skin.letter)
        return "※ 已切换文字皮肤：" .. skin.letter .. " " .. skin.label
    end
    return nil
end

local function translator(input, seg, env)
    ensure_env(env)
    observe_input_activity(env, input)
    -- 文字皮肤指令优先处理
    local skin_msg = text_skin_command(input, env)
    if skin_msg then
        if ok_key_counter and key_counter.reset then key_counter.reset() end
        return yield_msg(seg, skin_msg, "🎨")
    end
    -- 指令输入的按键清理已下沉到 key_counter 的 processor 里（它能拿到"还没进输入串"的
    -- 那一下按键，比 translator 更早、覆盖更全），这里不再逐键 reset，
    -- 免得把 =wx 数字守卫刚推进输入串的数字又清掉。
    local title, subtitle, start_day, end_day, device_id,
        speed_start_day, speed_end_day = standard_report(input, env)
    local data
    if title then
        prepare_report(env)
        data = aggregate_statistics(env, start_day, end_day, device_id,
            speed_start_day, speed_end_day)
        if not data and env.stats_db_error then
            return yield_msg(seg,
                "※ 统计数据库打开失败", "⚠️")
        end
    else
        try_flush(env)
        local history, first, second, empty_message = history_report(input, env)
        if history == false then return yield_msg(seg, first, second) end
        -- 注意：history_report 用返回值的个数区分两种情况——
        --   不是历史查询 → 只返回 nil（empty_message 也是 nil）→ 什么都不显示
        --   是历史查询但没数据 → 返回 nil, 标题, 副标题, 空提示 → 要显示空提示
        -- 只看 history == nil 会把第二种情况误当第一种，导致「该日没有记录」永远不显示。
        if history == nil and empty_message == nil then return end
        if not history and env.stats_db_error then
            return yield_msg(seg,
                "※ 统计数据库打开失败", "⚠️")
        end
        if not history then return yield_msg(seg, empty_message) end
        data, title, subtitle = history, first, second
    end
    -- 指令面板显示时清空待取击键：确认当前输入是 = 指令并出了面板，
    -- 就把这一串指令键整体作废，绝不残留进下一次真实上屏的码长。
    if ok_key_counter and key_counter.reset then key_counter.reset() end
    yield(Candidate("stat", seg.start, seg._end,
        format_summary(title, subtitle, data, env), "📖"))
end

-- text_skins / realm_of 也导出：给冒烟测试逐款核对皮肤表与境界映射用（生产代码不读它们）
return {init=init, func=translator, fini=fini,
    text_skins=TEXT_SKINS, realm_of=realm_of, realm_thresholds=REALM_THRESHOLDS}