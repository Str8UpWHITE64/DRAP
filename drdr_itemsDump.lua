-- Dead Rising Deluxe Remaster
-- Dump all items to JSON with fields:
--   "name"       : OriginContent (nice in-game name)
--   "game_id"    : internal ID like ITEM_NO_PYLON (from get_DisplayName)
--   "item_number": mItemNo

local did_run = false

local function log(msg)
    print(msg)
end

-- Helpers ----------------------------------------------------------

local function idx(container, i)
    if container == nil then return nil end
    if container.get_Item ~= nil then
        local ok, v = pcall(function() return container:get_Item(i) end)
        if ok then return v end
    end
    if container.get_element ~= nil then
        local ok, v = pcall(function() return container:get_element(i) end)
        if ok then return v end
    end
    return nil
end

local function get_len(container)
    if container == nil then return 0 end

    if container.get_Count ~= nil then
        local ok, v = pcall(function() return container:get_Count() end)
        if ok then return v end
    end
    if container.get_Length ~= nil then
        local ok, v = pcall(function() return container:get_Length() end)
        if ok then return v end
    end
    if container.get_size ~= nil then
        local ok, v = pcall(function() return container:get_size() end)
        if ok then return v end
    end

    return 0
end

-- Find a field in type hierarchy (for OriginContent on base class)
local function find_field_in_hierarchy(obj, field_name)
    if obj == nil then return nil end
    local td = obj:get_type_definition()
    while td ~= nil do
        local f = td:get_field(field_name)
        if f ~= nil then
            return f
        end
        td = td:get_parent_type()
    end
    return nil
end

-- JSON Formatter ------------------------------------------------------

local function indent(level)
    return string.rep("  ", level)
end

local function json_escape(str)
    str = tostring(str or "")
    str = str:gsub("\\", "\\\\")
             :gsub("\"", "\\\"")
             :gsub("\n", "\\n")
             :gsub("\r", "\\r")
    return str
end

local function to_json_array(items)
    local out = {}
    table.insert(out, "[\n")

    for i, it in ipairs(items) do
        table.insert(out, indent(1) .. "{\n")
        table.insert(out, indent(2) .. "\"name\": \"" .. json_escape(it.name) .. "\",\n")
        table.insert(out, indent(2) .. "\"game_id\": \"" .. json_escape(it.game_id) .. "\",\n")
        table.insert(out, indent(2) .. "\"item_number\": " .. tostring(it.item_number) .. "\n")
        table.insert(out, indent(1) .. "}")

        if i < #items then
            table.insert(out, ",\n")
        else
            table.insert(out, "\n")
        end
    end

    table.insert(out, "]")
    return table.concat(out)
end

-- Main -------------------------------------------------------------

