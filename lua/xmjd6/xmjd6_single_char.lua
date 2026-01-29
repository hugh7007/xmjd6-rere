--[[
单字优先过滤器优化版，此版本经过二次优化 来源：@浮生 https://github.com/wzxmer/rime-txjx
功能：重排序候选项，使单字或短注释项优先显示
优化点：
1. 减少不必要的utf8.len计算
2. 添加类型安全检查
3. 优化内存使用
4. 增强可读性
5. 跳过反查候选，避免影响反查结果的完整性
--]]

local single_char_filter = {}

function single_char_filter.func(input, env)
   if not input or not input.iter then return end  -- 安全校验

   -- 检查是否为反查模式（输入包含万能符 `）
   local context = env.engine.context
   local input_text = context.input or ""
   local is_reverse_lookup = input_text:find("`") ~= nil

   -- 如果是反查模式，直接透传所有候选，不做重排序
   if is_reverse_lookup then
       for cand in input:iter() do
           yield(cand)
       end
       return
   end

   -- 每次调用时创建新的 buffer，避免累积
   local buffer = {}
   local buffer_size = 0

   for cand in input:iter() do

       -- 安全检查：确保cand是有效的候选对象
       if cand and cand.text and type(cand.text) == "string" then
           -- 优化：优先检查comment长度（性能更高）
           -- 安全检查 comment 类型
           if cand.comment and type(cand.comment) == "string" and #cand.comment == 0 then
               yield(cand)
           -- 新增：如果是数字日期格式（如2025-06-13），也优先输出
           elseif cand.text:match('^%d%d%d%d%-%d%d%-%d%d$') then
               yield(cand)
           else
               -- 单字检查（安全处理 utf8.len 可能返回 nil）
               local text_len = utf8.len(cand.text)
               if text_len == 1 then
                   yield(cand)
               elseif text_len and text_len > 1 then
                   -- 只有当 text_len 有效且大于1时才放入 buffer
                   buffer_size = buffer_size + 1
                   buffer[buffer_size] = cand
               end
               -- 如果 text_len 是 nil（非法 UTF-8），跳过该候选词
           end
       end
   end

   -- 批量输出非优先候选项
   for i = 1, buffer_size do
       yield(buffer[i])
   end

   -- buffer 是局部变量，函数结束后自动被 GC 回收
end

function single_char_filter.fini(env)
    -- 不再需要清理 buffer，因为使用局部变量
    -- 使用增量 GC 避免卡顿
    collectgarbage("step", 1)
end

return single_char_filter
