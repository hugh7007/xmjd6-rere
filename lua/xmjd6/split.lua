local function filter(input, env)
    for cand in input:iter() do
        local hasSpace = string.find(cand.text, " ")
        if hasSpace then
            local delimiter = string.find(cand.text, "`[^`]*$")
            if delimiter == nil then
                yield(cand)
            else
                local word = string.sub(cand.text, 1, delimiter - 1)
                local comment = string.sub(cand.text, delimiter + 1)
                if word == "" or comment == "" then
                    yield(cand)
                else
                    local original_comment = cand:get_genuine().comment
                    if word:sub(1, 1) ~= "$" then
                        yield(Candidate(cand.type, cand.start, cand._end, word, original_comment .. comment))
                    else
                        yield(Candidate(word, cand.start, cand._end, original_comment .. comment, ""))
                    end
                end
            end
        else
            local str = cand.text
            if string.sub(str, -1) == "`" then
                str = string.sub(str, 1, -2)
                yield(Candidate(cand.type, cand.start, cand._end, str, cand:get_genuine().comment))
            else
                yield(cand)
            end

        end

    end
end

return filter
