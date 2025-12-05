local function filter(input, env)
    for cand in input:iter() do
        local hasGun = (string.find(cand.text, "|") or string.find(cand.text, "\\n"))
        if hasGun then
            local str = cand.text
            str = string.gsub(str, "|", " ")
            str = string.gsub(str, "\\n", "\n")
            yield(Candidate(cand.type, cand.start, cand._end, str, cand:get_genuine().comment))
        else
            yield(cand)
        end
    end
end

return filter