re.on_frame(function()
    if did_run then return end

    ----------------------------------------------------------------
    -- 1) Build itemNo -> name map from MessageManager
    ----------------------------------------------------------------
    local mm = sdk.get_managed_singleton("app.solid.gamemastering.MessageManager")
    local mm_td = mm:get_type_definition()
    local ud_list_field = mm_td:get_field("mSolidMessageUserDataList")
    local ud_list = ud_list_field:get_data(mm)
    local ud_count = get_len(ud_list)

    log(string.format("[ItemJsonDump] MessageUserData count: %d", ud_count))

    local ud2 = idx(ud_list, 2)
    local ud2_td = ud2:get_type_definition()
    local map_field = ud2_td:get_field("mDataMapping")
    local map = map_field:get_data(ud2)
    local map_td = map:get_type_definition()

    log("[ItemJsonDump] mDataMapping type: " ..
        (map_td and map_td:get_full_name() or "?"))

    local entries_field = map_td:get_field("_entries")
    local entries = entries_field:get_data(map)
    local entries_len = get_len(entries)

    log(string.format("[ItemJsonDump] _entries length: %d", entries_len))

    local item_names = {}

    for i = 0, entries_len - 1 do
        local entry = idx(entries, i)
        if entry ~= nil then
            local e_td = entry:get_type_definition()
            if e_td ~= nil then
                local val_field = e_td:get_field("value") or e_td:get_field("Value")
                if val_field ~= nil then
                    local unit = val_field:get_data(entry)
                    if unit ~= nil then
                        local unit_td = unit:get_type_definition()

                        -- MessageId on MessageDataUnit: "ItemName_0004"
                        local id_field = unit_td:get_field("MessageId")
                        local msg_id = id_field and id_field:get_data(unit) or nil

                        -- DataList[0] on MessageDataUnit
                        local dl_field = unit_td:get_field("DataList")
                        local dl = dl_field and dl_field:get_data(unit) or nil

                        local origin = nil
                        if dl ~= nil then
                            local dl_count = get_len(dl)
                            if dl_count > 0 then
                                local raw = idx(dl, 0)  -- MessageDataRaw : MessageDataBase
                                if raw ~= nil then
                                    local origin_field = find_field_in_hierarchy(raw, "OriginContent")
                                    if origin_field ~= nil then
                                        local ok, val = pcall(function()
                                            return origin_field:get_data(raw)
                                        end)
                                        if ok then
                                            origin = val
                                        end
                                    end
                                end
                            end
                        end

                        if msg_id ~= nil and origin ~= nil then
                            -- msg_id like "ItemName_0004" -> extract "0004"
                            local num_str = tostring(msg_id):match("ItemName_%s*(%d+)")
                            if num_str ~= nil then
                                local num = tonumber(num_str)
                                if num ~= nil and item_names[num] == nil then
                                    item_names[num] = origin
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    ----------------------------------------------------------------
    -- 2) Walk ItemManager.ItemInstanceTable to get game_id + mItemNo
    ----------------------------------------------------------------
    local im = sdk.get_managed_singleton("app.solid.gamemastering.ItemManager")
    local im_td = im:get_type_definition()

    -- Try direct field name first
    local item_table_field = im_td:get_field("ItemInstanceTable")
    local item_table = nil

    if item_table_field ~= nil then
        item_table = item_table_field:get_data(im)
    else
        -- Fallback: auto-detect the field whose element type is rItemInstanceTable__ItemInstance
        local target_entry_type_name = "solid.MT2RE.rItemInstanceTable__ItemInstance"
        for _, f in ipairs(im_td:get_fields()) do
            local ok, v = pcall(function() return f:get_data(im) end)
            if ok and v ~= nil and type(v) == "userdata" then
                local c = get_len(v)
                if c > 0 then
                    local entry = idx(v, 0)
                    if entry ~= nil then
                        local etd = entry:get_type_definition()
                        if etd ~= nil and etd:get_full_name() == target_entry_type_name then
                            item_table = v
                            break
                        end
                    end
                end
            end
        end
    end

    local item_count = get_len(item_table)
    log(string.format("[ItemJsonDump] ItemInstanceTable count: %d", item_count))

    local items_out = {}

    for i = 0, item_count - 1 do
        local entry = idx(item_table, i)
        if entry ~= nil then
            local td = entry:get_type_definition()

            -- mItemNo
            local no_field = td:get_field("mItemNo")
            local mItemNo = no_field and no_field:get_data(entry) or nil

            -- game_id from get_DisplayName() -> first token
            local game_id = ""
            local ok_disp, disp = pcall(function()
                return entry:call("get_DisplayName")
            end)
            if ok_disp and disp ~= nil then
                local s = tostring(disp)
                game_id = s:match("^(%S+)") or s
            end

            -- nice name from item_names map
            local nice_name = nil
            if mItemNo ~= nil then
                nice_name = item_names[tonumber(mItemNo)]
            end

            table.insert(items_out, {
                name        = nice_name or "",
                game_id     = game_id or "",
                item_number = tonumber(mItemNo) or 0
            })
        end
    end

    ----------------------------------------------------------------
    -- 3) Encode as JSON and output
    ----------------------------------------------------------------
    local json = to_json_array(items_out)

    -- Print to REFramework console
    log("[ItemJsonDump] JSON dump:")
    log(json)

    -- Also write to a file in the game directory
    local ok, err = pcall(function()
        local file = io.open("drdr_items.json", "w")
        if file then
            file:write(json)
            file:close()
            log("[ItemJsonDump] Wrote drdr_items.json")
        else
            log("[ItemJsonDump] Failed to open drdr_items.json for writing")
        end
    end)
    if not ok then
        log("[ItemJsonDump] Error writing file: " .. tostring(err))
    end

    did_run = true
end)
