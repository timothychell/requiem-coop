-- Requiem Co-op: native title-menu integration.
--
-- Adds a "Co-op" entry to the game's own title menu (app.UI1010GuiBehavior) and turns the same
-- menu into a co-op lobby when it is chosen: host / join / invite / ready / start / leave.
-- The menu is a data-driven FluentScrollList: updateItems(GuiTitleSelectType[]) creates one row per
-- entry from a template, so extra rows get the game's own font, layout, animation and input.
-- Rows reuse an existing entry type and are relabelled; decisions on our rows never reach the game.
--
-- Engine notes (verified in-game):
--  * via.gui writes only stick during the game's update phase (LateUpdateBehavior), not at present.
--  * A Text shows its MessageId's string; clear the id (zero Guid) before set_Message.
--  * Enum arrays: element data starts at offset 0x20, 4 bytes per element.
local M = {}

local ROW_TYPE = 4          -- app.GuiTitleSelectType.Option: plain row, always decidable, no "new" badge
local MAIN_STORY = 0
local COOP_INDEX = 1        -- inserted right below Main Story
local ARRAY_DATA = 0x20

local T_GUI = sdk.typeof("via.gui.GUI")
local TITLE_TD = sdk.find_type_definition("app.UI1010GuiBehavior")
local GUID_TD = sdk.find_type_definition("System.Guid")
local SCENE_TD = sdk.find_type_definition("via.SceneManager")

local function scene()
    local sm = sdk.get_native_singleton("via.SceneManager")
    return sm and sdk.call_native_func(sm, SCENE_TD, "get_CurrentScene")
end

local function child(o, name)
    local c = o and o:call("get_Child")
    while c do
        if c:call("get_Name") == name then return c end
        c = c:call("get_Next")
    end
end

