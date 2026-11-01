--[[ enchanter_npc.lua - an enchanter NPC for AzerothCore + Eluna (3.3.5a).

     Install:  put this file and enchants_data.lua in lua_scripts/.
     Attach:   the gossip handler picks up NPC entry 601015; change NPC_ID for
               another one, or set NPC_ID on the creature template to match.

     The flow is four gossip pages: slot -> era -> formula list -> reagents and
     the Apply button. Formulas come from enchants_data.lua.

     Cost is the reagents plus a fee that scales with the skill the recipe
     requires (Config.FeeEcon below), so Classic formulas stay cheap and the
     top Northrend ones do not.
]]

local NPC_ID = 601015

local Config = {
    RequireMaterials         = true,
    PageSize                 = 10,
    -- minimum item level a formula's target must have, by era. Classic has none.
    -- Set either to 0 to switch that era's gate off (and its menu line).
    MinIlvlTBC               = 35,
    MinIlvlWotLK             = 60,
    -- fee = GoldFee * (skill / 300) ^ FeeExponent * FeeEra[era], in copper,
    -- rounded to whole silver. Below 300 the curve is cheap, so a lowbie is
    -- never priced out of a low-level formula; above it the price climbs hard.
    GoldFee                  = 100000,
    FeeExponent              = 2.5,
    FeeEra                   = { vanilla = 0.5, tbc = 1.0, wotlk = 2.0 },
    AnnounceLogin            = false,
    VisualSpell              = 12512,
    ShowVanilla              = true,
    ShowTBC                  = true,
    ShowWotLK                = true,
    ShowBreadcrumbs          = true,
    ShowSlotIcons            = true,
    DebugReview              = false,
}

local EQ = {
    HEAD = 0, SHOULDERS = 2, CHEST = 4, LEGS = 6, FEET = 7,
    WRISTS = 8, HANDS = 9, BACK = 14, MAINHAND = 15, OFFHAND = 16,
}

local INV = {
    WEAPON = 13, SHIELD = 14, TWOHAND = 17, ROBE = 20,
    WEAPONMAINHAND = 21, WEAPONOFFHAND = 22, HOLDABLE = 23,
}

local PERM_ENCHANT = 0
local ITEM_SUBCLASS_STAFF = 10
local GOSSIP_MAX_ROWS = 32

local ACT = {
    PICK_SLOT  = 10,
    PICK_ERA   = 12,
    OPEN       = 14,
    PAGE_NEXT  = 15,
    PAGE_PREV  = 16,
    BACK       = 17,
    APPLY      = 20,
    NOOP       = 99,
}

local LVL_MAIN, LVL_ERA, LVL_LIST, LVL_MATS = 1, 2, 3, 4
local TIER_AVAILABLE   = 1
local TIER_UNAVAILABLE = 2

local EXP_KEY = { [1] = "vanilla", [2] = "tbc", [3] = "wotlk" }
local EXP_ID  = { vanilla = 1, tbc = 2, wotlk = 3 }
local EXP_WORD = { [1] = "Classic", [2] = "Outland", [3] = "Northrend" }

local REASON_TEXT = {
    no_item      = "You have nothing equipped in that slot.",
    bad_item     = "The item in that slot cannot take these formulas.",
    ilvl         = "Your item's level is below what these formulas need.",
    mats         = "You are missing the reagents for every one of these.",
    gold         = "You cannot afford my fee.",
    era_off      = "That era is switched off on this realm.",
}

local Slots = {
    { key = "weapon",    label = "Main Hand",  icon = "Interface/ICONS/Inv_sword_04",            eq = EQ.MAINHAND },
    { key = "offhand",   label = "Off Hand",   icon = "Interface/ICONS/Inv_weapon_shortblade_05", eq = EQ.OFFHAND },
    { key = "weapon2h",  label = "2H Weapon",  icon = "Interface/ICONS/Inv_axe_09",               eq = EQ.MAINHAND },
    { key = "staff",     label = "Staff",      icon = "Interface/ICONS/Inv_staff_13",             eq = EQ.MAINHAND },
    { key = "shield",    label = "Shield",     icon = "Interface/ICONS/Inv_shield_04",            eq = EQ.OFFHAND },
    { key = "back",      label = "Cloak",      icon = "Interface/ICONS/Inv_misc_cape_18",         eq = EQ.BACK },
    { key = "chest",     label = "Chest",      icon = "Interface/ICONS/Inv_chest_cloth_04",       eq = EQ.CHEST },
    { key = "wrist",     label = "Bracers",    icon = "Interface/ICONS/Inv_bracer_07",            eq = EQ.WRISTS },
    { key = "hands",     label = "Gloves",     icon = "Interface/ICONS/Inv_gauntlets_04",         eq = EQ.HANDS },
    { key = "feet",      label = "Boots",      icon = "Interface/ICONS/Inv_boots_05",             eq = EQ.FEET },
}

local SLOT_BY_KEY = {}
for i = 1, #Slots do SLOT_BY_KEY[Slots[i].key] = Slots[i] end
local SLOT_ACCEPTS = {}
for key in pairs(SLOT_BY_KEY) do SLOT_ACCEPTS[key] = { [key] = true } end
SLOT_ACCEPTS.weapon   = { weapon = true }
SLOT_ACCEPTS.offhand  = { weapon = true }
SLOT_ACCEPTS.weapon2h = { weapon2h = true }
SLOT_ACCEPTS.staff    = { staff = true }

