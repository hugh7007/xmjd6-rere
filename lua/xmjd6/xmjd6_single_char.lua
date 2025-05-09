--[[
单字优先过滤器优化版 来源：@浮生 https://github.com/wzxmer/rime-txjx
功能：重排序候选项，使单字或短注释项优先显示
优化点：
1. 减少不必要的utf8.len计算
2. 添加类型安全检查
3. 优化内存使用
4. 增强可读性
--]]

local function single_char_filter(input)
   if not input or not input.iter then return end  -- 安全校验
   
   local buffer = {}  -- 非单字候选项缓存
   local buffer_size = 0
   
   for cand in input:iter() do
       -- 安全检查：确保cand是有效的候选对象
       if not cand or not cand.text then goto continue end
       
       -- 优化：优先检查comment长度（性能更高）
       if cand.comment and cand.comment:len() == 0 then
           yield(cand)
       else
           -- 单字检查（带UTF-8安全处理）
           local char_len = utf8.len(cand.text)
           if char_len and char_len == 1 then
               yield(cand)
           else
               buffer_size = buffer_size + 1
               buffer[buffer_size] = cand
           end
       end
       
       ::continue::
   end
   
   -- 批量输出非优先候选项
   for i = 1, buffer_size do
       yield(buffer[i])
   end
end

return single_char_filter