local function type_array(values)
    local arr = sdk.create_managed_array("app.GuiTitleSelectType", #values):add_ref()
    for i, v in ipairs(values) do arr:write_dword(ARRAY_DATA + (i - 1) * 4, v) end
    return arr
end

local function read_types(arr)
    local out = {}
    local n = arr and arr:get_size() or 0
    for i = 0, n - 1 do out[#out + 1] = arr:read_dword(ARRAY_DATA + i * 4) end
    return out
end

function M.new(api)
    local self = {
        mode = "main",          -- "main" (game menu + Co-op row) or "lobby" (our rows)
        behavior = nil,         -- live app.UI1010GuiBehavior
        orig = nil,             -- the game's last types array (managed, kept alive)
        arrays = {},            -- arrays we handed to the game (kept alive while in use)
        rows = {},              -- current lobby rows {id, label, guide, action}
        row_key = "",
        labels = {},            -- row index -> text
        guides = {},            -- row index -> description text
        texts = {},             -- row index -> cached m_name Text element
        guide_text = nil,       -- cached Gui_ui0400 description Text
        guide_scan = -100,
        dirty = true,
        want_select = nil,
        flash = nil, flash_until = 0,
        error = "",
    }
    local empty_guid = ValueType.new(GUID_TD)

    local function set_text(t, s)
        if t and t:call("get_Message") ~= s then
            t:call("set_MessageId", empty_guid)
            t:call("set_Message", s)
        end
    end

    local function helper()
        local b = self.behavior
        return b and b:get_field("_ScrollListHelper")
    end

    local function selected()
        local h = helper()
        return h and h:get_field("_SelectItemIndex") or -1
    end

    -- lobby rows for the current session state --------------------------------------------
    local function lobby_rows()
        local link, lobby = api.link(), api.lobby
        local rows = {}
        local function add(id, label, guide, action) rows[#rows + 1] = { id = id, label = label, guide = guide, action = action } end
        if not api.plugin_alive() then
            add("noplugin", "Network plugin not running",
                "requiem_coop_net.dll is missing from reframework\\plugins, or REFramework isn't installed.", nil)
        elseif not api.in_session() then
            add("host", "Host Co-op Session", "Create a friends-only Steam lobby, then invite a friend.", api.host)
            local listed = 0
            for _, f in ipairs(link.friends or {}) do
                if f.lobby and f.lobby ~= "0" and listed < 4 then
                    listed = listed + 1
                    add("join:" .. f.lobby, "Join " .. tostring(f.name), "Join " .. tostring(f.name) .. "'s co-op session.",
                        function() api.join(f.lobby) end)
                end
            end
            if listed == 0 then
                add("nofriends", "No friends hosting", "When a friend hosts, they appear here. Accepting a Steam invite also works.", nil)
            end
        else
            local present = api.partner_present()
            local partner = present and tostring(link.peer) or nil
            local host = api.is_host()
            if present then
                add("partner", (host and "Partner: " or "Host: ") .. partner .. (lobby.partner_ready and "  -  Ready" or "  -  Not ready"),
                    host and "Your partner's game follows yours: New Game, Continue and Load Game start for both of you."
                        or "The host chooses New Game, Continue or Load Game; your game follows automatically.", nil)
            else
                add("waiting", host and "Waiting for a partner..." or "Connecting to the host...",
                    host and "Invite a friend through Steam. They can also join from their own Co-op menu." or "Connecting through Steam.", nil)
            end
            if host then add("invite", "Invite Friend", "Open the Steam overlay to invite a friend.", api.invite) end
            if api.get_player() == nil then
                add("ready", lobby.me_ready and "Ready  [X]" or "Ready  [  ]",
                    "Both players must be ready before the host can start.", api.toggle_ready)
            end
            if host then
                local can = (not present) or (lobby.me_ready and lobby.partner_ready)
                add("start", "Start Game", can and "Choose New Game, Continue or Load Game. Your partner's game follows."
                    or "Waiting until both players are ready.", function() if can then api.start() end end)
            elseif present and api.can_join_running() then
                add("joinrun", "Join Host's Game in Progress", "The host is already playing: their game is saved and sent to you.", api.join_running)
            end
            add("leave", "Leave Session", "Leave the co-op session.", api.leave)
        end
        add("back", "Back", "Return to the title menu.", function() self.back() end)
        return rows
    end

    local function lobby_types(n)
        local t = {}
        for i = 1, n do t[i] = ROW_TYPE end
        return t
    end

    -- ask the game to rebuild the list; the updateItems hook substitutes our entries
    local function refresh()
        local b = self.behavior
        if not (b and self.orig) then return end
        b:call("requestUpdateItems(app.GuiTitleSelectType[], app.GuiTitleSelectType, System.Boolean)", self.orig, MAIN_STORY, false)
        self.dirty = true
    end

    function self.open_lobby()
        self.mode = "lobby"
        self.rows = lobby_rows()
        self.row_key = ""
        refresh()
        self.want_select = self.first_action()
    end

    -- index of the first row that does something (status rows have no action)
    function self.first_action()
        for i, r in ipairs(self.rows) do if r.action then return i - 1 end end
        return 0
    end

    function self.back()
        self.mode = "main"
        refresh()
        self.want_select = COOP_INDEX
    end

    -- after "Start Game": back to the game menu with Main Story highlighted
    function self.to_main_story(msg)
        self.mode = "main"
        refresh()
        self.want_select = 0
        self.press_main_story = api.now()
        self.say(msg)
    end

    -- open the Main Story submenu (New Game / Continue / Load Game) as if the player pressed it
    local function press_main_story()
        local b, cb = self.behavior, self.last_cb
        if not (b and cb) then self.press_main_story = nil; return end
        local h = helper()
        local fsl = h and h:get_field("_ScrollList")
        if not (fsl and fsl:call("get_ItemCount") == #(self.orig_values or {}) + 1 and selected() == 0) then
            if api.now() - self.press_main_story > 2 then self.press_main_story = nil end   -- give up: Main Story stays highlighted
            return
        end
        self.press_main_story = nil
        cb:call("set_SelectIndex", 0)
        self.auto_decide = true
        local ok, err
        if self.decide_method then ok, err = pcall(self.decide_method.call, self.decide_method, b, cb)   -- the real input path
        else ok, err = pcall(b.call, b, "onSelectItemDecided", cb) end
        self.auto_decide = false
        if not ok then self.error = tostring(err) end
    end

    function self.say(msg)
        if msg and msg ~= "" then self.flash, self.flash_until = msg, api.now() + 6 end
    end

    -- hooks (dispatched from the main script so hot reloads swap the implementation) -------
    -- updateItems(types[], default, bool): returns a replacement array or nil
    function self.on_update_items(this, types)
        self.behavior = this
        self.texts, self.dirty = {}, true
        local values = read_types(types)
        local ours = false
        local addr = types:get_address()
        for _, a in ipairs(self.arrays) do if a:get_address() == addr then ours = true end end
        if not ours then
            local is_title = false
            for _, v in ipairs(values) do if v == MAIN_STORY or v == 5 --[[Exit]] then is_title = true end end
            if not is_title then return nil end
            if not (self.orig and self.orig:get_address() == addr) then
                if self.orig then pcall(self.orig.release, self.orig) end
                self.orig = types:add_ref()
            end
            self.orig_values = values
        end
        local new, labels, guides = {}, {}, {}
        if self.mode == "lobby" then
            self.rows = lobby_rows()
            local key = {}
            for i, r in ipairs(self.rows) do key[i] = r.id end
            self.row_key = table.concat(key, "|")
            new = lobby_types(#self.rows)
            for i, r in ipairs(self.rows) do labels[i - 1], guides[i - 1] = r.label, r.guide end
        else
            for i, v in ipairs(self.orig_values or values) do
                new[#new + 1] = v
                if i == COOP_INDEX then
                    new[#new + 1] = ROW_TYPE
                    labels[COOP_INDEX] = api.coop_label()
                    guides[COOP_INDEX] = api.coop_guide()
                end
            end
        end
        self.labels, self.guides = labels, guides
        local arr = type_array(new)
        self.arrays[#self.arrays + 1] = arr
        while #self.arrays > 4 do
            local old = table.remove(self.arrays, 1)
            pcall(old.release, old)
        end
        return arr
    end

    -- returns true to keep the game from handling the decision.
    -- cb: the game's GuiFluentScrollListHelper.CallbackArgs (not constructible from Lua, so the
    -- last real one is kept to "press" Main Story after Start Game).
    function self.on_decided(this, cb)
        if not (this and self.behavior and this:get_address() == self.behavior:get_address()) then return false end
        if self.auto_decide then return false end     -- our own Main Story press
        local i = selected()
        if cb then
            local ok, v = pcall(cb.call, cb, "get_SelectIndex")
            if ok and type(v) == "number" then i = v end
            if self.last_cb then pcall(self.last_cb.release, self.last_cb) end
            self.last_cb = cb:add_ref()
        end
        if self.mode == "main" then
            if i == COOP_INDEX then self.open_lobby(); self.reenable_until = api.now() + 0.5; return true end
            return false
        end
        local r = self.rows[i + 1]
        if r and r.action then
            local ok, err = pcall(r.action)
            if not ok then self.error = tostring(err) end
        end
        -- the helper switches its input off when an item is decided (it expects the menu to close);
        -- we skipped the game's handling, so switch it back on in the next update
        self.reenable_until = api.now() + 0.5
        return true
    end

    function self.on_canceled(this)
        if not (this and self.behavior and this:get_address() == self.behavior:get_address()) or self.mode ~= "lobby" then return false end
        self.back()
        return true
    end

    -- per frame, in the game's update phase ------------------------------------------------
    local function row_text(i)
        local t = self.texts[i]
        if t then return t end
        local h = helper()
        local fsl = h and h:get_field("_ScrollList")
        t = child(child(fsl, "Item_" .. i), "m_name")
        self.texts[i] = t
        return t
    end

    local function guide_text()
        if self.guide_text then return self.guide_text end
        if api.now() - self.guide_scan < 2 then return nil end
        self.guide_scan = api.now()
        local sc = scene()
        local guis = sc and sc:call("findComponents(System.Type)", T_GUI)
        for i = 0, (guis and guis:get_size() or 0) - 1 do
            local g = guis:get_element(i)
            local go = g:call("get_GameObject")
            if go and go:call("get_Name") == "Gui_ui0400" then
                local view = g:call("get_View")
                self.guide_text = child(child(child(child(child(view, "main"), "layout"), "type"), "type1"), "m_text")
                return self.guide_text
            end
        end
    end

    function self.tick()
        local b = self.behavior
        if not b then return end
        -- 10 Hz is plenty for status text; run every frame only while the list is settling or
        -- the cursor moved (so the description never shows the game's text for a frame)
        local t = api.now()
        local ok_s, sel_now = pcall(selected)
        if self.reenable_until then
            local h = helper()
            if h and not h:get_field("_InputEnable") then
                pcall(h.call, h, "setInputEnable(System.Boolean, System.Boolean)", true, false)
            end
            if t > self.reenable_until then self.reenable_until = nil end
        end
        if ok_s and not (self.dirty or self.want_select or self.press_main_story) and sel_now == self.last_sel
            and t - (self.last_tick or -1) < 0.1 then return end
        self.last_tick, self.dirty, self.last_sel = t, false, sel_now
        if api.get_player() ~= nil or not b:call("get_Valid") then
            self.behavior, self.mode, self.texts, self.guide_text = nil, "main", {}, nil
            return
        end
        if self.mode == "lobby" then
            local rows = lobby_rows()
            local key = {}
            for i, r in ipairs(rows) do key[i] = r.id end
            key = table.concat(key, "|")
            if key ~= self.row_key then
                -- row set changed (hosted, joined, partner arrived...): rebuild, keeping the cursor
                -- on the same row if it still exists, otherwise on the first actionable row
                local cur = self.rows[selected() + 1]
                self.rows = rows
                self.want_select = self.first_action()
                for i, r in ipairs(rows) do if cur and r.id == cur.id then self.want_select = i - 1 end end
                refresh()
                return
            end
            self.rows = rows
            for i, r in ipairs(rows) do self.labels[i - 1], self.guides[i - 1] = r.label, r.guide end
        else
            self.labels[COOP_INDEX], self.guides[COOP_INDEX] = api.coop_label(), api.coop_guide()
        end
        if self.press_main_story and not self.want_select then press_main_story() end
        if self.want_select then
            local h = helper()
            local fsl = h and h:get_field("_ScrollList")
            if fsl and fsl:call("get_ItemCount") > self.want_select then
                pcall(h.call, h, "setSelectItemIndex", self.want_select)
                self.want_select = nil
            end
        end
        for i, s in pairs(self.labels) do
            local t = row_text(i)
            if t then
                local ok = pcall(set_text, t, s)
                if not ok then self.texts[i] = nil end
            end
        end
        local sel = selected()
        local msg = (self.flash and api.now() < self.flash_until) and self.flash or nil
        local guide = self.guides[sel]
        if msg then guide = msg; self.flash_shown = true
        elseif self.flash_shown then
            self.flash_shown = false
            if not guide then pcall(b.call, b, "requestShowGuide") end   -- hand the line back to the game
        end
        if guide then
            local g = guide_text()
            if g and not pcall(set_text, g, guide) then self.guide_text = nil end
        end
    end

    return self
end

return M