local DATA_FILE       = "enchants_data.lua"
local DATA_GLOBAL     = "ElunaEnchanterFormulas"
local DATA_CANDIDATES = {
    DATA_FILE,
    "lua_scripts/" .. DATA_FILE,
    "./lua_scripts/" .. DATA_FILE,
    "../lua_scripts/" .. DATA_FILE,
    "../../lua_scripts/" .. DATA_FILE,
}

local Enchants = {}
local bookLoaded = false

local function LoadFormulaBook()
    local published = rawget(_G, DATA_GLOBAL)
    if type(published) == "table" and #published > 0 then
        return published, DATA_GLOBAL
    end
    for _, path in ipairs(DATA_CANDIDATES) do
        local ok, res = pcall(dofile, path)
        if ok and type(res) == "table" and #res > 0 then
            return res, path
        end
    end
    return nil
end

local BookSlots = {}

local function IndexBookSlots()
    BookSlots = {}
    for i = 1, #Enchants do
        local enc = Enchants[i]
        if enc.slot then BookSlots[enc.slot] = true end
    end
end

local function SlotInBook(meta)
    local accepts = SLOT_ACCEPTS[meta.key] or {}
    for key in pairs(accepts) do
        if BookSlots[key] then return true end
    end
    return false
end

local function EnsureBook()
    if bookLoaded then return true end
    local book = LoadFormulaBook()
    if book then
        Enchants = book
        IndexBookSlots()
        bookLoaded = true
        return true
    end
    return false
end

EnsureBook()

local Session = {}

--===========================================================================
--  Small helpers
--===========================================================================

local function Sid(player)
    return player:GetGUIDLow()
end

local function GetSession(player)
    local id = Sid(player)
    local sess = Session[id]
    if not sess then
        sess = { slot = 1, exp = 3, page = 1, cache = {} }
        Session[id] = sess
    end
    return sess
end

local ItemMemo = {}
local MemoGen = 0
local MEMO_NIL = {}

local function Safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return true, value end
    return false, nil
end

local function ItemIsAlive(item)
    if item == nil then return false end
    local ok = pcall(function() return item:GetGUID() end)
    return ok
end

--===========================================================================
--  Names
--===========================================================================

local NameMemo = {}

local function LookupItemName(id)
    if type(id) ~= "number" or id <= 0 then return nil end
    if not GetItemTemplate then return nil end
    local ok, tmpl = Safe(function() return GetItemTemplate(id) end)
    if not ok or not tmpl then return nil end
    local ok2, name = Safe(function() return tmpl:GetName() end)
    if ok2 and type(name) == "string" and name ~= "" then return name end
    return nil
end

local function LookupSpellName(id)
    if type(id) ~= "number" or id <= 0 then return nil end
    if not GetSpellInfo then return nil end
    local ok, info = Safe(function() return GetSpellInfo(id) end)
    if not ok or not info then return nil end
    local ok2, name = Safe(function() return info:GetName() end)
    if ok2 and type(name) == "string" and name ~= "" then return name end
    return nil
end

local function CachedName(kind, id)
    if type(id) ~= "number" or id <= 0 then return nil end
    local key = kind .. ":" .. id
    local hit = NameMemo[key]
    if hit ~= nil then
        return hit or nil
    end
    local name = (kind == "item") and LookupItemName(id) or LookupSpellName(id)
    NameMemo[key] = name or false
    return name
end


local function MemoRead(item, key, getter)
    local id = item
    local rec = ItemMemo[id]
    if rec and rec.gen == MemoGen then
        local cached = rec[key]
        if cached ~= nil then
            if cached == MEMO_NIL then return nil end
            return cached
        end
    else
        rec = { gen = MemoGen }
        ItemMemo[id] = rec
    end
    local ok, value = pcall(getter, item)
    if not ok then value = nil end
    rec[key] = (value == nil) and MEMO_NIL or value
    return value
end

local function ItemName(item)
    if not item then return "nothing" end
    local name = MemoRead(item, "name", function(it) return it:GetName() end)
    return name or "selected item"
end

-- --------------------------------------------------------------------------
--  How a name is drawn: in a menu it is coloured text in brackets (a gossip
--  row cannot render a hyperlink), in chat - breadcrumbs only - it is a real
--  |Hitem / |Hspell link. MatText is the menu form, MatLink/SpellLink the
--  chat forms; nothing else here builds brackets or colours.
-- --------------------------------------------------------------------------

local ITEM_TEXT_COLOUR = "|cffffffff"
local SPELL_LINK_COLOUR = "|cff1f6fb2"

local function Bracketed(colour, name)
    if type(name) ~= "string" or name == "" then return nil end
    return colour .. "[" .. name .. "]|r"
end

-- The colour a link is painted in, read back off the link's own |c code, so a
-- plain bracket matches the link it replaces. No link, no colour.
local LINK_COLOUR = "^|c(%x%x%x%x%x%x%x%x)|H"

local function ItemColour(id)
    if type(id) ~= "number" or id <= 0 then return nil end
    if type(GetItemLink) ~= "function" then return nil end
    local ok, link = Safe(function() return GetItemLink(id) end)
    if not ok or type(link) ~= "string" then return nil end
    return link:match(LINK_COLOUR)
end

local function ColourOf(id)
    local c = ItemColour(id)
    if c then return "|c" .. c end
    return nil
end

-- An item name as a menu reads it: [Lesser Magic Essence], in link colour.
local function MatText(id)
    local name = CachedName("item", id)
    if not name then return nil end
    return Bracketed(ColourOf(id) or ITEM_TEXT_COLOUR, name)
end

