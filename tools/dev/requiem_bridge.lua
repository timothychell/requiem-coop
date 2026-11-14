-- Requiem Bridge (DEVELOPMENT ONLY - never ship this in a release).
-- Runs Lua sent by tools/Invoke-CoopBridge.ps1 so the mod can be inspected and tested in the running game.
-- Anything that can write to reframework/data can run code while it is enabled, so it starts disabled:
-- enable it under Script Generated UI > Requiem Bridge when you need it.
--   Claude writes reframework/data/bridge_cmd.json  : { "id": N, "code": "<lua>" }
--   This script runs it (once per new id) and writes reframework/data/bridge_out.json
-- Toggle with the checkbox under Script Generated UI > Requiem Bridge.

local CMD_FILE, OUT_FILE = "bridge_cmd.json", "bridge_out.json"
local enabled = false
local last_id = -1
local last_check = 0
local status = "waiting for commands"

-- Prevent re-running an old command after a script reset
do
    local prev = json.load_file(OUT_FILE)
    if type(prev) == "table" and type(prev.id) == "number" then last_id = prev.id end
end

---------------------------------------------------------------------------
-- Helpers available to commands
---------------------------------------------------------------------------
local H = {}

function H.is_obj(v)
    if type(v) ~= "userdata" then return false end
    local ok, td = pcall(v.get_type_definition, v)
    return ok and td ~= nil
end

function H.tname(v)
    if not H.is_obj(v) then return type(v) end
    return v:get_type_definition():get_full_name()
end

function H.all_fields(td)
    local out = {}
    while td and td:get_full_name() ~= "System.Object" do
        for _, f in ipairs(td:get_fields()) do
            if not f:is_static() then out[#out + 1] = f end
        end
        td = td:get_parent_type()
    end
    return out
end

-- Serialize any value to plain Lua data (depth-limited)
function H.S(v, depth, arr_max)
    depth = depth or 1
    arr_max = arr_max or 32
    if v == nil then return nil end
    local t = type(v)
    if t ~= "userdata" then return v end
    if not H.is_obj(v) then return tostring(v) end
    local td = v:get_type_definition()
    local res = { ["$type"] = td:get_full_name() }
    local okN, nm = pcall(v.get_field, v, "_Name")
    if okN and type(nm) == "string" then res["$name"] = nm end
    local okS, size = pcall(v.get_size, v)
    if okS and type(size) == "number" then
        res["$size"] = size
        if depth > 0 then
            local items = {}
            for i = 0, math.min(size, arr_max) - 1 do
                local okE, e = pcall(v.get_element, v, i)
                items[#items + 1] = okE and H.S(e, depth - 1, arr_max) or "<err>"
            end
            res["$items"] = items
        end
        return res
    end
    if depth <= 0 then return res end
    for _, f in ipairs(H.all_fields(td)) do
        local okv, fv = pcall(f.get_data, f, v)
        if okv then
            if H.is_obj(fv) then
                res[f:get_name()] = (depth > 1) and H.S(fv, depth - 1, arr_max) or ("<" .. H.tname(fv) .. ">")
            else
                res[f:get_name()] = fv == nil and "nil" or fv
            end
        end
    end
    return res
end

function H.singleton(name) return sdk.get_managed_singleton(name) end

-- List methods of an object/type, optional name filter (Lua pattern, case-insensitive)
function H.methods(obj_or_type, filter)
    local td = obj_or_type
    if type(obj_or_type) == "string" then td = sdk.find_type_definition(obj_or_type)
    elseif H.is_obj(obj_or_type) then td = obj_or_type:get_type_definition() end
    local out = {}
    while td and td:get_full_name() ~= "System.Object" do
        for _, m in ipairs(td:get_methods()) do
            local n = m:get_name()
            if not filter or n:lower():find(filter:lower()) then
                local ptxt = ""
                local okt, pts = pcall(m.get_param_types, m)
                if okt and pts then
                    local names = {}
                    for _, p in ipairs(pts) do names[#names + 1] = p:get_full_name() end
                    ptxt = table.concat(names, ", ")
                end
                local okr, rtn = pcall(function() return m:get_return_type():get_full_name() end)
                out[#out + 1] = td:get_full_name() .. "::" .. n .. "(" .. ptxt .. ") -> " .. tostring(okr and rtn or "?")
            end
        end
        td = td:get_parent_type()
    end
    return out
end

-- Static fields of a type (e.g. enum names/values)
function H.statics(type_name)
    local td = sdk.find_type_definition(type_name)
    if not td then return "type not found" end
    local out = {}
    for _, f in ipairs(td:get_fields()) do
        if f:is_static() then
            local ok, v = pcall(f.get_data, f, nil)
            out[f:get_name()] = ok and (H.is_obj(v) and ("<" .. H.tname(v) .. ">") or v) or "<err>"
        end
    end
    return out
end

-- Iterate a Dictionary / CatalogDictionary: fn(key, value)
function H.dict(obj, fn)
    local okD, inner = pcall(obj.get_field, obj, "_Dict")
    if okD and inner then obj = inner end
    local entries = obj:get_field("_entries")
    for i = 0, entries:get_size() - 1 do
        local e = entries:get_element(i)
        if e then
            local ok, k, v = pcall(function() return e:get_field("key"), e:get_field("value") end)
            if ok and k ~= nil and v ~= nil then
                if fn(k, v) then return end
            end
        end
    end
end

local log_lines = {}
function H.log(...)
    local parts = {}
    for _, p in ipairs({ ... }) do parts[#parts + 1] = tostring(p) end
    log_lines[#log_lines + 1] = table.concat(parts, " ")
end

---------------------------------------------------------------------------
-- Command loop
---------------------------------------------------------------------------
local function run_command(cmd)
    log_lines = {}
    local env = setmetatable({ H = H, S = H.S, log = H.log }, { __index = _G })
    local chunk, cerr = load(cmd.code, "bridge", "t", env)
    local result = { id = cmd.id, time = os.clock() }
    if not chunk then
        result.ok = false
        result.error = "compile: " .. tostring(cerr)
    else
        local ok, ret = xpcall(chunk, function(e)
            return (debug and debug.traceback) and debug.traceback(tostring(e)) or tostring(e)
        end)
        result.ok = ok
        if ok then
            local okS, ser = pcall(H.S, ret, cmd.depth or 2, cmd.arr_max or 32)
            result.result = okS and ser or ("<serialize error> " .. tostring(ser))
        else
            result.error = ret
        end
    end
    result.log = log_lines
    json.dump_file(OUT_FILE, result)
    status = string.format("ran command #%s (%s)", tostring(cmd.id), result.ok and "ok" or "error")
end

re.on_frame(function()
    if not enabled then return end
    local now = os.clock()
    if now - last_check < 0.5 then return end
    last_check = now
    local cmd = json.load_file(CMD_FILE)
    if type(cmd) == "table" and type(cmd.id) == "number" and cmd.id > last_id and type(cmd.code) == "string" then
        last_id = cmd.id
        local ok, err = pcall(run_command, cmd)
        if not ok then
            json.dump_file(OUT_FILE, { id = cmd.id, ok = false, error = "bridge: " .. tostring(err) })
        end
    end
end)

re.on_draw_ui(function()
    if not imgui.tree_node("Requiem Bridge") then return end
    local c, v = imgui.checkbox("Bridge enabled (runs Lua from reframework/data/bridge_cmd.json)", enabled)
    if c then enabled = v; status = v and "enabled" or "disabled" end
    imgui.text("Status: " .. status)
    imgui.text("Last command id: " .. tostring(last_id))
    imgui.tree_pop()
end)
