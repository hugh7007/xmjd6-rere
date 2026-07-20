-- Numeric formatting and explicit conversion helpers for xmjd6.

local M = {}

local UPPER_DIGITS = { [0] = "零", "壹", "贰", "叁", "肆", "伍", "陆", "柒", "捌", "玖" }
local LOWER_DIGITS = { [0] = "零", "一", "二", "三", "四", "五", "六", "七", "八", "九" }
local UPPER_SMALL = { [0] = "", "拾", "佰", "仟" }
local LOWER_SMALL = { [0] = "", "十", "百", "千" }
local GROUP_UNITS = { [0] = "", "万", "亿", "兆", "京" }

local function parse_decimal(value)
    if type(value) ~= "string" then
        return nil
    end
    local sign, integer, fraction = value:match("^([+-]?)(%d+)%.?(%d*)$")
    if not integer then
        return nil
    end
    integer = integer:gsub("^0+", "")
    if integer == "" then integer = "0" end
    return sign == "-", integer, fraction or ""
end

local function increment_decimal_string(integer)
    local out = {}
    local carry = 1
    for i = #integer, 1, -1 do
        local digit = tonumber(integer:sub(i, i)) + carry
        if digit >= 10 then
            digit = digit - 10
            carry = 1
        else
            carry = 0
        end
        out[#out + 1] = tostring(digit)
    end
    if carry == 1 then
        out[#out + 1] = "1"
    end
    local result = {}
    for i = #out, 1, -1 do
        result[#result + 1] = out[i]
    end
    return table.concat(result)
end

local function read_integer(integer, digit_names, small_units, omit_leading_one)
    integer = integer:gsub("^0+", "")
    if integer == "" then
        return digit_names[0]
    end

    local out = {}
    local zero_pending = false
    for i = 1, #integer do
        local digit = tonumber(integer:sub(i, i))
        local position = #integer - i
        if digit == 0 then
            if #out > 0 then
                zero_pending = true
            end
        else
            if zero_pending then
                out[#out + 1] = digit_names[0]
                zero_pending = false
            end
            local group_index = math.floor(position / 4)
            local unit = small_units[position % 4] .. (GROUP_UNITS[group_index] or ("10^" .. tostring(group_index * 4)))
            out[#out + 1] = digit_names[digit] .. unit
        end
    end

    local result = table.concat(out)
    if omit_leading_one then
        result = result:gsub("^一十", "十")
    end
    return result
end

function M.rmb_upper(value)
    local negative, integer, fraction = parse_decimal(value)
    if negative == nil then return nil end

    local jiao = tonumber(fraction:sub(1, 1)) or 0
    local fen = tonumber(fraction:sub(2, 2)) or 0
    local third = tonumber(fraction:sub(3, 3)) or 0
    if third >= 5 then
        fen = fen + 1
        if fen >= 10 then
            fen = 0
            jiao = jiao + 1
            if jiao >= 10 then
                jiao = 0
                integer = increment_decimal_string(integer)
            end
        end
    end

    local is_zero = integer == "0" and jiao == 0 and fen == 0
    local out = {}
    if negative and not is_zero then
        out[#out + 1] = "负"
    end

    if integer ~= "0" then
        out[#out + 1] = read_integer(integer, UPPER_DIGITS, UPPER_SMALL, false)
        out[#out + 1] = "元"
    elseif jiao == 0 and fen == 0 then
        out[#out + 1] = "零元"
    end

    if jiao > 0 then
        out[#out + 1] = UPPER_DIGITS[jiao] .. "角"
    end
    if fen > 0 then
        if integer ~= "0" and jiao == 0 then
            out[#out + 1] = "零"
        end
        out[#out + 1] = UPPER_DIGITS[fen] .. "分"
    end
    if jiao == 0 and fen == 0 then
        out[#out + 1] = "整"
    end

    return table.concat(out)
end

function M.number_lower(value)
    local negative, integer, fraction = parse_decimal(value)
    if negative == nil then return nil end
    local out = {}
    local all_zero = integer == "0" and not fraction:find("[1-9]")
    if negative and not all_zero then
        out[#out + 1] = "负"
    end
    out[#out + 1] = read_integer(integer, LOWER_DIGITS, LOWER_SMALL, true)
    if fraction ~= "" then
        out[#out + 1] = "点"
        for i = 1, #fraction do
            out[#out + 1] = LOWER_DIGITS[tonumber(fraction:sub(i, i))]
        end
    end
    return table.concat(out)
end

function M.add_grouping(value)
    local negative, integer, fraction = parse_decimal(value)
    if negative == nil then return nil end
    local groups = {}
    while #integer > 3 do
        table.insert(groups, 1, integer:sub(-3))
        integer = integer:sub(1, -4)
    end
    table.insert(groups, 1, integer)
    local result = table.concat(groups, ",")
    if fraction ~= "" then
        result = result .. "." .. fraction
    end
    if negative and result ~= "0" then
        result = "-" .. result
    end
    return result
end

local DIGITS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local MAX_SAFE_INTEGER = 9007199254740991

local function digit_value(ch)
    ch = string.upper(ch)
    local position = DIGITS:find(ch, 1, true)
    return position and (position - 1) or nil
end

function M.convert_base(value, from_base, to_base)
    from_base = tonumber(from_base)
    to_base = tonumber(to_base)
    if not from_base or not to_base or from_base < 2 or from_base > 36 or to_base < 2 or to_base > 36 then
        return nil
    end
    from_base = math.floor(from_base)
    to_base = math.floor(to_base)
    if type(value) ~= "string" or value == "" then
        return nil
    end

    local negative = value:sub(1, 1) == "-"
    if negative or value:sub(1, 1) == "+" then
        value = value:sub(2)
    end
    if value == "" then return nil end

    local number = 0
    for i = 1, #value do
        local digit = digit_value(value:sub(i, i))
        if digit == nil or digit >= from_base then
            return nil
        end
        number = number * from_base + digit
        if number > MAX_SAFE_INTEGER then
            return nil
        end
    end

    if number == 0 then return "0" end
    local out = {}
    while number > 0 do
        local remainder = number % to_base
        out[#out + 1] = DIGITS:sub(remainder + 1, remainder + 1)
        number = math.floor(number / to_base)
    end
    local result = {}
    for i = #out, 1, -1 do
        result[#result + 1] = out[i]
    end
    local text = table.concat(result)
    return negative and ("-" .. text) or text
end

local UNIT_FAMILIES = {
    length = {
        mm = 0.001,
        cm = 0.01,
        m = 1,
        km = 1000,
        ["in"] = 0.0254,
        ft = 0.3048,
        yd = 0.9144,
        mi = 1609.344,
    },
    mass = {
        mg = 0.000001,
        g = 0.001,
        kg = 1,
        oz = 0.028349523125,
        lb = 0.45359237,
    },
    data = {
        b = 1,
        kb = 1024,
        mb = 1024 ^ 2,
        gb = 1024 ^ 3,
        tb = 1024 ^ 4,
    },
}

local function format_number(number)
    if number == 0 then return "0" end
    local text = string.format("%.10g", number)
    text = text:gsub("e%+", "e")
    return text
end

local function temperature_to_celsius(value, unit)
    if unit == "c" then return value end
    if unit == "f" then return (value - 32) * 5 / 9 end
    if unit == "k" then return value - 273.15 end
    return nil
end

local function celsius_to_temperature(value, unit)
    if unit == "c" then return value end
    if unit == "f" then return value * 9 / 5 + 32 end
    if unit == "k" then return value + 273.15 end
    return nil
end

function M.convert_unit(value, from_unit, to_unit)
    value = tonumber(value)
    if not value or type(from_unit) ~= "string" or type(to_unit) ~= "string" then
        return nil
    end
    from_unit = string.lower(from_unit)
    to_unit = string.lower(to_unit)

    local from_celsius = temperature_to_celsius(value, from_unit)
    if from_celsius ~= nil then
        local converted = celsius_to_temperature(from_celsius, to_unit)
        return converted ~= nil and format_number(converted) or nil
    end

    for _, family in pairs(UNIT_FAMILIES) do
        local from_factor = family[from_unit]
        local to_factor = family[to_unit]
        if from_factor and to_factor then
            return format_number(value * from_factor / to_factor)
        end
        if from_factor or to_factor then
            return nil
        end
    end
    return nil
end

local function make_candidate(seg, text, comment, quality)
    local cand = Candidate("number_tools", seg.start, seg._end, text, comment or "")
    cand.quality = quality or 100000
    return cand
end

local function prefixed_base(value, base)
    local sign = ""
    if value:sub(1, 1) == "-" then
        sign = "-"
        value = value:sub(2)
    end
    if base == 2 then return sign .. "0b" .. value end
    if base == 8 then return sign .. "0o" .. value end
    if base == 16 then return sign .. "0x" .. value end
    return nil
end

function M.translator(input, seg, env)
    local explicit_amount = input:match("^=rmb([+-]?%d+%.?%d*)$")
    local decimal_amount = input:match("^=([+-]?%d+%.%d+)$")
    local amount = explicit_amount or decimal_amount
    if amount then
        local upper = M.rmb_upper(amount)
        local lower = M.number_lower(amount)
        local grouped = M.add_grouping(amount)
        if upper then yield(make_candidate(seg, upper, "人民币大写", 100000)) end
        if lower then yield(make_candidate(seg, lower, "数字读法", 99999)) end
        if grouped then yield(make_candidate(seg, grouped, "千分位", 99998)) end
        return
    end

    local from_base, base_value, to_base = input:match("^=(%d+):([+-]?[%w]+)>(%d+)$")
    if from_base then
        local result = M.convert_base(base_value, tonumber(from_base), tonumber(to_base))
        if result then
            yield(make_candidate(seg, result, "进制转换", 100000))
            local prefixed = prefixed_base(result, tonumber(to_base))
            if prefixed then yield(make_candidate(seg, prefixed, "带前缀", 99999)) end
        end
        return
    end

    local decimal_value, decimal_target = input:match("^=([+-]?%d+)>(%d+)$")
    if decimal_value then
        local target = tonumber(decimal_target)
        local result = M.convert_base(decimal_value, 10, target)
        if result then
            yield(make_candidate(seg, result, "十进制转" .. tostring(target) .. "进制", 100000))
            local prefixed = prefixed_base(result, target)
            if prefixed then yield(make_candidate(seg, prefixed, "带前缀", 99999)) end
        end
        return
    end

    local numeric_value, from_unit, to_unit = input:match("^=([+-]?%d+%.?%d*)([A-Za-z]+)>([A-Za-z]+)$")
    if numeric_value then
        local result = M.convert_unit(tonumber(numeric_value), from_unit, to_unit)
        if result then
            yield(make_candidate(seg, result .. " " .. string.lower(to_unit),
                string.lower(from_unit) .. " → " .. string.lower(to_unit), 100000))
        end
    end
end

M.func = M.translator
M._read_integer = read_integer
M._parse_decimal = parse_decimal
M._format_number = format_number

return M
