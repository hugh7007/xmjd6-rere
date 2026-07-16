local function filter(input)
    for cand in input:iter() do
        if cand.text:find("\\n", 1, true) then
            local text = cand.text:gsub("\\n", "\n")
            local converted = Candidate(
                cand.type,
                cand.start,
                cand._end,
                text,
                cand.comment
            )
            converted.quality = cand.quality
            yield(converted)
        else
            yield(cand)
        end
    end
end

return { func = filter }