-- An item name as chat draws it: the real link, tooltip and all.
local function MatLink(id)
    local name = CachedName("item", id)
    if type(id) == "number" and id > 0 and type(GetItemLink) == "function" then
        local ok, link = Safe(function() return GetItemLink(id) end)
        if ok and type(link) == "string" and link ~= "" then return link end
    end
    return MatText(id) or name or ("item " .. tostring(id))
end

-- A chat spell link; the caption defaults to the client's recipe name.
local function SpellLink(id, caption)
    if type(id) ~= "number" or id <= 0 then return nil end
    local name = caption or CachedName("spell", id)
    if not name then return nil end
    return "|cff71d5ff|Hspell:" .. id .. "|h[" .. name .. "]|h|r"
end

local function EnchantName(enc)
    if not enc then return "?" end
    if enc.spell then
        local n = CachedName("spell", enc.spell)
        if n then return n end
    end
    if enc.apply then
        local n = CachedName("item", enc.apply)
        if n then return n end
    end
    return enc.name or "?"
end

local function EnchantEffect(enc)
    if not enc then return "" end
    return enc.effect or enc.name or ""
end

-- A formula's name as a menu row prints it: bracketed, spell blue.
local function EnchantNameColoured(enc)
    if not enc then return nil end
    local caption = EnchantName(enc)
    if enc.apply then
        return MatText(enc.apply) or Bracketed(ITEM_TEXT_COLOUR, caption)
    end
    return Bracketed(SPELL_LINK_COLOUR, caption)
end

local function EnchantRow(enc)
    local name = EnchantName(enc)
    local effect = EnchantEffect(enc) or ""
    local tail = name
    local cut = name:find(" %- ")
    if cut then tail = name:sub(cut + 3) end
    local shown = EnchantNameColoured(enc) or name
    if effect == "" or effect == name or effect == tail
        or effect == EnchantName(enc) then
        return shown
    end
    return shown .. ": " .. effect
end

local function ItemInvType(item)
    if not item then return nil end
    return MemoRead(item, "inv", function(it) return it:GetInventoryType() end)
end

local function ItemILvl(item)
    if not item then return nil end
    return MemoRead(item, "ilvl", function(it) return it:GetItemLevel() end)
end

local QUALITY_HEIRLOOM = 7

local function ItemIsHeirloom(item)
    if not item then return false end
    return MemoRead(item, "quality", function(it) return it:GetQuality() end) == QUALITY_HEIRLOOM
end

-- The item level a formula needs, from its era: the book carries no per-formula
-- level because every formula in an era shares the same one.
local function MinIlvl(enc)
    if not enc then return 0 end
    if enc.exp == "tbc" then return Config.MinIlvlTBC or 0 end
    if enc.exp == "wotlk" then return Config.MinIlvlWotLK or 0 end
    return 0
end

local function IlvlFits(item, enc)
    local need = MinIlvl(enc)
    if need <= 0 then return true end
    local ilvl = ItemILvl(item)
    if not ilvl then return true end
    return ilvl >= need
end

local function ItemLevelText(item)
    if not item then return "?" end
    if ItemIsHeirloom(item) then return "Heirloom" end
    local ilvl = ItemILvl(item)
    if not ilvl then return "?" end
    return "ilvl " .. tostring(ilvl)
end

local function ItemLink(item)
    if not item then return nil end
    local ok, link = Safe(function() return item:GetItemLink() end)
    if ok and type(link) == "string" and link ~= "" then return link end
    return nil
end

local function ItemEntry(item)
    if not item then return nil end
    return MemoRead(item, "entry", function(it) return it:GetEntry() end)
end

local function ItemNameColoured(item)
    local name = ItemName(item)
    if not name or name == "nothing" or name == "selected item" then return name end
    local link = ItemLink(item)
    if link then
        local colour = link:match(LINK_COLOUR)
        return Bracketed(colour and ("|c" .. colour) or ITEM_TEXT_COLOUR, name)
    end
    local colour = ColourOf(ItemEntry(item))
    return Bracketed(colour or ITEM_TEXT_COLOUR, name) or name
end

local function ItemNameLinked(item)
    local name = ItemName(item)
    if not name or name == "nothing" or name == "selected item" then return name end
    local link = ItemLink(item)
    if link then return link end
    local entry = ItemEntry(item)
    if entry then return MatLink(entry) end
    return name
end

local function ItemSubClass(item)
    if not item then return nil end
    return MemoRead(item, "subclass", function(it) return it:GetSubClass() end)
end

local function ItemIdentity(item, eqSlot)
    if not item then return "empty:" .. tostring(eqSlot) end
    local guid = MemoRead(item, "guid", function(it) return it:GetGUID() end)
    if guid then return "guid:" .. tostring(guid) end
    local entry = MemoRead(item, "entry", function(it) return it:GetEntry() end)
    if entry then return "entry:" .. tostring(entry) end
    return "stale:" .. tostring(MemoGen) .. ":" .. tostring(eqSlot)
end

local function ItemEnchantId(item, perm)
    if not item then return nil end
    return MemoRead(item, "ench", function(it)
        return it:GetEnchantmentId(perm or PERM_ENCHANT)
    end)
end

local function Equipped(player, eqSlot)
    for _ = 1, 2 do
        local ok, item = Safe(function() return player:GetEquippedItemBySlot(eqSlot) end)
        if ok and item and ItemIsAlive(item) then return item end
        ok, item = Safe(function() return player:GetItemByPos(255, eqSlot) end)
        if ok and item and ItemIsAlive(item) then return item end
    end
    return nil
