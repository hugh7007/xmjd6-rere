

local function bianzi(key, env)
    local engine = env.engine
    local context = engine.context
    local commit_text = context:get_commit_text()
    local config = engine.schema.config
    local bindKey = config:get_string('key_binder/bian_zi')

    if context:has_menu() and context:get_selected_candidate().text ~= '' then
        if (key:repr() == bindKey) then

            local candidate = context:get_selected_candidate()
            if candidate ~= nil then
				local text = candidate.text
                -- local text = handle(candidate.text)
                engine:commit_text("ᥬ" .. text .. "ᩤ")

                context:clear()
                return 1 -- kAccepted
            end
        end
    end

    return 2 -- kNoop
end

return bianzi