end

local function Whisper(player, msg)
    player:SendBroadcastMessage(msg)
end

local function GoldString(copper)
    copper = math.floor(tonumber(copper) or 0)
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end

local function FormatMats(enc)
    local parts = {}
    for i = 1, #enc.mats do
        local id, n = enc.mats[i][1], enc.mats[i][2]
        parts[#parts + 1] = n .. "x " .. (MatText(id) or ("item " .. tostring(id)))
    end
    if #parts == 0 then return "nothing" end
    return table.concat(parts, ", ")
end

local function IsWeaponInv(inv)
    return inv == INV.WEAPON or inv == INV.WEAPONMAINHAND
        or inv == INV.WEAPONOFFHAND or inv == INV.TWOHAND
end

local function CountItem(player, id)
    local ok, n = Safe(function() return player:GetItemCount(id) end)
    if ok and type(n) == "number" then return n end
    local lo, hi = 0, 200
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if player:HasItem(id, mid) then lo = mid else hi = mid - 1 end
    end
    return lo
end

--===========================================================================
--  Targeting: which item would this slot touch?
--===========================================================================

local function ResolveEqSlot(slotKey)
    local meta = SLOT_BY_KEY[slotKey]
    if slotKey == "offhand" or slotKey == "shield" then
        return EQ.OFFHAND
    end
    return meta and meta.eq or EQ.MAINHAND
end

local function TargetItem(player, slotKey)
    local eq = ResolveEqSlot(slotKey)
    return Equipped(player, eq), eq
end

local function RowFitsItem(item, slotKey)
    if not item then return false end
    local inv = ItemInvType(item)
    if not inv then return true end

    local staff = inv == INV.TWOHAND
        and ItemSubClass(item) == ITEM_SUBCLASS_STAFF

    if slotKey == "weapon" then
        return IsWeaponInv(inv)
    elseif slotKey == "offhand" then
        return IsWeaponInv(inv)
    elseif slotKey == "weapon2h" then
        return inv == INV.TWOHAND
    elseif slotKey == "staff" then
        return staff
    elseif slotKey == "shield" then
        return inv == INV.SHIELD
    end
    return true
end

local function PoolFor(slotKey)
    if slotKey == "offhand" then return "weapon" end
    return slotKey
end

local function ItemAccepts(item, slotKey, enc)
    if not item then return false, "no_item" end
    if not RowFitsItem(item, slotKey) then return false, "bad_item" end
    if enc then
        if PoolFor(slotKey) ~= enc.slot then return false, "pool" end
    end
    return true
end

--===========================================================================
--  Gates
--===========================================================================

local function EraEnabled(exp)
    if exp == "vanilla" then return Config.ShowVanilla end
    if exp == "tbc" then return Config.ShowTBC end
    if exp == "wotlk" then return Config.ShowWotLK end
    return true
end

local function MissingMats(player, enc)
    local missing = nil
    for i = 1, #enc.mats do
        local id, n = enc.mats[i][1], enc.mats[i][2]
        local have = CountItem(player, id)
        if have < n then
            missing = missing or {}
            missing[#missing + 1] = { id, n, have }
        end
    end
    return missing
end

local function FeeFor(enc)
    local base = Config.GoldFee or 0
    if base <= 0 or not enc then return 0 end
    local skill = tonumber(enc.skill) or 0
    if skill <= 0 then skill = 1 end
    local era = Config.FeeEra and Config.FeeEra[enc.exp] or 1
    local fee = base * (skill / 300) ^ (Config.FeeExponent or 1) * era
    return math.max(0, math.floor(fee / 100 + 0.5) * 100)
end

local function Coinage(player)
    local ok, coin = Safe(function() return player:GetCoinage() end)
    if ok and type(coin) == "number" then return coin end
    return nil
end

local function CanAffordFee(player, enc)
    local fee = FeeFor(enc)
    if fee <= 0 then return true end
    local coin = Coinage(player)
    if coin then return coin >= fee end
    return true
end

local function CanUse(player, item, slotKey, enc, ignoreMats)
    local accepts, why = ItemAccepts(item, slotKey, enc)
    if not accepts then return false, why end

    local need = MinIlvl(enc)
    if need > 0 and not IlvlFits(item, enc) then
        return false, "ilvl", { ilvl = ItemILvl(item), need = need, heirloom = ItemIsHeirloom(item) }
    end

    if not EraEnabled(enc.exp) then return false, "era_off" end

    if Config.RequireMaterials and not ignoreMats then
        local missing = MissingMats(player, enc)
        if missing then return false, "mats", { missing = missing } end
    end
    if not ignoreMats and not CanAffordFee(player, enc) then return false, "gold" end

    return true
end

--===========================================================================
--  Evaluation
--===========================================================================

local function Evaluate(player, sess, slotKey)
    local item, eq = TargetItem(player, slotKey)
    sess.cache = sess.cache or {}
    local key = (Config.DebugReview and "r:" or "p:") .. tostring(slotKey) .. "#" .. ItemIdentity(item, eq)
    local cached = sess.cache[key]
    if cached then
        cached.item = item
        return cached
    end

    local res = {
        item = item,
        ok = {},
        byExp = {},
        usable = {},
        reasons = {},
        blocked = nil,
    }
    for i = 1, 3 do res.byExp[i] = { available = {}, unavailable = {} } end

    local pool = PoolFor(slotKey)
    for idx = 1, #Enchants do
        local enc = Enchants[idx]
        if enc.slot == pool and EraEnabled(enc.exp) then
            local ok, reason = CanUse(player, item, slotKey, enc)
            local b = res.byExp[EXP_ID[enc.exp]]
            if ok then
                res.ok[#res.ok + 1] = idx
                res.usable[idx] = true
                b.available[#b.available + 1] = idx
            else
                res.reasons[reason] = true
                if Config.DebugReview or CanUse(player, item, slotKey, enc, true) then
                    b.unavailable[#b.unavailable + 1] = idx
                end
            end
        end
    end

    if not item then
        res.blocked = "no_item"
    else
        for _, code in ipairs({ "bad_item", "ilvl", "mats", "gold" }) do
            if res.reasons[code] then res.blocked = code break end
        end
    end

    sess.cache[key] = res
    return res
end

local function EraTotal(res, expId)
    local b = res.byExp[expId]
    return b and (#b.available + #b.unavailable) or 0
end

local function Invalidate(sess)
    if sess then sess.cache = {} end
end

local function Restart(sess)
    Invalidate(sess)
    ItemMemo = {}
    MemoGen = MemoGen + 1
end

--===========================================================================
--  Menus
--    1  slot          all equippable slots + number of available formulas
--    2  era           per era: available list / unavailable list
--    3  enchant       name + effect, highest item level first
--    4  materials     reagents, have/need, and the Apply button
--===========================================================================

local function Icon(path)
    if not Config.ShowSlotIcons or not path then return "" end
    return "|T" .. path .. ":22:22:-18:0|t "
end

local function ItemIconPath(item, meta)
    if item then
        local path = MemoRead(item, "icon", function(it)
            local tmpl = it:GetItemTemplate()
            if not tmpl then return nil end
            local icon = tmpl:GetIcon()
            if type(icon) ~= "string" or icon == "" then return nil end
            if icon:find("/", 1, true) then return icon end
            return "Interface/Icons/" .. icon
        end)
        if path then return path end
    end
    return meta and meta.icon or nil
end

local MenuRowCount = 0

local function AddMenu(player, text, sender, action)
    if MenuRowCount >= GOSSIP_MAX_ROWS then return false end
    MenuRowCount = MenuRowCount + 1
    player:GossipMenuAddItem(0, text, sender, action)
    return true
end

local function Button(player, text, sender, action)
    if MenuRowCount >= GOSSIP_MAX_ROWS then return false end
    MenuRowCount = MenuRowCount + 1
    player:GossipMenuAddItem(7, text, sender, action)
    return true
end

local function Message(player, text)
    if MenuRowCount >= GOSSIP_MAX_ROWS then return false end
    MenuRowCount = MenuRowCount + 1
    AddMenu(player, text, 0, ACT.NOOP)
    return true
end

--===========================================================================
--  Breadcrumbs
--===========================================================================

local CRUMB_ENCHANT = "> "

local function CrumbItem(player, sess, res)
    if not Config.ShowBreadcrumbs then return end
    local ident = ItemIdentity(res.item, sess.slot)
    if sess.crumbItem == ident then return end
    sess.crumbItem = ident
    if not res.item then
        player:SendBroadcastMessage("nothing equipped")
        return
    end
    player:SendBroadcastMessage(ItemNameLinked(res.item)
        .. " (" .. ItemLevelText(res.item) .. ")")
end

local function CrumbEnchant(player, sess, enc)
    if not Config.ShowBreadcrumbs then return end
    if not sess.crumbItem then return end          -- no trail to continue
    local line = (enc.spell and SpellLink(enc.spell))
        or (enc.apply and MatLink(enc.apply))
        or EnchantName(enc)
    player:SendBroadcastMessage(CRUMB_ENCHANT .. line)
end

local function IsCurrent(item, enc)
    if not item or not enc then return false end
    local cur = ItemEnchantId(item)
    return cur ~= nil and cur == enc.eid
end

local function SkillRank(enc)
    local s = enc and enc.skill
    if type(s) == "number" and s > 0 then return s end
    return 0
end

local function SortBySkill(list)
    table.sort(list, function(a, b)
        local ea, eb = Enchants[a], Enchants[b]
        local ka, kb = SkillRank(ea), SkillRank(eb)
        if ka ~= kb then return ka > kb end
        local na, nb = EnchantName(ea), EnchantName(eb)
        if na ~= nb then return na < nb end
        return a < b
    end)
    return list
end

local function Paginate(list, page)
    local size = Config.PageSize
    if size < 4 then size = 4 end
    if size > 20 then size = 20 end
    local pages = math.max(1, math.ceil(#list / size))
    if page > pages then page = pages end
    if page < 1 then page = 1 end
    return (page - 1) * size + 1, math.min(#list, page * size), pages, page
end

local function RowWanted(slotKey, item)
    if not item then return false end
    local inv = ItemInvType(item)
    if not inv then return true end

    local staff = inv == INV.TWOHAND and ItemSubClass(item) == ITEM_SUBCLASS_STAFF

    if slotKey == "weapon2h" then
        return inv == INV.TWOHAND
    elseif slotKey == "staff" then
        return staff
    elseif slotKey == "shield" then
        return inv == INV.SHIELD
    end
    return true
end


--===========================================================================
--  1. slot menu
--===========================================================================

local function MainMenu(player, creature)
    ItemMemo = {}
    MemoGen = MemoGen + 1
    player:GossipClearMenu()
    MenuRowCount = 0
    local sess = GetSession(player)
    sess.view = LVL_MAIN

    local anyGear = false
    for i = 1, #Slots do
        local meta = Slots[i]
        if SlotInBook(meta) then
            local res = Evaluate(player, sess, meta.key)
            local showable = res.item ~= nil and RowWanted(meta.key, res.item)
                and (EraTotal(res, 1) + EraTotal(res, 2) + EraTotal(res, 3)) > 0
            if Config.DebugReview or showable then
                anyGear = true
                local count = #res.ok
                if Config.DebugReview then
                    count = EraTotal(res, 1) + EraTotal(res, 2) + EraTotal(res, 3)
                end
                local what = res.item and ItemNameColoured(res.item) or "nothing"
                AddMenu(player,
                    Icon(ItemIconPath(res.item, meta)) .. meta.label
                        .. " [" .. what .. "] (" .. count .. ")",
                    i, ACT.PICK_SLOT)
            end
        end
    end

    if not anyGear then
        Message(player, "You are not wearing anything I can work on.")
        Message(player, "Equip the piece you want enchanted and speak to me again.")
    end

    player:GossipSendMenu(NPC_ID, creature)
end

--===========================================================================
--  2. era menu
--===========================================================================
local function EraMenu(player, creature)
    ItemMemo = {}
    MemoGen = MemoGen + 1
    local sess = GetSession(player)
    local meta = Slots[sess.slot]
    if not meta then
        MainMenu(player, creature)
        return
    end

    local res = Evaluate(player, sess, meta.key)
    player:GossipClearMenu()
    MenuRowCount = 0
    sess.view = LVL_ERA
    CrumbItem(player, sess, res)

    local listed = 0
    for expId = 1, 3 do
        local b = res.byExp[expId]
        if EraEnabled(EXP_KEY[expId]) and EraTotal(res, expId) > 0 then
            local avail, unavail = #b.available, #b.unavailable
            listed = listed + 1
            if avail > 0 then
                AddMenu(player,
                    EXP_WORD[expId] .. " - " .. avail .. " available",
                    expId * 10 + TIER_AVAILABLE, ACT.PICK_ERA)
            end
            if unavail > 0 then
                AddMenu(player,
                    EXP_WORD[expId] .. " - " .. unavail .. " unavailable",
                    expId * 10 + TIER_UNAVAILABLE, ACT.PICK_ERA)
            end
        end
    end

    if listed == 0 then
        local why = res.blocked and REASON_TEXT[res.blocked]
        Message(player, why or "No formula in my book fits this item.")
    end

    Button(player, "Back", 0, ACT.BACK)
    player:GossipSendMenu(NPC_ID, creature)
end

--===========================================================================
--  3. enchant list
--===========================================================================
local function BuildList(res, expId, tier)
    local b = res.byExp[expId]
    if not b then return {} end
    local src = (tier == TIER_UNAVAILABLE) and b.unavailable or b.available
    local copy = {}
    for i = 1, #src do copy[i] = src[i] end
    return SortBySkill(copy)
end

local function ListMenu(player, creature)
    ItemMemo = {}
    MemoGen = MemoGen + 1
    local sess = GetSession(player)
    local meta = Slots[sess.slot]
    if not meta then
        MainMenu(player, creature)
        return
    end

    local res = Evaluate(player, sess, meta.key)
    local list = BuildList(res, sess.exp, sess.tier)

    local first, last, pages, page = Paginate(list, sess.page or 1)
    sess.page = page

    player:GossipClearMenu()
    MenuRowCount = 0
    sess.view = LVL_LIST
    if #list == 0 then
        Message(player, "Nothing in this list.")
    end

    for n = first, last do
        local idx = list[n]
        local enc = Enchants[idx]
        local current = IsCurrent(res.item, enc) and " (current)" or ""
        AddMenu(player, EnchantRow(enc) .. current, idx, ACT.OPEN)
    end

    if pages > 1 then
        if page > 1 then Button(player, "<< Previous page", 0, ACT.PAGE_PREV) end
        if page < pages then Button(player, "Next page >>", 0, ACT.PAGE_NEXT) end
    end

    Button(player, "Back", 0, ACT.BACK)
    player:GossipSendMenu(NPC_ID, creature)
end

--===========================================================================
--  4. materials
--===========================================================================
local COL_OK   = "|cff008000"
local COL_BAD  = "|cff8b0000"
local COL_OFF  = "|r"

local function Coloured(ok, text)
    return (ok and COL_OK or COL_BAD) .. text .. COL_OFF
end

local function ReqLine(name, value, ok)
    return "  > " .. name .. " (" .. Coloured(ok, value) .. ")"
end

local function MatsMenu(player, creature, idx)
    ItemMemo = {}
    MemoGen = MemoGen + 1
    local sess = GetSession(player)
    local meta = Slots[sess.slot]
    local enc = Enchants[idx]
    if not meta or not enc then
        MainMenu(player, creature)
        return
    end

    local res = Evaluate(player, sess, meta.key)
    player:GossipClearMenu()
    MenuRowCount = 0
    sess.view = LVL_MATS
    sess.chosen = idx

    local fee = FeeFor(enc)
    local enough = true

    -- Each requirement is listed only when it is actually enforced, so the page
    -- never asks for something the NPC is not checking.
    local matLines = {}
    if Config.RequireMaterials then
        for i = 1, #enc.mats do
            local id, need = enc.mats[i][1], enc.mats[i][2]
            local have = CountItem(player, id)
            if have < need then enough = false end
            matLines[#matLines + 1] = ReqLine(MatText(id) or ("item " .. tostring(id)), need, have >= need)
        end
    end

    local ilvlLine = nil
    local need = MinIlvl(enc)
    if need > 0 then
        ilvlLine = ReqLine("ilvl Requirement", tostring(need), IlvlFits(res.item, enc))
    end

    local feeLine = nil
    if fee > 0 then
        feeLine = ReqLine("Enchanter Fee", GoldString(fee), CanAffordFee(player, enc))
    end

    if IsCurrent(res.item, enc) then
         Message(player, EnchantRow(enc) .. "(current)")
    elseif ((enough or not Config.RequireMaterials) and CanAffordFee(player, enc)) or Config.DebugReview then
        local popup = "Enchant " .. ItemNameColoured(res.item) .. "\n\n"
            .. EnchantRow(enc)
        if Config.RequireMaterials then
            popup = popup .. "\n\nThis will consume:\n" .. FormatMats(enc)
        end
        if fee > 0 then
            popup = popup .. "\n\nFee: " .. GoldString(fee)
        end
        popup = popup .. "\n\nContinue?"
        local button = "Apply " .. (EnchantNameColoured(enc) or EnchantName(enc))
        player:GossipMenuAddItem(1, button, idx, ACT.APPLY, nil, popup, fee)
    else
        Message(player, EnchantRow(enc))
    end

    if ilvlLine then Message(player, ilvlLine) end
    for _, line in ipairs(matLines) do Message(player, line) end
    if feeLine then Message(player, feeLine) end

    Button(player, "Back", 0, ACT.BACK)
    player:GossipSendMenu(NPC_ID, creature)
end

-- Redraw whatever the player is looking at.
local function Redraw(player, creature, sess)
    local view = sess.view
    if view == LVL_MATS then
        MatsMenu(player, creature, sess.chosen)
    elseif view == LVL_LIST then
        ListMenu(player, creature)
    elseif view == LVL_ERA then
        EraMenu(player, creature)
    else
        MainMenu(player, creature)
    end
end

--===========================================================================
--  Apply
--===========================================================================

local function TryEnchant(player, creature, idx)
    local enc = Enchants[idx]
    if not enc then
        Whisper(player, "That formula is missing from my book.")
        player:GossipComplete()
        return
    end

    local sess = GetSession(player)

    local meta = Slots[sess.slot]
    local accepts = meta and SLOT_ACCEPTS[meta.key] or {}
    if not meta or not accepts[enc.slot] then
        Whisper(player, "That formula does not belong to this slot.")
        player:GossipComplete()
        return
    end

    -- Re-check everything against the live state. Never trust the menu alone:
    -- the player may have banked a reagent or swapped weapons since, so the
    -- cache is dropped and the whole slot is evaluated again.
    Invalidate(sess)
    local res = Evaluate(player, sess, meta.key)
    if not res.usable[idx] then
        local item = res.item
        local ok, reason, detail = CanUse(player, item, meta.key, enc)
        if ok then
            -- Cannot happen after a fresh pass, but never refuse silently.
            reason, detail = "mats", nil
        end
        local msg = REASON_TEXT[reason] or "I cannot do that."
        if reason == "mats" and detail and detail.missing then
            local parts = {}
            for i = 1, #detail.missing do
                local m = detail.missing[i]
                parts[#parts + 1] = tostring(m[2] - m[3]) .. " more " .. (MatText(m[1]) or ("item " .. tostring(m[1])))
            end
            msg = "You are short reagents: " .. table.concat(parts, ", ") .. "."
        elseif reason == "ilvl" and detail then
            msg = "Your " .. ItemNameColoured(item) .. " is ilvl " .. tostring(detail.ilvl)
                .. ". " .. EnchantName(enc) .. " needs ilvl " .. tostring(detail.need) .. "+."
        end
        Whisper(player, msg)
        player:GossipComplete()
        return
    end

    local item = res.item
    if not item then
        Whisper(player, REASON_TEXT.no_item)
        player:GossipComplete()
        return
    end

    -- The list shows this formula as "(current)" with no Apply button, so
    -- reaching here means a hand-crafted packet. Refuse before any reagent or
    -- coin is touched.
    if IsCurrent(item, enc) then
        Whisper(player, EnchantName(enc) .. " is already on " .. ItemName(item) .. ".")
        ListMenu(player, creature)
        return
    end

    -- The price is worked out once here and refunded as-is, so a config change
    -- mid-application cannot make the refund differ from the charge.
    local fee = FeeFor(enc)
    if not CanAffordFee(player, enc) then
        Whisper(player, REASON_TEXT.gold)
        player:GossipComplete()
        return
    end

    -- Take the fee first so a failed RemoveItem cannot leave the player short.
    if fee > 0 then
        player:ModifyMoney(-fee)
    end

    local paid = {}
    if Config.RequireMaterials then
        for i = 1, #enc.mats do
            local id, n = enc.mats[i][1], enc.mats[i][2]
            local removed = player:RemoveItem(id, n)
            if removed == false then
                -- Put back what we already took and stop.
                for j = 1, #paid do
                    player:AddItem(paid[j][1], paid[j][2])
                end
                if fee > 0 then
                    player:ModifyMoney(fee)
                end
                Whisper(player, "Your bags changed while I was working. Nothing was spent.")
                player:GossipComplete()
                return
            end
            paid[#paid + 1] = { id, n }
        end
    end

    -- Anything that goes wrong from here on has to give the reagents back:
    -- they are already out of the player's bags at this point.
    local function Refund()
        for j = 1, #paid do
            player:AddItem(paid[j][1], paid[j][2])
        end
        if fee > 0 then
            player:ModifyMoney(fee)
        end
    end

    if not ItemIsAlive(item) then
        -- The handle went stale mid-session; try to pick the item up again.
        local eq = ResolveEqSlot(meta.key)
        local fresh = Equipped(player, eq)
        if fresh then
            item = fresh
            MemoGen = MemoGen + 1
        else
            Refund()
            Whisper(player,
                "That item just went out of reach. Nothing was spent - close and reopen the gossip.")
            player:GossipComplete()
            return
        end
    end

    Safe(function() return item:ClearEnchantment(PERM_ENCHANT) end)
    local setOk, applied = Safe(function() return item:SetEnchantment(enc.eid, PERM_ENCHANT) end)
    if not setOk then applied = false end
    if applied == false or applied == nil then
        -- Refund and explain: the core rejected the enchant id.
        Refund()
        Whisper(player, "The formula fizzled. Check that enchant id " ..
            tostring(enc.eid) .. " exists in this core build.")
        player:GossipComplete()
        return
    end

    Safe(function() item:SetBinding(true) end)
    Safe(function() item:SaveToDB() end)

    if Config.VisualSpell and Config.VisualSpell > 0 then
        Safe(function() creature:CastSpell(player, Config.VisualSpell, true) end)
    end

    player:SendNotification(EnchantName(enc) .. " inscribed on " .. ItemName(item) .. ".")
    Whisper(player, "Done. " .. EnchantEffect(enc) .. " on " .. ItemName(item) .. ".")

    -- Refresh the list the player was reading: one formula is now current and
    -- the rest show the shortfalls the purchase left in the bag.
    ItemMemo = {}
    Invalidate(sess)
    ListMenu(player, creature)
end

--===========================================================================
--  Events
--===========================================================================

-- One bad call on a core whose API differs should print a readable error in
-- the console, not leave the player staring at an empty gossip window.
local function Guard(label, fn)
    return function(event, player, creature, ...)
        local ok, err = pcall(fn, event, player, creature, ...)
        if not ok then
            print("[Eluna Enchanter] " .. label .. " error: " .. tostring(err))
            if player then
                player:SendBroadcastMessage(
                    "The enchantress hit a snag - the error is in the worldserver console.")
                pcall(function() player:GossipComplete() end)
            end
        end
    end
end

local BOOK_MISSING = "[Eluna Enchanter] Formula book not found. Put enchants_data.lua "
    .. "in the same folder as enchanter_npc.lua."

local function OnHello(event, player, creature)
    if not EnsureBook() then
        print(BOOK_MISSING)
        player:SendBroadcastMessage("The enchantress cannot find her formula book.")
        player:GossipComplete()
        return
    end
    local sess = GetSession(player)
    Invalidate(sess)
    sess.page = 1
    MainMenu(player, creature)
end

local function OnSelect(event, player, creature, sender, intid, code)
    if not EnsureBook() then
        print(BOOK_MISSING)
        player:GossipComplete()
        return
    end
    local sess = GetSession(player)

    -- The lore rows (the item line, a reagent, the fee) are not buttons: they
    -- redraw the page they are on and print no crumb of their own.
    if intid == ACT.NOOP then
        Redraw(player, creature, sess)
        return
    end

    if intid == ACT.PICK_SLOT then
        sess.slot = sender
        sess.page = 1
        EraMenu(player, creature)
        return
    end

    if intid == ACT.PICK_ERA then
        sess.exp = math.floor(sender / 10)
        sess.tier = sender - sess.exp * 10
        sess.page = 1
        Restart(sess)
        ListMenu(player, creature)
        return
    end

    if intid == ACT.OPEN then
        -- Printed here, not in the menu: a redraw is not a new step, but
        -- picking a formula always is, even the one already open.
        local enc = Enchants[sender]
        if enc then CrumbEnchant(player, sess, enc) end
        MatsMenu(player, creature, sender)
        return
    end

    if intid == ACT.PAGE_NEXT or intid == ACT.PAGE_PREV then
        local step = (intid == ACT.PAGE_NEXT) and 1 or -1
        sess.page = math.max(1, (sess.page or 1) + step)
        Restart(sess)
        ListMenu(player, creature)
        return
    end

    if intid == ACT.BACK then
        Restart(sess)
        if sess.view == LVL_MATS then
            ListMenu(player, creature)
        elseif sess.view == LVL_LIST then
            EraMenu(player, creature)
        else
            MainMenu(player, creature)
        end
        return
    end

    if intid == ACT.APPLY then
        TryEnchant(player, creature, sender)
        return
    end

    MainMenu(player, creature)
end

local function OnLogin(event, player)
    if Config.AnnounceLogin then
        player:SendBroadcastMessage(
            "This realm is running the Eluna Enchanter NPC. Reagents and "
            .. "item-level rules apply.")
    end
end

local function OnLogout(event, player)
    Session[Sid(player)] = nil
end

RegisterCreatureGossipEvent(NPC_ID, 1, Guard("hello", OnHello))
RegisterCreatureGossipEvent(NPC_ID, 2, Guard("select", OnSelect))
RegisterPlayerEvent(3, OnLogin)
RegisterPlayerEvent(4, OnLogout)

if bookLoaded then
    print("[Eluna Enchanter] NPC " .. NPC_ID .. " loaded with "
        .. tostring(#Enchants) .. " formulas from " .. DATA_FILE .. ".")
else
    print("[Eluna Enchanter] NPC " .. NPC_ID .. " loaded, but " .. DATA_FILE
        .. " was not found yet - it will be picked up on the first gossip.")
end
