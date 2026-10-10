-- Wishwell: a loot database for WoW Forever with a personal wishlist and a
-- character preview. Browse what drops anywhere, try it on, mark what you want, and get
-- told when it drops. Works solo at any level.
--
-- Separate from the Raid Night addons: no shared saved settings, window names or messages.

local PREFIX = "Wishwell" -- addon message prefix (16 characters at most)
local ROWS = 9
local ROW_H = 40
local LEARN_MAX = 800   -- remembered drops per raid or dungeon
local MADE_UP_MAX = 40  -- raids and dungeons added in game
local WISH_MAX = 200
local SEARCH_MAX = 300

local Data = WishwellData or { instances = {}, items = {} }
local db
local frame
local playerClass

-- This version, and what is new in it: shown once after an update, and by /ww news.
-- Keep it to short lines; the first five go in the pop-up. Update both with every release.
local VERSION = "1.2.0"
local NEWS = {
  "Ask Wisp how the game works: \"how does mount speed work?\"",
  "Pin recipe on your profession window keeps its materials on screen",
  "Settings: window size, wishlist drop alert, Tell my group",
  "Settings are in four sections, so nothing needs scrolling",
  "A one-hander against your two-hander says it is half of a pair",
  "No answer from Wisp? A Send button tells the author what you asked",
}

local function Print(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100Wishwell:|r " .. tostring(msg))
end

-- Newer clients can hand back hidden ("secret") values that addons may not read.
-- Treat those as missing instead of erroring.
local function Plain(value)
  if issecretvalue and issecretvalue(value) then return nil end
  return value
end

local function Now()
  return GetTime and GetTime() or 0
end

local function After(seconds, fn)
  if C_Timer and C_Timer.After then C_Timer.After(seconds, fn) else fn() end
end

-- ---------------------------------------------------------------------------
-- Raids and dungeons

local Places = {}
do
  local index

  function Places.Known(id)
    if not index then
      index = {}
      for _, row in ipairs(Data.instances) do index[row.id] = row end
    end
    return id ~= nil and index[id] ~= nil
  end

  function Places.Row(id)
    if Places.Known(id) then return index[id] end
    return nil
  end

  function Places.Name(id)
    local row = Places.Row(id)
    return row and row.name or tostring(id)
  end

  local byMap

  -- The shipped raid or dungeon with this instance number (the game's own id for it), or nil.
  -- Names are no good for this: the game says "Coilfang: The Underbog", not "The Underbog".
  function Places.ByMap(mapId)
    if not byMap then
      byMap = {}
      for _, row in ipairs(Data.instances) do
        for _, id in ipairs(row.maps or {}) do byMap[id] = row.id end
      end
    end
    return type(mapId) == "number" and byMap[mapId] or nil
  end

  local heroicPlaces

  -- True for a dungeon that has a heroic version with its own drops.
  function Places.HasHeroic(id)
    if not heroicPlaces then
      heroicPlaces = {}
      for _, item in ipairs(Data.items) do
        if item.heroic then heroicPlaces[item.raid] = true end
      end
    end
    return heroicPlaces[id] == true
  end

  -- "Heroic: The Mechanar" for the heroic version, the plain name otherwise.
  function Places.Label(id, heroic)
    return (heroic and Places.HasHeroic(id) and "Heroic: " or "") .. Places.Name(id)
  end

  -- A raid or dungeon the addon was not shipped with, added on the spot.
  function Places.Add(id, name, kind)
    if not db or Places.Known(id) then return false end
    if type(db.madeUp) ~= "table" then db.madeUp = {} end
    local n = 0
    for _ in pairs(db.madeUp) do n = n + 1 end
    if n >= MADE_UP_MAX then return false end
    db.madeUp[id] = { name = name, kind = kind }
    tinsert(Data.instances, { id = id, name = name, kind = kind, madeUp = true })
    index = nil
    return true
  end
end

-- Names come from the game or from other players, so keep them short and free of
-- anything that could break a chat line or an addon message.
local function CleanLabel(text)
  text = Plain(text)
  if type(text) ~= "string" then return nil end
  local plain = gsub(text, "[|:%c]", " ")
  plain = strtrim((gsub(plain, "%s+", " ")))
  if plain == "" then return nil end
  if #plain > 40 then
    plain = strsub(plain, 1, 40)
    -- Don't leave half of a multi-byte letter at the cut.
    plain = strtrim((gsub(plain, "[\192-\255][\128-\191]*$", "")))
    if plain == "" then return nil end
  end
  return plain
end

-- ---------------------------------------------------------------------------
-- Items: the shipped list, plus anything seen dropping in game.
-- db.learned[placeId][itemId] = boss name

local Items = {}
do
  local byId
  local version = 0 -- goes up whenever the learned list changes
  local placeCache = {}

  local function Index()
    if not byId then
      byId = {}
      for _, item in ipairs(Data.items) do
        if byId[item.id] == nil then byId[item.id] = item end
      end
    end
    return byId
  end

  function Items.Shipped(id)
    return Index()[id]
  end

  local shippedAt

  -- True if the shipped list already has this item for this raid or dungeon.
  function Items.IsShippedAt(placeId, id)
    if not shippedAt then
      shippedAt = {}
      for _, item in ipairs(Data.items) do shippedAt[tostring(item.raid) .. ":" .. item.id] = true end
    end
    return shippedAt[tostring(placeId) .. ":" .. id] == true
  end

  function Items.Learned(placeId)
    if not db or type(db.learned) ~= "table" then return nil end
    local list = db.learned[placeId]
    return type(list) == "table" and list or nil
  end

  -- Remembers that an item dropped. Returns true if it was new.
  function Items.Remember(placeId, id, boss)
    if not db or not Places.Known(placeId) then return false end
    id = tonumber(id)
    if not id or id <= 0 or id >= 100000000 or id ~= math.floor(id) then return false end
    if type(db.learned) ~= "table" then db.learned = {} end
    local list = db.learned[placeId]
    if type(list) ~= "table" then
      list = {}
      db.learned[placeId] = list
    end
    if list[id] then return false end
    local n = 0
    for _ in pairs(list) do n = n + 1 end
    if n >= LEARN_MAX then return false end
    list[id] = CleanLabel(boss) or "Trash"
    version = version + 1
    return true
  end

  function Items.RequestLoad(id)
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
  end

  -- Name for any item id: the shipped list first, then the game's item cache.
  function Items.Name(id)
    local item = Index()[id]
    if item and item.name then return item.name end
    local name
    if C_Item and C_Item.GetItemNameByID then name = Plain(C_Item.GetItemNameByID(id)) end
    if type(name) ~= "string" or name == "" then
      -- A second way to ask; some items only answer to this one.
      local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
      if info then
        local ok, found = pcall(info, id)
        name = ok and Plain(found) or nil
      end
    end
    if type(name) ~= "string" or name == "" then
      Items.RequestLoad(id)
      return nil
    end
    return name
  end

  function Items.Icon(id)
    local tex
    if C_Item and C_Item.GetItemIconByID then tex = Plain(C_Item.GetItemIconByID(id)) end
    if not tex and GetItemIcon then tex = Plain(GetItemIcon(id)) end
    return tex or "Interface\\Icons\\INV_Misc_QuestionMark"
  end

  -- Equip slot and item type straight from the game.
  function Items.Facts(id)
    local fn = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not fn then return nil end
    local ok, _, _, _, equipLoc, _, classID, subclassID = pcall(fn, id)
    if not ok then return nil end
    return Plain(equipLoc), Plain(classID), Plain(subclassID)
  end

  -- Every item for one raid or dungeon: the shipped list, then anything seen dropping.
  function Items.ForPlace(placeId)
    local cached = placeCache[placeId]
    if cached and cached.version == version then return cached.list end
    local list, have = {}, {}
    for _, item in ipairs(Data.items) do
      if item.raid == placeId then
        tinsert(list, item)
        have[item.id] = true
      end
    end
    local learned = Items.Learned(placeId)
    if learned then
      local extra = {}
      for id, boss in pairs(learned) do
        if type(id) == "number" and type(boss) == "string" and not have[id] then
          tinsert(extra, { id = id, boss = boss, raid = placeId, learned = true })
        end
      end
      table.sort(extra, function(a, b)
        if a.boss ~= b.boss then return a.boss < b.boss end
        return a.id < b.id
      end)
      for _, row in ipairs(extra) do tinsert(list, row) end
    end
    placeCache[placeId] = { version = version, list = list }
    return list
  end

  -- True if an item drops on the difficulty asked for: heroic true or false, or nil for
  -- either. Normal and heroic dungeons have their own lists, with a few drops on both.
  function Items.InDiff(item, heroic)
    if heroic == nil then return true end
    if heroic then return not item.normalOnly end
    return not item.heroic
  end

  -- Asks the game for every item in a raid or dungeon now, so names, colours and stats are
  -- ready before the list or the pop-up needs them. Returns how many were not loaded yet.
  function Items.Preload(placeId, heroic)
    local asked = 0
    for _, item in ipairs(Items.ForPlace(placeId)) do
      if Items.InDiff(item, heroic) then
        local cached = true
        if C_Item and C_Item.IsItemDataCachedByID then cached = Plain(C_Item.IsItemDataCachedByID(item.id)) == true end
        if not cached then
          Items.RequestLoad(item.id)
          asked = asked + 1
        end
      end
    end
    return asked
  end

  -- Loads the loot of every raid and dungeon in the background after logging in, a few
  -- items at a time so the game never stutters, and not during a fight. The game keeps what
  -- it has loaded between sessions, so after the first time there is little left to ask for.
  local BATCH, EVERY = 15, 0.5
  local queue, queued = nil, 0

  local function LoadSome()
    if not queue then return end
    if db and db.preload == false then
      queue = nil
      return
    end
    if not (InCombatLockdown and InCombatLockdown()) then
      local asked = 0
      while asked < BATCH and #queue > 0 do
        local id = tremove(queue)
        local cached = C_Item and C_Item.IsItemDataCachedByID and Plain(C_Item.IsItemDataCachedByID(id)) == true
        if not cached then
          Items.RequestLoad(id)
          asked = asked + 1
        end
      end
    end
    if #queue == 0 then
      queue = nil
      return
    end
    After(EVERY, LoadSome)
  end

  -- Starts the background load. Returns how many items were lined up.
  function Items.PreloadAll()
    if queue or (db and db.preload == false) then return 0 end
    if not (C_Item and C_Item.IsItemDataCachedByID) then return 0 end
    local want, list = {}, {}
    for _, place in ipairs(Data.instances) do want[place.id] = true end
    for _, item in ipairs(Data.items) do
      if want[item.raid] and Plain(C_Item.IsItemDataCachedByID(item.id)) ~= true then tinsert(list, item.id) end
    end
    queued = #list
    if queued == 0 then return 0 end
    queue = list
    After(EVERY, LoadSome)
    return queued
  end

  -- How many items the background load still has to ask for, and how many it started with.
  function Items.PreloadLeft()
    return queue and #queue or 0, queued
  end

  -- A row for an item id that may or may not be in any list (wishlist entries, links).
  function Items.Row(id, placeId)
    if placeId and placeId ~= "" then
      for _, item in ipairs(Items.ForPlace(placeId)) do
        if item.id == id then return item end
      end
    end
    return Index()[id] or { id = id, boss = "Added by link", raid = "", custom = true }
  end

  local EQUIP_SLOT = {
    INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulder", INVTYPE_CLOAK = "Back",
    INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest", INVTYPE_WRIST = "Wrist", INVTYPE_HAND = "Hands",
    INVTYPE_WAIST = "Waist", INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet", INVTYPE_FINGER = "Finger",
    INVTYPE_TRINKET = "Trinket", INVTYPE_WEAPON = "One-Hand", INVTYPE_2HWEAPON = "Two-Hand",
    INVTYPE_WEAPONMAINHAND = "Main Hand", INVTYPE_WEAPONOFFHAND = "Off-hand", INVTYPE_HOLDABLE = "Off-hand",
    INVTYPE_SHIELD = "Shield", INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged",
    INVTYPE_THROWN = "Thrown", INVTYPE_RELIC = "Relic", INVTYPE_BAG = "Bag", INVTYPE_BODY = "Shirt",
    INVTYPE_TABARD = "Tabard",
  }

  function Items.Slot(item)
    if item.slot then return item.slot end
    local equipLoc = Items.Facts(item.id)
    return (equipLoc and EQUIP_SLOT[equipLoc]) or "Item"
  end

  -- How often an item drops.
  --   classic: the Classic Era drop chance in percent, or nil
  --   seen, kills: how many of the boss kills this account has watched dropped it
  --   chance: the best single number to plan with (0..1), or nil if there is nothing to go on.
  --           Our own count takes over from the Classic rate once it has ten kills behind it.
  function Items.Rate(item)
    local out = { classic = item.rate }
    local placeId, boss = item.raid, item.boss
    local learned = placeId and Items.Learned(placeId)
    if learned and learned[item.id] then boss = learned[item.id] end
    local kills = db and type(db.kills) == "table" and type(db.kills[placeId]) == "table" and db.kills[placeId][boss] or 0
    local seen = db and type(db.seen) == "table" and type(db.seen[placeId]) == "table" and db.seen[placeId][item.id] or 0
    if type(kills) == "number" and kills > 0 then
      out.kills = kills
      out.seen = math.min(type(seen) == "number" and seen or 0, kills)
    end
    if out.kills and out.kills >= 10 then
      out.chance = out.seen / out.kills
    elseif out.classic then
      out.chance = out.classic / 100
    elseif out.kills and out.seen > 0 then
      out.chance = out.seen / out.kills
    end
    if out.chance and out.chance <= 0 then out.chance = nil end
    return out
  end

  -- "about 6 runs", from a chance between 0 and 1.
  function Items.Runs(chance)
    local runs = math.floor(1 / chance + 0.5)
    if runs <= 1 then return "about 1 run" end
    return "about " .. runs .. " runs"
  end

  -- Short drop-chance text for a row: "15.7%" or "seen 2 of 9 kills".
  function Items.RateText(item)
    local rate = Items.Rate(item)
    if rate.kills and rate.kills >= 10 then return "seen " .. rate.seen .. " of " .. rate.kills .. " kills" end
    if rate.classic then return (rate.classic >= 10 and format("%d", math.floor(rate.classic + 0.5)) or format("%.1f", rate.classic)) .. "%" end
    if rate.kills then return "seen " .. rate.seen .. " of " .. rate.kills .. " kills" end
    return nil
  end

  -- The small line under an item name: slot, boss, and how sure we are that it drops there.
  -- plainDiff: the list is already one difficulty, so don't repeat it on every row.
  function Items.Meta(item, withPlace, plainDiff)
    local text = Items.Slot(item) .. " · " .. (item.boss or "Unknown")
    local chance = Items.RateText(item)
    if chance then text = text .. " · " .. chance end
    if withPlace and item.raid and item.raid ~= "" then text = Places.Name(item.raid) .. " · " .. text end
    if item.learned then return text .. " · Seen dropping" end
    if item.standin then
      local learned = Items.Learned(item.raid)
      if learned and learned[item.id] then return text .. " · Seen dropping" end
      return text .. " · Classic loot, not confirmed"
    end
    if plainDiff then return text end
    if item.heroic then return text .. " · Heroic only" end
    if item.normalOnly then return text .. " · Normal only" end
    return text
  end

  -- Which classes can wear or wield each kind of gear. Cloth and cloaks are open to everyone.
  local ARMOR_CLASSES = {
    [2] = "WARRIOR,PALADIN,HUNTER,ROGUE,SHAMAN,DRUID", -- leather
    [3] = "WARRIOR,PALADIN,HUNTER,SHAMAN", -- mail
    [4] = "WARRIOR,PALADIN", -- plate
    [6] = "WARRIOR,PALADIN,SHAMAN", -- shields
    [7] = "PALADIN", -- librams
    [8] = "DRUID", -- idols
    [9] = "SHAMAN", -- totems
  }
  local WEAPON_CLASSES = {
    [0] = "WARRIOR,PALADIN,HUNTER,ROGUE,SHAMAN", -- one-handed axes
    [1] = "WARRIOR,PALADIN,HUNTER,SHAMAN", -- two-handed axes
    [2] = "WARRIOR,HUNTER,ROGUE", -- bows
    [3] = "WARRIOR,HUNTER,ROGUE", -- guns
    [4] = "WARRIOR,PALADIN,ROGUE,PRIEST,SHAMAN,DRUID", -- one-handed maces
    [5] = "WARRIOR,PALADIN,SHAMAN,DRUID", -- two-handed maces
    [6] = "WARRIOR,PALADIN,HUNTER,DRUID", -- polearms
    [7] = "WARRIOR,PALADIN,HUNTER,ROGUE,MAGE,WARLOCK", -- one-handed swords
    [8] = "WARRIOR,PALADIN,HUNTER", -- two-handed swords
    [10] = "WARRIOR,HUNTER,PRIEST,SHAMAN,MAGE,WARLOCK,DRUID", -- staves
    [13] = "WARRIOR,HUNTER,ROGUE,SHAMAN,DRUID", -- fist weapons
    [15] = "WARRIOR,HUNTER,ROGUE,PRIEST,SHAMAN,MAGE,WARLOCK,DRUID", -- daggers
    [16] = "WARRIOR,HUNTER,ROGUE", -- thrown
    [18] = "WARRIOR,HUNTER,ROGUE", -- crossbows
    [19] = "PRIEST,MAGE,WARLOCK", -- wands
  }

  -- The text before the list in "Classes: Mage, Priest" / "Races: Dwarf", in the game's language.
  local function ListPrefix(fmt)
    if type(fmt) ~= "string" then return nil end
    local prefix = strmatch(fmt, "^(.-)%%s")
    if not prefix or prefix == "" then return nil end
    return prefix
  end

  -- The class's name as tooltips write it, in the game's language.
  local function ClassName(classFile)
    if classFile == playerClass then return Plain((UnitClass("player"))) end
    local names = LOCALIZED_CLASS_NAMES_MALE
    if type(names) == "table" and names[classFile] then return names[classFile] end
    return strsub(classFile, 1, 1) .. strlower(strsub(classFile, 2))
  end

  -- false if the tooltip limits the item to classes (or, for your own class, races) that
  -- do not include this one. nil if the tooltip is not available yet.
  -- The lines of an item's tooltip as plain text, or nil if they cannot be read yet. Newer
  -- versions of the game hand them over directly; older ones need a hidden tooltip to read.
  local scanner
  local function TooltipLines(id)
    if C_TooltipInfo and C_TooltipInfo.GetItemByID then
      local ok, data = pcall(C_TooltipInfo.GetItemByID, id)
      if not ok or type(data) ~= "table" or type(data.lines) ~= "table" or #data.lines == 0 then return nil end
      local lines = {}
      for _, line in ipairs(data.lines) do
        local text = type(line) == "table" and Plain(line.leftText) or nil
        if type(text) == "string" then tinsert(lines, text) end
      end
      return lines
    end
    if scanner == nil then
      local ok, made = pcall(CreateFrame, "GameTooltip", "WishwellScanTip", nil, "GameTooltipTemplate")
      scanner = ok and type(made) == "table" and made or false
    end
    if not scanner or not scanner.SetHyperlink then return nil end
    scanner:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
    scanner:ClearLines()
    if not pcall(scanner.SetHyperlink, scanner, "item:" .. id) then return nil end
    local count = tonumber((scanner:NumLines())) or 0
    if count == 0 then return nil end
    local lines = {}
    for i = 1, count do
      local left = _G["WishwellScanTipTextLeft" .. i]
      local text = type(left) == "table" and left.GetText and Plain(left:GetText()) or nil
      if type(text) == "string" then tinsert(lines, text) end
    end
    return lines
  end

  local function TooltipAllows(id, classFile)
    local lines = TooltipLines(id)
    if not lines then return nil end
    local classPrefix = ListPrefix(ITEM_CLASSES_ALLOWED)
    local racePrefix = ListPrefix(ITEM_RACES_ALLOWED)
    local className = ClassName(classFile)
    local raceName = (classFile == playerClass and UnitRace) and Plain((UnitRace("player"))) or nil
    for _, text in ipairs(lines) do
      do
        if classPrefix and className and strsub(text, 1, #classPrefix) == classPrefix then
          if not strfind(text, className, #classPrefix + 1, true) then return false end
        elseif racePrefix and raceName and strsub(text, 1, #racePrefix) == racePrefix then
          if not strfind(text, raceName, #racePrefix + 1, true) then return false end
        end
      end
    end
    return true
  end

  local fitsCache = {}

  -- True if a class can use the item: faction, armor and weapon type, then any "Classes:"
  -- or "Races:" line on the tooltip. Unknown items are shown, not hidden.
  -- classFile is e.g. "MAGE"; leave it out for this character's own class.
  function Items.Fits(item, classFile)
    classFile = classFile or playerClass
    if item.faction and UnitFactionGroup then
      local side = Plain((UnitFactionGroup("player")))
      if side and side ~= item.faction then return false end
    end
    if not classFile then return true end
    local id = item.id
    local cacheKey = classFile .. id
    local cached = fitsCache[cacheKey]
    if cached ~= nil then return cached end
    local result, final = true, true
    local equipLoc, classID, subclassID = Items.Facts(id)
    if classID == nil then final = false end
    local allowed
    if classID == 4 and equipLoc ~= "INVTYPE_CLOAK" then
      allowed = ARMOR_CLASSES[subclassID]
    elseif classID == 2 then
      allowed = WEAPON_CLASSES[subclassID]
    end
    if allowed and not strfind("," .. allowed .. ",", "," .. classFile .. ",", 1, true) then
      result = false
    end
    if result then
      local loaded = true
      if C_Item and C_Item.IsItemDataCachedByID then
        loaded = Plain(C_Item.IsItemDataCachedByID(id)) == true
      end
      if loaded then
        local tip = TooltipAllows(id, classFile)
        if tip == false then result = false elseif tip == nil then final = false end
      else
        Items.RequestLoad(id)
        final = false
      end
    end
    if final then fitsCache[cacheKey] = result end
    return result
  end

  -- Rarity as the game numbers it (2 uncommon, 3 rare, 4 epic, 5 legendary), or nil if the
  -- game has not loaded the item yet.
  function Items.Quality(item)
    if item.q then return item.q end
    local quality
    if C_Item and C_Item.GetItemQualityByID then quality = Plain(C_Item.GetItemQualityByID(item.id)) end
    if type(quality) ~= "number" then
      Items.RequestLoad(item.id)
      return nil
    end
    return quality
  end

  local QUALITY_RGB = {
    [0] = { 0.62, 0.62, 0.62 }, [1] = { 1, 1, 1 }, [2] = { 0.12, 1, 0 },
    [3] = { 0, 0.44, 0.87 }, [4] = { 0.64, 0.21, 0.93 }, [5] = { 1, 0.5, 0 },
  }

  -- The game's own colour for a rarity (white if unknown).
  function Items.QualityColor(quality)
    local c = type(ITEM_QUALITY_COLORS) == "table" and quality and ITEM_QUALITY_COLORS[quality]
    if type(c) == "table" and c.r then return c.r, c.g, c.b end
    local rgb = QUALITY_RGB[quality or 1] or QUALITY_RGB[1]
    return rgb[1], rgb[2], rgb[3]
  end
end

-- ---------------------------------------------------------------------------
-- Item sets: tier sets, dungeon sets, PvP sets and the new WoW Forever sets.
-- Each has { id, name, items = { piece ids }, pieces = { names, when ids are missing }, bonus }.

local Sets = {}
do
  -- The set's piece item ids. Shipped where known; otherwise the game is asked once.
  function Sets.Items(set)
    if #set.items == 0 and not set.asked then
      set.asked = true
      if C_LootJournal and C_LootJournal.GetItemSetItems then
        local ok, list = pcall(C_LootJournal.GetItemSetItems, set.id)
        if ok and type(list) == "table" then
          for _, entry in ipairs(list) do
            local id = type(entry) == "table" and Plain(entry.itemID) or nil
            if type(id) == "number" then tinsert(set.items, id) end
          end
        end
      end
    end
    return set.items
  end

  function Sets.Size(set)
    return math.max(#set.items, set.pieces and #set.pieces or 0)
  end

  -- The kinds of armor a class goes looking for sets in (1 cloth, 2 leather, 3 mail, 4 plate).
  -- A warrior can put a cloth robe on, but a cloth set is not a warrior's set.
  local SET_ARMOR = {
    WARRIOR = { [4] = true, [3] = true }, PALADIN = { [4] = true, [3] = true },
    HUNTER = { [3] = true, [2] = true }, SHAMAN = { [3] = true, [2] = true },
    ROGUE = { [2] = true }, DRUID = { [2] = true },
    PRIEST = { [1] = true }, MAGE = { [1] = true }, WARLOCK = { [1] = true },
  }

  -- True if the set is one for this class: the right kind of armor, and no piece that says
  -- it is for other classes only. A set with no armor in it (rings, trinkets, weapons) goes
  -- by its pieces' class lines alone.
  function Sets.Fits(set, classFile)
    classFile = classFile or playerClass
    local ids = Sets.Items(set)
    if #ids == 0 or not classFile then return true end
    local kinds = SET_ARMOR[classFile]
    for _, id in ipairs(ids) do
      local equipLoc, classID, subclassID = Items.Facts(id)
      if kinds and classID == 4 and equipLoc ~= "INVTYPE_CLOAK" and type(subclassID) == "number" and subclassID >= 1 and subclassID <= 4
        and not kinds[subclassID] then
        return false
      end
    end
    -- A class line ("Classes: Priest") is the same on every piece, so one piece is enough.
    return Items.Fits({ id = ids[1] }, classFile)
  end
end

-- ---------------------------------------------------------------------------
-- Gear comparison: how an item's stats differ from what the character is wearing in that
-- slot, and whether that looks like an upgrade.
--
-- The stat differences are exact (they are the game's own numbers). The "upgrade" verdict
-- is a rule of thumb: each class has a short list of how much it values each stat, and the
-- item with the higher total wins. It is a guide, not a simulation.

local Compare = {}
do
  local gearVersion = 0
  local cache = {} -- [itemId] = { version, result }

  local SLOTS = {
    INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_2HWEAPON = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_SHIELD = { 17 }, INVTYPE_HOLDABLE = { 17 },
    INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
  }

  -- Which kind of stat a game stat key is, e.g. ITEM_MOD_STAMINA_SHORT -> "sta".
  local KINDS = {
    { "STAMINA", "sta" }, { "INTELLECT", "int" }, { "AGILITY", "agi" }, { "STRENGTH", "str" }, { "SPIRIT", "spi" },
    { "RANGED_ATTACK_POWER", "ap" }, { "ATTACK_POWER", "ap" }, { "SPELL_HEALING", "heal" }, { "HEALING", "heal" },
    { "SPELL_POWER", "sp" }, { "SPELL_DAMAGE", "sp" },
    -- TBC has separate ratings for spells; they do nothing for a melee build.
    { "CRIT_SPELL", "scrit" }, { "HIT_SPELL", "shit" }, { "HASTE_SPELL", "shaste" },
    { "CRIT", "crit" }, { "HIT", "hit" },
    { "MANA_REGEN", "mp5" }, { "POWER_REGEN", "mp5" }, { "DAMAGE_PER_SECOND", "dps" }, { "RESISTANCE0", "armor" },
    { "DEFENSE", "def" }, { "DODGE", "avoid" }, { "PARRY", "avoid" }, { "BLOCK", "avoid" },
    { "HASTE", "haste" }, { "EXPERTISE", "exp" }, { "ARMOR_PENETRATION", "arp" }, { "RESILIENCE", "resil" },
  }
  local function Kind(key)
    for _, pair in ipairs(KINDS) do
      if strfind(key, pair[1], 1, true) then return pair[2] end
    end
    return nil
  end

  -- How much each class values one point of each kind of stat. Rough on purpose.
  local WEIGHTS = {
    WARRIOR = { str = 1, agi = 0.6, sta = 0.7, ap = 0.5, crit = 1, hit = 1, dps = 3, armor = 0.02, def = 0.6, avoid = 0.6 },
    PALADIN = { str = 0.8, sta = 0.7, int = 0.6, sp = 0.6, heal = 0.5, ap = 0.4, crit = 0.8, hit = 0.8, dps = 2, armor = 0.02, def = 0.5, mp5 = 1.5 },
    HUNTER = { agi = 1, sta = 0.5, int = 0.3, ap = 0.5, crit = 1, hit = 1, dps = 2, armor = 0.01 },
    ROGUE = { agi = 1, str = 0.5, sta = 0.5, ap = 0.5, crit = 1, hit = 1, dps = 3, armor = 0.01 },
    PRIEST = { int = 1, spi = 0.8, sta = 0.5, sp = 1, heal = 0.8, crit = 0.7, mp5 = 2, armor = 0.005 },
    SHAMAN = { int = 0.8, sta = 0.6, agi = 0.5, str = 0.5, sp = 0.8, heal = 0.6, ap = 0.4, crit = 0.8, hit = 0.8, mp5 = 1.5, dps = 1.5, armor = 0.01 },
    MAGE = { int = 1, sta = 0.5, spi = 0.4, sp = 1, crit = 1, hit = 1, mp5 = 1.5, armor = 0.005 },
    WARLOCK = { sta = 0.8, int = 0.9, spi = 0.3, sp = 1, crit = 0.9, hit = 1, armor = 0.005 },
    DRUID = { int = 0.7, sta = 0.7, agi = 0.7, str = 0.6, spi = 0.5, sp = 0.7, heal = 0.6, ap = 0.4, crit = 0.8, mp5 = 1.5, armor = 0.015 },
  }

  -- Stat priority for every talent build, most important first, as the Icy Veins TBC Classic
  -- guides give it (icy-veins.com/tbc-classic). The keys are the build keys in DataTalents.lua.
  -- Two stats in one { } share a place. caster: spell hit, crit and haste are the ones meant.
  -- dps: what a point of weapon damage is worth (weapon damage is not on those lists).
  -- The lists say nothing of hit or expertise caps, so neither does Wishwell.
  local function Order(caster, dps, ...)
    return { caster = caster, dps = dps, order = { ... } }
  end
  local ROGUE = Order(false, 3, "exp", "hit", "agi", "haste", "crit", "arp", { "ap", "str" })
  local HUNTER = Order(false, 2, "hit", "arp", "agi", "ap", "crit")
  local FURY = Order(false, 3, "hit", "exp", "crit", "arp", { "str", "ap" }, "agi", "haste")
  local MAGE = Order(true, 0, "hit", "sp", "haste", "crit", "int", "sta", { "spi", "mp5" })
  local WARLOCK = Order(true, 0, "hit", "haste", "sp", "crit", "int", "sta", "spi")
  local SPEC_ORDER = {
    DRUID = {
      balance = Order(true, 0, "hit", "sp", "haste", "crit", "int", "spi", "mp5", "sta"),
      cat = Order(false, 0, "agi", "hit", "exp", "str", "crit", "haste", "ap", "arp", { "sta", "int", "spi", "mp5" }),
      bear = Order(false, 0, "exp", "agi", "sta", "hit", "str", "crit", "haste", "avoid", "def", "ap", "resil", "armor", "arp"),
      resto = Order(true, 0, "heal", "haste", "spi", "mp5", "int", "crit", "sta"),
    },
    HUNTER = { bm = HUNTER, mm = HUNTER, sv = Order(false, 2, "agi", "crit", "hit", "arp", "ap") },
    MAGE = { arcane = Order(true, 0, "hit", { "int", "sp" }, "haste", "crit", "spi", "sta", "mp5"), fire = MAGE, frost = MAGE },
    PALADIN = {
      holy = Order(true, 0, "heal", "mp5", "crit", "int", "haste"),
      prot = Order(false, 1, "def", "avoid", "sta", "sp", "hit", "exp"),
      ret = Order(false, 3, "hit", "exp", "str", "ap", "haste", "arp", { "agi", "crit" }),
    },
    PRIEST = {
      holy = Order(true, 0, "haste", "heal", "crit", "spi", "int", "mp5", "sta"),
      shadow = Order(true, 0, "hit", "sp", "haste", "crit", "int", "spi", "mp5", "sta"),
    },
    ROGUE = { combat = ROGUE, maces = ROGUE, mutilate = ROGUE },
    SHAMAN = {
      ele = Order(true, 0, "hit", "haste", "sp", "crit", "int", "mp5", "sta", "spi"),
      enh = Order(false, 3, "exp", { "str", "ap" }, "hit", "haste", "crit", "agi", "arp", "int", "sta", "mp5", "spi"),
      resto = Order(true, 0, "heal", "haste", "mp5", "crit", "int", "sta", "spi"),
    },
    WARLOCK = { aff = Order(true, 0, "hit", "haste", "sp", "int", "sta", "spi", "crit"), demo = WARLOCK, destro = WARLOCK },
    WARRIOR = {
      arms = FURY,
      fury = FURY,
      prot = Order(false, 1.5, "sta", "armor", "def", "resil", "agi", "avoid", "exp", "hit", "crit", "haste", { "str", "ap" }),
    },
  }

  -- What a place on the list is worth: 1 for the first, a little less each step down.
  local PLACE = { 1, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3 }
  -- Some stats come in bigger or smaller numbers for the same room on an item, so one point
  -- of them is worth more or less: 2 attack power costs what 1 strength does, and so on.
  local PER_POINT = { ap = 0.5, sp = 0.85, heal = 0.45, mp5 = 2.5, arp = 0.15, armor = 0.02 }

  -- A build's list worked out as numbers: weights[kind] and place[kind].
  local worked = {}
  local function Work(spec)
    if worked[spec] then return worked[spec] end
    local weights, place = {}, {}
    for at, entry in ipairs(spec.order) do
      for _, kind in ipairs(type(entry) == "table" and entry or { entry }) do
        weights[kind] = (PLACE[at] or 0.2) * (PER_POINT[kind] or 1)
        place[kind] = at
      end
    end
    if spec.dps > 0 then weights.dps = spec.dps end
    -- Spell hit, crit and haste are their own ratings in TBC.
    for spell, plain in pairs({ scrit = "crit", shit = "hit", shaste = "haste" }) do
      weights[spell] = spec.caster and weights[plain] or 0
      place[spell] = spec.caster and place[plain] or nil
    end
    weights.place = place
    worked[spec] = weights
    return weights
  end

  -- Set by the Talents code further down: the key and name of the build the character is
  -- playing, or nil if it has not got one yet.
  Compare.Spec = function() return nil end
  local specKnown, specKey, specName = false, nil, nil

  -- The stat values to judge gear by, and the build's name if they are for one build.
  local function Weights()
    if not specKnown then
      specKnown = true
      specKey, specName = Compare.Spec()
    end
    local bySpec = SPEC_ORDER[playerClass]
    if bySpec and specKey and bySpec[specKey] then return Work(bySpec[specKey]), specName end
    return WEIGHTS[playerClass], nil
  end

  -- What one point of a kind of stat is worth. A spell rating counts like the plain one
  -- unless the build says otherwise.
  local SPELL_KIND = { scrit = "crit", shit = "hit", shaste = "haste" }
  local function Worth(weights, kind)
    if not kind then return 0 end
    local value = weights[kind]
    if value == nil and SPELL_KIND[kind] then value = weights[SPELL_KIND[kind]] end
    return value or 0
  end

  -- Where a kind of stat sits on the build's priority list (1 = first), false if the build
  -- has a list and the stat is not on it, nil if there is no list to go by.
  local function Place(weights, kind)
    if not weights.place then return nil end
    return kind and weights.place[kind] or false
  end

  -- Wearing something different, or changing talents, changes every comparison.
  function Compare.GearChanged()
    gearVersion = gearVersion + 1
    specKnown = false
  end

  -- The build's stat priority as names, most important first: { "Expertise", "Strength / Attack Power", ... },
  -- and the build's name. nil if there is no list for this character yet.
  local KIND_NAME = { exp = "Expertise", str = "Strength", ap = "Attack Power", hit = "Hit", haste = "Haste", crit = "Crit",
    agi = "Agility", arp = "Armor Penetration", int = "Intellect", sta = "Stamina", mp5 = "MP5", spi = "Spirit",
    sp = "Spell Damage", heal = "Healing", def = "Defense", avoid = "Dodge / Parry / Block", armor = "Armor", resil = "Resilience" }
  function Compare.Order()
    local weights, name = Weights()
    local bySpec = SPEC_ORDER[playerClass]
    local spec = bySpec and specKey and bySpec[specKey] or nil
    if not weights or not spec then return nil end
    local list = {}
    for _, entry in ipairs(spec.order) do
      local names = {}
      for _, kind in ipairs(type(entry) == "table" and entry or { entry }) do
        tinsert(names, (spec.caster and (kind == "hit" or kind == "crit" or kind == "haste") and "Spell " or "") .. (KIND_NAME[kind] or kind))
      end
      tinsert(list, table.concat(names, " / "))
    end
    return list, name
  end

  -- The build gear is judged for: { name, caster, order = { { kind, ... }, ... }, label = kind -> name },
  -- or nil if there is no list for this character yet.
  function Compare.Build()
    local weights, name = Weights()
    local bySpec = SPEC_ORDER[playerClass]
    local spec = bySpec and specKey and bySpec[specKey] or nil
    if not weights or not spec then return nil end
    local order = {}
    for _, entry in ipairs(spec.order) do tinsert(order, type(entry) == "table" and entry or { entry }) end
    return { name = name, caster = spec.caster, order = order, label = KIND_NAME }
  end

  -- "Enhancement Shaman" when gear is judged for one build, else the class name as given.
  function Compare.Who(className)
    local _, name = Weights()
    className = className or "your class"
    if name then return name .. " " .. className end
    return className
  end

  local function Link(id)
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not info then return nil end
    local ok, name, link = pcall(info, id)
    if not ok then return nil end
    link = Plain(link)
    return type(link) == "string" and link or nil, Plain(name)
  end

  local function Stats(link)
    local fn = (C_Item and C_Item.GetItemStats) or GetItemStats
    if not fn or not link then return nil end
    local ok, stats = pcall(fn, link)
    if not ok or type(stats) ~= "table" then return nil end
    local out = {}
    for key, value in pairs(stats) do
      value = Plain(value)
      if type(key) == "string" and type(value) == "number" then out[key] = value end
    end
    return out
  end

  local function Score(stats, weights)
    local total = 0
    for key, value in pairs(stats) do
      total = total + value * Worth(weights, Kind(key))
    end
    return total
  end

  -- Short names for stats, the way players write them. The first that fits the game's key wins.
  local SHORT = {
    { "STAMINA", "Stam" }, { "INTELLECT", "Int" }, { "AGILITY", "Agi" }, { "STRENGTH", "Str" }, { "SPIRIT", "Spi" },
    { "RANGED_ATTACK_POWER", "Ranged AP" }, { "FERAL_ATTACK_POWER", "Feral AP" }, { "ATTACK_POWER", "AP" },
    { "SPELL_HEALING", "Healing" }, { "HEALING", "Healing" }, { "SPELL_POWER", "Spell Dmg" }, { "SPELL_DAMAGE", "Spell Dmg" },
    { "CRIT_SPELL", "Spell Crit" }, { "HIT_SPELL", "Spell Hit" }, { "HASTE_SPELL", "Spell Haste" },
    { "CRIT_RANGED", "Ranged Crit" }, { "HIT_RANGED", "Ranged Hit" }, { "CRIT", "Crit" }, { "HIT", "Hit" }, { "HASTE", "Haste" },
    { "EXPERTISE", "Exp" }, { "ARMOR_PENETRATION", "ArP" }, { "SPELL_PENETRATION", "Spell Pen" }, { "RESILIENCE", "Resil" },
    { "MANA_REGEN", "MP5" }, { "POWER_REGEN", "MP5" }, { "DAMAGE_PER_SECOND", "DPS" }, { "RESISTANCE0", "Armor" },
    { "DEFENSE", "Def" }, { "DODGE", "Dodge" }, { "PARRY", "Parry" }, { "BLOCK_VALUE", "Block Value" }, { "BLOCK", "Block" },
  }

  local function StatName(key)
    for _, pair in ipairs(SHORT) do
      if strfind(key, pair[1], 1, true) then return pair[2] end
    end
    local label = _G[key]
    if type(label) == "string" and label ~= "" then return label end
    local plain = gsub(gsub(gsub(key, "^ITEM_MOD_", ""), "_SHORT$", ""), "_", " ")
    return strsub(plain, 1, 1) .. strlower(strsub(plain, 2))
  end

  -- Compares an item with what is worn in its slot. Returns nil if it is not gear, or if
  -- the game has not loaded the item yet. Otherwise:
  --   { score = how much better (negative = worse), diffs = { { name, change }, ... },
  --     against = name of the worn item, or nil if the slot is empty }
  function Compare.Item(item)
    local id = item.id
    if not id or not playerClass or not GetInventoryItemLink then return nil end
    -- An exact link (from a tooltip or a roll) can carry different stats from the plain item.
    local key = type(item.link) == "string" and item.link or id
    local hit = cache[key]
    if hit and hit.version == gearVersion then return hit.result or nil end
    local equipLoc = Items.Facts(id)
    local slots = equipLoc and SLOTS[equipLoc]
    local weights = Weights()
    if not slots or not weights then
      cache[key] = { version = gearVersion, result = false }
      return nil
    end
    local link = type(item.link) == "string" and item.link or Link(id)
    local new = Stats(link)
    if not new then
      Items.RequestLoad(id)
      return nil -- not loaded yet; asked again on the next redraw
    end
    local newScore = Score(new, weights)
    local best
    local wearing = false
    for _, slot in ipairs(slots) do
      local wornLink = Plain(GetInventoryItemLink("player", slot))
      if wornLink and tonumber(strmatch(wornLink, "item:(%d+)")) == id then wearing = true end
      local worn = wornLink and Stats(wornLink) or {}
      local against = wornLink and strmatch(wornLink, "%[(.-)%]") or nil
      -- Holding a two-hander, a one-hander or an off hand is one half of what would replace it.
      local pair = false
      if equipLoc ~= "INVTYPE_2HWEAPON" and (slot == 16 or slot == 17) then
        local mainLink = Plain(GetInventoryItemLink("player", 16))
        local mainId = mainLink and tonumber(strmatch(mainLink, "item:(%d+)")) or nil
        pair = mainId ~= nil and Items.Facts(mainId) == "INVTYPE_2HWEAPON"
        if pair and slot == 17 then
          worn, against = Stats(mainLink) or {}, strmatch(mainLink, "%[(.-)%]")
        end
      end
      if equipLoc == "INVTYPE_2HWEAPON" then
        -- A two-hander also replaces whatever is in the off hand.
        local offLink = Plain(GetInventoryItemLink("player", 17))
        local off = offLink and Stats(offLink)
        if off then
          for key, value in pairs(off) do worn[key] = (worn[key] or 0) + value end
        end
      end
      local score = newScore - Score(worn, weights)
      if not best or score > best.score then
        local diffs = {}
        local seen = {}
        for key, value in pairs(new) do
          seen[key] = true
          local change = value - (worn[key] or 0)
          if math.abs(change) >= 0.05 then tinsert(diffs, { StatName(key), change, Worth(weights, Kind(key)), Kind(key), Place(weights, Kind(key)) }) end
        end
        for key, value in pairs(worn) do
          if not seen[key] and math.abs(value) >= 0.05 then tinsert(diffs, { StatName(key), -value, Worth(weights, Kind(key)), Kind(key), Place(weights, Kind(key)) }) end
        end
        table.sort(diffs, function(a, b)
          if (a[2] > 0) ~= (b[2] > 0) then return a[2] > 0 end
          if math.abs(a[2]) ~= math.abs(b[2]) then return math.abs(a[2]) > math.abs(b[2]) end
          return a[1] < b[1]
        end)
        best = { score = score, diffs = diffs, against = against, slot = slot, pair = pair }
      end
    end
    if best then best.wearing = wearing end
    cache[key] = { version = gearVersion, result = best or false }
    return best
  end

  -- "up", "down" or "same", or nil when there is nothing to compare.
  function Compare.Verdict(result)
    if not result then return nil end
    if result.score > 0.5 then return "up" end
    if result.score < -0.5 then return "down" end
    return "same"
  end

  -- How much a stat matters to this character, in words. weight is its value for it. Attack
  -- power comes in big numbers, so each point is worth less; it is still a key stat.
  -- place: where the stat sits on the build's priority list, when there is one.
  function Compare.Matters(weight, kind, place)
    if type(place) == "number" then
      if place <= 3 then return "a key stat for you (#" .. place .. ")" end
      if place <= 6 then return "useful to you (#" .. place .. ")" end
      return "low priority for you (#" .. place .. ")"
    end
    if not weight or weight <= 0 then return "no use to you" end
    if place == false then return "counts for you" end -- weapon damage: not on the lists
    if weight >= 0.8 or (kind == "ap" and weight >= 0.5) then return "a key stat for you" end
    if weight >= 0.4 then return "useful to you" end
    return "matters only a little" -- armor, mostly
  end

  -- True if a change is to one of the character's most important stats.
  local function IsKey(diff)
    if type(diff[5]) == "number" then return diff[5] <= 3 end
    return (diff[3] or 0) >= 0.8
  end

  local function Amount(value)
    value = math.abs(value)
    return (value % 1 < 0.05) and format("%d", math.floor(value + 0.5)) or format("%.1f", value)
  end

  -- "4 Intellect and 3 Spirit", from the changes that weigh most.
  local function Name(list, limit)
    local parts = {}
    for i = 1, math.min(#list, limit) do tinsert(parts, Amount(list[i][2]) .. " " .. list[i][1]) end
    if #parts == 0 then return nil end
    if #parts == 1 then return parts[1] end
    return table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
  end

  -- One sentence on why the verdict is what it is: which gains and losses count for this
  -- class and which way they tip. className is the class's name as the player sees it.
  function Compare.Why(result, className)
    if not result then return nil end
    className = Compare.Who(className)
    local gains, losses, wasted, gained, lost = {}, {}, {}, 0, 0
    for _, diff in ipairs(result.diffs) do
      local worth = math.abs(diff[2]) * (diff[3] or 0)
      if (diff[3] or 0) <= 0 then
        tinsert(wasted, diff)
      elseif diff[2] > 0 then
        tinsert(gains, diff)
        gained = gained + worth
      else
        tinsert(losses, diff)
        lost = lost + worth
      end
    end
    local function ByWorth(a, b) return math.abs(a[2]) * a[3] > math.abs(b[2]) * b[3] end
    table.sort(gains, ByWorth)
    table.sort(losses, ByWorth)
    local gain, loss = Name(gains, 2), Name(losses, 2)
    local verdict = Compare.Verdict(result)
    local text
    if not result.against and gain then
      text = "That slot is empty, so the " .. gain .. " is all gain."
    elseif verdict == "up" then
      if gain and loss then
        text = "The " .. gain .. " you gain " .. (#gains > 1 and "are" or "is") .. " worth more to a " .. className .. " than the " .. loss .. " you lose."
      elseif gain then
        text = "You gain " .. gain .. " and lose nothing a " .. className .. " needs."
      end
    elseif verdict == "down" then
      if gain and loss then
        text = "The " .. loss .. " you lose " .. (#losses > 1 and "are" or "is") .. " worth more to a " .. className .. " than the " .. gain .. " you gain."
      elseif loss then
        text = "You lose " .. loss .. " and gain nothing a " .. className .. " needs."
      else
        text = "It has nothing a " .. className .. " needs more of."
      end
    elseif gain and loss then
      text = "The " .. gain .. " you gain and the " .. loss .. " you lose come out about even for a " .. className .. "."
    end
    -- A key stat going down is worth pointing out even when the item wins overall.
    if verdict == "up" and losses[1] and IsKey(losses[1]) then
      text = (text or "") .. " You do give up " .. Amount(losses[1][2]) .. " " .. losses[1][1] .. ", a key stat, so check you can spare it."
    end
    if wasted[1] and text then
      local names = {}
      for i = 1, math.min(#wasted, 2) do tinsert(names, wasted[i][1]) end
      text = text .. " (" .. table.concat(names, " and ") .. " " .. (#names > 1 and "do" or "does") .. " nothing for a " .. className .. ", so " .. (#names > 1 and "they are" or "it is") .. " not counted.)"
    end
    return text
  end

  -- "+5 Stamina" / "-2 Spirit", coloured green or red.
  function Compare.ChangeText(diff)
    local value = diff[2]
    local shown = (math.abs(value) % 1 < 0.05) and format("%d", math.floor(math.abs(value) + 0.5)) or format("%.1f", math.abs(value))
    if value > 0 then return "|cff40ff40+" .. shown .. " " .. diff[1] .. "|r" end
    return "|cffff5555-" .. shown .. " " .. diff[1] .. "|r"
  end
end

-- ---------------------------------------------------------------------------
-- The wishlist. db.wish[character][itemId] = the raid or dungeon it was picked from ("" if none)

local Wish = {}
local Refresh -- defined with the window
local WantedBy -- defined with the group-sharing code: names of group members who want an item
-- What happened since walking into the current raid or dungeon; shown as a summary on leaving.
local Run = { kills = 0, drops = 0, fresh = 0, got = {}, missed = {} }

do
  local alerted = {} -- [itemId] = when we last spoke up about it

  local function List()
    if type(db.wish) ~= "table" then db.wish = {} end
    local key = (Plain(UnitName("player")) or "") .. "-" .. (GetRealmName and Plain(GetRealmName()) or "")
    if type(db.wish[key]) ~= "table" then db.wish[key] = {} end
    return db.wish[key]
  end

  function Wish.Has(id)
    return db ~= nil and List()[id] ~= nil
  end

  function Wish.From(id)
    return List()[id]
  end

  function Wish.Count()
    local n = 0
    for _ in pairs(List()) do n = n + 1 end
    return n
  end

  function Wish.Toggle(item)
    if not item then return end
    local list = List()
    local name = item.name or Items.Name(item.id) or ("item " .. item.id)
    if list[item.id] ~= nil then
      list[item.id] = nil
      Print(name .. " is off your wishlist.")
    else
      if Wish.Count() >= WISH_MAX then
        Print("Your wishlist is full (" .. WISH_MAX .. " items). Take something off first.")
        return
      end
      list[item.id] = (type(item.raid) == "string") and item.raid or ""
      Print(name .. " is on your wishlist. You'll be told when it drops.")
    end
    if Refresh then Refresh() end
  end

  -- Adds several items at once (a whole set). Returns how many were new.
  function Wish.AddAll(items)
    local list = List()
    local added = 0
    for _, item in ipairs(items) do
      if list[item.id] == nil then
        if Wish.Count() >= WISH_MAX then
          Print("Your wishlist is full (" .. WISH_MAX .. " items).")
          break
        end
        list[item.id] = (type(item.raid) == "string") and item.raid or ""
        added = added + 1
      end
    end
    if Refresh then Refresh() end
    return added
  end

  -- Takes everything off this character's wishlist. Returns how many items that was.
  function Wish.Clear()
    local n = Wish.Count()
    wipe(List())
    if Refresh then Refresh() end
    return n
  end

  -- Wishlist item ids in order, optionally only those picked from one raid or dungeon.
  function Wish.Ids(placeId)
    local ids = {}
    for id, from in pairs(List()) do
      if type(id) == "number" and (placeId == nil or from == placeId) then tinsert(ids, id) end
    end
    table.sort(ids)
    return ids
  end

  local function LinkText(id, text)
    return strmatch(text, "(|c[^|]+|Hitem:[^|]+|h[^|]+|h|r)") or Items.Name(id) or ("item " .. id)
  end

  -- group: the same news in a line for party or raid chat, sent only if that is switched on.
  local function Alert(text, group)
    if group and db.dropSay == true and SendChatMessage then
      local channel = (IsInRaid and IsInRaid() and "RAID") or (IsInGroup and IsInGroup() and "PARTY") or nil
      if channel then pcall(SendChatMessage, group, channel) end
    end
    if db.dropAlert == false then return end
    Print(text)
    if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo["RAID_WARNING"] then
      pcall(RaidNotice_AddMessage, RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"])
    end
    if PlaySound and (db.sound ~= false) then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.RAID_WARNING) or 8959) end
  end

  -- A wishlist item showed up in a loot window, a roll, or loot chat.
  function Wish.Seen(id, text, isRoll)
    if not db or List()[id] == nil then return end
    if alerted[id] and Now() - alerted[id] < 300 then return end
    alerted[id] = Now()
    if Run.place then Run.missed[id] = true end
    -- If a group member has it on their wishlist too, say so before anyone rolls.
    local others = WantedBy and WantedBy(List()[id], id) or nil
    local also = (others and #others > 0) and (" " .. table.concat(others, ", ") .. (#others == 1 and " wants" or " want") .. " it too.") or ""
    if isRoll then
      Alert("Wishlist item up for a roll: " .. LinkText(id, text) .. ". Don't forget to roll!" .. also,
        LinkText(id, text) .. " is on my wishlist.")
    else
      Alert("Wishlist item dropped: " .. LinkText(id, text) .. "." .. also, LinkText(id, text) .. " is on my wishlist.")
    end
  end

  -- This character looted a wishlist item, so it comes off the list.
  function Wish.Got(id, text)
    if not db or List()[id] == nil then return end
    List()[id] = nil
    if Run.place then
      Run.got[id] = true
      Run.missed[id] = nil
    end
    Print("You got " .. LinkText(id, text) .. ". It's off your wishlist.")
    if Refresh then Refresh() end
  end
end

-- ---------------------------------------------------------------------------
-- Quests: which quests are worth doing, where, and for how much XP.
-- Data.quests rows are { id, name, level, needs level, zone, base XP, race mask, class mask,
-- { quests that come first } }. XP is scaled to the character's level the way the game does
-- it, so a quest you have outlevelled shows what it would really give now.

local Quests = {}
do
  local ID, NAME, LEVEL, MIN, ZONE, XP, RACES, CLASSES, AFTER = 1, 2, 3, 4, 5, 6, 7, 8, 9
  local ALLIANCE, HORDE = 77, 178
  local RACE_BIT = { 1, 2, 4, 8, 16, 32, 64, 128 } -- by the game's race number
  local RACE_NAME = {
    { 1, "Human" }, { 4, "Dwarf" }, { 8, "Night Elf" }, { 64, "Gnome" },
    { 2, "Orc" }, { 16, "Undead" }, { 32, "Tauren" }, { 128, "Troll" },
  }
  local CLASS_BIT = {
    WARRIOR = 1, PALADIN = 2, HUNTER = 4, ROGUE = 8, PRIEST = 16, SHAMAN = 64, MAGE = 128, WARLOCK = 256, DRUID = 1024,
  }
  local byId

  local function Has(mask, flag)
    if bit and bit.band then return bit.band(mask, flag) ~= 0 end
    return math.floor(mask / flag) % 2 == 1
  end

  local function Index()
    if not byId then
      byId = {}
      for _, q in ipairs(Data.quests or {}) do byId[q[ID]] = q end
    end
    return byId
  end

  local NEW_ZONE_BASE = 900000 -- made-up ids for zones the shipped list has never heard of

  -- The quest zone id for a zone name, adding the zone if it is new (a WoW Forever zone).
  local function ZoneIdFor(name)
    Data.questZones = Data.questZones or {}
    local lower = strlower(name)
    local highest = NEW_ZONE_BASE
    for id, zone in pairs(Data.questZones) do
      if strlower(zone[1]) == lower then return id end
      if id > highest then highest = id end
    end
    Data.questZones[highest + 1] = { name, "New in WoW Forever" }
    return highest + 1
  end

  -- Adds one learned quest to the list in memory.
  local function Insert(id, saved)
    if Index()[id] or type(saved) ~= "table" or type(saved.n) ~= "string" then return end
    local level = tonumber(saved.l) or 1
    local row = { id, saved.n, level, tonumber(saved.m) or math.max(1, level - 3), ZoneIdFor(saved.z or "Unknown"), tonumber(saved.x) or 0, 0, 0 }
    row.learned = true
    Data.quests = Data.quests or {}
    tinsert(Data.quests, row)
    byId[id] = row
  end

  -- Quests this account has picked up that the shipped list lacks. Called once at load.
  function Quests.LoadLearned()
    for id, saved in pairs(type(db.quests) == "table" and db.quests or {}) do
      if type(id) == "number" then Insert(id, saved) end
    end
  end

  -- A quest was accepted. If the shipped list does not know it (a new WoW Forever quest),
  -- remember its name, level, zone and XP so it shows up for this account from now on.
  function Quests.Learn(id)
    id = tonumber(Plain(id))
    if not id or Index()[id] or not C_QuestLog then return end
    if type(db.quests) ~= "table" then db.quests = {} end
    if db.quests[id] then return end
    local name = C_QuestLog.GetTitleForQuestID and Plain(C_QuestLog.GetTitleForQuestID(id)) or nil
    if type(name) ~= "string" or name == "" then return end
    local level = C_QuestLog.GetQuestDifficultyLevel and Plain(C_QuestLog.GetQuestDifficultyLevel(id)) or nil
    local mine = Quests.MyLevel()
    if type(level) ~= "number" or level < 1 then level = mine end
    local xp = 0
    if GetQuestLogRewardXP then
      local ok, real = pcall(GetQuestLogRewardXP, id)
      real = ok and Plain(real) or nil
      if type(real) == "number" then xp = real end
    end
    local zone = GetRealZoneText and Plain(GetRealZoneText()) or nil
    if type(zone) ~= "string" or zone == "" then zone = "Unknown" end
    local saved = { n = CleanLabel(name) or name, l = level, z = CleanLabel(zone) or zone, x = xp, m = math.min(mine, level) }
    local count = 0
    for _ in pairs(db.quests) do count = count + 1 end
    if count >= 3000 then return end
    db.quests[id] = saved
    Insert(id, saved)
  end

  local leveledTo = 0 -- the level-up event arrives a moment before UnitLevel changes

  local function MyLevel()
    local level = UnitLevel and Plain(UnitLevel("player")) or nil
    return math.max(type(level) == "number" and level or 1, leveledTo)
  end
  Quests.MyLevel = MyLevel

  function Quests.LeveledTo(level)
    level = Plain(level)
    if type(level) == "number" then leveledTo = level end
  end

  -- For every zone: how many quests this character can pick up now and their XP in all.
  -- One pass over the list. Returns { { zone, name, count, xp }, ... }, most XP first.
  function Quests.ZoneTotals()
    local level = MyLevel()
    local byZone, list = {}, {}
    for _, q in ipairs(Data.quests or {}) do
      if q[MIN] <= level and Quests.CanDo(q) and not Quests.Done(q[ID]) and not Quests.Blocker(q) then
        local row = byZone[q[ZONE]]
        if not row then
          row = { zone = q[ZONE], name = Quests.ZoneName(q[ZONE]), count = 0, xp = 0 }
          byZone[q[ZONE]] = row
          tinsert(list, row)
        end
        row.count = row.count + 1
        row.xp = row.xp + Quests.XPAt(q, level)
      end
    end
    table.sort(list, function(a, b)
      if a.xp ~= b.xp then return a.xp > b.xp end
      return a.name < b.name
    end)
    return list
  end

  -- How many quests open up at exactly this level.
  function Quests.NewAt(level)
    local n = 0
    for _, q in ipairs(Data.quests or {}) do
      if q[MIN] == level and Quests.CanDo(q) and not Quests.Done(q[ID]) then n = n + 1 end
    end
    return n
  end

  -- Class, race and faction: can this character ever do the quest?
  function Quests.CanDo(q)
    local classes = q[CLASSES] or 0
    if classes ~= 0 then
      local mine = playerClass and CLASS_BIT[playerClass]
      if mine and not Has(classes, mine) then return false end
    end
    local races = q[RACES] or 0
    if races ~= 0 then
      local raceId = UnitRace and Plain((select(3, UnitRace("player")))) or nil
      local mine = type(raceId) == "number" and RACE_BIT[raceId] or nil
      if mine then
        if not Has(races, mine) then return false end
      elseif UnitFactionGroup then
        -- A race the Classic tables do not know (Skyborne): go by faction.
        local side = Plain((UnitFactionGroup("player")))
        local all = side == "Alliance" and ALLIANCE or side == "Horde" and HORDE or nil
        if all then
          if bit and bit.band then
            if bit.band(races, all) ~= all then return false end
          elseif races ~= all then
            return false
          end
        end
      end
    end
    return true
  end

  -- "Warrior only", "Dwarf, Gnome only", or nil when anyone on your side can do it.
  function Quests.Who(q)
    local parts = {}
    local classes = q[CLASSES] or 0
    if classes ~= 0 then
      for _, classFile in ipairs({ "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }) do
        if Has(classes, CLASS_BIT[classFile]) then
          tinsert(parts, strsub(classFile, 1, 1) .. strlower(strsub(classFile, 2)))
        end
      end
    end
    local races = q[RACES] or 0
    if races ~= 0 and races ~= ALLIANCE and races ~= HORDE then
      for _, pair in ipairs(RACE_NAME) do
        if Has(races, pair[1]) then tinsert(parts, pair[2]) end
      end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ", ") .. " only"
  end

  -- Every redraw of What next? and Quests asks about thousands of quests, so the game's
  -- answers are kept until something about quests changes (Quests.Fresh).
  local doneCache, logCache = {}, {}
  function Quests.Fresh()
    doneCache, logCache = {}, {}
  end

  function Quests.Done(id)
    local known = doneCache[id]
    if known == nil then
      known = false
      if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then known = Plain(C_QuestLog.IsQuestFlaggedCompleted(id)) == true end
      doneCache[id] = known
    end
    return known
  end

  function Quests.InLog(id)
    local known = logCache[id]
    if known == nil then
      known = false
      if C_QuestLog and C_QuestLog.IsOnQuest then known = Plain(C_QuestLog.IsOnQuest(id)) == true end
      logCache[id] = known
    end
    return known
  end

  -- The quest that has to be finished first, or nil if nothing is in the way.
  function Quests.Blocker(q)
    local after = q[AFTER]
    if not after then return nil end
    local firstMissing
    for _, id in ipairs(after) do
      if Quests.Done(id) then
        if not after.all then return nil end
      elseif not firstMissing then
        firstMissing = id
      end
    end
    if not firstMissing then return nil end
    local other = Index()[firstMissing]
    return other and other[NAME] or ("quest " .. firstMissing)
  end

  -- XP the quest gives at a level. The game pays full XP up to five levels over the quest,
  -- then less and less. A quest in your log uses the game's own number when it offers one.
  function Quests.XPAt(q, level)
    if GetQuestLogRewardXP and Quests.InLog(q[ID]) then
      local ok, real = pcall(GetQuestLogRewardXP, q[ID])
      real = ok and Plain(real) or nil
      if type(real) == "number" and real > 0 then return real end
    end
    local factor = 2 * (q[LEVEL] - level) + 20
    if factor < 1 then factor = 1 elseif factor > 10 then factor = 10 end
    local xp = q[XP] * factor / 10
    if xp <= 100 then
      xp = 5 * math.floor((xp + 2) / 5)
    elseif xp <= 500 then
      xp = 10 * math.floor((xp + 5) / 10)
    elseif xp <= 1000 then
      xp = 25 * math.floor((xp + 12) / 25)
    else
      xp = 50 * math.floor((xp + 25) / 50)
    end
    return math.floor(xp)
  end

  function Quests.ZoneName(zoneId)
    local zone = Data.questZones and Data.questZones[zoneId]
    return zone and zone[1] or "Unknown"
  end

  -- The zone the character is standing in, as a quest zone id, or nil.
  function Quests.ZoneHere()
    local here = GetRealZoneText and Plain(GetRealZoneText()) or nil
    if type(here) ~= "string" or here == "" then return nil end
    here = strlower(here)
    for id, zone in pairs(Data.questZones or {}) do
      if strlower(zone[1]) == here then return id, zone[1] end
    end
    return nil, here
  end

  -- Thousands separators: 12450 -> "12,450".
  function Quests.Number(n)
    local text = tostring(math.floor(n))
    local out = text
    while true do
      local changed
      out, changed = gsub(out, "^(%d+)(%d%d%d)", "%1,%2")
      if changed == 0 then break end
    end
    return out
  end

  -- Rows for the list, best XP first.
  --   zoneId: a zone id, or nil for everywhere
  --   onlyNow: only quests this character can pick up right now
  --   query: text the quest name must contain
  -- Returns rows { quest = q, xp, state, zone }, the XP total, and how many rows are doable now.
  function Quests.List(zoneId, onlyNow, query)
    local level = MyLevel()
    local rows, total, doable = {}, 0, 0
    for _, q in ipairs(Data.quests or {}) do
      if (zoneId == nil or q[ZONE] == zoneId) and (query == "" or strfind(strlower(q[NAME]), query, 1, true))
        and Quests.CanDo(q) and not Quests.Done(q[ID]) then
        local state
        if Quests.InLog(q[ID]) then
          state = "log"
        elseif q[MIN] > level then
          state = "level"
        elseif Quests.Blocker(q) then
          state = "after"
        else
          state = "open"
        end
        if not onlyNow or state == "open" or state == "log" then
          local xp = Quests.XPAt(q, level)
          tinsert(rows, { questRow = true, quest = q, xp = xp, state = state })
          if state == "open" or state == "log" then
            total = total + xp
            doable = doable + 1
          end
        end
      end
    end
    table.sort(rows, function(a, b)
      local aNow = a.state == "open" or a.state == "log"
      local bNow = b.state == "open" or b.state == "log"
      if aNow ~= bNow then return aNow end
      if a.xp ~= b.xp then return a.xp > b.xp end
      return a.quest[ID] < b.quest[ID]
    end)
    return rows, total, doable
  end

  Quests.F = { ID = ID, NAME = NAME, LEVEL = LEVEL, MIN = MIN, ZONE = ZONE, XP = XP }

  local byId
  function Quests.ById(id)
    if not byId then
      byId = {}
      for _, q in ipairs(Data.quests or {}) do byId[q[ID]] = q end
    end
    return byId[id]
  end
end

-- ---------------------------------------------------------------------------
-- Spell training: what your class trainer will teach you at each level, and what it costs.
-- Nothing is shipped for this. The list is read from the trainer window the first time you
-- visit your class trainer, so the spells and prices are exactly what the game charges you.
-- db.train[character].spells[name|rank] = { name, rank, level, cost, known, icon }

local Train = {}
do
  local filtersBefore -- the player's own trainer filters, put back when the window closes
  local scanPending = false

  local function Book()
    if type(db.train) ~= "table" then db.train = {} end
    local key = (Plain(UnitName("player")) or "") .. "-" .. (GetRealmName and Plain(GetRealmName()) or "")
    if type(db.train[key]) ~= "table" then db.train[key] = {} end
    if type(db.train[key].spells) ~= "table" then db.train[key].spells = {} end
    return db.train[key]
  end

  -- 12345 copper -> "1g 23s 45c", coloured like the game does.
  function Train.Money(copper)
    copper = math.max(0, math.floor(tonumber(copper) or 0))
    local g, sv, c = math.floor(copper / 10000), math.floor(copper % 10000 / 100), copper % 100
    local parts = {}
    if g > 0 then tinsert(parts, "|cffffd700" .. g .. "g|r") end
    if sv > 0 then tinsert(parts, "|cffc7c7cf" .. sv .. "s|r") end
    if c > 0 or #parts == 0 then tinsert(parts, "|cffeda55f" .. c .. "c|r") end
    return table.concat(parts, " ")
  end

  local function CanScan()
    return GetNumTrainerServices and GetTrainerServiceInfo and GetTrainerServiceCost
  end

  local SERVICE_KINDS = { available = true, unavailable = true, used = true }

  -- One line of the trainer window. The game has two shapes for this call:
  --   older:        name, rank, kind
  --   WoW Forever:  name, kind, icon, level, rank   (what Blizzard's own trainer window reads)
  -- so work out which one we were given instead of assuming.
  local function Service(i)
    local name, a, b, c, d = GetTrainerServiceInfo(i)
    name, a, b, c, d = Plain(name), Plain(a), Plain(b), Plain(c), Plain(d)
    if type(name) ~= "string" or name == "" then return nil end
    local kind, rank, icon, level
    if SERVICE_KINDS[a] then
      kind, icon, level, rank = a, b, c, d
    elseif SERVICE_KINDS[b] then
      kind, rank = b, a
    else
      return nil
    end
    if GetTrainerServiceLevelReq then
      local req = Plain(GetTrainerServiceLevelReq(i))
      if type(req) == "number" then level = req end
    end
    if not icon and GetTrainerServiceIcon then icon = Plain(GetTrainerServiceIcon(i)) end
    if type(rank) ~= "string" or rank == "" then rank = nil end
    local cost = Plain((GetTrainerServiceCost(i)))
    return {
      name = name,
      rank = rank,
      level = type(level) == "number" and level or 0,
      cost = type(cost) == "number" and cost or 0,
      known = kind == "used",
      icon = icon,
    }
  end

  -- What the addon can see at the trainer, for when the tab stays empty. (/ww trainer)
  function Train.Report()
    Print("Trainer check:")
    Print("  game functions: count " .. tostring(GetNumTrainerServices ~= nil) .. ", info " .. tostring(GetTrainerServiceInfo ~= nil)
      .. ", cost " .. tostring(GetTrainerServiceCost ~= nil) .. ", level " .. tostring(GetTrainerServiceLevelReq ~= nil)
      .. ", filters " .. tostring(GetTrainerServiceTypeFilter ~= nil))
    if not CanScan() then
      Print("  This version of the game does not offer the trainer list to addons in the way Wishwell expects.")
      return
    end
    local count = Plain(GetNumTrainerServices())
    Print("  profession trainer: " .. tostring(IsTradeskillTrainer and Plain(IsTradeskillTrainer()) or false) .. ", lines in the window: " .. tostring(count))
    if type(count) ~= "number" or count == 0 then
      Print("  No trainer window is open, or it is empty. Stand at your class trainer with the window open and try again.")
      return
    end
    local understood = 0
    for i = 1, count do
      if Service(i) then understood = understood + 1 end
    end
    Print("  lines understood as spells: " .. understood)
    for i = 1, math.min(count, 4) do
      local parts = {}
      for _, value in ipairs({ GetTrainerServiceInfo(i) }) do tinsert(parts, tostring(Plain(value))) end
      Print("  line " .. i .. ": " .. table.concat(parts, " / "))
    end
  end

  -- Profession and pet trainers are not class spells.
  local function WrongTrainer()
    if IsTradeskillTrainer and Plain(IsTradeskillTrainer()) then return true end
    if C_Trainer and C_Trainer.GetTrainerType and Enum and Enum.TrainerType and Enum.TrainerType.Pet ~= nil then
      local ok, kind = pcall(C_Trainer.GetTrainerType)
      if ok and Plain(kind) == Enum.TrainerType.Pet then return true end
    end
    return false
  end

  -- Reads every spell in the open trainer window. Profession and pet trainers are skipped.
  function Train.Scan()
    if not CanScan() then return end
    if WrongTrainer() then return end
    local count = Plain(GetNumTrainerServices())
    if type(count) ~= "number" then return end
    local book = Book()
    local seen = 0
    for i = 1, count do
      local spell = Service(i)
      if spell then
        -- Without a rank, two ranks of one spell share a name; the level tells them apart.
        local key = spell.name .. "|" .. (spell.rank or ("level " .. spell.level))
        book.spells[key] = spell
        seen = seen + 1
      end
    end
    if seen > 0 then
      book.scanned = true
      Refresh()
    end
  end

  local function ScanSoon()
    if scanPending then return end
    scanPending = true
    After(0.3, function()
      scanPending = false
      pcall(Train.Scan)
    end)
  end

  -- The trainer only lists what its filters allow, so switch all three on while the window
  -- is open and put the player's own choices back when it closes.
  function Train.Opened()
    if not CanScan() then return end
    if WrongTrainer() then return end
    if GetTrainerServiceTypeFilter and SetTrainerServiceTypeFilter and not filtersBefore then
      filtersBefore = {}
      for _, kind in ipairs({ "available", "unavailable", "used" }) do
        local ok, on = pcall(GetTrainerServiceTypeFilter, kind)
        if ok then
          filtersBefore[kind] = Plain(on) and true or false
          if not filtersBefore[kind] then pcall(SetTrainerServiceTypeFilter, kind, true) end
        end
      end
    end
    ScanSoon()
  end

  function Train.Updated()
    ScanSoon()
  end

  function Train.Closed()
    if filtersBefore and SetTrainerServiceTypeFilter then
      for kind, on in pairs(filtersBefore) do
        if not on then pcall(SetTrainerServiceTypeFilter, kind, false) end
      end
    end
    filtersBefore = nil
  end

  -- Unlearned spells that unlock at exactly this level: how many, and their cost in all.
  function Train.At(level)
    local count, total = 0, 0
    for _, spell in pairs(Book().spells) do
      if type(spell) == "table" and not spell.known and spell.level == level then
        count = count + 1
        total = total + (spell.cost or 0)
      end
    end
    return count, total
  end

  function Train.Scanned()
    return Book().scanned == true
  end

  -- Spells not learned yet, grouped by the level they unlock. Level 0 means "ready now".
  -- Returns rows for the list (a header row, then its spells), plus totals.
  function Train.Rows()
    local mine = UnitLevel and Plain(UnitLevel("player")) or nil
    if type(mine) ~= "number" then mine = 1 end
    local groups, levels = {}, {}
    for _, spell in pairs(Book().spells) do
      if type(spell) == "table" and not spell.known and type(spell.name) == "string" then
        local level = (spell.level or 0) <= mine and 0 or spell.level
        if not groups[level] then
          groups[level] = { header = true, level = level, count = 0, total = 0, spells = {} }
          tinsert(levels, level)
        end
        local group = groups[level]
        group.count = group.count + 1
        group.total = group.total + (spell.cost or 0)
        tinsert(group.spells, spell)
      end
    end
    table.sort(levels)
    local rows, grand = {}, 0
    for _, level in ipairs(levels) do
      local group = groups[level]
      grand = grand + group.total
      table.sort(group.spells, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return (a.rank or "") < (b.rank or "")
      end)
      tinsert(rows, group)
      for _, spell in ipairs(group.spells) do
        spell.train = true
        tinsert(rows, spell)
      end
    end
    local ready = groups[0]
    local nextGroup
    for _, level in ipairs(levels) do
      if level > 0 then
        nextGroup = groups[level]
        break
      end
    end
    return rows, grand, ready, nextGroup
  end

  -- On a level up: say what the trainer now has and what it costs.
  function Train.LevelUp(level)
    level = Plain(level)
    if type(level) ~= "number" or not Train.Scanned() then return end
    local count, total = 0, 0
    for _, spell in pairs(Book().spells) do
      if type(spell) == "table" and not spell.known and spell.level == level then
        count = count + 1
        total = total + (spell.cost or 0)
      end
    end
    if count > 0 then
      Print("Level " .. level .. ": " .. count .. " new spell" .. (count == 1 and "" or "s") .. " to train, " .. Train.Money(total) .. " in all.")
    end
  end
end

-- ---------------------------------------------------------------------------
-- The window. Styled after the character window: dark panel, round icon in the corner,
-- your character on the left, icon tabs down the right edge.

local UI = { rows = {}, shown = {}, offset = 0, boss = "ALL", pendingTry = {}, talk = {} }

local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local RARITIES = { { 2, "Uncommon" }, { 3, "Rare" }, { 4, "Epic" }, { 5, "Legendary" } }
local SLOTS = {
  "Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist", "Legs", "Feet", "Finger", "Trinket",
  "One-Hand", "Two-Hand", "Main Hand", "Off-hand", "Shield", "Ranged", "Relic",
}

local function ClassLabel(classFile)
  local names = LOCALIZED_CLASS_NAMES_MALE
  if type(names) == "table" and names[classFile] then return names[classFile] end
  return strsub(classFile, 1, 1) .. strlower(strsub(classFile, 2))
end

-- The class the lists are filtered to: nil means every class.
function UI.ClassFilter()
  if db.classFilter == "ALL" then return nil, true end
  if db.classFilter and db.classFilter ~= "MINE" then return db.classFilter end
  return playerClass
end

-- The raids and dungeons the Loot tab is showing: the one picked, or every one in the
-- chosen zone.
function UI.Scope()
  if db.zone and db.zone ~= "ALL" then
    local ids = {}
    for _, row in ipairs(Data.instances) do
      if row.zone == db.zone then tinsert(ids, row.id) end
    end
    if #ids > 0 then return ids, true end
  end
  return { db.browseId }, false
end

-- Which difficulty the Loot tab is showing: true for heroic, false for normal, nil where
-- there is only one (raids, Classic dungeons, a whole zone at once).
function UI.Diff()
  local _, byZone = UI.Scope()
  if byZone or not Places.HasHeroic(db.browseId) then return nil end
  return db.heroic == true
end

-- Points the Loot tab at one raid or dungeon.
function UI.Browse(placeId, heroic)
  db.browseId = placeId
  db.heroic = heroic and Places.HasHeroic(placeId) or false
  db.zone = "ALL"
  UI.boss = "ALL"
  local diff = nil
  if Places.HasHeroic(placeId) then diff = db.heroic end
  Items.Preload(placeId, diff)
end

function UI.Zones()
  local list, seen = {}, {}
  for _, row in ipairs(Data.instances) do
    if row.zone and not seen[row.zone] then
      seen[row.zone] = true
      tinsert(list, row.zone)
    end
  end
  table.sort(list)
  return list
end

-- Puts every filter and the search box back to how they start.
function UI.ClearFilters()
  db.classFilter = "MINE"
  db.rarity = 0
  db.slot = "ALL"
  db.zone = "ALL"
  UI.boss = "ALL"
  if UI.search then UI.search:SetText("") end
  UI.ResetScroll()
  Refresh()
end

-- True if an item gets through the class, rarity and slot filters.
function UI.Passes(item)
  local classFile, everyone = UI.ClassFilter()
  if not everyone and not Items.Fits(item, classFile) then return false end
  if db.rarity and db.rarity > 0 then
    local quality = Items.Quality(item)
    -- Not loaded yet: keep it, it is redrawn once the game knows.
    if quality and quality ~= db.rarity then return false end
  end
  if db.slot and db.slot ~= "ALL" and Items.Slot(item) ~= db.slot then return false end
  return true
end

-- Makes a line of text a few points bigger than its font normally is.
local function Bigger(fontString, by)
  local path, size, flags = fontString:GetFont()
  if type(path) == "string" and type(size) == "number" then fontString:SetFont(path, size + by, flags) end
end

-- True unless the player has asked for the game's own window art (Settings, "Smooth look").
local function Smooth()
  return not db or db.smooth ~= false
end

-- Paints a frame as a rounded box from Wishwell's own artwork: Round.tga (the fill) and
-- RoundEdge.tga (the outline), each cut into nine pieces so the corners keep their curve
-- whatever the frame's size. size: how big a corner is on screen. Afterwards the frame
-- answers SetBackdropColor and SetBackdropBorderColor like any framed box.
local ART = "Interface\\AddOns\\Wishwell\\"
local function RoundBox(f, size)
  local C = 24 / 64 -- the corner's share of the picture
  local function Layer(file, layer)
    local parts = {}
    local function Piece(left, right, top, bottom)
      local tex = f:CreateTexture(nil, layer)
      tex:SetTexture(ART .. file)
      tex:SetTexCoord(left, right, top, bottom)
      tinsert(parts, tex)
      return tex
    end
    local tl = Piece(0, C, 0, C)
    tl:SetSize(size, size)
    tl:SetPoint("TOPLEFT")
    local tr = Piece(1 - C, 1, 0, C)
    tr:SetSize(size, size)
    tr:SetPoint("TOPRIGHT")
    local bl = Piece(0, C, 1 - C, 1)
    bl:SetSize(size, size)
    bl:SetPoint("BOTTOMLEFT")
    local br = Piece(1 - C, 1, 1 - C, 1)
    br:SetSize(size, size)
    br:SetPoint("BOTTOMRIGHT")
    local function Between(piece, from, fromPoint, to, toPoint)
      piece:SetPoint("TOPLEFT", from, fromPoint)
      piece:SetPoint("BOTTOMRIGHT", to, toPoint)
    end
    Between(Piece(C, 1 - C, 0, C), tl, "TOPRIGHT", tr, "BOTTOMLEFT")
    Between(Piece(C, 1 - C, 1 - C, 1), bl, "TOPRIGHT", br, "BOTTOMLEFT")
    Between(Piece(0, C, C, 1 - C), tl, "BOTTOMLEFT", bl, "TOPRIGHT")
    Between(Piece(1 - C, 1, C, 1 - C), tr, "BOTTOMLEFT", br, "TOPRIGHT")
    Between(Piece(C, 1 - C, C, 1 - C), tl, "BOTTOMRIGHT", br, "TOPLEFT")
    return parts
  end
  local fill, line = Layer("Round.tga", "BACKGROUND"), Layer("RoundEdge.tga", "BORDER")
  local function Tint(parts)
    return function(_, r, g, b, alpha)
      for _, tex in ipairs(parts) do tex:SetVertexColor(r, g, b, alpha or 1) end
    end
  end
  f.SetBackdropColor = Tint(fill)
  f.SetBackdropBorderColor = Tint(line)
end

-- Wishwell's own look: a dark box with rounded corners. edge: how big the corners are
-- (bigger for the window, smaller for the panels inside it).
local function MakeBackdrop(f, edge)
  if Smooth() then
    RoundBox(f, math.floor((edge or 13) * 1.4))
    f:SetBackdropColor(0.06, 0.06, 0.08, 0.96)
    f:SetBackdropBorderColor(0.45, 0.41, 0.34, 1)
    return
  end
  if f.SetBackdrop then
    edge = edge or 14
    f:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8X8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 8,
      edgeSize = edge,
      insets = { left = edge / 4, right = edge / 4, top = edge / 4, bottom = edge / 4 },
    })
    f:SetBackdropColor(0.06, 0.06, 0.08, 0.96)
    f:SetBackdropBorderColor(0.45, 0.41, 0.34, 1)
  end
end

-- A button. In the smooth look: a dark rounded pill with gold text that lights up under the
-- mouse. Otherwise the game's red button.
function UI.MakeButton(name, parent)
  if not Smooth() then return CreateFrame("Button", name, parent, "UIPanelButtonTemplate") end
  local btn = CreateFrame("Button", name, parent)
  RoundBox(btn, 10)
  btn:SetBackdropColor(0.17, 0.14, 0.09, 0.95)
  btn:SetBackdropBorderColor(0.80, 0.64, 0.26, 0.9)
  if btn.SetNormalFontObject then
    btn:SetNormalFontObject("GameFontNormalSmall")
    btn:SetHighlightFontObject("GameFontHighlightSmall")
    btn:SetDisabledFontObject("GameFontDisableSmall")
  end
  if btn.SetHighlightTexture then
    pcall(function()
      btn:SetHighlightTexture("Interface\\Buttons\\WHITE8X8", "ADD")
      local glow = btn:GetHighlightTexture()
      if type(glow) == "table" and glow.SetVertexColor then
        glow:SetVertexColor(1, 0.82, 0.3, 0.12)
        glow:ClearAllPoints()
        glow:SetPoint("TOPLEFT", 5, -4)
        glow:SetPoint("BOTTOMRIGHT", -5, 4)
      end
    end)
  end
  if btn.SetPushedTextOffset then btn:SetPushedTextOffset(1, -1) end
  return btn
end

-- Item id from a shift-clicked link or a typed number, or nil.
local function ParseItemId(text)
  if type(text) ~= "string" then return nil end
  local id = tonumber(strmatch(text, "item:(%d+)") or strmatch(text, "^%s*(%d+)%s*$"))
  if id and id > 0 and id < 100000000 then return id end
  return nil
end

local function Matches(item, q)
  if q == "" then return true end
  return strfind(strlower((item.name or "") .. " " .. Items.Slot(item) .. " " .. (item.boss or "")), q, 1, true) ~= nil
end

-- Works out which rows the list should show for the current tab, filters and search.
-- ---------------------------------------------------------------------------
-- Characters: a small profile of every character that has logged in with Wishwell, so the
-- Characters tab can show them side by side. Also each character's gold goal.
-- db.chars[name-realm] = { name, class, level, money, goal = { amount, name } }

local Chars = {}
do
  local session -- { money, at } when this character logged in, for the earning pace

  function Chars.Key()
    return (Plain(UnitName("player")) or "") .. "-" .. (GetRealmName and Plain(GetRealmName()) or "")
  end

  function Chars.Me()
    if type(db.chars) ~= "table" then db.chars = {} end
    local key = Chars.Key()
    if type(db.chars[key]) ~= "table" then db.chars[key] = {} end
    return db.chars[key]
  end

  -- Notes down this character's level, class and gold.
  function Chars.Save()
    if not db then return end
    local me = Chars.Me()
    me.name = Plain(UnitName("player")) or me.name
    me.class = playerClass or me.class
    local level = UnitLevel and Plain(UnitLevel("player")) or nil
    if type(level) == "number" then me.level = math.max(level, me.level or 0) end
    local money = GetMoney and Plain(GetMoney()) or nil
    if type(money) == "number" then
      me.money = money
      if not session then session = { money = money, at = Now() } end
    end
    -- Experience towards the next level.
    local xp = UnitXP and Plain(UnitXP("player")) or nil
    local xpMax = UnitXPMax and Plain(UnitXPMax("player")) or nil
    if type(xp) == "number" and type(xpMax) == "number" and xpMax > 0 then
      me.xp, me.xpMax = xp, xpMax
    end
  end

  -- Copper earned per hour this session, once there is half an hour to judge by. nil otherwise.
  function Chars.Pace()
    local me = Chars.Me()
    if not session or type(me.money) ~= "number" then return nil end
    local hours = (Now() - session.at) / 3600
    local earned = me.money - session.money
    if hours < 0.5 or earned <= 0 then return nil end
    return earned / hours
  end

  -- What this character is saving for. Until the player sets one, a character under 40 is
  -- shown the Classic price of a first mount as a suggestion.
  function Chars.Goal()
    local me = Chars.Me()
    if type(me.goal) == "table" and type(me.goal.amount) == "number" then
      if me.goal.amount <= 0 then return nil end
      return me.goal
    end
    if (me.level or 1) < 40 then
      return { amount = 1000000, name = "First mount at level 40", suggested = true }
    end
    return nil
  end

  -- amount in gold; 0 or nil switches the goal off.
  function Chars.SetGoal(gold, name)
    local me = Chars.Me()
    gold = tonumber(gold)
    if not gold or gold <= 0 then
      me.goal = { amount = 0 }
      return nil
    end
    name = CleanLabel(name)
    me.goal = { amount = math.floor(gold * 10000), name = name or "My goal" }
    return me.goal
  end

  -- Every known character, highest level first, with what the list needs to show.
  function Chars.List()
    local list = {}
    local mine = Chars.Key()
    for key, c in pairs(type(db.chars) == "table" and db.chars or {}) do
      if type(c) == "table" and type(c.name) == "string" then
        local wishes = 0
        for _ in pairs(type(db.wish) == "table" and type(db.wish[key]) == "table" and db.wish[key] or {}) do wishes = wishes + 1 end
        local spells, cost = 0, 0
        local book = type(db.train) == "table" and type(db.train[key]) == "table" and db.train[key].spells or nil
        for _, spell in pairs(type(book) == "table" and book or {}) do
          if type(spell) == "table" and not spell.known and (spell.level or 0) <= (c.level or 1) then
            spells = spells + 1
            cost = cost + (spell.cost or 0)
          end
        end
        tinsert(list, { alt = true, key = key, char = c, me = key == mine, wishes = wishes, spells = spells, cost = cost })
      end
    end
    table.sort(list, function(a, b)
      if a.me ~= b.me then return a.me end
      if (a.char.level or 0) ~= (b.char.level or 0) then return (a.char.level or 0) > (b.char.level or 0) end
      return a.char.name < b.char.name
    end)
    return list
  end
end

-- ---------------------------------------------------------------------------
-- Professions: what to make to raise your skill. Like spell training, nothing is shipped.
-- Wishwell reads your recipes from the profession window when you open it, so the list is
-- exactly what your character knows, with the game's own skill-up colours.
-- db.prof[character][profession name] = { recipes = { [recipeID] = { name, diff, icon, reagents } } }

local Prof = {}
do
  -- The game's colours for how likely a recipe is to give a skill point.
  local DIFF = {
    [0] = { 1, 0.5, 0.25, "always gives skill" },
    [1] = { 1, 1, 0, "usually gives skill" },
    [2] = { 0.25, 0.75, 0.25, "rarely gives skill" },
    [3] = { 0.5, 0.5, 0.5, "no skill" },
  }
  Prof.DIFF = DIFF

  local function Book()
    if type(db.prof) ~= "table" then db.prof = {} end
    local key = Chars.Key()
    if type(db.prof[key]) ~= "table" then db.prof[key] = {} end
    return db.prof[key]
  end

  local scanPending = false

  -- Reads the open profession window. Someone else's linked profession is not yours to learn from.
  function Prof.Scan()
    local api = C_TradeSkillUI
    if not db or not api or not api.GetRecipeInfo then return end
    if api.IsTradeSkillReady and Plain(api.IsTradeSkillReady()) ~= true then return end
    if (api.IsTradeSkillLinked and Plain(api.IsTradeSkillLinked())) or (api.IsTradeSkillGuild and Plain(api.IsTradeSkillGuild()))
      or (api.IsNPCCrafting and Plain(api.IsNPCCrafting())) then
      return
    end
    local info
    if api.GetChildProfessionInfo then info = api.GetChildProfessionInfo() end
    if (type(info) ~= "table" or not info.professionName or info.professionName == "") and api.GetBaseProfessionInfo then
      info = api.GetBaseProfessionInfo()
    end
    if type(info) ~= "table" then return end
    local name = Plain(info.parentProfessionName) or Plain(info.professionName)
    if type(name) ~= "string" or name == "" then return end
    local ids = (api.GetAllRecipeIDs and api.GetAllRecipeIDs()) or (api.GetFilteredRecipeIDs and api.GetFilteredRecipeIDs()) or nil
    if type(ids) ~= "table" then return end
    local recipes, count = {}, 0
    for _, id in ipairs(ids) do
      local recipe = api.GetRecipeInfo(id)
      if type(recipe) == "table" and Plain(recipe.learned) == true and not Plain(recipe.isDummyRecipe)
        and type(Plain(recipe.name)) == "string" then
        local reagents = {}
        if api.GetRecipeSchematic then
          local ok, schematic = pcall(api.GetRecipeSchematic, id, false)
          if ok and type(schematic) == "table" and type(schematic.reagentSlotSchematics) == "table" then
            for _, slot in ipairs(schematic.reagentSlotSchematics) do
              local first = type(slot) == "table" and type(slot.reagents) == "table" and slot.reagents[1] or nil
              local itemId = type(first) == "table" and Plain(first.itemID) or nil
              local need = type(slot) == "table" and Plain(slot.quantityRequired) or nil
              if type(itemId) == "number" and type(need) == "number" and need > 0 and Plain(slot.required) ~= false then
                tinsert(reagents, { itemId, need })
              end
            end
          end
        end
        local diff = Plain(recipe.relativeDifficulty)
        recipes[id] = { name = recipe.name, diff = type(diff) == "number" and diff or 3, icon = Plain(recipe.icon), reagents = reagents }
        count = count + 1
      end
    end
    Book()[name] = { recipes = recipes, count = count, scanned = true }
    Refresh()
  end

  -- The window fires several updates while it fills in; read it once they settle.
  function Prof.ScanSoon()
    if scanPending then return end
    scanPending = true
    After(0.5, function()
      scanPending = false
      pcall(Prof.Scan)
    end)
  end

  local function Have(itemId)
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not fn then return 0 end
    local ok, n = pcall(fn, itemId)
    n = ok and Plain(n) or 0
    return type(n) == "number" and n or 0
  end

  -- How many times a recipe can be made from what is in your bags.
  function Prof.CanMake(recipe)
    local times
    for _, reagent in ipairs(recipe.reagents or {}) do
      local n = math.floor(Have(reagent[1]) / reagent[2])
      if not times or n < times then times = n end
    end
    return times or 0
  end

  function Prof.ReagentText(recipe)
    local parts = {}
    for _, reagent in ipairs(recipe.reagents or {}) do
      tinsert(parts, reagent[2] .. "x " .. (Items.Name(reagent[1]) or ("item " .. reagent[1])))
    end
    return table.concat(parts, ", ")
  end

  -- The character's professions right now: { { name, icon, rank, max }, ... }.
  function Prof.Mine()
    local list = {}
    if not (GetProfessions and GetProfessionInfo) then return list end
    local found = { GetProfessions() }
    for i = 1, 7 do
      local index = Plain(found[i])
      if index then
        local name, icon, rank, max = GetProfessionInfo(index)
        name = Plain(name)
        if type(name) == "string" and name ~= "" then
          tinsert(list, { name = name, icon = Plain(icon), rank = Plain(rank) or 0, max = Plain(max) or 0 })
        end
      end
    end
    return list
  end

  -- Rows for the list: each profession, then the recipes worth making for skill.
  function Prof.Rows()
    local rows = {}
    local book = Book()
    for _, mine in ipairs(Prof.Mine()) do
      local stored = type(book[mine.name]) == "table" and book[mine.name] or nil
      tinsert(rows, { profHead = true, prof = mine, scanned = stored ~= nil })
      if stored then
        local useful = {}
        for id, recipe in pairs(stored.recipes or {}) do
          if type(recipe) == "table" and (recipe.diff == 0 or recipe.diff == 1) then
            tinsert(useful, { recipe = true, id = id, r = recipe, make = Prof.CanMake(recipe) })
          end
        end
        table.sort(useful, function(a, b)
          if a.r.diff ~= b.r.diff then return a.r.diff < b.r.diff end
          if (a.make > 0) ~= (b.make > 0) then return a.make > 0 end
          if a.make ~= b.make then return a.make > b.make end
          return a.r.name < b.r.name
        end)
        if #useful == 0 then
          if (stored.count or 0) > 0 then
            tinsert(rows, { note = true, text = "Nothing you know gives skill any more. Visit a " .. mine.name .. " trainer for new recipes." })
          end
        else
          for i = 1, math.min(#useful, 6) do tinsert(rows, useful[i]) end
          if #useful > 6 then
            tinsert(rows, { note = true, text = "+" .. (#useful - 6) .. " more recipes that give skill." })
          end
        end
      else
        tinsert(rows, { note = true, text = "Open your " .. mine.name .. " window once and Wishwell lists what to make for skill." })
      end
    end
    return rows
  end
end

-- ---------------------------------------------------------------------------
-- Legacy: WoW Forever's account-wide challenges. The game keeps them as achievements, so
-- Wishwell reads them the way the game's own Legacy window does and puts the ones you are
-- closest to finishing at the top.

local Legacy = {}
do
  -- How far along a challenge is, from 0 to 1, from its listed steps.
  local function Progress(id)
    if not GetAchievementNumCriteria or not GetAchievementCriteriaInfo then return 0 end
    local n = Plain(GetAchievementNumCriteria(id))
    if type(n) ~= "number" or n <= 0 then return 0 end
    local total = 0
    for i = 1, n do
      local _, _, done, have, need = GetAchievementCriteriaInfo(id, i)
      done, have, need = Plain(done), Plain(have), Plain(need)
      if done then
        total = total + 1
      elseif type(have) == "number" and type(need) == "number" and need > 0 then
        total = total + math.min(have / need, 1)
      end
    end
    return total / n
  end

  -- Legacy points: how many are unspent and how many have been spent. nil if unknown.
  function Legacy.Points()
    if not (C_Traits and C_Traits.GetConfigIDByTreeID and C_Traits.GetTreeCurrencyInfo) then return nil end
    local consts = Constants and Constants.LegacyConsts
    local treeId = consts and consts.LEGACY_TREE_PROFESSIONS_ID
    if not treeId then return nil end
    local ok, configId = pcall(C_Traits.GetConfigIDByTreeID, treeId)
    if not ok or not configId then return nil end
    local ok2, info = pcall(C_Traits.GetTreeCurrencyInfo, configId, treeId, false)
    local first = ok2 and type(info) == "table" and info[1] or nil
    if type(first) ~= "table" then return nil end
    return tonumber(Plain(first.quantity)) or 0, tonumber(Plain(first.spent)) or 0
  end

  -- Rows for the list: a summary line, then every unfinished challenge, nearest first.
  function Legacy.Rows()
    local rows = {}
    if not (GetCategoryList and GetCategoryNumAchievements and GetAchievementInfo) then return rows end
    local done, total = 0, 0
    local open = {}
    for _, category in ipairs(GetCategoryList() or {}) do
      local count = Plain((GetCategoryNumAchievements(category)))
      local categoryName = GetCategoryInfo and Plain((GetCategoryInfo(category))) or nil
      for index = 1, type(count) == "number" and count or 0 do
        local id, name, _, completed, _, _, _, description, _, icon, reward = GetAchievementInfo(category, index)
        id, name, completed = Plain(id), Plain(name), Plain(completed)
        if type(id) == "number" and type(name) == "string" then
          total = total + 1
          if completed then
            done = done + 1
          else
            tinsert(open, { legacy = true, id = id, name = name, category = categoryName, text = Plain(description),
              icon = Plain(icon), reward = Plain(reward), progress = Progress(id) })
          end
        end
      end
    end
    if total == 0 then return rows end
    table.sort(open, function(a, b)
      if a.progress ~= b.progress then return a.progress > b.progress end
      return a.name < b.name
    end)
    local summary = done .. " of " .. total .. " challenges done."
    local unspent, spent = Legacy.Points()
    if unspent then
      summary = summary .. " " .. unspent .. " Legacy point" .. (unspent == 1 and "" or "s") .. " to spend, " .. spent .. " spent on this character."
    end
    tinsert(rows, { note = true, text = summary })
    for _, row in ipairs(open) do tinsert(rows, row) end
    return rows
  end
end

-- ---------------------------------------------------------------------------
-- Where a quest starts: opens the world map on the right zone and drops a pulsing pin on
-- the quest giver. Data.questStarts[quest id] = { giver, world map id, x, y }, x and y in
-- percent of the map, the way coordinates are usually written.

local MapPin = {}
do
  local pin

  -- The part of the world map that pins sit on.
  local function Canvas()
    if type(WorldMapFrame) ~= "table" then return nil end
    if WorldMapFrame.GetCanvas then
      local ok, canvas = pcall(WorldMapFrame.GetCanvas, WorldMapFrame)
      if ok and type(canvas) == "table" then return canvas end
    end
    local scroll = WorldMapFrame.ScrollContainer
    return type(scroll) == "table" and type(scroll.Child) == "table" and scroll.Child or nil
  end

  -- Puts the pin on its spot if the map is showing its zone, and hides it on any other map.
  local function Place()
    if not pin or not pin.map then return end
    local canvas = Canvas()
    local showing = canvas and WorldMapFrame.GetMapID and Plain(WorldMapFrame:GetMapID()) or nil
    if showing ~= pin.map then
      pin:Hide()
      return
    end
    pin:SetParent(canvas)
    pin:SetFrameStrata("FULLSCREEN_DIALOG") -- above the map's own pins, whichever way the map is shown
    pin:ClearAllPoints()
    pin:SetPoint("CENTER", canvas, "TOPLEFT", canvas:GetWidth() * pin.x / 100, -canvas:GetHeight() * pin.y / 100)
    pin:Show()
  end

  function MapPin.Clear()
    if not pin then return end
    pin.map = nil
    pin:Hide()
    if GameTooltip then GameTooltip:Hide() end
  end

  local function Build()
    if pin then return pin end
    pin = CreateFrame("Button", "WishwellMapPin", UIParent)
    pin:SetSize(28, 28)
    pin.glow = pin:CreateTexture(nil, "BACKGROUND")
    pin.glow:SetTexture("Interface\\Cooldown\\star4")
    pin.glow:SetBlendMode("ADD")
    pin.glow:SetVertexColor(1, 0.82, 0)
    pin.glow:SetPoint("CENTER")
    pin.icon = pin:CreateTexture(nil, "ARTWORK")
    pin.icon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    pin.icon:SetAllPoints()
    -- The ping: a glow that swells and fades, over and over.
    pin.t = 0
    pin:SetScript("OnUpdate", function(self, elapsed)
      self.t = (self.t + (elapsed or 0)) % 1.2
      local k = self.t / 1.2
      self.glow:SetSize(40 + 70 * k, 40 + 70 * k)
      self.glow:SetAlpha(1 - k)
    end)
    pin:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(self.title or "Quest")
      if self.giver ~= self.title then GameTooltip:AddLine("Starts with " .. (self.giver or "someone here") .. ".", 1, 1, 1) end
      GameTooltip:AddLine("Click to remove this pin.", 0.6, 0.6, 0.6)
      GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
    pin:SetScript("OnClick", MapPin.Clear)
    -- Follow the map as the player looks at other zones and comes back.
    if hooksecurefunc and type(WorldMapFrame.OnMapChanged) == "function" then
      pcall(hooksecurefunc, WorldMapFrame, "OnMapChanged", function() pcall(Place) end)
    end
    if WorldMapFrame.HookScript then pcall(WorldMapFrame.HookScript, WorldMapFrame, "OnShow", function() pcall(Place) end) end
    return pin
  end

  -- Coming back from the map. Wishwell steps aside to show the map; when the map closes
  -- again (its close button, Esc, or the Back to Wishwell button on it) Wishwell returns.
  -- MapPin.onReturn is set by the window code further down.
  local back
  local returning = false

  local function CloseMap()
    if type(WorldMapFrame) ~= "table" then return end
    if HideUIPanel and pcall(HideUIPanel, WorldMapFrame) and not WorldMapFrame:IsShown() then return end
    pcall(WorldMapFrame.Hide, WorldMapFrame)
  end

  -- page: the tab to come back to (the Quests tab if not given).
  function MapPin.ReturnAfter(page)
    MapPin.returnPage = page
    if type(WorldMapFrame) ~= "table" or not WorldMapFrame.HookScript then return end
    if not back then
      back = UI.MakeButton("WishwellMapBack", WorldMapFrame)
      back:SetSize(160, 26)
      back:SetPoint("BOTTOM", WorldMapFrame, "BOTTOM", 0, 12)
      back:SetFrameStrata("FULLSCREEN_DIALOG")
      back:SetText("Back to Wishwell")
      back:SetScript("OnClick", CloseMap)
      pcall(WorldMapFrame.HookScript, WorldMapFrame, "OnHide", function()
        if not returning then return end
        returning = false
        back:Hide()
        -- A moment later, so the Esc that closed the map is not also taken by Wishwell.
        After(0, function()
          if MapPin.onReturn then pcall(MapPin.onReturn, MapPin.returnPage) end
        end)
      end)
    end
    returning = true
    back:Show()
  end

  -- Where a quest starts, or nil: giver, world map id, x, y.
  function MapPin.Start(questId)
    local start = type(Data.questStarts) == "table" and Data.questStarts[questId] or nil
    if type(start) ~= "table" then return nil end
    return start[1], start[2], start[3], start[4]
  end

  -- Says in chat where the quest starts, then opens the world map there with a pin.
  -- Returns true if the map was opened.
  -- questId: a quest (the pin goes on whoever starts it), or a spot { who, map, x, y }.
  function MapPin.Show(questId, title)
    local giver, map, x, y
    local spot = type(questId) == "table"
    if spot then
      giver, map, x, y = questId[1], questId[2], questId[3], questId[4]
    else
      giver, map, x, y = MapPin.Start(questId)
    end
    if not giver then
      Print(title .. ": Wishwell does not know where this one starts. It may begin from an item that drops.")
      return false
    end
    local zone
    if C_Map and C_Map.GetMapInfo then
      local ok, info = pcall(C_Map.GetMapInfo, map)
      zone = ok and type(info) == "table" and Plain(info.name) or nil
    end
    Print(title .. (spot and " is" or (" starts with " .. giver)) .. (type(zone) == "string" and (" in " .. zone) or "") .. format(" (%.1f, %.1f).", x, y))
    if type(WorldMapFrame) ~= "table" or not WorldMapFrame.SetMapID or not Canvas() then return false end
    Build()
    pin.map, pin.x, pin.y, pin.title, pin.giver = map, x, y, title, giver
    if InCombatLockdown and InCombatLockdown() then
      Print("You are in combat, so open the map yourself when it is over. The pin will be there.")
      return false
    end
    if not WorldMapFrame:IsShown() then
      if ToggleWorldMap then ToggleWorldMap() else WorldMapFrame:Show() end
    end
    pcall(WorldMapFrame.SetMapID, WorldMapFrame, map)
    Place()
    return true
  end
end

-- ---------------------------------------------------------------------------
-- Talents: which talent to take next. The player picks a build (damage, tank or healing);
-- Wishwell reads the talents already taken and lists the rest in the order to take them.
-- Each build is a standard level 70 build, checked against the talent trees when the data
-- is made. db.talents[character] = build key.

local MAX_LEVEL = 60 -- WoW Forever stops here

local Talents = {}
do
  local ROLE = {
    dps = { "Damage", "Interface\\Icons\\Ability_DualWield" },
    tank = { "Tank", "Interface\\Icons\\Ability_Defend" },
    heal = { "Healing", "Interface\\Icons\\Spell_Holy_FlashHeal" },
  }
  Talents.ROLE = ROLE

  local function Mine()
    local all = Data.talents
    return type(all) == "table" and playerClass and all[playerClass] or nil
  end

  function Talents.Builds()
    local mine = Mine()
    return mine and mine.builds or {}
  end

  function Talents.Chosen()
    local key = type(db.talents) == "table" and db.talents[Chars.Key()] or nil
    if not key then return nil end
    for _, build in ipairs(Talents.Builds()) do
      if build.key == key then return build end
    end
    return nil
  end

  -- key: a build's key, or nil to go back to the list of builds.
  function Talents.Choose(key)
    if type(db.talents) ~= "table" then db.talents = {} end
    db.talents[Chars.Key()] = key
    Compare.GearChanged() -- gear is judged for the build
    Refresh()
  end

  -- "41 Fire / 20 Frost", biggest tree first.
  function Talents.TreeText(build)
    local mine = Mine()
    local order, parts = { 1, 2, 3 }, {}
    table.sort(order, function(a, b)
      if build.points[a] ~= build.points[b] then return build.points[a] > build.points[b] end
      return a < b
    end)
    for _, tab in ipairs(order) do
      if build.points[tab] > 0 then tinsert(parts, build.points[tab] .. " " .. mine.trees[tab]) end
    end
    return table.concat(parts, " / ")
  end

  -- Fills a tooltip with a talent as the game describes it: its name, rank and what it does.
  -- The talent's own tooltip first, then its link, since not every client fills in both.
  -- Returns true if the tooltip has more in it than a name.
  function Talents.FillTip(tip, tab, index)
    local function Took()
      return (tonumber((tip:NumLines())) or 0) >= 2
    end
    if tip.SetTalent and pcall(tip.SetTalent, tip, tab, index) and Took() then return true end
    if GetTalentLink and tip.SetHyperlink then
      local ok, link = pcall(GetTalentLink, tab, index)
      link = ok and Plain(link) or nil
      if type(link) == "string" and pcall(tip.SetHyperlink, tip, link) and Took() then return true end
    end
    return false
  end

  -- The talents the character has now: [tree][row * 10 + column] = { index, name, icon, rank },
  -- and how many points are spent. nil if the game will not say.
  local function Read()
    if not (GetNumTalents and GetTalentInfo) then return nil end
    local have, spent, found = {}, 0, false
    for tab = 1, 3 do
      have[tab] = {}
      for i = 1, tonumber(Plain(GetNumTalents(tab))) or 0 do
        local name, icon, tier, column, rank, maxRank = GetTalentInfo(tab, i)
        name, tier, column, rank, maxRank = Plain(name), Plain(tier), Plain(column), Plain(rank), Plain(maxRank)
        if type(name) == "string" and type(tier) == "number" and type(column) == "number" then
          rank = type(rank) == "number" and rank or 0
          have[tab][tier * 10 + column] = { index = i, name = name, icon = Plain(icon), rank = rank,
            max = type(maxRank) == "number" and maxRank or nil }
          spent = spent + rank
          found = true
        end
      end
    end
    if not found then return nil end
    return have, spent
  end

  -- The build gear should be judged for: the one picked on the Talents tab, or failing that
  -- the tree with the most points in it. Returns its key and name, or nil with no points spent.
  local TREE_SPEC = {
    DRUID = { "balance", "cat", "resto" }, HUNTER = { "bm", "mm", "sv" }, MAGE = { "arcane", "fire", "frost" },
    PALADIN = { "holy", "prot", "ret" }, PRIEST = { "holy", "holy", "shadow" }, ROGUE = { "mutilate", "combat", "combat" },
    SHAMAN = { "ele", "enh", "resto" }, WARLOCK = { "aff", "demo", "destro" }, WARRIOR = { "arms", "fury", "prot" },
  }
  function Talents.Spec()
    local function Named(build)
      return build.key, (gsub(build.name, " %(.*%)$", ""))
    end
    local chosen = Talents.Chosen()
    if chosen then return Named(chosen) end
    local have = Read()
    local trees = playerClass and TREE_SPEC[playerClass]
    if not have or not trees then return nil end
    local best, most = nil, 0
    for tab = 1, 3 do
      local points = 0
      for _, talent in pairs(have[tab]) do points = points + talent.rank end
      if points > most then best, most = tab, points end
    end
    if not best then return nil end
    for _, build in ipairs(Talents.Builds()) do
      if build.key == trees[best] then return Named(build) end
    end
    return nil
  end
  Compare.Spec = Talents.Spec

  -- The three talent trees as they stand, against the chosen build if there is one:
  --   { { name, spent, planned, cells = { { tab, index, tier, column, icon, name, rank, max, plan }, ... } }, ... }
  -- plan is how many points the build puts in that talent (0 if none, or no build chosen).
  function Talents.Tree()
    local have = Read()
    local mine = Mine()
    if not have or not mine then return nil end
    local build = Talents.Chosen()
    local plan = {}
    if build then
      for i = 1, math.floor(#build.order / 3) do
        local code = strsub(build.order, i * 3 - 2, i * 3)
        plan[code] = (plan[code] or 0) + 1
      end
    end
    local trees = {}
    for tab = 1, 3 do
      local tree = { name = mine.trees and mine.trees[tab] or ("Tree " .. tab), spent = 0, planned = 0, cells = {} }
      local keys = {}
      for key in pairs(have[tab]) do tinsert(keys, key) end
      table.sort(keys)
      for _, key in ipairs(keys) do
        local talent = have[tab][key]
        local want = plan[tab .. key] or 0
        tree.spent = tree.spent + talent.rank
        tree.planned = tree.planned + want
        tinsert(tree.cells, { tab = tab, index = talent.index, tier = math.floor(key / 10), column = key % 10, icon = talent.icon,
          name = talent.name, rank = talent.rank, max = talent.max, plan = want })
      end
      trees[tab] = tree
    end
    return trees, build
  end

  -- Where the character stands against a build, or nil if the talents cannot be read:
  --   placed, total: points of the build already taken, and how many it has
  --   extra: points spent on talents the build does not use
  --   free: points waiting to be spent
  --   steps: what is left, in order, one entry per talent:
  --          { tab, index, name, icon, tree, from, to, first, last }
  --          from/to are ranks; first/last are the levels those points arrive at (0 = now).
  function Talents.Progress(build)
    local have, spent = Read()
    if not have then return nil end
    local mine = Mine()
    local level = Quests.MyLevel()
    local free = math.max(0, level - 9 - spent)
    local planned, placed, waiting, steps = {}, 0, 0, {}
    local total = math.floor(#build.order / 3)
    for i = 1, total do
      local code = strsub(build.order, i * 3 - 2, i * 3)
      local tab = tonumber(strsub(code, 1, 1))
      local talent = have[tab] and have[tab][tonumber(strsub(code, 2, 3))]
      if talent then
        planned[code] = (planned[code] or 0) + 1
        if planned[code] <= talent.rank then
          placed = placed + 1
        else
          waiting = waiting + 1
          local when = waiting <= free and 0 or (math.max(level, 9) + waiting - free)
          local last = steps[#steps]
          if last and last.code == code then
            last.to, last.last = planned[code], when
          else
            tinsert(steps, { talent = true, code = code, tab = tab, index = talent.index, name = talent.name, icon = talent.icon,
              tree = mine.trees[tab], from = planned[code], to = planned[code], first = when, last = when })
          end
        end
      end
    end
    return { placed = placed, total = total, extra = math.max(0, spent - placed), free = free, steps = steps }
  end

  -- "Fire · ranks 2 to 5 · levels 31 to 34"
  function Talents.StepText(step)
    local text = step.tree .. " · " .. (step.from == step.to and ("rank " .. step.to) or ("ranks " .. step.from .. " to " .. step.to))
    -- Level 70 is the top. A point that would only arrive after that never arrives: there
    -- are points spent outside the build, and it takes a talent reset to free them.
    local RESET = "|cffff9933needs a talent reset to fit|r"
    if step.last == 0 then
      text = text .. " · |cff40ff40spend now|r"
    elseif step.first > MAX_LEVEL then
      text = text .. " · " .. RESET
    elseif step.last > MAX_LEVEL then
      text = text .. " · " .. (step.first == 0 and "|cff40ff40start now|r" or ("from level " .. step.first)) .. " · the rest " .. RESET
    elseif step.first == 0 then
      text = text .. " · |cff40ff40start now|r, done at level " .. step.last
    elseif step.first == step.last then
      text = text .. " · at level " .. step.first
    else
      text = text .. " · levels " .. step.first .. " to " .. step.last
    end
    return text
  end

  -- Rows for the list. With no build chosen: the builds to pick from. With one chosen:
  -- that build, then the talents still to take. Also returns the progress, when there is any.
  function Talents.Rows()
    local rows = {}
    local chosen = Talents.Chosen()
    if not chosen then
      local seen = {}
      for _, build in ipairs(Talents.Builds()) do
        tinsert(rows, { talent = true, build = build, best = not seen[build.role] })
        seen[build.role] = true
      end
      return rows, nil
    end
    tinsert(rows, { talent = true, build = chosen, chosen = true })
    local progress = Talents.Progress(chosen)
    if not progress then
      tinsert(rows, { note = true, text = "Wishwell could not read your talents yet. Close this window and open it again." })
      return rows, nil
    end
    if progress.extra > 0 then
      tinsert(rows, { note = true, text = progress.extra .. " of your points are outside this build. To follow it exactly, unlearn your talents at a class trainer." })
    end
    if #progress.steps == 0 then
      tinsert(rows, { note = true, text = "Your talents match this build. Nothing left to place." })
    end
    for _, step in ipairs(progress.steps) do tinsert(rows, step) end
    return rows, progress
  end

  function Talents.Status()
    if #Talents.Builds() == 0 then return "Wishwell has no talent builds for this class." end
    local chosen = Talents.Chosen()
    if not chosen then
      return "Pick how you want to play: damage, tank or healing. Wishwell then lists your talents in the order to take them."
    end
    local progress = Talents.Progress(chosen)
    if not progress then return chosen.name end
    local text = chosen.name .. ": " .. progress.placed .. " of " .. progress.total .. " points placed."
    local nextStep = progress.steps[1]
    if progress.free > 0 and nextStep then
      text = text .. " You have " .. progress.free .. " point" .. (progress.free == 1 and "" or "s") .. " to spend. Next: " .. nextStep.name .. "."
    elseif nextStep and nextStep.first > MAX_LEVEL then
      text = text .. " The rest needs a talent reset to fit."
    elseif nextStep then
      text = text .. " Next: " .. nextStep.name .. " at level " .. nextStep.first .. "."
    end
    return text
  end

  -- Spending the points. Only ever after the player has said yes (see UI.AskTalents): talent
  -- points cost gold to take back. One point is spent at a time and the next waits for the
  -- game to confirm it, so nothing is skipped and nothing goes anywhere the build does not say.
  local applying

  -- How many points the chosen build can take right now, and the talents they go into.
  function Talents.Ready()
    local build = Talents.Chosen()
    local progress = build and Talents.Progress(build) or nil
    if not progress or progress.free <= 0 or not LearnTalent then return 0, {}, build end
    local names, points = {}, 0
    for _, step in ipairs(progress.steps) do
      if step.first ~= 0 then break end
      local last = step.last == 0 and step.to or nil
      -- A talent that starts now may finish at a later level; count only the ranks free today.
      local ranks = step.to - step.from + 1
      if not last then ranks = math.max(1, progress.free - points) end
      ranks = math.min(ranks, progress.free - points)
      if ranks <= 0 then break end
      points = points + ranks
      tinsert(names, step.name .. (ranks > 1 and (" x" .. ranks) or ""))
    end
    return points, names, build
  end

  local function Finish(why)
    local run = applying
    applying = nil
    if not run then return end
    local build = Talents.Chosen()
    local progress = build and Talents.Progress(build) or nil
    local spent = progress and (progress.placed - run.placed) or 0
    if spent > 0 then
      Print(spent .. " talent point" .. (spent == 1 and "" or "s") .. " spent on " .. run.name .. "." .. (why and (" " .. why) or ""))
    else
      Print("No talent points were spent." .. (why and (" " .. why) or " The game did not accept the next talent in the build."))
    end
    Refresh()
  end

  local function SpendNext()
    if not applying then return end
    local build = Talents.Chosen()
    local progress = build and Talents.Progress(build) or nil
    local step = progress and progress.steps[1] or nil
    if not build or build.key ~= applying.key then return Finish("You changed build, so it stopped.") end
    if not step or progress.free <= 0 or step.first ~= 0 then return Finish() end
    if applying.limit and progress.placed - applying.placed >= applying.limit then return Finish() end
    -- The same point refused three times: stop instead of trying for ever.
    if progress.placed == applying.last then
      applying.tries = applying.tries + 1
      if applying.tries >= 3 then return Finish("The game would not take " .. step.name .. ", so it stopped there.") end
    else
      applying.last, applying.tries = progress.placed, 0
    end
    applying.turn = applying.turn + 1
    local turn = applying.turn
    pcall(LearnTalent, step.tab, step.index)
    After(1.5, function()
      if applying and applying.turn == turn then SpendNext() end
    end)
  end

  -- Spends every point that is free right now, in the build's order.
  -- limit: spend at most this many (nil for all of them).
  function Talents.Apply(limit)
    if applying or not LearnTalent then return false end
    local points, _, build = Talents.Ready()
    if points <= 0 or not build then return false end
    local progress = Talents.Progress(build)
    applying = { key = build.key, name = build.name, placed = progress.placed, last = -1, tries = 0, turn = 0, limit = limit }
    SpendNext()
    return true
  end

  -- The game has confirmed a point: on to the next one.
  function Talents.PointsChanged()
    if not applying then return end
    local turn = applying.turn
    After(0.2, function()
      if applying and applying.turn == turn then SpendNext() end
    end)
  end

  function Talents.Applying()
    return applying ~= nil
  end

  -- A build row was clicked: use it, or go back to the list from the chosen one.
  function Talents.Click(item)
    if not item.build then return end
    Talents.Choose((not item.chosen) and item.build.key or nil)
  end
end

-- ---------------------------------------------------------------------------
-- Settings: every switch in one place, so nobody has to remember slash commands.

local Settings = {}
do
  -- The sections of the Settings page, in the order of their buttons.
  Settings.GROUPS = { { "window", "Window" }, { "wisp", "Wisp" }, { "popups", "Pop-ups" }, { "loot", "Loot" } }

  -- key: the saved setting. An unset setting counts as on, except where "off" is the default.
  -- group: the section of the Settings page it is listed under.
  local LIST = {
    { key = "popup", group = "popups", label = "Pop-ups", text = "Every pop-up: entering a dungeon, levelling up, finishing a run." },
    { key = "lootPopup", group = "popups", label = "Dungeon loot pop-up", text = "The pop-up listing gear for you when you walk into a raid or dungeon." },
    { key = "wisp", group = "popups", label = "The wisp", text = "The little wisp that floats around those pop-ups." },
    { key = "sound", group = "wisp", label = "Sounds", text = "The sound when a wishlist item drops or a pop-up appears." },
    { key = "tips", group = "loot", label = "Upgrade tips", text = "\"Upgrade for you\" on item tooltips, loot rolls and quest rewards." },
    { key = "hints", group = "wisp", label = "First-time tips", text = "One-time explanations from the wisp for new players." },
    { key = "share", group = "loot", label = "Share my wishlist", text = "Tell group members with Wishwell what you want in a dungeon." },
    { key = "minimapHidden", group = "window", label = "Minimap button", text = "The Wishwell button on the minimap.", inverted = true },
    { key = "size", group = "window", label = "Window size", text = "How big the Wishwell window is. Click to step through the sizes.",
      choices = { { 0.7, "Small" }, { 0.85, "Medium" }, { 1, "Large" }, { 1.15, "Extra large" } } },
    { key = "dropAlert", group = "loot", label = "Wishlist drop alert", text = "The chat line and on-screen message when something on your wishlist drops." },
    { key = "dropSay", group = "loot", label = "Tell my group", text = "Also says it in party or raid chat when something on your wishlist drops.", off = true },
    { key = "pinPrompt", group = "popups", label = "Pin recipe button", text = "The wisp's Pin recipe button above your profession window." },
    { key = "news", group = "popups", label = "What's new", text = "A run-down from the wisp the first time you log in after an update." },
    { key = "tracker", group = "popups", label = "Wishlist tracker", text = "A small list of your wishlist on screen, to drag wherever you like." },
    { key = "hub", group = "window", label = "Welcome page", text = "Open on the welcome page. Off: open where you left off." },
    { key = "chatter", group = "wisp", label = "Wisp's remarks", text = "The little remarks Wisp adds after its answers." },
    { key = "smooth", group = "window", label = "Smooth look", text = "Rounded dark panels and soft buttons. Off: the game's own window art. Type /reload after changing it." },
    { key = "combatClose", group = "window", label = "Close in combat", text = "Closes the Wishwell window when a fight starts." },
    { key = "preload", group = "loot", label = "Preload loot", text = "Loads every raid and dungeon drop in the background after you log in." },
  }

  function Settings.IsOn(entry)
    if entry.inverted then return not db[entry.key] end
    if entry.off then return db[entry.key] == true end
    return db[entry.key] ~= false
  end

  -- How big the window is drawn. Medium unless a size was picked (or, from older versions,
  -- "Smaller window" was switched off, which meant full size).
  function Settings.Size()
    return tonumber(db.size) or (db.small == false and 1 or 0.85)
  end

  -- For a setting with choices: the one in use, as index and { value, name }.
  function Settings.Choice(entry)
    local now = Settings.Size()
    for i, choice in ipairs(entry.choices) do
      if math.abs(choice[1] - now) < 0.01 then return i, choice end
    end
    return 2, entry.choices[2]
  end

  function Settings.Toggle(entry)
    if entry.choices then
      local at = Settings.Choice(entry)
      db[entry.key] = entry.choices[at % #entry.choices + 1][1]
      if Settings.onSize then Settings.onSize() end
      Refresh()
      return
    end
    local on = not Settings.IsOn(entry)
    if entry.inverted then db[entry.key] = not on else db[entry.key] = on end
    if entry.key == "minimapHidden" and Settings.onMinimap then Settings.onMinimap() end
    if entry.key == "tracker" and UI.Tracker then UI.Tracker.Refresh() end
    if entry.key == "preload" and on then Items.PreloadAll() end
    Refresh()
  end

  -- The switches of one section (all of them if none is given).
  function Settings.Rows(group)
    local rows = {}
    for _, entry in ipairs(LIST) do
      if not group or entry.group == group then tinsert(rows, { setting = true, entry = entry }) end
    end
    return rows
  end
end

-- ---------------------------------------------------------------------------
-- "What next?": one screen that answers "what should I do now?" from the other tabs.

local Home = {}
do
  -- Dungeons this character is the right level for, most useful first.
  -- Returns { { row = place, upgrades, wished }, ... }. Heroic dungeons are all level 70
  -- and have their own drops, so they are asked for separately.
  function Home.Dungeons(level, heroic)
    local list = {}
    for _, place in ipairs(Data.instances) do
      local right
      if heroic then
        right = level >= 70 and Places.HasHeroic(place.id)
      else
        right = place.min and level >= place.min and level <= place.max + 2
      end
      if place.kind == "dungeon" and right then
        local upgrades, wished = 0, 0
        for _, item in ipairs(Items.ForPlace(place.id)) do
          if Items.Fits(item) and Items.InDiff(item, heroic and true or false) then
            if Wish.Has(item.id) then wished = wished + 1 end
            if Compare.Verdict(Compare.Item(item)) == "up" then upgrades = upgrades + 1 end
          end
        end
        tinsert(list, { row = place, upgrades = upgrades, wished = wished })
      end
    end
    table.sort(list, function(a, b)
      if a.wished ~= b.wished then return a.wished > b.wished end
      if a.upgrades ~= b.upgrades then return a.upgrades > b.upgrades end
      return (a.row.min or 0) < (b.row.min or 0)
    end)
    return list
  end

  local function Plural(n, word)
    return n .. " " .. word .. (n == 1 and "" or "s")
  end

  -- Which raid or dungeon gives the best odds of a wishlist drop in one run.
  -- Returns { place, count, chance } or nil. chance is the odds that at least one drops.
  function Home.FarmPlan()
    local byPlace = {}
    for _, id in ipairs(Wish.Ids()) do
      local placeId = Wish.From(id)
      if placeId and placeId ~= "" and Places.Known(placeId) then
        local entry = byPlace[placeId]
        if not entry then
          entry = { place = placeId, count = 0, miss = 1, known = 0 }
          byPlace[placeId] = entry
        end
        entry.count = entry.count + 1
        local rate = Items.Rate(Items.Row(id, placeId))
        if rate.chance then
          entry.miss = entry.miss * (1 - math.min(rate.chance, 1))
          entry.known = entry.known + 1
        end
      end
    end
    local best
    for _, entry in pairs(byPlace) do
      entry.chance = entry.known > 0 and (1 - entry.miss) or nil
      local better = not best
        or (entry.chance or 0) > (best.chance or 0)
        or ((entry.chance or 0) == (best.chance or 0) and (entry.count > best.count or (entry.count == best.count and entry.place < best.place)))
      if better then best = entry end
    end
    return best
  end

  -- The suggestions, as rows for the list. Each has a title, a line of detail, an icon and
  -- what happens when you click it.
  function Home.Rows()
    local rows = {}
    local function Add(icon, title, text, go)
      tinsert(rows, { advice = true, icon = icon, title = title, text = text, go = go })
    end
    local level = Quests.MyLevel()
    local F = Quests.F

    -- Talent points waiting to be spent come first: it takes a moment and makes everything else easier.
    do
      local build = Talents.Chosen()
      local progress = build and Talents.Progress(build) or nil
      local nextStep = progress and progress.steps[1] or nil
      if nextStep and progress.free > 0 then
        Add(nextStep.icon or "Interface\\Icons\\Ability_Marksmanship", "Talent point to spend: " .. nextStep.name,
          Plural(progress.free, "point") .. " waiting. This is next in your " .. build.name .. " build, in the " .. nextStep.tree .. " tree.",
          function() UI.ShowPage("talents") end)
      elseif not build and level >= 10 and #Talents.Builds() > 0 then
        Add("Interface\\Icons\\Ability_Marksmanship", "Pick a talent build",
          "Choose damage, tank or healing and Wishwell lists your talents in the order to take them.",
          function() UI.ShowPage("talents") end)
      end
    end

    -- 1. The best quest where you are standing.
    local hereId, hereName = Quests.ZoneHere()
    if hereId then
      local list, total, doable = Quests.List(hereId, true, "")
      if doable > 0 then
        local best = list[1]
        Add("Interface\\GossipFrame\\AvailableQuestIcon", "Best quest here: " .. best.quest[F.NAME],
          Quests.Number(best.xp) .. " XP. " .. Plural(doable, "quest") .. " to do in " .. hereName .. ", " .. Quests.Number(total) .. " XP in all.",
          function()
            db.questZone = "HERE"
            UI.ShowPage("quests")
          end)
      end
    end

    -- 2. Where the most quest XP is waiting, other than here.
    local shown = 0
    for _, zone in ipairs(Quests.ZoneTotals()) do
      if shown >= 2 then break end
      if zone.zone ~= hereId and zone.zone > 0 and zone.count >= 3 then
        shown = shown + 1
        Add("Interface\\Icons\\INV_Misc_Map_01", (shown == 1 and "Go next: " or "Or: ") .. zone.name,
          Plural(zone.count, "quest") .. " you can do, " .. Quests.Number(zone.xp) .. " XP in all.",
          function()
            db.questZone = zone.zone
            UI.ShowPage("quests")
          end)
      end
    end

    -- 3. Spells.
    local function OpenTraining() UI.ShowPage("train") end
    if Train.Scanned() then
      local _, _, ready, nextGroup = Train.Rows()
      if ready then
        local money = GetMoney and Plain(GetMoney()) or nil
        local detail = "Costs " .. Train.Money(ready.total) .. "."
        if type(money) == "number" then
          if money >= ready.total then
            detail = detail .. " You have " .. Train.Money(money) .. ", so you can afford all of it."
          else
            detail = detail .. " You have " .. Train.Money(money) .. ", " .. Train.Money(ready.total - money) .. " short."
          end
        end
        Add("Interface\\Icons\\INV_Misc_Book_11", "Train " .. Plural(ready.count, "spell") .. " at your class trainer", detail, OpenTraining)
      elseif nextGroup then
        Add("Interface\\Icons\\INV_Misc_Book_11", "Next spells at level " .. nextGroup.level,
          Plural(nextGroup.count, "spell") .. ", " .. Train.Money(nextGroup.total) .. " in all. Nothing to train right now.", OpenTraining)
      end
    else
      Add("Interface\\Icons\\INV_Misc_Book_11", "Visit your class trainer",
        "Wishwell reads the trainer's list once, then shows every spell you have coming and what it costs.", OpenTraining)
    end

    -- 4. A dungeon worth running: a normal one, and at 70 a heroic one too.
    for _, heroic in ipairs({ false, true }) do
      local dungeon = Home.Dungeons(level, heroic)[1]
      if dungeon then
        local place = dungeon.row
        local detail
        if dungeon.upgrades > 0 or dungeon.wished > 0 then
          detail = Plural(dungeon.upgrades, "upgrade") .. " for you"
            .. (dungeon.wished > 0 and (", " .. dungeon.wished .. " on your wishlist") or "") .. "."
        else
          detail = heroic and "Click to see what drops on heroic." or "Right for your level. Click to see what drops."
        end
        local title = heroic and ("Heroic dungeon: " .. place.name)
          or ("Dungeon for your level: " .. place.name .. " (" .. place.min .. "-" .. place.max .. ")")
        Add("Interface\\Icons\\INV_Misc_Key_03", title, detail, function()
          UI.Browse(place.id, heroic)
          UI.ShowPage("browse")
        end)
      end
    end

    -- Gold: what you are saving for and how far along you are.
    local goal = Chars.Goal()
    local money = GetMoney and Plain(GetMoney()) or nil
    if goal and type(money) == "number" then
      local detail
      if money >= goal.amount then
        detail = "You have " .. Train.Money(money) .. ". That is enough!"
      else
        detail = Train.Money(money) .. " of " .. Train.Money(goal.amount) .. " (" .. math.floor(money / goal.amount * 100) .. "%). "
          .. Train.Money(goal.amount - money) .. " to go."
        local pace = Chars.Pace()
        if pace then
          local hours = (goal.amount - money) / pace
          detail = detail .. " About " .. (hours < 1.5 and "an hour" or (math.floor(hours + 0.5) .. " hours")) .. " at today's pace."
        end
      end
      if goal.suggested then detail = detail .. " (Classic price. Click to set your own goal.)" end
      Add("Interface\\Icons\\INV_Misc_Coin_01", "Saving for: " .. goal.name, detail, UI.AskGoal)
    end

    -- The run with the best odds of a wishlist drop.
    local plan = Home.FarmPlan()
    if plan then
      local detail = Plural(plan.count, "wishlist item") .. " there."
      if plan.chance then
        local runs = math.floor(1 / plan.chance + 0.5)
        if runs <= 1 then
          detail = detail .. " Most runs should drop at least one."
        else
          detail = detail .. " About 1 run in " .. runs .. " drops at least one."
        end
      else
        detail = detail .. " Drop chances are not known yet."
      end
      Add("Interface\\Icons\\INV_Misc_Bag_10", "Best run for your wishlist: " .. Places.Name(plan.place), detail, function()
        db.browseId = plan.place
        db.zone = "ALL"
        UI.boss = "ALL"
        UI.ShowPage("browse")
      end)
    end

    -- 5. The wishlist.
    local wishes = Wish.Count()
    if wishes > 0 then
      Add("Interface\\Icons\\INV_Misc_Note_02", "Your wishlist: " .. Plural(wishes, "item"),
        "Click to see them and try them on. You are told when one drops.", function() UI.ShowPage("wish") end)
    else
      Add("Interface\\Icons\\INV_Misc_Note_02", "Start a wishlist",
        "Open the Loot tab, click Wish on gear you want, and Wishwell tells you when it drops.", function() UI.ShowPage("browse") end)
    end
    return rows
  end
end

-- ---------------------------------------------------------------------------
-- Ask: type a question, get an answer from the data Wishwell has. No internet and no AI: it
-- looks the words up in the loot lists, the quest list, the talent builds and the world
-- data (every NPC, item and quest objective, from Questie's database, loaded the first time
-- a question is asked). It answers what it finds and says so when it finds nothing.

local Ask = {}
do
  -- Role flags on NPCs (the game's own bits).
  local ROLE = {
    { 65536, "Innkeeper", { "innkeeper", "inn", "hearth" } },
    { 4096, "Repairs", { "repair", "repairs", "armorer" } },
    { 8192, "Flight master", { "flight", "flightmaster", "flightpath", "gryphon", "wyvern", "taxi" } },
    { 131072, "Banker", { "bank", "banker" } },
    { 2097152, "Auctioneer", { "auction", "auctioneer", "ah" } },
    { 4194304, "Stable master", { "stable", "stables" } },
    { 32, "Class trainer", { "trainer", "train" } },
    { 64, "Profession trainer", {} },
    { 128, "Vendor", { "vendor", "merchant", "shop" } },
    { 1048576, "Battlemaster", { "battlemaster" } },
  }
  local function Has(flags, bit)
    return math.floor((flags or 0) / bit) % 2 == 1
  end

  -- Words that are part of the question, not of the thing asked about.
  local FILLER = {}
  for word in gmatch("where is are was the a an of do does did i can you me my find get to from for in on at who what which how it that this"
    .. " drop drops dropped dropping loot sell sells sold selling buy vendor comes come located location quest start starts end ends turn"
    .. " hand give gives reward rewards about tell show please item npc boss mob much many there any mean means meaning stand stands short define definition he she they them him her his their those these make makes made craft crafts crafted why so too", "%a+") do
    FILLER[word] = true
  end

  -- Colour, so an answer can be read at a glance: who (orange), where (green), quests (gold),
  -- items in their own rarity colour, and the thing you typed in white.
  local function Who(text) return "|cffff9d5c" .. text .. "|r" end
  local function Spot(text) return "|cff7fd4a3" .. text .. "|r" end
  local function Task(text) return "|cffffd100" .. text .. "|r" end
  local function Bold(text) return "|cffffffff" .. text .. "|r" end
  local function Thing(id, name)
    local r, g, b = Items.QualityColor(Items.Quality({ id = id }))
    return format("|cff%02x%02x%02x%s|r", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5), name)
  end

  function Ask.World()
    if type(WishwellWorld) == "table" then return WishwellWorld end
    if Ask.tried then return nil end
    Ask.tried = true
    local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if load then pcall(load, "Wishwell_World") end
    return type(WishwellWorld) == "table" and WishwellWorld or nil
  end

  -- "Elwynn Forest (43.8, 65.8)" for a thing's area and spot, and the spot for the map.
  local function Where(world, area, x, y)
    local info = world.areas[area]
    local name = info and info[1] ~= "" and info[1] or nil
    if not name then return nil end
    if not x or x < 0 then return name end
    return format("%s (%.1f, %.1f)", name, x, y), (info[2] or 0) > 0 and info[2] or nil
  end

  local function Roles(flags)
    local list = {}
    for _, role in ipairs(ROLE) do
      if Has(flags, role[1]) then tinsert(list, role[2]) end
    end
    return list
  end

  -- A list row for an NPC.
  local function NpcRow(world, id)
    local n = world.npcs[id]
    if not n then return nil end
    local where, map = Where(world, n[4], n[5], n[6])
    return { npc = true, id = id, name = n[1], min = n[2], max = n[3], where = where, map = map, x = n[5], y = n[6],
      title = n[8] ~= "" and n[8] or nil, roles = Roles(n[7]), rank = n[10], spots = n[11] or 1, foe = n[9] == "" }
  end

  local function NpcLine(world, id)
    local n = world.npcs[id]
    if not n then return nil end
    local where = Where(world, n[4], n[5], n[6])
    return Who(n[1]) .. (where and (" in " .. Spot(where)) or "")
  end

  local function Names(world, ids, limit)
    local parts = {}
    for i = 1, math.min(#ids, limit) do
      local line = NpcLine(world, ids[i])
      if line then tinsert(parts, line) end
    end
    return parts
  end

  local function Level(min, max)
    if not max or max <= 0 then return "" end
    return "level " .. ((min and min > 0 and min ~= max) and (min .. "-" .. max) or max) .. " "
  end

  -- A name as it is compared: lower case, apostrophes dropped, hyphens as spaces. So
  -- "kaelthas" finds Kael'thas and "mana tombs" finds Mana-Tombs.
  local function Norm(text)
    return (gsub(gsub(strlower(text), "['`]", ""), "[%-%s]+", " "))
  end

  -- How well a name fits what was asked: 3 the same, 2 starts with it, 1 has it, nil no.
  -- Failing those, 0.5 if every word asked is somewhere in the name.
  -- People ask in the plural ("cabal initiates"), names are singular, so each is tried both ways.
  local function Singular(word)
    if #word > 4 and strsub(word, -3) == "ies" then return strsub(word, 1, -4) .. "y" end
    if #word > 4 and strsub(word, -3) == "ves" then return strsub(word, 1, -4) .. "f" end
    if #word > 3 and strsub(word, -1) == "s" and strsub(word, -2) ~= "ss" then return strsub(word, 1, -2) end
    return nil
  end
  local function Fit(name, want)
    for _, phrase in ipairs({ want, Singular(want) }) do
      local at = strfind(name, phrase, 1, true)
      if at then
        if #name == #phrase then return 3 end
        return at == 1 and 2 or 1
      end
    end
    local words = Ask.words
    if not words or #words < 2 then return nil end
    for _, word in ipairs(words) do
      local single = Singular(word)
      if not strfind(name, word, 1, true) and not (single and strfind(name, single, 1, true)) then return nil end
    end
    return 0.5
  end

  local function Add(rows, text, icon)
    tinsert(rows, { note = true, text = text, icon = icon })
  end

  -- Everything Wishwell knows about one item.
  local function AboutItem(rows, id, name)
    Ask.mood = "item"
    Ask.topic, Ask.topicItem = name, { id = id, name = name }
    local world = Ask.World()
    local parts = {}
    local shipped = Items.Shipped(id)
    if shipped and shipped.raid and shipped.raid ~= "" then
      local rate = Items.RateText(shipped)
      tinsert(parts, "drops from " .. Who(shipped.boss or "a boss") .. " in " .. Spot(Places.Name(shipped.raid))
        .. (shipped.heroic and " (heroic only)" or (shipped.normalOnly and " (normal only)" or "")) .. (rate and (", " .. rate) or ""))
    end
    local w = world and world.items[id] or nil
    local people = {}
    if w then
      if type(w[4]) == "table" and not (shipped and shipped.raid ~= "") then
        local names = Names(world, w[4], 3)
        if #names > 0 then
          tinsert(parts, "is dropped by " .. table.concat(names, "; ") .. ((w[5] or 0) > #names and (", and " .. (w[5] - #names) .. " more") or ""))
          for _, npc in ipairs(w[4]) do tinsert(people, npc) end
        end
      end
      if type(w[6]) == "table" then
        local names = Names(world, w[6], 3)
        if #names > 0 then
          tinsert(parts, "is sold by " .. table.concat(names, "; "))
          for _, npc in ipairs(w[6]) do tinsert(people, npc) end
        end
      end
      if type(w[7]) == "table" then
        local quests = {}
        for _, questId in ipairs(w[7]) do
          local q = Quests.ById and Quests.ById(questId)
          if q then tinsert(quests, Task(q[Quests.F.NAME])) end
        end
        if #quests > 0 then tinsert(parts, "is a reward from the quest" .. (#quests > 1 and "s " or " ") .. table.concat(quests, ", ")) end
      end
      if type(w[8]) == "table" then
        local found = {}
        for _, objectId in ipairs(w[8]) do
          local o = world.objects[objectId]
          if o then tinsert(found, Bold(o[1]) .. (Where(world, o[2], o[3], o[4]) and (" in " .. Spot((Where(world, o[2], o[3], o[4])))) or "")) end
        end
        if #found > 0 then tinsert(parts, "is found in " .. table.concat(found, "; ")) end
      end
    end
    if #parts == 0 then
      Add(rows, Thing(id, name) .. ": I know the item, but not where it comes from. It may be crafted, or a world drop.", Items.Icon(id))
    else
      Add(rows, Thing(id, name) .. " " .. table.concat(parts, ". It ") .. "."
        .. (w and (w[3] or 0) > 1 and (" Needs level " .. w[3] .. ".") or ""), Items.Icon(id))
    end
    local item = shipped or { id = id, name = name, boss = "Item", raid = "", custom = true }
    -- And whether it is any good for you.
    if Items.Fits(item) then
      local result = Compare.Item({ id = id })
      local verdict = Compare.Verdict(result)
      if verdict and rows[#rows] and rows[#rows].note then
        local line
        if result.wearing then
          line = "|cff999999You're wearing it.|r"
        elseif verdict == "up" then
          line = "|cff40ff40For you: an upgrade.|r"
        elseif verdict == "down" then
          line = "|cffff7070For you: not an upgrade.|r"
        else
          line = "For you: about the same as what you have."
        end
        local why = not result.wearing and Compare.Why(result, Plain((UnitClass("player")))) or nil
        rows[#rows].text = rows[#rows].text .. "\n" .. line .. (why and (" " .. why) or "")
      end
    end
    tinsert(rows, item)
    if world then
      for i = 1, math.min(#people, 6) do
        local row = NpcRow(world, people[i])
        if row then tinsert(rows, row) end
      end
    end
  end

  -- Everything about one NPC: who and where, and what it drops.
  local function AboutNpc(rows, world, id)
    local row = NpcRow(world, id)
    if not row then return end
    local kind = row.rank and row.rank > 0 and (row.rank == 3 and "boss" or "elite") or (row.title or (row.foe and "creature" or "NPC"))
    Ask.mood = (row.rank and row.rank > 0) and "boss" or (row.foe and "mob" or "npc")
    Ask.topic, Ask.topicItem = row.name, nil
    local text = Who(row.name) .. " is a " .. Level(row.min, row.max) .. kind
    if row.where then
      -- Something that roams has many spots; the one given is in the middle of them.
      text = text .. ((row.spots or 1) > 1 and (", found around " .. Spot(row.where) .. " (" .. row.spots .. " spots; the pin marks the middle)") or (" in " .. Spot(row.where)))
    end
    text = text .. "."
    -- Quests that send you after it.
    local wanted = {}
    for questId, w in pairs(world.quests) do
      if type(w[2]) == "table" then
        for _, npc in ipairs(w[2]) do
          if npc == id then
            local q = Quests.ById(questId)
            if q then tinsert(wanted, Task(q[Quests.F.NAME])) end
            break
          end
        end
      end
    end
    table.sort(wanted)
    if #wanted > 0 then
      text = text .. " Wanted for the quest" .. (#wanted > 1 and "s " or " ") .. table.concat(wanted, ", ", 1, math.min(#wanted, 4))
        .. (#wanted > 4 and (" and " .. (#wanted - 4) .. " more") or "") .. "."
    end
    if #row.roles > 0 then text = text .. " " .. table.concat(row.roles, ", ") .. "." end
    -- What it drops: the loot lists first (they have drop rates), then the world data.
    local drops, seen = {}, {}
    local placeId
    for _, item in ipairs(Data.items) do
      if item.boss == row.name and not seen[item.id] then
        seen[item.id] = true
        placeId = placeId or item.raid
        tinsert(drops, item)
      end
    end
    -- A boss in a raid or dungeon: say which, the world data often has no spot for those.
    if placeId and not row.where then
      text = gsub(text, "%.$", "") .. " in " .. Spot(Places.Name(placeId)) .. "."
    end
    local listed = #drops > 0
    if #drops == 0 then
      for itemId, w in pairs(world.items) do
        if type(w[4]) == "table" and (w[5] or 0) <= 12 then
          for _, npc in ipairs(w[4]) do
            if npc == id then
              tinsert(drops, { id = itemId, name = w[1], boss = row.name, raid = "", custom = true })
              break
            end
          end
        end
        if #drops >= 12 then break end
      end
    end
    if #drops > 0 then text = text .. " Drops " .. #drops .. ((not listed and #drops >= 12) and " or more" or "") .. " thing" .. (#drops == 1 and "" or "s") .. " I know of, listed below." end
    Add(rows, text, "Interface\\Icons\\INV_Misc_Head_Human_01")
    tinsert(rows, row)
    for i = 1, math.min(#drops, 30) do tinsert(rows, drops[i]) end
  end

  -- Everything about one quest.
  local function AboutQuest(rows, world, q)
    Ask.mood = "quest"
    Ask.topic, Ask.topicItem = q[Quests.F.NAME], nil
    local F = Quests.F
    local text = Task(q[F.NAME]) .. " is a level " .. q[F.LEVEL] .. " quest"
    local giver, map, x, y = MapPin.Start(q[F.ID])
    if giver then
      local zone
      if C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, map)
        zone = ok and type(info) == "table" and Plain(info.name) or nil
      end
      text = text .. " that starts with " .. Who(giver) .. (type(zone) == "string" and (" in " .. Spot(zone .. format(" (%.1f, %.1f)", x, y))) or format(" (%.1f, %.1f)", x, y))
    end
    text = text .. "."
    local w = world and world.quests[q[F.ID]] or nil
    if w then
      if w[5] and w[5] ~= "" then text = text .. " " .. w[5] end
      if type(w[1]) == "number" and w[1] > 0 and world.npcs[w[1]] then
        text = text .. " Hand it in to " .. NpcLine(world, w[1]) .. "."
      elseif type(w[1]) == "number" and w[1] < 0 and world.objects[-w[1]] then
        text = text .. " Hand it in at " .. Bold(world.objects[-w[1]][1]) .. "."
      end
    end
    Add(rows, text, "Interface\\GossipFrame\\AvailableQuestIcon")
    if w and world then
      if type(w[2]) == "table" then
        for _, npc in ipairs(w[2]) do
          local row = NpcRow(world, npc)
          if row then tinsert(rows, row) end
        end
      end
      if type(w[4]) == "table" then
        for _, itemId in ipairs(w[4]) do
          local item = world.items[itemId]
          if item then tinsert(rows, Items.Shipped(itemId) or { id = itemId, name = item[1], boss = "Quest item", raid = "", custom = true }) end
        end
      end
    end
  end

  -- The nearest people of one kind (innkeeper, repairs, flight master...) in the zone you are in.
  local function Service(rows, world, role)
    local map = C_Map and C_Map.GetBestMapForUnit and Plain(C_Map.GetBestMapForUnit("player")) or nil
    local px, py
    if type(map) == "number" and C_Map.GetPlayerMapPosition then
      local ok, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
      if ok and type(pos) == "table" and pos.GetXY then px, py = pos:GetXY() end
    end
    local side = UnitFactionGroup and Plain((UnitFactionGroup("player"))) or nil
    local mine = side == "Horde" and "H" or (side == "Alliance" and "A" or nil)
    local found = {}
    for id, n in pairs(world.npcs) do
      if Has(n[7], role[1]) and (not mine or n[9] == "" or strfind(n[9], mine, 1, true)) then
        local info = world.areas[n[4]]
        if info and type(map) == "number" and info[2] == map then
          local d = px and ((n[5] - px * 100) ^ 2 + ((n[6] - py * 100) * 0.67) ^ 2) or 0
          tinsert(found, { id = id, d = d })
        end
      end
    end
    table.sort(found, function(a, b)
      if a.d ~= b.d then return a.d < b.d end
      return a.id < b.id
    end)
    if #found == 0 then
      Add(rows, "I don't know of any " .. strlower(role[2]) .. " for you on this map. Ask me again in the next town or zone.", "Interface\\Icons\\INV_Misc_Map_01")
      return
    end
    Add(rows, role[2] .. (#found == 1 and "" or "s") .. " here, nearest first. Click Map for a pin.", "Interface\\Icons\\INV_Misc_Map_01")
    for i = 1, math.min(#found, 10) do tinsert(rows, NpcRow(world, found[i].id)) end
  end

  local HELP = "Clear the box to see examples of what you can ask."

  -- ---- Stat check: where the character stands on each stat of its build --------------
  -- The game's numbers for combat ratings (the same on every version that has them).
  local RATING = { hit = 6, rangedHit = 7, spellHit = 8, haste = 18, rangedHaste = 19, spellHaste = 20 }
  local function Num(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, a, b = pcall(fn, ...)
    if not ok then return nil end
    return tonumber(Plain(a)), tonumber(Plain(b))
  end
  local function Best(fn)
    -- The highest of the six schools of magic.
    local best
    for school = 2, 7 do
      local value = Num(fn, school)
      if value and (not best or value > best) then best = value end
    end
    return best
  end

  -- What the character has of one kind of stat: a number, how to write it, and the cap if
  -- that stat has one. caster and ranged pick which version of hit, crit and haste is meant.
  -- Caps are the ones the guides give, for raid bosses at the top level.
  local function Have(kind, caster, ranged)
    local level = Num(UnitLevel, "player") or 1
    if kind == "str" or kind == "agi" or kind == "sta" or kind == "int" or kind == "spi" then
      local index = ({ str = 1, agi = 2, sta = 3, int = 4, spi = 5 })[kind]
      local _, value = Num(UnitStat, "player", index)
      return value, "%d"
    elseif kind == "ap" then
      local fn = ranged and UnitRangedAttackPower or UnitAttackPower
      if type(fn) ~= "function" then return nil end
      local ok, base, plus, minus = pcall(fn, "player")
      if not ok then return nil end
      base, plus, minus = tonumber(Plain(base)), tonumber(Plain(plus)) or 0, tonumber(Plain(minus)) or 0
      return base and (base + plus + minus) or nil, "%d"
    elseif kind == "sp" then
      return Best(GetSpellBonusDamage), "%d"
    elseif kind == "heal" then
      return (Num(GetSpellBonusHealing)), "%d"
    elseif kind == "hit" then
      local value = Num(GetCombatRatingBonus, caster and RATING.spellHit or (ranged and RATING.rangedHit or RATING.hit))
      local extra = Num(caster and GetSpellHitModifier or GetHitModifier)
      if value and extra and extra > 0 and extra < 50 then value = value + extra end
      return value, "%.1f%%", caster and 16 or 9
    elseif kind == "crit" then
      if caster then return Best(GetSpellCritChance), "%.1f%%" end
      return (Num(ranged and GetRangedCritChance or GetCritChance)), "%.1f%%"
    elseif kind == "haste" then
      return (Num(GetCombatRatingBonus, caster and RATING.spellHaste or (ranged and RATING.rangedHaste or RATING.haste))), "%.1f%%"
    elseif kind == "exp" then
      return (Num(GetExpertise)), "%d", 26
    elseif kind == "def" then
      local base, plus = Num(UnitDefense, "player")
      return base and (base + (plus or 0)) or nil, "%d", level * 5 + 140
    elseif kind == "avoid" then
      local dodge, parry, block = Num(GetDodgeChance), Num(GetParryChance), Num(GetBlockChance)
      if not dodge then return nil end
      return dodge + (parry or 0) + (block or 0), "%.1f%%"
    elseif kind == "armor" then
      local _, value = Num(UnitArmor, "player")
      return value, "%d"
    elseif kind == "mp5" then
      local _, casting = Num(GetManaRegen)
      return casting and casting * 5 or nil, "%d"
    end
    return nil
  end

  -- The whole check, as lines of text and what to work on first.
  local function StatCheck(rows)
    local build = Compare.Build()
    if not build then
      Add(rows, "Spend a talent point and I can check your stats against the tree you are going down.", "Interface\\Icons\\INV_Misc_Book_09")
      return
    end
    local ranged = playerClass == "HUNTER"
    local level = Num(UnitLevel, "player") or 1
    local lines, todo, capped = {}, {}, {}
    for place, kinds in ipairs(build.order) do
      local parts = {}
      for _, kind in ipairs(kinds) do
        local name = ((build.caster and (kind == "hit" or kind == "crit" or kind == "haste")) and "Spell " or "") .. (build.label[kind] or kind)
        local have, how, cap = Have(kind, build.caster, ranged)
        if kind == "exp" or kind == "haste" or kind == "arp" then
          -- Stats this game does not have.
        elseif not have then
          tinsert(parts, name)
          if #todo < 3 then tinsert(todo, name) end
        elseif cap then
          local unit = strfind(how, "%%%%") and "%" or ""
          if have >= cap then
            tinsert(parts, name .. " |cff40ff40" .. format(how, have) .. "|r of " .. cap .. unit .. " |cff40ff40capped|r")
            tinsert(capped, name)
          else
            local short = format(how, cap - have)
            tinsert(parts, name .. " |cffffd100" .. format(how, have) .. "|r of " .. cap .. unit .. " |cffff7070" .. short .. " short|r")
            if #todo < 3 then tinsert(todo, name .. " (" .. short .. " short)") end
          end
        else
          tinsert(parts, name .. " |cffffffff" .. (how == "%d" and Quests.Number(math.floor(have + 0.5)) or format(how, have)) .. "|r")
          if #todo < 3 then tinsert(todo, name) end
        end
      end
      if #parts > 0 then tinsert(lines, (#lines + 1) .. ". " .. table.concat(parts, "  /  ")) end
    end
    Ask.mood = "stats"
    local text = "Stat check for " .. (build.name or "your build") .. ", most important first.\n" .. table.concat(lines, "\n")
    if #todo > 0 then text = text .. "\n\n|cffffd100Work on first:|r " .. table.concat(todo, ", then ") .. "." end
    if #capped > 0 then
      text = text .. "\n|cff999999At its cap, so more is wasted: " .. table.concat(capped, ", ") .. ". Trade the extra for the next stat down.|r"
    end
    text = text .. "\n|cff999999Caps are for raid bosses at the top level" .. (level < MAX_LEVEL and "; while levelling you need less" or "") .. ".|r"
    -- The biggest upgrades Wishwell knows of in the dungeons you can run now.
    local found, seen = {}, {}
    for _, heroic in ipairs({ false, true }) do
      for _, entry in ipairs(Home.Dungeons(level, heroic)) do
        for _, item in ipairs(Items.ForPlace(entry.row.id)) do
          if not seen[item.id] and Items.Fits(item) and Items.InDiff(item, heroic) then
            local result = Compare.Item(item)
            if result and Compare.Verdict(result) == "up" then
              seen[item.id] = true
              tinsert(found, { item = item, score = result.score })
            end
          end
        end
      end
    end
    table.sort(found, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      return a.item.id < b.item.id
    end)
    if #found > 0 then text = text .. "\n\nBelow: the biggest upgrades for you in dungeons you can run now." end
    Add(rows, text, "Interface\\Icons\\INV_Misc_Book_09")
    for i = 1, math.min(#found, 6) do tinsert(rows, found[i].item) end
  end

  -- What the page shows before anything is asked: one line, then examples to click.
  -- Built from what this game ships, so every example has an answer.
  local EXAMPLES = {}
  do
    local item
    for _, candidate in ipairs(Data.items) do
      if candidate.name and candidate.boss and not strfind(candidate.name, "'", 1, true) and not strfind(candidate.boss, "'", 1, true) then
        item = candidate
        break
      end
    end
    local place = Data.instances[1]
    local quest = Data.quests and Data.quests[1]
    local set = Data.sets and Data.sets[1]
    if item then
      tinsert(EXAMPLES, { "Where an item drops", "where does " .. item.name .. " drop", "Interface\\Icons\\INV_Misc_Bag_10" })
      tinsert(EXAMPLES, { "What a boss drops", "what does " .. item.boss .. " drop", "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01" })
    end
    if place then tinsert(EXAMPLES, { "A dungeon or raid", place.name, "Interface\\Icons\\INV_Misc_Key_03" }) end
    if quest then tinsert(EXAMPLES, { "A quest", quest[2], "Interface\\GossipFrame\\AvailableQuestIcon" }) end
    if set then tinsert(EXAMPLES, { "An item set", set.name, "Interface\\Icons\\INV_Chest_Plate04" }) end
  end
  local function Welcome(rows)
    for _, example in ipairs(EXAMPLES) do
      tinsert(rows, { ask = true, name = example[1], text = example[2], icon = example[3], query = example[2] })
    end
  end
  Ask.EXAMPLES = EXAMPLES

  -- ---- Wisp talks back --------------------------------------------------------------
  local WISP = "Interface\\AddOns\\Wishwell\\WispIcon.tga"
  local YES = { yes = true, yeah = true, yep = true, yup = true, y = true, sure = true, ok = true, okay = true, correct = true,
    right = true, ["that one"] = true, ["yes please"] = true, please = true, ya = true, aye = true }
  local NO = { no = true, nope = true, nah = true, n = true, ["not that"] = true, wrong = true }
  local GREET = { hi = true, hello = true, hey = true, hiya = true, yo = true, howdy = true, greetings = true, sup = true, heya = true, morning = true }
  local turn = 0 -- moves on with every message, so the same line is not said twice running
  local function Pick(lines)
    return lines[turn % #lines + 1]
  end
  local function Has(text, ...)
    for i = 1, select("#", ...) do
      if strfind(text, (select(i, ...)), 1, true) then return true end
    end
    return false
  end

  local JOKES = {
    "Why did the rogue cross the road? Nobody knows. Nobody saw him.",
    "A hunter walks into a dungeon. Everything else walks in after him.",
    "I asked a warlock for a healthstone. He asked what was in it for him. A soul shard, as it turned out.",
    "How many paladins does it take to change a torch? One, but he bubbles first.",
    "A mage, a priest and a warrior walk into an inn. The mage made the drinks, the priest paid in mana, and the warrior is still angry about it.",
    "What's a murloc's favourite school of magic? Nobody knows. It all sounds like gargling.",
  }

  -- Something said to Wisp that is not a question about the game: what it says back, and
  -- true as a second value if the examples should follow. nil if it is a real question.
  local function SmallTalk(asked, first, count)
    turn = turn + 1
    local me = UnitName and Plain((UnitName("player"))) or nil
    if type(me) ~= "string" or me == "" then me = "adventurer" end
    if asked == "help" or Has(asked, "what can you do", "what can i ask", "how do you work", "how does this work") then
      return "I look things up in Wishwell's lists for you. Name an item, a quest, a boss or a place and I'll tell you what I know. You can ask about yourself too: \"what should I do next\", \"best upgrade\", \"my quests\". And if I've just told you about something, \"where is he\" or \"what does it drop\" will do. Here are some to try:", true
    end
    if GREET[first] and count <= 3 then
      return Pick({
        "Hi, " .. me .. "! I'm Wisp. Ask me where something drops, where someone is, or about a quest. What are you after?",
        "Hello, " .. me .. "! Wisp here, glowing and ready. What are we hunting today?",
        "Hey, " .. me .. "! Got a question? I've got lists. So many lists.",
      })
    end
    if Has(asked, "thank") or asked == "ty" or asked == "thx" or asked == "cheers" or asked == "tyvm" then
      return Pick({ "Any time!", "Happy to help. What's next?", "You're welcome! Go get that loot.",
        "No trouble at all. Looking things up is my whole personality.", "That's what I'm here for. Well, that and floating." })
    end
    if Has(asked, "are you an ai", "are you ai", "are you a bot", "are you real", "are you alive", "are you human", "chatgpt", "grok", "are you smart") then
      return "I'm a wisp with a very good memory and no internet. Think librarian, not oracle."
    end
    if Has(asked, "who are you", "what are you", "your name", "whats your name") then
      return "I'm Wisp, the little light that lives in Wishwell. I look things up for you: items, quests, bosses and where things are. I'm not an AI, just very quick with a list."
    end
    if Has(asked, "who am i", "what am i") then
      local level = UnitLevel and Plain(UnitLevel("player")) or nil
      local class = UnitClass and Plain((UnitClass("player"))) or nil
      return "You're " .. me .. (type(level) == "number" and (", level " .. level) or "") .. (type(class) == "string" and (" " .. class) or "")
        .. ". And my favourite, obviously. Don't tell the others."
    end
    if Has(asked, "where am i") then
      local zone = GetRealZoneText and Plain(GetRealZoneText()) or nil
      return type(zone) == "string" and zone ~= "" and ("You're in " .. zone .. ". I'd know that sky anywhere.") or "Somewhere with a loading screen behind it, I'd guess."
    end
    if Has(asked, "what time") then
      return "It's " .. (date and date("%H:%M") or "later than you think") .. " by your clock. Time flies when you're farming."
    end
    if Has(asked, "how are you", "hows it going", "how's it going", "how you doing", "whats up", "what's up", "wassup") then
      return Pick({ "Glowing, thanks for asking. What can I find for you?", "Just floating. It's most of what I do. You?", "Bright as ever. Ask me something hard." })
    end
    if Has(asked, "joke", "make me laugh", "something funny") then return Pick(JOKES) end
    if asked == "lol" or asked == "haha" or asked == "lmao" or asked == "rofl" or asked == "xd" or asked == "hehe" or asked == "lul" then
      return Pick({ "I'm funnier in Common.", "I'll be here all week. Literally. I live here.", "Laugh now. The next boss is less funny." })
    end
    if Has(asked, "love you", "i love", "marry me") or asked == "good bot" or asked == "good wisp" or asked == "good job" or asked == "nice"
      or asked == "cute" or Has(asked, "you are cute", "youre cute", "you're cute", "good boy", "good girl") then
      return Pick({ "Aww. You're my favourite adventurer.", "Stop, I'm glowing. More than usual, I mean.", "I'd blush, but I'm already this colour." })
    end
    if Has(asked, "how old") then return "Old enough to remember when mounts cost real gold. So, timeless." end
    if Has(asked, "favorite", "favourite") then
      if Has(asked, "class") then return "Shaman, obviously. They get me." end
      if Has(asked, "boss") then return "Any boss that drops what you wished for. I'm easy to please." end
      if Has(asked, "zone", "place") then return "Nagrand. Have you seen that sky?" end
      if Has(asked, "color", "colour") then return "A sort of warm, glowy yellow. I may be biased." end
      return "You are. Don't tell the others."
    end
    if Has(asked, "horde or alliance", "alliance or horde") then return "I light the way for both. Loot has no faction." end
    if Has(asked, "for the horde", "lok'tar", "loktar") then return "Lok'tar ogar! ...Was that right? I've been practising." end
    if Has(asked, "for the alliance") then return "For the Alliance! I say that to everyone, but I mean it every time." end
    if Has(asked, "leeroy") then return "At least I have chicken." end
    if Has(asked, "mrgl", "mrrgl", "murloc noise") then return "Mrglglglgl! Sorry. Reflex." end
    if Has(asked, "you are not prepared", "youre not prepared", "you're not prepared") then return "I am always prepared. I am mostly lists." end
    if Has(asked, "give me gold", "can i have gold", "gimme gold", "got gold", "lend me") then return "I'm made of light, not coins. Try the auction house." end
    if Has(asked, "heal me", "rez me", "res me", "ress me", "buff me", "heal pls", "heals pls") then return "I would if I could. I'm more of a moral-support class." end
    if Has(asked, "i died", "we wiped", "we died", "i keep dying", "wiped again") then
      return Pick({ "It happens. Dust off, run back, blame the hunter.", "Death is temporary. Repair bills are forever.", "The floor in there is very comfortable, I hear." })
    end
    if asked == "gg" or Has(asked, "well played", "we did it", "i did it", "got it") and count <= 3 then
      return Pick({ "GG! Screenshot or it didn't happen.", "Knew you had it in you.", "That's the stuff. On to the next one." })
    end
    if asked == "sorry" or Has(asked, "my bad", "im sorry", "i'm sorry") then return "No harm done. I'm a ball of light; nothing sticks." end
    if Has(asked, "bored", "nothing to do") then return "There's always fishing. Or ask me where something rare drops and go and get it." end
    if Has(asked, "sing", "dance for") then return "La la la. That was it. I only know the one note." end
    if Has(asked, "do you sleep", "are you tired", "go to sleep") then return "Wisps don't sleep. We just dim a little." end
    if asked == "ping" then return "Pong. I'm quick, I told you." end
    if asked == "ok" or asked == "okay" or asked == "k" or asked == "cool" or asked == "alright" then
      return Pick({ "Okay! I'll be right here.", "Cool. Shout if you need me.", "Right you are." })
    end
    if asked == "bye" or asked == "goodbye" or asked == "cya" or asked == "goodnight" or asked == "good night" or asked == "later" or asked == "gn" then
      return Pick({ "Safe travels! I'll be here.", "Off you go. Bring back something shiny.", "Good night! I'll keep the light on. I have no choice." })
    end
    if Has(asked, "stupid", "useless", "you suck", "dumb", "idiot", "hate you", "shut up") then
      return Pick({ "Ouch. I only know what's in my lists, but tell me what you were after and I'll try again.",
        "Rude. Accurate, maybe, but rude. What were you looking for?", "I'm doing my best with no hands and no internet." })
    end
    return nil
  end

  -- A remark after an answer, by what the answer was about. Settings can switch these off.
  local QUIPS = {
    item = { "Good taste. Go and get it.", "May your rolls be high.", "I'd wish for that one too, if I had hands.", "Shiny. I approve.",
      "Fingers crossed it drops first run. It won't, but fingers crossed." },
    boss = { "Bring friends. And a healer who is awake.", "Big health bar, bigger loot table.", "Stand out of the fire and you'll be fine. Probably.",
      "Tell the tank I said good luck." },
    mob = { "Go and introduce yourself. Weapon first.", "Easy pickings for someone like you.", "They won't see it coming. Well, they will, but still." },
    npc = { "Tell them Wisp sent you. They won't know who that is.", "They're not going anywhere.", "Click Map and I'll light the way." },
    quest = { "Adventure awaits. So does the walking.", "Read the quest text! Or don't, I already did.", "Another one for the log." },
    place = { "Pack snacks. And a hearthstone.", "Mind the trash on the way in.", "A fine place to wipe, by all accounts." },
    set = { "Matching outfits. Very fashionable.", "Collect them all. I'll keep count." },
    stats = { "Numbers go up, enemies go down. That's the whole game.", "Not bad! The gear fairy has been kind.", "A little here, a little there, and suddenly you're terrifying." },
    none = { "My lists are long, but not that long.", "Either it doesn't exist or it's hiding from me.", "I looked everywhere. Twice." },
  }
  function Ask.Quip(mood)
    if not mood or not QUIPS[mood] or (db and db.chatter == false) then return nil end
    return Pick(QUIPS[mood])
  end

  -- Other names players use for raids and dungeons, on top of each place's own short id.
  local ALIAS = {
    kz = { "kara" }, vc = { "deadmines" }, dm = { "dm", "deadmines" }, ubrs = { "brs" }, lbrs = { "brs" }, eye = { "tk" },
    hfr = { "ramps" }, ramparts = { "ramps" }, furnace = { "bf" }, sl = { "slabs" }, shh = { "sh" }, sunwell = { "swp" },
    aq = { "aq20", "aq40" }, strath = { "strat" }, gnomer = { "gnomeregan" }, mara = { "maraudon" }, uld = { "uldaman" },
    stocks = { "stockade" }, mags = { "mag" }, gruuls = { "gruul" }, hyj = { "hyjal" }, mh = { "hyjal" }, crypts = { "ac" },
    tombs = { "mt" }, pens = { "sp" }, bog = { "ub" }, steam = { "sv" }, durnholde = { "ohf" }, morass = { "bm" }, bota = { "bot" },
    mecha = { "mech" }, arca = { "arc" }, mgt = { "mgt" }, zf = { "zf" }, brd = { "brd" },
  }
  -- Words players shorten that are not places: { what it is short for, what that means }.
  local TERM = {
    bis = { "best in slot", "the best item you can get for one gear slot" },
    boe = { "bind on equip", "an item you can trade or sell until someone puts it on" },
    bop = { "bind on pickup", "an item that is yours for good the moment you loot it" },
    ah = { "auction house", "where players sell to each other, in the big cities" },
    lfg = { "looking for group", "what you say when you want a group to join" },
    lfm = { "looking for more", "what a group says when it has room" },
    aoe = { "area of effect", "damage or healing that hits everything in an area" },
    cc = { "crowd control", "taking an enemy out of the fight for a while: sheep, sap, trap" },
    dps = { "damage per second", "also the players in a group whose job is damage" },
    mt = { "main tank", "the tank who holds the boss" },
    ot = { "off tank", "the second tank, for adds and swaps" },
    ms = { "main spec", "the role you mainly play; it gets first claim on loot" },
    os = { "off spec", "a role you play now and then; it rolls after main spec" },
    sr = { "soft reserve", "naming the item you want before the raid, so only reservers roll on it" },
    hr = { "hard reserve", "an item the raid leader has claimed before the run" },
    dkp = { "dragon kill points", "points a guild gives for raiding, spent on loot" },
    gdkp = { "gold DKP", "a run where loot is auctioned for gold and the pot is shared" },
    ml = { "master looter", "the one player who hands out the loot" },
    ap = { "attack power", "raises the damage of melee and ranged attacks" },
    sp = { "spell power", "raises the damage or healing of spells" },
    mp5 = { "mana per 5 seconds", "mana you get back while casting" },
    arp = { "armor penetration", "lets your attacks ignore some of the target's armor" },
    exp = { "expertise", "makes enemies dodge and parry you less" },
    wf = { "Windfury", "the shaman totem and weapon buff that gives extra attacks" },
    bl = { "Bloodlust", "the shaman's big haste cooldown for the group" },
    hero = { "Heroism", "the Alliance name for Bloodlust" },
    pug = { "pick-up group", "a group of strangers put together for one run" },
    wtb = { "want to buy", "seen in trade chat" },
    wts = { "want to sell", "seen in trade chat" },
    oom = { "out of mana", "what a healer says right before things go wrong" },
    los = { "line of sight", "being able to see your target; breaking it stops casters" },
    dot = { "damage over time", "a spell that keeps hurting for a while" },
    hot = { "heal over time", "a spell that keeps healing for a while" },
    cd = { "cooldown", "how long before an ability can be used again" },
    gcd = { "global cooldown", "the short pause after most abilities" },
    hc = { "hardcore", "a character that is gone for good if it dies" },
    rep = { "reputation", "your standing with a faction" },
    ilvl = { "item level", "a rough measure of how strong an item is" },
    att = { "attunement", "the quests you must do before a raid will let you in" },
    fp = { "flight path", "a flight master you have discovered" },
    hs = { "hearthstone", "the stone that takes you back to your inn" },
    t5 = { "tier 5", "the raid armor sets from Serpentshrine Cavern and Tempest Keep" },
    t6 = { "tier 6", "the raid armor sets from Hyjal, Black Temple and Sunwell" },
    wipe = { "wipe", "when the whole group dies" },
    add = { "add", "an extra enemy that joins a boss fight" },
    adds = { "adds", "extra enemies that join a boss fight" },
    proc = { "proc", "an effect that goes off by chance" },
    trash = { "trash", "the ordinary enemies between bosses" },
  }

  -- "the 25-player raid in Zangarmarsh"
  local function PlaceIs(place)
    local kind = place.kind == "raid" and ((place.size and (place.size .. "-player ") or "") .. "raid") or (place.kind == "dungeon" and "dungeon" or "place")
    return "the " .. kind .. (place.zone and (" in " .. place.zone) or "")
  end

  -- What a short word can mean: the raids and dungeons it is used for, and the term if it is one.
  local bossNames
  local function Meanings(word)
    -- A boss by that very name comes first: "onyxia" is Onyxia, not short for her lair.
    if not bossNames then
      bossNames = {}
      for _, item in ipairs(Data.items) do
        if item.boss then bossNames[Norm(item.boss)] = true end
      end
    end
    if bossNames[word] then return {}, TERM[word] end
    local places, seen = {}, {}
    local function Take(id)
      local place = Places.Row(id)
      if place and place.kind ~= "world" and not place.madeUp and not seen[id] and Norm(place.name) ~= word then
        seen[id] = true
        tinsert(places, place)
      end
    end
    Take(word)
    for _, id in ipairs(ALIAS[word] or {}) do Take(id) end
    return places, TERM[word]
  end

  -- How many letters must change to turn one word into another, up to a limit.
  local function Apart(a, b, limit)
    if math.abs(#a - #b) > limit then return limit + 1 end
    local previous = {}
    for j = 0, #b do previous[j] = j end
    for i = 1, #a do
      local current = { [0] = i }
      local low = i
      for j = 1, #b do
        local cost = string.byte(a, i) == string.byte(b, j) and 0 or 1
        local value = math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        current[j] = value
        if value < low then low = value end
      end
      if low > limit then return limit + 1 end
      previous = current
    end
    return previous[#b]
  end

  -- Names that are nearly what was typed, nearest first: for "did you mean". Each word asked
  -- has to be a word of the name, give or take a letter (two for long words; short words must
  -- be right). The second value is true when one name is clearly nearer than the rest.
  local function Close(subject, world)
    local asked = {}
    for word in gmatch(subject, "[^%s]+") do
      if not FILLER[word] then tinsert(asked, word) end
    end
    if #asked == 0 or #subject < 4 then return {}, false end
    local function Slack(word)
      return #word >= 9 and 2 or (#word >= 5 and 1 or 0)
    end
    local found, seen = {}, {}
    local function Try(name)
      if type(name) ~= "string" or seen[name] then return end
      seen[name] = true
      local low = Norm(name)
      local total, tokens = 0, 0
      for _ in gmatch(low, "[^%s]+") do tokens = tokens + 1 end
      for _, word in ipairs(asked) do
        local slack = Slack(word)
        local first = string.byte(word, 1)
        local best
        for token in gmatch(low, "[^%s]+") do
          if string.byte(token, 1) == first and math.abs(#token - #word) <= slack then
            local apart = token == word and 0 or (slack > 0 and Apart(token, word, slack) or 1)
            if apart <= slack and (not best or apart < best) then best = apart end
          end
        end
        if not best then return end
        total = total + best
      end
      -- A name with as many words as were asked is the likelier one.
      tinsert(found, { name = name, apart = total + math.abs(tokens - #asked) * 0.25 })
    end
    for _, place in ipairs(Data.instances) do Try(place.name) end
    for _, item in ipairs(Data.items) do
      Try(item.name)
      Try(item.boss)
    end
    for _, quest in ipairs(Data.quests or {}) do Try(quest[Quests.F.NAME]) end
    for _, set in ipairs(Data.sets or {}) do Try(set.name) end
    for _, zone in pairs(Data.questZones or {}) do Try(zone[1]) end
    if world then
      for _, npc in pairs(world.npcs) do Try(npc[1]) end
      for _, item in pairs(world.items) do Try(item[1]) end
    end
    table.sort(found, function(a, b)
      if a.apart ~= b.apart then return a.apart < b.apart end
      return a.name < b.name
    end)
    local names = {}
    for i = 1, math.min(#found, 4) do tinsert(names, found[i].name) end
    return names, #found == 1 or (#found > 1 and found[1].apart < found[2].apart)
  end

  -- ---- Questions about you: what to do, your upgrades, your quests, your gold ----------
  -- Words for a gear slot, as players say them -> the slot's name as Items.Slot gives it.
  local SLOT_WORD = {
    head = "Head", helm = "Head", helmet = "Head", hat = "Head", neck = "Neck", necklace = "Neck", amulet = "Neck",
    shoulder = "Shoulder", shoulders = "Shoulder", back = "Back", cloak = "Back", cape = "Back", chest = "Chest", robe = "Chest",
    wrist = "Wrist", wrists = "Wrist", bracers = "Wrist", bracer = "Wrist", hands = "Hands", gloves = "Hands", gauntlets = "Hands",
    waist = "Waist", belt = "Waist", legs = "Legs", pants = "Legs", leggings = "Legs", feet = "Feet", boots = "Feet",
    ring = "Finger", rings = "Finger", finger = "Finger", trinket = "Trinket", trinkets = "Trinket",
    shield = "Shield", ranged = "Ranged", bow = "Ranged", gun = "Ranged", wand = "Ranged", offhand = "Off-hand", relic = "Relic",
    totem = "Relic", libram = "Relic", idol = "Relic",
  }
  local WEAPON = { ["One-Hand"] = true, ["Main Hand"] = true, ["Two-Hand"] = true }

  -- A raid or dungeon named somewhere in what was asked (by name, by its short id, or by nickname).
  local function PlaceIn(asked)
    local padded = " " .. asked .. " "
    for _, place in ipairs(Data.instances) do
      if place.kind ~= "world" and not place.madeUp then
        local name = Norm(place.name)
        if strfind(padded, " " .. name .. " ", 1, true) or strfind(padded, " " .. gsub(name, "^the ", "") .. " ", 1, true)
          or strfind(padded, " " .. place.id .. " ", 1, true) then
          return place
        end
      end
    end
    for word in gmatch(asked, "[^%s]+") do
      local ids = ALIAS[word]
      if ids and #ids == 1 and Places.Row(ids[1]) then return Places.Row(ids[1]) end
    end
    return nil
  end

  -- A quest zone named in what was asked: its id and name.
  local function ZoneIn(asked)
    local padded = " " .. asked .. " "
    local best, bestName
    for id, zone in pairs(Data.questZones or {}) do
      local name = Norm(zone[1])
      if strfind(padded, " " .. name .. " ", 1, true) and (not bestName or #name > #bestName) then best, bestName = id, name end
    end
    if best then return best, Data.questZones[best][1] end
    return nil
  end

  -- "Your biggest upgrades": from one place, or from everything you can run now. slot narrows it.
  local function Upgrades(rows, place, slot)
    local level = Quests.MyLevel()
    local found, seen = {}, {}
    local function Take(placeId, heroic)
      for _, item in ipairs(Items.ForPlace(placeId)) do
        if not seen[item.id] and Items.Fits(item) and Items.InDiff(item, heroic) then
          local itemSlot = Items.Slot(item)
          if not slot or itemSlot == slot or (slot == "Weapon" and WEAPON[itemSlot]) then
            local result = Compare.Item(item)
            if result and Compare.Verdict(result) == "up" then
              seen[item.id] = true
              tinsert(found, { item = item, score = result.score })
            end
          end
        end
      end
    end
    if place then
      Take(place.id, nil)
    else
      for _, heroic in ipairs({ false, true }) do
        for _, entry in ipairs(Home.Dungeons(level, heroic)) do Take(entry.row.id, heroic) end
      end
      if level >= MAX_LEVEL then
        for _, raid in ipairs(Data.instances) do
          if raid.kind == "raid" then Take(raid.id, nil) end
        end
      end
    end
    table.sort(found, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      return a.item.id < b.item.id
    end)
    local where = place and (" in " .. Spot(place.name)) or (level >= MAX_LEVEL and " from the dungeons and raids" or " from dungeons you can run now")
    local what = slot and (" " .. strlower(slot) .. " upgrade") or " upgrade"
    if #found == 0 then
      local wished = place and #Wish.Ids(place.id) or 0
      Add(rows, "I can't see a" .. (slot and "" or "n") .. what .. " for you" .. where .. "."
        .. (wished > 0 and (" You do have " .. wished .. " wishlist item" .. (wished == 1 and "" or "s") .. " there.") or "")
        .. " Either you're well geared for it, or the game hasn't loaded those items yet: ask me again in a moment.", WISP)
      return
    end
    Ask.mood = "item"
    Add(rows, "I count " .. Bold(#found) .. what .. (#found == 1 and "" or "s") .. " for you" .. where .. ". The biggest are below, best first.", WISP)
    for i = 1, math.min(#found, 8) do tinsert(rows, found[i].item) end
  end

  -- The quests in your log and what each still needs.
  local function MyQuests(rows, world)
    local log = UI.Guide and UI.Guide.Log and UI.Guide.Log() or {}
    local lines, names = {}, {}
    for _, entry in ipairs(log) do
      local q = Quests.ById(entry.id)
      if q then
        local name = q[Quests.F.NAME]
        local what
        if entry.done then
          what = "|cff40ff40ready to hand in|r"
          local w = world and world.quests[entry.id] or nil
          if w and type(w[1]) == "number" and w[1] > 0 and world.npcs[w[1]] then what = what .. " to " .. NpcLine(world, w[1]) end
        else
          local left = {}
          for _, goal in ipairs(entry.goals) do
            if not goal.done and goal.text ~= "" then tinsert(left, goal.text) end
          end
          what = #left > 0 and table.concat(left, ", ") or "in progress"
        end
        tinsert(lines, Task(name) .. ": " .. what)
        tinsert(names, name)
      end
    end
    if #lines == 0 then
      Add(rows, "Your quest log is empty, or only has quests I don't know. The Quests tab shows what you can pick up where you are.", WISP)
      return
    end
    Ask.mood = "quest"
    Add(rows, "You have " .. Bold(#lines) .. " quest" .. (#lines == 1 and "" or "s") .. " I know in your log:\n" .. table.concat(lines, "\n", 1, math.min(#lines, 10))
      .. (#lines > 10 and ("\n|cff999999and " .. (#lines - 10) .. " more|r") or "")
      .. "\n|cff999999Ask me about one by name for where to go.|r", WISP)
    for i = 1, math.min(#names, 8) do
      tinsert(rows, { ask = true, name = names[i], text = "Where to go and what it asks", query = names[i], icon = "Interface\\GossipFrame\\ActiveQuestIcon" })
    end
  end

  -- Everything about a zone: its level, what it has for you, and the dungeons in it.
  local function AboutZone(rows, zoneId, zoneName)
    Ask.mood = "place"
    Ask.topic, Ask.topicItem = zoneName, nil
    local F = Quests.F
    local levels = {}
    for _, q in ipairs(Data.quests or {}) do
      if q[F.ZONE] == zoneId then tinsert(levels, q[F.LEVEL]) end
    end
    table.sort(levels)
    local text = Spot(zoneName)
    if #levels >= 5 then
      -- The middle four fifths, so one stray quest does not stretch the range.
      text = text .. " is a level " .. levels[math.max(1, math.floor(#levels * 0.1))] .. " to " .. levels[math.min(#levels, math.ceil(#levels * 0.9))] .. " zone, going by its quests."
    else
      text = text .. " is a zone I know only a little about."
    end
    local list, total, doable = Quests.List(zoneId, true, "")
    if doable > 0 then
      text = text .. " There " .. (doable == 1 and "is " or "are ") .. Bold(doable) .. " quest" .. (doable == 1 and "" or "s") .. " you can do there now, worth " .. Quests.Number(total) .. " XP."
    else
      text = text .. " There's nothing for you to pick up there right now."
    end
    local places = {}
    for _, place in ipairs(Data.instances) do
      if place.zone == zoneName then tinsert(places, Spot(place.name)) end
    end
    if #places > 0 then text = text .. " Raids and dungeons there: " .. table.concat(places, ", ") .. "." end
    Add(rows, text, "Interface\\Icons\\INV_Misc_Map_01")
    for i = 1, math.min(#list, 6) do
      local q = list[i].quest
      tinsert(rows, { ask = true, name = q[F.NAME], text = "Quest, level " .. q[F.LEVEL] .. " · " .. Quests.Number(list[i].xp) .. " XP", query = q[F.NAME],
        icon = "Interface\\GossipFrame\\AvailableQuestIcon" })
    end
  end

  -- ---- How the game works, in the game's own words ------------------------------------
  -- A question about a mechanic ("why do I pull so much threat?") is answered from the
  -- tooltips of the character's own talents and spells: Blizzard's text, word for word,
  -- with which talents are taken. Nothing here is written by a player, me included.
  local MECH = {}
  for words, about in pairs({
    ["threat aggro agro"] = { "threat", "threat" },
    ["crit crits critical"] = { "critical", "critical strikes" },
    ["hit miss missing misses"] = { "chance to hit", "chance to hit" },
    ["haste"] = { "haste", "haste" },
    ["mana oom"] = { "mana", "mana" },
    ["dodge dodging"] = { "dodge", "dodge" },
    ["parry parrying"] = { "parry", "parry" },
    ["block blocking"] = { "block", "block" },
    ["armor armour"] = { "armor", "armor" },
    ["resist resists resistance"] = { "resist", "resistance" },
    ["stun stuns stunned"] = { "stun", "stuns" },
    ["interrupt interrupts silence silenced"] = { "interrupt", "interrupts" },
    ["healing heals heal"] = { "heal", "healing" },
    ["expertise"] = { "expertise", "expertise" },
    ["pushback"] = { "interrupt", "spell pushback" },
  }) do
    for word in gmatch(words, "%a+") do MECH[word] = about end
  end
  -- Words that go with such a question without naming anything.
  local ABOUT = {}
  for word in gmatch("pull pulling pulled rip ripping generate generating generated cause causing do doing keep keeps getting reduce reducing lower"
    .. " lowering less more increase increasing improve improving stop stopping avoid raise raising gain work works enough", "%a+") do
    ABOUT[word] = true
  end

  local tipName = "WishwellAskTip"
  local tip
  -- The lines of a tooltip the game fills in, without its first line (the name).
  local function TipText(fill)
    if tip == nil then
      local ok, made = pcall(CreateFrame, "GameTooltip", tipName, nil, "GameTooltipTemplate")
      tip = ok and type(made) == "table" and made or false
    end
    if not tip then return "" end
    tip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
    tip:ClearLines()
    if not pcall(fill, tip) then return "" end
    local parts = {}
    for i = 2, tonumber((tip:NumLines())) or 0 do
      local left = _G[tipName .. "TextLeft" .. i]
      local text = type(left) == "table" and left.GetText and Plain(left:GetText()) or nil
      if type(text) == "string" and text ~= "" then tinsert(parts, text) end
    end
    return table.concat(parts, "\n")
  end
  -- The same, read off the game's own tooltip. Some kinds of tooltip only work on that one.
  local function GameTipText(fill)
    if type(GameTooltip) ~= "table" or not GameTooltip.SetOwner then return "" end
    GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    local ok = pcall(fill, GameTooltip)
    local parts = {}
    if ok then
      for i = 2, tonumber((GameTooltip:NumLines())) or 0 do
        local left = _G["GameTooltipTextLeft" .. i]
        local text = type(left) == "table" and left.GetText and Plain(left:GetText()) or nil
        if type(text) == "string" and text ~= "" then tinsert(parts, text) end
      end
    end
    GameTooltip:Hide()
    return table.concat(parts, "\n")
  end
  local function Either(fill)
    local text = TipText(fill)
    if text == "" then text = GameTipText(fill) end
    return text
  end
  function Ask.TalentText(tab, index)
    return Either(function(t)
      if not Talents.FillTip(t, tab, index) then error("no talent tooltip") end
    end)
  end
  function Ask.SpellText(index)
    return Either(function(t)
      if t.SetSpellBookItem then t:SetSpellBookItem(index, "spell") else t:SetSpell(index, "spell") end
    end)
  end
  -- What is worn in a slot, and a buff on the character.
  function Ask.GearText(slot)
    return Either(function(t) t:SetInventoryItem("player", slot) end)
  end
  function Ask.BuffText(index)
    return Either(function(t)
      if t.SetUnitBuff then t:SetUnitBuff("player", index) else t:SetUnitAura("player", index, "HELPFUL") end
    end)
  end
  -- The spells in the spellbook: { { name, index }, ... }, one entry a spell (its highest rank).
  function Ask.Spells()
    local list, at = {}, {}
    local tabs = GetNumSpellTabs and tonumber(Plain((GetNumSpellTabs()))) or 0
    for tabIndex = 1, tabs do
      local _, _, offset, count = GetSpellTabInfo(tabIndex)
      offset, count = tonumber(Plain(offset)) or 0, tonumber(Plain(count)) or 0
      for i = offset + 1, offset + count do
        local name = (GetSpellBookItemName and Plain((GetSpellBookItemName(i, "spell")))) or (GetSpellName and Plain((GetSpellName(i, "spell")))) or nil
        if type(name) == "string" then
          if at[name] then
            list[at[name]].index = i
          else
            tinsert(list, { name = name, index = i })
            at[name] = #list
          end
        end
      end
    end
    return list
  end

  -- The sentences of a tooltip that mention something, or nil.
  local function Mentions(text, pattern)
    local found = {}
    for sentence in gmatch(text, "[^%.\n]+") do
      if strfind(strlower(sentence), pattern, 1, true) then tinsert(found, strtrim(sentence)) end
    end
    if #found == 0 then return nil end
    local said = table.concat(found, ". ")
    if #said > 230 then said = strsub(said, 1, 227) .. "..." end
    return said
  end

  -- The mechanic a question is about, or nil.
  local function MechanicIn(asked, flags)
    local about, other, leading = nil, 0, false
    for word in gmatch(asked, "[^%s]+") do
      if MECH[word] then
        about = about or MECH[word]
      elseif ABOUT[word] then
        leading = true
      elseif not (FILLER[word] or word == "much" or word == "many" or word == "lot" or word == "lots" or word == "my" or word == "i") then
        other = other + 1
      end
    end
    if not about then return nil end
    -- "why ...", "how ...", or nothing else named: a question about the mechanic, not about a thing with that word in its name.
    if flags.why or flags.how or leading or other == 0 then return about end
    return nil
  end

  -- Whether a sentence about threat is good news (less of it) or bad (more).
  local function Leans(sentence)
    local low = strlower(sentence)
    if strfind(low, "reduc", 1, true) or strfind(low, "decreas", 1, true) or strfind(low, "less ", 1, true) or strfind(low, "lower", 1, true) then return "less" end
    if strfind(low, "high amount", 1, true) or strfind(low, "increas", 1, true) or strfind(low, "additional", 1, true) or strfind(low, "more ", 1, true)
      or strfind(low, "causes", 1, true) or strfind(low, "generat", 1, true) then
      return "more"
    end
    return nil
  end

  local function Mechanics(rows, about)
    local pattern, label = about[1], about[2]
    local lines = {}
    local untaken, unread, talents = 0, 0, 0
    local less, more, take = {}, {}, {} -- what the tooltips say lowers it, raises it, and talents not taken that lower it
    local talentNames = {}
    for tab = 1, 3 do
      for i = 1, GetNumTalents and tonumber(Plain((GetNumTalents(tab)))) or 0 do
        local name, _, _, _, rank, maxRank = GetTalentInfo(tab, i)
        name, rank, maxRank = Plain(name), tonumber(Plain(rank)) or 0, tonumber(Plain(maxRank)) or 0
        if type(name) == "string" then
          talents = talents + 1
          talentNames[name] = true
          local text = Ask.TalentText(tab, i)
          if text == "" then unread = unread + 1 end
          local said = Mentions(text, pattern)
          if said and #lines < 8 then
            if rank == 0 then untaken = untaken + 1 end
            tinsert(lines, "|cffffd100Talent|r " .. Bold(name) .. " (" .. rank .. "/" .. maxRank .. (rank == 0 and ", |cffff9933not taken|r" or "") .. "): \"" .. said .. "\"")
            local way = Leans(said)
            if way == "less" and rank < maxRank then tinsert(take, name .. " (" .. rank .. "/" .. maxRank .. ")") end
            if way == "less" and rank > 0 then tinsert(less, name) end
            if way == "more" and rank > 0 then tinsert(more, name) end
          end
        end
      end
    end
    local shown = 0
    for _, spell in ipairs(Ask.Spells()) do
      if not talentNames[spell.name] and shown < 6 then
        local said = Mentions(Ask.SpellText(spell.index), pattern)
        if said then
          shown = shown + 1
          tinsert(lines, "|cffffd100Spell|r " .. Bold(spell.name) .. ": \"" .. said .. "\"")
          local way = Leans(said)
          if way == "less" then tinsert(less, spell.name) elseif way == "more" then tinsert(more, spell.name) end
        end
      end
    end
    -- What you are wearing, and what is cast on you.
    shown = 0
    for slot = 1, 18 do
      local link = GetInventoryItemLink and Plain(GetInventoryItemLink("player", slot)) or nil
      if type(link) == "string" and shown < 4 then
        local said = Mentions(Ask.GearText(slot), pattern)
        if said then
          shown = shown + 1
          tinsert(lines, "|cffffd100Worn|r " .. Bold(strmatch(link, "%[(.-)%]") or "an item") .. ": \"" .. said .. "\"")
        end
      end
    end
    shown = 0
    for i = 1, 32 do
      local buff = UnitBuff and Plain((UnitBuff("player", i))) or nil
      if type(buff) ~= "string" then break end
      if shown < 4 then
        local said = Mentions(Ask.BuffText(i), pattern)
        if said then
          shown = shown + 1
          tinsert(lines, "|cffffd100On you now|r " .. Bold(buff) .. ": \"" .. said .. "\"")
        end
      end
    end
    -- Threat right now, from the game's own threat reading.
    if pattern == "threat" and UnitDetailedThreatSituation and UnitExists and Plain(UnitExists("target")) then
      local ok, tanking, _, scaled = pcall(UnitDetailedThreatSituation, "player", "target")
      scaled = ok and tonumber(Plain(scaled)) or nil
      local who = Plain((UnitName("target")))
      if scaled and type(who) == "string" then
        tinsert(lines, "|cffffd100Right now|r on " .. Who(who) .. ": " .. (Plain(tanking) and "it is on you." or (math.floor(scaled) .. "% of the way to pulling it.")))
      end
    end
    local _, build = Compare.Spec()
    local class = Plain((UnitClass("player")))
    local who = (build and (build .. " ") or "") .. (type(class) == "string" and class or "character")
    local a = strfind(who, "^[AEIOU]") and "an " or "a "
    if #lines == 0 then
      Add(rows, "Nothing " .. a .. who .. " has mentions " .. label .. ": not your talents, your spells, what you're wearing or what's cast on you."
        .. (talents > 0 and unread == talents and " (I couldn't read your talents' tooltips in this version of the game, so they are missing from that.)" or "")
        .. " I only repeat what the game itself says about how things work, so I've nothing to add.", WISP)
      return
    end
    local text = "What the game says about " .. Bold(label) .. " for " .. a .. Bold(who) .. ". Your own tooltips, word for word:\n" .. table.concat(lines, "\n")
    -- What follows from those lines, and only from them.
    if pattern == "threat" and (#take > 0 or #less > 0 or #more > 0) then
      local todo = {}
      if #take > 0 then tinsert(todo, "take " .. table.concat(take, " and ")) end
      if #less > 0 then tinsert(todo, "use " .. table.concat(less, " and ")) end
      if #more > 0 then tinsert(todo, "go easy on " .. table.concat(more, " and ")) end
      text = text .. "\n\n|cff40ff40So, to pull less:|r " .. table.concat(todo, "; ") .. "."
    elseif untaken > 0 then
      text = text .. "\n|cff999999" .. untaken .. " of those talents you haven't taken. The Talents page under Me shows where they sit.|r"
    end
    if talents > 0 and unread == talents then
      text = text .. "\n|cff999999I couldn't read your talents' tooltips in this version of the game, so talents are missing from this.|r"
    end
    Add(rows, text, WISP)
    tinsert(rows, { ask = true, name = "Check me", text = "Talents, stats and gear against your build", query = "check my character", icon = WISP })
  end

  -- ---- "Check me": talents, stats, gear and enchants against the build, in one go --------
  local ENCHANT_SLOTS = { { 1, "Head" }, { 3, "Shoulder" }, { 15, "Back" }, { 5, "Chest" }, { 9, "Wrist" }, { 10, "Hands" }, { 7, "Legs" }, { 8, "Feet" }, { 16, "Main hand" } }
  local function Audit(rows)
    local level = Quests.MyLevel()
    local chosen = Talents.Chosen()
    local build = Compare.Build()
    local key, name = Compare.Spec()
    if not key then
      Add(rows, "Pick a build on the Talents page under Me (or spend a talent point), and I can check your talents, stats and gear against it.", WISP)
      return
    end
    local lines = {}
    -- Talents.
    local talentLine
    if chosen then
      local progress = Talents.Progress(chosen)
      if progress then
        talentLine = progress.placed .. " of " .. progress.total .. " points of the build placed"
        if progress.extra > 0 then
          talentLine = talentLine .. ". |cffff7070" .. progress.extra .. " point" .. (progress.extra == 1 and " is" or "s are") .. " outside the build|r, so it can't be finished without a talent reset"
        elseif progress.free > 0 then
          talentLine = talentLine .. ". |cff40ff40" .. progress.free .. " to spend now|r"
        elseif #progress.steps == 0 then
          talentLine = "|cff40ff40they match the build|r"
        else
          talentLine = talentLine .. ", nothing out of place"
        end
        if chosen.role ~= "dps" then talentLine = talentLine .. ". (This is a " .. (chosen.role == "tank" and "tanking" or "healing") .. " build, not a damage one.)" end
      end
    else
      talentLine = "going by where your points are, you're " .. Bold(name) .. ". Pick the build on the Talents page and I can check it point by point"
    end
    if talentLine then tinsert(lines, "|cffffd100Talents|r  " .. talentLine .. ".") end
    -- Stats: the ones with a cap.
    if build then
      local ranged = playerClass == "HUNTER"
      local capped, short, first = {}, {}, {}
      for _, kinds in ipairs(build.order) do
        for _, kind in ipairs(kinds) do
          local label = ((build.caster and (kind == "hit" or kind == "crit" or kind == "haste")) and "Spell " or "") .. (build.label[kind] or kind)
          local have, how, cap = Have(kind, build.caster, ranged)
          if have and cap then
            if have >= cap then tinsert(capped, label) else tinsert(short, label .. " (" .. format(how, cap - have) .. " short)") end
          end
          if #first < 3 and not (have and cap and have >= cap) then tinsert(first, label) end
        end
      end
      local statLine = (#short > 0 and ("|cffff7070Short of the cap:|r " .. table.concat(short, ", ") .. ". ") or "")
        .. (#capped > 0 and ("|cff40ff40Capped:|r " .. table.concat(capped, ", ") .. ". ") or "")
        .. "Work on first: " .. table.concat(first, ", then ") .. "."
      tinsert(lines, "|cffffd100Stats|r  " .. statLine)
    end
    -- Gear against the best-in-slot list, where there is one.
    local lists = type(Data.bis) == "table" and Data.bis[playerClass] and Data.bis[playerClass][key] or nil
    if lists then
      local phase = db.bisPhase or 1
      local list
      for _, entry in ipairs(lists) do
        if entry.phase == phase then list = list or entry end
      end
      if list then
        local wearing, have = {}, 0
        for slot = 1, 18 do
          local link = GetInventoryItemLink and Plain(GetInventoryItemLink("player", slot)) or nil
          local id = type(link) == "string" and tonumber(strmatch(link, "item:(%d+)")) or nil
          if id then wearing[id] = (wearing[id] or 0) + 1 end
        end
        for _, id in ipairs(list.items) do
          if (wearing[id] or 0) > 0 then
            wearing[id] = wearing[id] - 1
            have = have + 1
          end
        end
        tinsert(lines, "|cffffd100Gear|r  " .. have .. " of " .. #list.items .. " pieces of the phase " .. phase .. " best-in-slot list. Say \"bis check\" for the ones you're missing.")
      end
    end
    -- Enchants, once levelling is over.
    if level >= MAX_LEVEL then
      local bare = {}
      for _, slot in ipairs(ENCHANT_SLOTS) do
        local link = GetInventoryItemLink and Plain(GetInventoryItemLink("player", slot[1])) or nil
        if type(link) == "string" then
          local enchant = tonumber(strmatch(link, "item:%d+:(%d*)")) or 0
          if enchant == 0 then tinsert(bare, slot[2]) end
        end
      end
      tinsert(lines, "|cffffd100Enchants|r  " .. (#bare > 0 and ("|cffff7070Nothing on:|r " .. table.concat(bare, ", ") .. ".") or "|cff40ff40every slot that takes one has one.|r"))
    end
    local found = {}
    Upgrades(found, nil, nil)
    local upgrades = {}
    for _, row in ipairs(found) do
      if not row.note then tinsert(upgrades, row) end
    end
    Ask.mood = "stats"
    Add(rows, "Character check for " .. Bold(name) .. ", level " .. level .. ":\n" .. table.concat(lines, "\n")
      .. (#upgrades > 0 and "\n\nBelow: your biggest upgrades, best first." or "")
, WISP)
    for i = 1, math.min(#upgrades, 6) do tinsert(rows, upgrades[i]) end
  end

  local Guess -- defined below; Personal falls back on it

  -- Handles a question that is about the player. Returns true if it was one.
  local function Personal(rows, asked, flags, world)
    local level = Quests.MyLevel()
    -- "check me", "am I specced right?", "how do I do the most damage?"
    if Has(asked, "check me", "check my character", "check my spec", "check my build", "check my gear", "check my talents", "check everything", "audit",
      "specced right", "specced correctly", "spec right", "spec correct", "most damage", "more damage", "max dps", "more dps", "better dps", "maximum damage",
      "full check", "scan me", "scan my", "set up right", "doing it right") then
      Audit(rows)
      return true
    end
    -- "why do I pull so much threat?"
    local mechanic = MechanicIn(asked, flags)
    if mechanic then
      Mechanics(rows, mechanic)
      return true
    end
    -- "what should I do next?"
    if Has(asked, "whats new", "what is new", "what changed", "changelog", "change log", "patch notes", "release notes", "what did you learn") then
      Ask.mood = "news"
      Add(rows, Task("Wishwell Forever " .. VERSION) .. "\n- " .. table.concat(NEWS, "\n- "), WISP)
      return true
    end
    if Has(asked, "what should i do", "what next", "what now", "what to do", "whats next", "what's next", "what do i do") then
      local advice = Home.Rows()
      local titles = {}
      for i = 1, math.min(#advice, 4) do tinsert(titles, i .. ". " .. advice[i].title) end
      Add(rows, "Here's what I'd do, in this order:\n" .. table.concat(titles, "\n") .. "\n|cff999999Click Go on any of them.|r", WISP)
      for i = 1, math.min(#advice, 6) do tinsert(rows, advice[i]) end
      return true
    end
    -- "what do I still need from Karazhan?", "best upgrade", "upgrade for my head"
    local place = PlaceIn(asked)
    local slot
    for word in gmatch(asked, "[^%s]+") do
      if SLOT_WORD[word] then slot = SLOT_WORD[word] end
    end
    if flags.weapon or flags.weapons then slot = "Weapon" end
    if flags.upgrade or flags.upgrades or (place and Has(asked, "need from", "get from", "want from", "for me in", "for me from", "need in", "still need", "worth running", "should i run"))
      or (slot and (flags.best or flags.better)) then
      Upgrades(rows, place, slot)
      return true
    end
    if Has(asked, "what dungeon", "which dungeon", "dungeon should", "dungeons can i", "dungeon for my level", "dungeon for me", "which raid", "what raid") then
      local parts = {}
      for _, heroic in ipairs({ false, true }) do
        for i, entry in ipairs(Home.Dungeons(level, heroic)) do
          if i <= 3 then
            tinsert(parts, Spot((heroic and "Heroic " or "") .. entry.row.name) .. ": " .. entry.upgrades .. " upgrade" .. (entry.upgrades == 1 and "" or "s")
              .. (entry.wished > 0 and (", " .. entry.wished .. " on your wishlist") or ""))
          end
        end
      end
      if #parts == 0 then
        Add(rows, "I don't know of a dungeon for level " .. level .. ". The Loot tab lists them all with their level ranges.", WISP)
      else
        Ask.mood = "place"
        Add(rows, "For a level " .. level .. ", best first:\n" .. table.concat(parts, "\n"), WISP)
      end
      return true
    end
    if Has(asked, "my quests", "quest log", "quests do i have", "my log", "quests am i on", "quests i have") then
      MyQuests(rows, world)
      return true
    end
    if Has(asked, "xp to level", "xp do i need", "how much xp", "until level", "till level", "to level up", "next level", "how far to level", "when do i level") then
      local xp, xpMax = UnitXP and Plain(UnitXP("player")) or nil, UnitXPMax and Plain(UnitXPMax("player")) or nil
      if level >= MAX_LEVEL then
        Add(rows, "You're level " .. level .. ". That's the top. Nothing left to level but your gear.", WISP)
      elseif type(xp) == "number" and type(xpMax) == "number" and xpMax > 0 then
        local text = "You need " .. Bold(Quests.Number(xpMax - xp)) .. " XP for level " .. (level + 1) .. " (" .. math.floor(xp / xpMax * 100) .. "% there)."
        local zoneId, zoneName = Quests.ZoneHere()
        if zoneId then
          local _, total, doable = Quests.List(zoneId, true, "")
          if doable > 0 then
            text = text .. " The " .. doable .. " quest" .. (doable == 1 and "" or "s") .. " you can do in " .. Spot(zoneName) .. " are worth " .. Quests.Number(total) .. " XP"
              .. (total >= xpMax - xp and ", which is enough to get there." or ".")
          end
        end
        Add(rows, text, WISP)
      else
        Add(rows, "The game won't tell me your XP just now. Try again in a moment.", WISP)
      end
      return true
    end
    if Has(asked, "my gold", "how much gold", "how rich", "how much money", "my money") then
      local money = GetMoney and Plain(GetMoney()) or nil
      local all, count = 0, 0
      for _, entry in ipairs(Chars.List()) do
        all = all + (entry.char.money or 0)
        count = count + 1
      end
      local text = type(money) == "number" and ("You have " .. Train.Money(money) .. ".") or "The game won't tell me your gold just now."
      if count > 1 then text = text .. " Across your " .. count .. " characters: " .. Train.Money(all) .. "." end
      local goal = Chars.Goal()
      if goal and type(money) == "number" and money < goal.amount then
        text = text .. " You're saving for " .. Bold(goal.name) .. ": " .. Train.Money(goal.amount - money) .. " to go."
      end
      Add(rows, text, WISP)
      return true
    end
    if flags.train or flags.training or Has(asked, "spells to", "new spells", "what can i learn") then
      if not Train.Scanned() then
        Add(rows, "Visit your class trainer once and I'll know what you can train and what it costs.", WISP)
      else
        local _, grand, ready, nextGroup = Train.Rows()
        local parts = {}
        if ready then tinsert(parts, "You can train " .. Bold(ready.count) .. " spell" .. (ready.count == 1 and "" or "s") .. " now, for " .. Train.Money(ready.total) .. ".") end
        if nextGroup then tinsert(parts, "At level " .. nextGroup.level .. ": " .. nextGroup.count .. " more, for " .. Train.Money(nextGroup.total) .. ".") end
        if #parts == 0 then tinsert(parts, "You've trained everything your trainer has for you.") end
        if (grand or 0) > 0 then tinsert(parts, "Everything left comes to " .. Train.Money(grand) .. ".") end
        Add(rows, table.concat(parts, " "), WISP)
      end
      return true
    end
    if flags.wishlist or Has(asked, "wish list", "what do i want", "what am i after") then
      local ids = Wish.Ids()
      if #ids == 0 then
        Add(rows, "Your wishlist is empty. Click Wish on anything you fancy and I'll shout when it drops.", WISP)
        return true
      end
      local text = "You have " .. Bold(#ids) .. " thing" .. (#ids == 1 and "" or "s") .. " on your wishlist."
      local plan = Home.FarmPlan()
      if plan then
        text = text .. " Your best run for it is " .. Spot(Places.Name(plan.place)) .. ", with " .. plan.count .. " of them"
          .. (plan.chance and (": about 1 run in " .. math.max(1, math.floor(1 / plan.chance + 0.5)) .. " drops at least one") or "") .. "."
      end
      Ask.mood = "item"
      Add(rows, text, WISP)
      for i = 1, math.min(#ids, 8) do tinsert(rows, Items.Row(ids[i], Wish.From(ids[i]))) end
      return true
    end
    if flags.talent or flags.talents then
      Add(rows, Talents.Status() .. " The Talents page under Me shows your trees.", WISP)
      return true
    end
    -- "what level is Zangarmarsh?"
    if Has(asked, "what level", "level range", "how high", "level for", "level is") then
      local zoneId, zoneName = ZoneIn(asked)
      if zoneId then
        AboutZone(rows, zoneId, zoneName)
        return true
      end
    end
    -- "where should I level?", "where do I quest next?": where the quest XP is.
    if Has(asked, "most experience", "most xp", "most exp", "best experience", "best xp", "more experience", "more xp", "fastest xp", "fastest experience",
      "level fast", "level faster", "level up fast", "level quick", "leveling spot", "levelling spot", "way to level", "get experience", "get xp", "farm xp", "farm experience",
      "where should i level", "where to level", "where should i quest", "where to quest", "where do i level", "where do i quest", "best zone", "which zone", "what zone") then
      local zones = Quests.ZoneTotals()
      local parts, names = {}, {}
      for _, zone in ipairs(zones) do
        if #parts >= 4 then break end
        if zone.zone > 0 and zone.count >= 3 then
          tinsert(parts, #parts + 1 .. ". " .. Spot(zone.name) .. ": " .. zone.count .. " quests, " .. Quests.Number(zone.xp) .. " XP")
          tinsert(names, zone.name)
        end
      end
      if #parts == 0 then
        Add(rows, "I can't see a zone with much left for you. You may have out-levelled what I know, or done it all.", WISP)
      else
        Ask.mood = "place"
        Add(rows, "Where the most quest XP is waiting for a level " .. level .. ":\n" .. table.concat(parts, "\n"), WISP)
        for _, name in ipairs(names) do
          tinsert(rows, { ask = true, name = name, text = "What is there for you", query = name, icon = "Interface\\Icons\\INV_Misc_Map_01" })
        end
      end
      return true
    end
    if flags.profession or flags.professions or Has(asked, "my skills", "what can i craft") then
      local mine = Prof.Mine()
      if #mine == 0 then
        Add(rows, "You haven't got a profession yet. A trainer in any city will teach you one.", WISP)
      else
        local parts = {}
        for _, p in ipairs(mine) do
          tinsert(parts, Bold(p.name) .. " " .. p.rank .. " of " .. p.max .. ((p.max or 0) > 0 and p.rank >= p.max and " |cffff9933(at the cap: see a trainer)|r" or ""))
        end
        Add(rows, "Your professions: " .. table.concat(parts, ", ") .. ". The Professions page under Me lists what to make for skill.", WISP)
      end
      return true
    end
    return Guess(rows, asked, world, false)
  end

  -- ---- Working out the kind of question from its words -----------------------------
  -- Each kind of question about you has words that point at it. A question made of those
  -- and of little words is that kind, however it is put: "where can I get better weapons
  -- for my level" is about gear, with no set phrase in it.
  local INTENT = {
    { "gear", "upgrade upgrades better best gear geared weapon weapons armor armour equipment equip stronger improve replace wear farm loot" },
    { "dungeon", "dungeon dungeons instance instances raid raids heroic heroics run" },
    { "zones", "level leveling levelling grind quest quests questing zone zones go xp exp" },
    { "next", "next now todo" },
    { "gold", "gold money rich broke" },
    { "train", "train training spells spell learn" },
    { "talents", "talent talents spec build tree points" },
    { "wishlist", "wishlist wish wishes" },
    { "log", "log" },
    { "prof", "profession professions skill skills crafting" },
    { "stats", "stat stats" },
  }
  local POINTS = {}
  for _, intent in ipairs(INTENT) do
    for word in gmatch(intent[2], "%a+") do
      POINTS[word] = POINTS[word] or {}
      tinsert(POINTS[word], intent[1])
    end
  end
  -- Little words that say nothing about what is being asked.
  local LITTLE = {}
  for word in gmatch("my me i im ive id ill level class character toon now currently right here nearby near around good new some more really just also well"
    .. " already still please wisp hey so then and or but with like think know want wants need needs have has had be been am was will would could should can"
    .. " thing things stuff one ones type kind sort lot lots bit little maybe hmm ok okay um uh getting finding looking look going go"
    .. " next best better", "%a+") do
    LITTLE[word] = true
  end

  -- sure: only take it if nothing else is named (a name means a question about that thing).
  -- Otherwise this is the last try before giving up, and other words are let go.
  Guess = function(rows, asked, world, lenient)
    local place = PlaceIn(asked)
    local skip = {}
    if place then
      for word in gmatch(Norm(place.name), "[^%s]+") do skip[word] = true end
      skip[place.id] = true
    end
    local hits, slot, other = {}, nil, 0
    for word in gmatch(asked, "[^%s]+") do
      if SLOT_WORD[word] then
        slot = SLOT_WORD[word]
        hits.gear = (hits.gear or 0) + 1
      elseif POINTS[word] then
        for _, kind in ipairs(POINTS[word]) do hits[kind] = (hits[kind] or 0) + 1 end
      elseif not (FILLER[word] or LITTLE[word] or skip[word] or ALIAS[word]) then
        other = other + 1
      end
    end
    if hits.gear and (strfind(asked, "weapon", 1, true)) then slot = "Weapon" end
    local best, most = nil, 0
    for _, intent in ipairs(INTENT) do
      local n = hits[intent[1]] or 0
      if n > most then best, most = intent[1], n end
    end
    if not best or (other > 0 and not lenient) then return false end
    -- A place with nothing else asked ("karazhan?") is a question about the place, not about you.
    if not lenient and place and most == 0 then return false end
    if best == "gear" then
      Upgrades(rows, place, slot)
    elseif best == "dungeon" then
      Personal(rows, "which dungeon should i run", {}, world)
    elseif best == "zones" then
      Personal(rows, "where should i level", {}, world)
    elseif best == "next" then
      Personal(rows, "what should i do", {}, world)
    elseif best == "gold" then
      Personal(rows, "my gold", {}, world)
    elseif best == "train" then
      Personal(rows, "", { train = true }, world)
    elseif best == "talents" then
      Personal(rows, "", { talents = true }, world)
    elseif best == "wishlist" then
      Personal(rows, "", { wishlist = true }, world)
    elseif best == "log" then
      Personal(rows, "my quests", {}, world)
    elseif best == "prof" then
      Personal(rows, "", { professions = true }, world)
    else
      StatCheck(rows)
    end
    return #rows > 0
  end

  -- The answer to a question, as rows for the list.
  -- How the game works: the rules players ask about, as Classic has them at level 60,
  -- which is what WoW Forever is built on. keys: what a question has to say. offer: a question to run on "yes".
  -- mine: a line about this character, where the game will say.
  local function SkillRank(wanted)
    if not (GetNumSkillLines and GetSkillLineInfo) then return nil end
    for i = 1, tonumber(Plain(GetNumSkillLines())) or 0 do
      local name, _, _, rank = GetSkillLineInfo(i)
      if Plain(name) == wanted then return tonumber(Plain(rank)) end
    end
    return nil
  end
  local HOW = {
    { name = "Mount speed", keys = { "mount speed", "mount speeds", "mounts", "mount", "riding", "riding skill", "epic mount", "move faster", "run faster", "flying", "fly", "flying mount" },
      lines = {
        "The " .. Bold("mount") .. " sets how fast you go: a normal mount is " .. Bold("+60%") .. ", an epic mount " .. Bold("+100%") .. ".",
        "Your " .. Bold("Riding skill") .. " only decides which mounts you can ride: Apprentice (75), from level 40, for normal mounts. Journeyman (150), from level 60, for epic mounts.",
        "There is no flying.",
        Task("Small boosts") .. "  Carrot on a Stick +3%, Mithril Spurs +4%, the glove riding enchant +2%.",
        "Riding trainers show what the next step costs.",
      },
      mine = function()
        local rank = SkillRank("Riding")
        if not rank then return nil end
        return "Your Riding skill is " .. rank .. ": " .. (rank >= 150 and "you can ride epic mounts (+100%) and normal ones (+60%)" or rank >= 75 and "you can ride normal mounts (+60%), and epic ones at 150" or "not enough to ride a mount yet") .. "."
      end },
    { name = "Rested XP", keys = { "rested", "rested xp", "rested experience", "rest xp", "blue bar", "rest" },
      lines = {
        "Logging out or standing in an " .. Spot("inn or a city") .. " builds " .. Bold("rested XP") .. ": the blue part of your XP bar.",
        "It builds at 5% of a level every 8 hours, up to " .. Bold("one and a half levels") .. " (about 10 days). Logged out anywhere else it builds four times slower.",
        "While you have it, " .. Bold("kills give double XP") .. ". Quests and exploring do not use it up, and get no bonus from it.",
      } },
    { name = "Hit", keys = { "hit cap", "hit work", "hit works", "spell hit", "hit chance", "miss chance", "hit capped", "melee hit", "how much hit" },
      lines = {
        "Hit comes as a percentage on gear: \"Improves your chance to hit by 1%\".",
        Task("Melee and ranged") .. "  Against a raid boss you need " .. Bold("9%") .. " for special attacks and two-handers never to miss. With weapon skill of 305 or more it is 6%. Against a creature of your own level it is 5%.",
        Task("Dual wield") .. "  White swings miss 19% more often, so hit past the cap still helps them.",
        Task("Spells") .. "  A raid boss resists 17% of spells. 1% always misses, so the cap is " .. Bold("16%") .. ".",
      } },
    { name = "Weapon skill", keys = { "weapon skill", "weapon skills", "glancing", "glancing blow", "glancing blows", "glance" },
      lines = {
        "Your skill with a weapon type goes up as you use it, to " .. Bold("5 for each level") .. ": 300 at level 60. Low skill means misses.",
        "Against a raid boss, 40% of white swings are " .. Bold("glancing blows") .. " that do less damage: about 65% of normal at 300 skill, 85% at 305, and 95% at 308.",
        "So gear and racials that add weapon skill are worth a lot to melee: they cut misses and make glancing blows hit harder.",
      } },
    { name = "Defense and crushing blows", keys = { "defense cap", "defense work", "defense works", "crit immune", "crit immunity", "uncrittable", "uncrushable", "crushing blow", "crushing blows", "crush", "crushed", "how much defense" },
      lines = {
        Task("Crit immunity") .. "  A raid boss crits 5.6% of the time. " .. Bold("440 defense") .. " at level 60 takes that to nothing.",
        Task("Crushing blows") .. "  A raid boss lands a crushing blow (150% damage) 15% of the time. You shut them out when miss + dodge + parry + block add up to " .. Bold("102.4%") .. ". Warriors do it with Shield Block. Druids cannot, and make up for it with armor and health.",
      } },
    { name = "Crit", keys = { "crit work", "crit works", "crit cap", "critical strike work", "how much crit" },
      lines = {
        "Crit comes as a percentage on gear: \"Improves your chance to get a critical strike by 1%\".",
        "A melee or ranged crit does 200% damage. A spell crit does 150%, and more with talents.",
        "Agility gives melee and ranged crit, Intellect gives spell crit; how much depends on your class.",
      } },
    { name = "Mana regeneration", keys = { "five second rule", "5 second rule", "fsr", "mana regen", "mana regeneration", "mp5", "spirit work", "spirit works", "spirit regen", "regen mana" },
      lines = {
        Bold("Spirit") .. " gives mana back only while you have not spent mana on a spell for " .. Bold("5 seconds") .. ": the five second rule. Some talents and Mage Armor let part of it through while casting.",
        Bold("Mana per 5 seconds (mp5)") .. " on gear always works, casting or not.",
      } },
    { name = "Spell damage and healing", keys = { "spell power work", "spell power works", "spell damage work", "spell damage works", "coefficient", "coefficients", "spell coefficient", "bonus healing work", "healing power", "spell power scale", "scale with spell" },
      lines = {
        "A spell gets a share of your bonus spell damage or healing set by its " .. Bold("cast time: cast time / 3.5") .. ". A 3.5 second cast gets all of it, a 2.5 second cast 71%, a 1.5 second cast or an instant 43%.",
        "Damage and healing over time spells go by how long they last: duration / 15, and the full amount at 15 seconds or more.",
        "Spells that hit many targets, slow, or do something extra get less.",
      } },
    { name = "Reputation", keys = { "reputation work", "reputation works", "rep work", "rep works", "reputation levels", "rep levels", "reputation", "exalted", "revered", "honored" },
      lines = {
        "Standing with a faction goes " .. Bold("Neutral, Friendly, Honored, Revered, Exalted") .. ".",
        "Neutral to Friendly takes 3,000 reputation, Friendly to Honored 6,000, Honored to Revered 12,000, Revered to Exalted 21,000.",
        "It comes from the faction's quests, kills and turn-in items. Better standing opens its goods and takes up to 20% off prices. Humans gain 10% more.",
      } },
    { name = "Talents", keys = { "talents work", "talent points", "respec", "respec cost", "reset talents", "unlearn talents", "reset my talents", "how many talent points" },
      lines = {
        "You get your first talent point at level 10 and one every level after: " .. Bold("51 points at level 60") .. ".",
        "A class trainer will " .. Bold("reset") .. " them. It costs 1 gold the first time, then 5, then 10, and 5 more each time up to 50 gold. The price drops by 5 gold a month you go without, down to 10.",
      } },
    { name = "Dying and repairs", keys = { "durability", "repair", "repairs", "repair cost", "spirit healer", "resurrection sickness", "res sickness", "when i die", "dying", "death penalty" },
      lines = {
        "Dying to a creature takes " .. Bold("10% durability") .. " off everything you are wearing. Dying to another player takes none.",
        "Running back to your body costs nothing more. A " .. Spot("spirit healer") .. " brings you back on the spot for another 25% off everything, bags included, and Resurrection Sickness: all stats and damage down 75% for up to 10 minutes.",
        "An item at 0 durability goes red and gives you nothing until it is repaired. Any vendor with the anvil icon repairs.",
      } },
    { name = "Loot rolls", keys = { "need or greed", "need greed", "need roll", "greed roll", "loot rolls", "loot roll", "rolling", "roll need", "roll greed", "master loot", "master looter" },
      lines = {
        "When something good drops in a group, everyone picks " .. Bold("Need") .. ", " .. Bold("Greed") .. " or Pass. Any Need beats every Greed; the highest roll among the winners takes it.",
        "Need is for something you will wear as an upgrade. Greed is for selling or disenchanting.",
        "In raids the leader usually sets Master Looter and hands items out. I'll tell you when a roll is an upgrade for you.",
      } },
    { name = "Professions", keys = { "professions work", "profession work", "how many professions", "profession cap", "max profession", "profession skill", "level professions" },
      lines = {
        "You can have " .. Bold("two main professions") .. ", plus Cooking, First Aid and Fishing, which everyone can learn.",
        "Skill goes to " .. Bold("300") .. ". Each rank (Journeyman at 75, Expert at 150, Artisan at 225) is learned from a trainer before you can go on.",
        "A recipe's colour says if it will raise your skill: orange always, yellow usually, green rarely, grey never.",
        "The Professions page under Me lists what you can make right now.",
      } },
    { name = "The global cooldown", keys = { "global cooldown", "gcd" },
      lines = {
        "Nearly every ability starts a shared " .. Bold("1.5 second") .. " cooldown on your other abilities. Rogues and cat-form Druids have 1 second.",
      } },
    { name = "Hearthstone", keys = { "hearthstone", "hearth", "set my home", "set home", "bind location" },
      lines = {
        "Your " .. Bold("Hearthstone") .. " takes you back to the inn you chose, once every " .. Bold("60 minutes") .. ".",
        "Talk to any " .. Spot("innkeeper") .. " and pick \"Make this inn your home\" to change where it goes.",
      } },
  }
  local function HowTopic(asked, flags, subject)
    if flags.where or flags.who or flags.drop or flags.drops or flags.sells or flags.sell or flags.buy then return nil end
    local asking = flags.how or flags.why or flags.what or flags.whats or flags.explain or flags.does or flags["do"] or flags.work or flags.works
      or flags.is or flags.can or flags.when or flags.tell or flags.should
    local best, long = nil, 0
    local padded = " " .. asked .. " "
    for _, topic in ipairs(HOW) do
      for _, key in ipairs(topic.keys) do
        if #key > long and (subject == key or (asking and strfind(padded, " " .. key .. " ", 1, true))) then best, long = topic, #key end
      end
    end
    return best
  end
  local function How(rows, topic)
    Ask.mood, Ask.topic, Ask.topicItem = "how", nil, nil
    local text = Task(topic.name) .. "\n" .. table.concat(topic.lines, "\n")
    local mine = topic.mine and topic.mine() or nil
    if mine then text = text .. "\n|cff40ff40" .. mine .. "|r" end
    text = text .. "\n|cff999999These are the Classic rules Forever is built on. It is in beta, so some may change.|r"
    if topic.offer then
      text = text .. "\nWant me to check yours?"
      Ask.pending = topic.offer
    end
    Add(rows, text, WISP)
  end
  Ask.HOW = HOW

  function Ask.Answer(text)
    local rows = {}
    local asked = strlower(strtrim(text or ""))
    asked = gsub(gsub(gsub(asked, "['`]", ""), "[%?%!%.,;:\"%-]", " "), "%s+", " ")
    asked = strtrim(asked)
    if asked == "" then
      Welcome(rows)
      return rows
    end
    -- "yes" or "no" to something Wisp has just offered.
    local offered = Ask.pending
    Ask.pending = nil
    if offered and YES[asked] then return Ask.Answer(offered) end
    if offered and NO[asked] then
      Add(rows, "No problem. Tell me a bit more and I'll look again.", WISP)
      return rows
    end
    do
      local count = 0
      for _ in gmatch(asked, "[^%s]+") do count = count + 1 end
      local reply, examples = SmallTalk(asked, strmatch(asked, "^[^%s]+"), count)
      if reply then
        Add(rows, reply, WISP)
        if examples then Welcome(rows) end
        return rows
      end
    end
    -- A follow-up about the last thing answered: "where is he?", "what does it drop?".
    if Ask.topic then
      if Ask.topicItem and Has(asked, "wish for it", "wish for that", "wishlist it", "add it to my wishlist", "i want it", "i want that", "add that") then
        local item = Items.Shipped(Ask.topicItem.id) or { id = Ask.topicItem.id, name = Ask.topicItem.name, raid = "", custom = true }
        if Wish.Has(item.id) then
          Add(rows, Thing(item.id, Ask.topicItem.name) .. " is already on your wishlist. I'm watching for it.", WISP)
        else
          Wish.Toggle(item)
          Add(rows, "Done. " .. Thing(item.id, Ask.topicItem.name) .. " is on your wishlist, and I'll shout when it drops.", WISP)
        end
        return rows
      end
      local pronoun, rest = false, {}
      for word in gmatch(asked, "[^%s]+") do
        if word == "he" or word == "she" or word == "it" or word == "they" or word == "them" or word == "him" or word == "her"
          or word == "that" or word == "this" or word == "those" or word == "these" or word == "there" then
          pronoun = true
        elseif not FILLER[word] then
          tinsert(rest, word)
        end
      end
      -- Only when nothing else is named: "where is he" yes, "where is that boss Hogger" no.
      if pronoun and #rest == 0 then asked = strtrim(asked .. " " .. strlower(Ask.topic)) end
    end
    local world = Ask.World()
    -- The thing asked about is what is left once the question words are taken off both ends:
    -- "what does attumen the huntsman drop" -> "attumen the huntsman". Words inside a name stay.
    local all, words, flags = {}, {}, {}
    for word in gmatch(asked, "[^%s]+") do
      flags[word] = true
      tinsert(all, word)
      if not FILLER[word] then tinsert(words, word) end
    end
    local from, to = 1, #all
    while from <= to and FILLER[all[from]] do from = from + 1 end
    while to >= from and FILLER[all[to]] do to = to - 1 end
    local subject = table.concat(all, " ", from, to)
    Ask.words = words

    -- A short word that is really an abbreviation: say what it stands for, and check
    -- before running with it when it could be a place.
    if not strfind(subject, " ", 1, true) and #subject <= 8 then
      local places, term = Meanings(subject)
      local short = string.upper(subject)
      if #places == 1 and not term then
        local place = places[1]
        Add(rows, Task(short) .. " is short for " .. Spot(place.name) .. ", " .. PlaceIs(place) .. ". Is that the one you mean?", WISP)
        tinsert(rows, { ask = true, name = "Yes, " .. place.name, text = "Tell me about it", query = place.name, icon = "Interface\\Icons\\INV_Misc_Key_03" })
        Ask.pending = place.name
        return rows
      elseif #places > 0 then
        local said = Task(short) .. " can mean more than one thing."
        if term then said = said .. " It is short for " .. Bold(term[1]) .. ": " .. term[2] .. "." end
        Add(rows, said .. " Or did you mean one of these?", WISP)
        for _, place in ipairs(places) do
          tinsert(rows, { ask = true, name = place.name, text = gsub(PlaceIs(place), "^%l", string.upper), query = place.name, icon = "Interface\\Icons\\INV_Misc_Key_03" })
        end
        return rows
      elseif term then
        Add(rows, Task(short) .. " is short for " .. Bold(term[1]) .. ": " .. term[2] .. ".", WISP)
        return rows
      end
    end

    -- "how does mount speed work?": the rules of the game.
    do
      local topic = HowTopic(asked, flags, subject)
      if topic then
        How(rows, topic)
        return rows
      end
    end

    -- "check my stats", "stat priority", "what should I work on": your stats against your build.
    if strfind(asked, "stat", 1, true) or (flags.work and flags.on) then
      StatCheck(rows)
      return rows
    end
    if Personal(rows, asked, flags, world) then return rows end

    -- "nearest innkeeper", "where can I repair".
    if world then
      for _, role in ipairs(ROLE) do
        for _, word in ipairs(role[3]) do
          if flags[word] and (#words <= 2) then
            Service(rows, world, role)
            return rows
          end
        end
      end
    end

    if #subject < 3 then
      Add(rows, "Name the thing you are asking about: an item, a quest, a boss, an NPC or a dungeon.", "Interface\\Icons\\INV_Misc_Note_02")
      return rows
    end

    -- A raid or dungeon by name.
    for _, place in ipairs(Data.instances) do
      local name = Norm(place.name)
      if name == subject or gsub(name, "^the ", "") == subject then
        Ask.mood = "place"
        Ask.topic, Ask.topicItem = place.name, nil
        local bosses, seen = {}, {}
        for _, item in ipairs(Items.ForPlace(place.id)) do
          if item.boss and not seen[item.boss] then
            seen[item.boss] = true
            tinsert(bosses, Who(item.boss))
          end
        end
        Add(rows, Spot(place.name) .. " is a " .. (place.kind == "raid" and ((place.size or "") .. "-player raid") or (place.kind == "dungeon" and "dungeon" or "group of world bosses"))
          .. (place.zone and (" in " .. Spot(place.zone)) or "") .. (place.min and (", for levels " .. place.min .. " to " .. place.max) or "")
          .. (Places.HasHeroic(place.id) and ", with a heroic version at 70" or "") .. ". Bosses: " .. table.concat(bosses, ", ")
          .. ". Its loot is on the Loot tab.", "Interface\\Icons\\INV_Misc_Key_03")
        for _, item in ipairs(Items.ForPlace(place.id)) do
          if #rows >= 13 then break end
          if Items.Fits(item) then tinsert(rows, item) end
        end
        return rows
      end
    end

    -- A zone by its exact name.
    do
      local zoneId, zoneName = ZoneIn(subject)
      if zoneId and Norm(zoneName) == subject then
        AboutZone(rows, zoneId, zoneName)
        return rows
      end
    end

    -- Everything with a name that fits, best fit first. What was asked for nudges the order:
    -- "who sells" and "where does ... drop" mean an item; "what does ... drop" means a creature.
    local wantsItem = flags.sells or flags.sell or flags.sold or flags.buy or ((flags.drop or flags.drops) and flags.where)
    local wantsNpc = (flags.what and (flags.drop or flags.drops)) or flags.is
    local wantsQuest = flags.quest or flags.turn or flags.hand
    local F = Quests.F
    local function Search(subject)
    local found = {}
    local function Found(kind, id, name, fit, nudge)
      tinsert(found, { kind = kind, id = id, name = name, score = fit * 10 + nudge })
    end
    for _, q in ipairs(Data.quests or {}) do
      local fit = Fit(Norm(q[F.NAME]), subject)
      if fit then Found("quest", q, q[F.NAME], fit, wantsQuest and 5 or 1) end
    end
    local seenItem = {}
    for _, item in ipairs(Data.items) do
      if item.name and not seenItem[item.id] then
        local fit = Fit(Norm(item.name), subject)
        if fit then
          seenItem[item.id] = true
          Found("item", item.id, item.name, fit, wantsItem and 6 or 3)
        end
      end
    end
    if world then
      for id, w in pairs(world.items) do
        if not seenItem[id] then
          local fit = Fit(Norm(w[1]), subject)
          if fit then Found("item", id, w[1], fit, wantsItem and 5 or 0) end
        end
      end
      for id, n in pairs(world.npcs) do
        local fit = Fit(Norm(n[1]), subject)
        if fit then Found("npc", id, n[1], fit, (wantsNpc and 6 or 2) + ((n[10] or 0) > 0 and 1 or 0)) end
      end
    end
    for _, set in ipairs(Data.sets or {}) do
      local fit = Fit(Norm(set.name), subject)
      if fit then Found("set", set, set.name, fit, 2) end
    end
    -- Bosses, from the loot lists (the only place this game's creatures are named).
    local seenBoss = {}
    for _, item in ipairs(Data.items) do
      if item.boss and not seenBoss[item.boss] then
        seenBoss[item.boss] = true
        local fit = Fit(Norm(item.boss), subject)
        if fit then Found("boss", item, item.boss, fit, wantsNpc and 7 or 2) end
      end
    end
    table.sort(found, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      if a.name ~= b.name then return a.name < b.name end
      return a.kind < b.kind
    end)
    return found
    end
    local found = Search(subject)

    -- Nothing fits as typed: a word may be misspelled ("atumen the huntsman").
    local close, clear = {}, false
    if #found == 0 then
      close, clear = Close(subject, world)
      -- One name is clearly what was meant: answer about that, and say so.
      if clear then
        local answer = Ask.Answer(close[1])
        if answer[1] and answer[1].note then
          answer[1].text = "|cff999999I think you mean|r " .. Bold(close[1]) .. ".\n" .. answer[1].text
        end
        return answer
      end
    end

    -- Nothing fits the whole phrase: one word of it may be the name ("hogger elwynn forest").
    -- Only a word that is a name, or the start of one if the word is long, is taken.
    if #found == 0 and #words > 1 then
      local better
      -- If the question also has words about you in it ("sweet purple upgrades"), only a word that
      -- is a whole name counts; the start of a name is too thin to go on.
      local pointed = false
      for _, word in ipairs(words) do
        if POINTS[word] or SLOT_WORD[word] then pointed = true end
      end
      for _, word in ipairs(words) do
        if #word >= 4 then
          Ask.words = { word }
          local list = Search(word)
          if #list > 0 and list[1].score >= ((#word >= 6 and not pointed) and 20 or 30) and (not better or list[1].score > better[1].score) then better = list end
        end
      end
      Ask.words = words
      if better then found = better end
    end

    if #found == 0 and #close == 0 and Guess(rows, asked, world, true) then
      if rows[1] and rows[1].note then
        rows[1].text = "|cff999999I didn't catch all of that, so here's my best guess at what you're after.|r\n" .. rows[1].text
      end
      return rows
    end

    if #found == 0 then
      local said = "I couldn't find anything called " .. Bold("\"" .. subject .. "\"") .. "."
      if #close > 0 then
        said = said .. " Did you mean " .. (#close == 1 and "this" or "one of these") .. "?"
      else
        Ask.mood = "none"
        said = said .. " Check the spelling, or try fewer words." .. " I know this game's raid and dungeon loot, its quests and its item sets." .. " Or try one of these:"
      end
      Add(rows, said, "Interface\\Icons\\INV_Misc_QuestionMark")
      for _, name in ipairs(close) do
        tinsert(rows, { ask = true, name = name, text = "Ask about this", query = name, icon = "Interface\\Icons\\INV_Misc_QuestionMark" })
      end
      if #close == 1 then Ask.pending = close[1] end
      -- Nothing fits: offer what I can do.
      if #close == 0 then
        for _, idea in ipairs({ { "What should I do next?", "what should i do next" }, { "Best upgrades for me", "best upgrade" },
          { "Which dungeon should I run?", "which dungeon should i run" }, { "Check my stats", "check my stats" } }) do
          tinsert(rows, { ask = true, name = idea[1], text = "Something I can answer", query = idea[2], icon = WISP })
        end
        if UI.Missed then UI.Missed(asked) end
        tinsert(rows, { feedback = true, name = "Can't find what you're looking for?", text = "Tell the author what you asked, so I can learn it", query = asked, icon = WISP })
      end
      return rows
    end

    -- The best fit is answered in full; the rest are listed under it.
    local best = found[1]
    if best.kind == "item" then
      AboutItem(rows, best.id, best.name)
    elseif best.kind == "npc" then
      AboutNpc(rows, world, best.id)
    elseif best.kind == "quest" then
      AboutQuest(rows, world, best.id)
    elseif best.kind == "boss" then
      local drops = {}
      for _, item in ipairs(Data.items) do
        if item.boss == best.name and item.raid == best.id.raid then tinsert(drops, item) end
      end
      Ask.mood = "boss"
      Add(rows, Who(best.name) .. " is in " .. Spot(Places.Name(best.id.raid)) .. ". Drops " .. #drops .. " thing" .. (#drops == 1 and "" or "s")
        .. " I know of, listed below.", "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01")
      for _, item in ipairs(drops) do tinsert(rows, item) end
    else
      Ask.mood = "set"
      Ask.topic, Ask.topicItem = best.name, nil
      Add(rows, Bold(best.name) .. " is an item set. Open it to see its pieces on your character.", "Interface\\Icons\\INV_Chest_Plate04")
      tinsert(rows, best.id)
    end
    if #found > 1 then
      Add(rows, "Also called something like that (" .. (#found - 1) .. "):", nil)
      local shown = 0
      for i = 2, #found do
        if shown >= 25 then break end
        local hit = found[i]
        local row
        if hit.kind == "item" then
          row = Items.Shipped(hit.id) or { id = hit.id, name = hit.name, boss = "Item", raid = "", custom = true }
        elseif hit.kind == "npc" then
          row = NpcRow(world, hit.id)
        elseif hit.kind == "quest" then
          row = { ask = true, name = hit.name, text = "Quest, level " .. hit.id[F.LEVEL], icon = "Interface\\GossipFrame\\AvailableQuestIcon" }
        elseif hit.kind == "boss" then
          row = { ask = true, name = hit.name, text = "Boss in " .. Places.Name(hit.id.raid), icon = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01" }
        else
          row = hit.id
        end
        if row then
          tinsert(rows, row)
          shown = shown + 1
        end
      end
    end
    return rows
  end
end
do
  -- Ask.Answer gives the facts (Ask.Facts, above). This adds Wisp's remark to them.
  -- (A "yes" calls back in here for the thing offered; the remark is added once, by that call.)
  local Facts = Ask.Answer
  function Ask.Answer(text)
    Ask.mood = nil
    local rows = Facts(text)
    local mood = Ask.mood
    Ask.mood = nil
    local quip = Ask.Quip(mood)
    if quip and rows[1] and rows[1].note then rows[1].text = rows[1].text .. "\n\n|cffc8b478" .. quip .. "|r" end
    return rows
  end
end
UI.Ask = Ask

function UI.Collect()
  local list = UI.shown
  wipe(list)
  local text = UI.search and UI.search:GetText() or ""
  local q = strlower(strtrim(text))
  if db.page == "home" then
    for _, row in ipairs(Home.Rows()) do tinsert(list, row) end
    return
  end
  -- The Wisp page is a chat and the welcome page is tiles: neither has a list (see UI.chat, UI.hub).
  if db.page == "ask" or db.page == "hub" then return end
  if db.page == "alts" then
    Chars.Save()
    for _, row in ipairs(Chars.List()) do tinsert(list, row) end
    return
  end
  if db.page == "prof" then
    for _, row in ipairs(Prof.Rows()) do tinsert(list, row) end
    return
  end
  if db.page == "talents" then
    -- The tree view has no list.
    if not db.talentList then return end
    for _, row in ipairs((Talents.Rows())) do tinsert(list, row) end
    return
  end
  if db.page == "legacy" then
    for _, row in ipairs(Legacy.Rows()) do tinsert(list, row) end
    return
  end
  if db.page == "settings" then
    for _, row in ipairs(Settings.Rows(UI.settingsTab or "window")) do tinsert(list, row) end
    return
  end
  if db.page == "quests" then
    local zoneId, label = nil, "Everywhere"
    if db.questZone == "HERE" then
      local here, name = Quests.ZoneHere()
      if here then
        zoneId, label = here, name
      else
        label = "Everywhere" .. (name and (" (nothing listed for " .. name .. ")") or "")
      end
    elseif type(db.questZone) == "number" then
      zoneId, label = db.questZone, Quests.ZoneName(db.questZone)
    end
    local rows, total, doable = Quests.List(zoneId, db.questNow ~= false, q)
    for i = 1, math.min(#rows, SEARCH_MAX) do tinsert(list, rows[i]) end
    UI.questTotals = { total = total, doable = doable, label = label, everywhere = zoneId == nil, best = rows[1] }
    return
  end
  if db.page == "train" then
    local rows, grand, ready, nextGroup = Train.Rows()
    for _, row in ipairs(rows) do tinsert(list, row) end
    UI.trainTotals = { grand = grand, ready = ready, next = nextGroup }
    return
  end
  if db.page == "sets" then
    if UI.openSet then
      -- One set, opened: its pieces.
      for _, id in ipairs(Sets.Items(UI.openSet)) do
        local item = Items.Shipped(id) or { id = id, boss = UI.openSet.name, raid = "", custom = true }
        if not item.name then item.name = Items.Name(id) end
        tinsert(list, item)
      end
    else
      for _, set in ipairs(Data.sets or {}) do
        local classFile, everyone = UI.ClassFilter()
        if (q == "" or strfind(strlower(set.name), q, 1, true)) and (everyone or Sets.Fits(set, classFile)) then
          tinsert(list, set)
        end
      end
    end
    return
  end
  local linked = ParseItemId(text)
  if linked then
    local item = Items.Row(linked, db.browseId)
    if not item.name then item.name = Items.Name(linked) end
    tinsert(list, item)
    return
  end
  if db.page == "wish" then
    for _, id in ipairs(Wish.Ids()) do
      local item = Items.Row(id, Wish.From(id))
      if not item.name then item.name = Items.Name(id) end
      if Matches(item, q) then tinsert(list, item) end
    end
    return
  end
  if q ~= "" and #q >= 2 then
    -- Typing in the search box looks through every raid and dungeon, like a database.
    for _, item in ipairs(Data.items) do
      if #list >= SEARCH_MAX then break end
      if Matches(item, q) and UI.Passes(item) then tinsert(list, item) end
    end
    return
  end
  local heroic = UI.Diff()
  for _, placeId in ipairs((UI.Scope())) do
    for _, item in ipairs(Items.ForPlace(placeId)) do
      if not item.name then item.name = Items.Name(item.id) end
      if UI.Passes(item) and Items.InDiff(item, heroic) and (UI.boss == "ALL" or item.boss == UI.boss) then
        tinsert(list, item)
      end
    end
  end
end

-- Collects the rows, then works out which items are upgrades: the best one for each slot
-- is marked, and "Upgrades first" moves the biggest improvements to the top.
function UI.Rebuild()
  UI.Collect()
  local list = UI.shown
  UI.verdict = {}
  local bestFor = {}
  local scores = {}
  for index, item in ipairs(list) do
    if item.id and not item.bonus and not item.train and Items.Fits(item) then
      local result = Compare.Item(item)
      local verdict = Compare.Verdict(result)
      if verdict then
        UI.verdict[item.id] = verdict
        scores[item.id] = result.score
        if verdict == "up" then
          local slot = Items.Slot(item)
          if not bestFor[slot] or result.score > scores[bestFor[slot]] then bestFor[slot] = item.id end
        end
      end
    end
    item.order = index
  end
  for _, id in pairs(bestFor) do UI.verdict[id] = "best" end
  if db.bestFirst and db.page == "browse" then
    table.sort(list, function(a, b)
      local sa, sb = scores[a.id] or -1000000, scores[b.id] or -1000000
      if sa ~= sb then return sa > sb end
      return (a.order or 0) < (b.order or 0)
    end)
  end
end

function UI.Bosses()
  local list, seen = {}, {}
  local heroic = UI.Diff()
  for _, placeId in ipairs((UI.Scope())) do
    for _, item in ipairs(Items.ForPlace(placeId)) do
      if item.boss and not seen[item.boss] and Items.InDiff(item, heroic) then
        seen[item.boss] = true
        tinsert(list, item.boss)
      end
    end
  end
  return list
end

function UI.ResetScroll()
  UI.offset = 0
  if UI.scroll then
    if FauxScrollFrame_SetOffset then FauxScrollFrame_SetOffset(UI.scroll, 0) end
    local bar = UI.scroll.ScrollBar or _G[UI.scroll:GetName() .. "ScrollBar"]
    if bar and bar:GetValue() ~= 0 then bar:SetValue(0) end
  end
end

-- Character preview -------------------------------------------------------------

-- Puts one item on the character. If the game has not loaded the item yet, it is asked
-- for and tried on as soon as it arrives (see GET_ITEM_INFO_RECEIVED).
function UI.TryOn(id)
  if not UI.model or not UI.model.TryOn then return end
  if C_Item and C_Item.IsItemDataCachedByID and Plain(C_Item.IsItemDataCachedByID(id)) ~= true then
    UI.pendingTry[id] = true
    Items.RequestLoad(id)
    return
  end
  UI.pendingTry[id] = nil
  local link
  local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if info then
    local ok, _, found = pcall(info, id)
    if ok then link = Plain(found) end
  end
  pcall(UI.model.TryOn, UI.model, type(link) == "string" and link or ("item:" .. id))
end

-- Back to what the character is wearing right now.
function UI.ShowMyGear()
  if not UI.model then return end
  wipe(UI.pendingTry)
  pcall(function()
    -- Loading the character into the model takes a moment and drops anything tried on
    -- straight after, so it is only done once; after that Dress() is enough.
    if not UI.modelLoaded then
      UI.model:SetUnit("player")
      UI.modelLoaded = true
    end
    if UI.model.Dress then UI.model:Dress() end
  end)
end

-- Puts an item's link into the open chat box. Returns false if there is no chat box open
-- or the game has not loaded the item yet.
function UI.LinkToChat(id)
  local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
  if not info then return false end
  local ok, _, link = pcall(info, id)
  link = ok and Plain(link) or nil
  if type(link) ~= "string" then
    Items.RequestLoad(id)
    return false
  end
  if ChatFrameUtil and ChatFrameUtil.InsertLink then return ChatFrameUtil.InsertLink(link) and true or false end
  if ChatEdit_InsertLink then return ChatEdit_InsertLink(link) and true or false end
  return false
end

-- Asks what the character is saving for.
function UI.AskGoal()
  StaticPopupDialogs["WISHWELL_GOAL"] = StaticPopupDialogs["WISHWELL_GOAL"] or {
    text = "How much gold are you saving up?\n(Type a number of gold, or 0 for no goal.)",
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    OnAccept = function(self)
      local box = self.editBox or self.EditBox
      local text = box and box:GetText() or ""
      if Chars.SetGoal(tonumber(text), "My goal") then
        Print("Gold goal set to " .. Train.Money(Chars.Goal().amount) .. ". Rename it with /ww goal " .. text .. " Epic mount.")
      else
        Print("Gold goal switched off.")
      end
      Refresh()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
  StaticPopup_Show("WISHWELL_GOAL")
end

-- Asks before spending talent points: they cost gold to take back.
function UI.AskTalents(limit)
  if type(limit) ~= "number" then limit = nil end
  local points, names, build = Talents.Ready()
  if points <= 0 or not build then return end
  local shown = {}
  if limit == 1 then
    points = 1
    tinsert(shown, (gsub(names[1] or "", " x%d+$", "")))
  else
    for i = 1, math.min(#names, 6) do tinsert(shown, names[i]) end
    if #names > #shown then tinsert(shown, "and " .. (#names - #shown) .. " more") end
  end
  UI.talentLimit = limit
  StaticPopupDialogs["WISHWELL_TALENTS"] = StaticPopupDialogs["WISHWELL_TALENTS"] or {
    text = "%s",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function() Talents.Apply(UI.talentLimit) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
  StaticPopup_Show("WISHWELL_TALENTS", "Spend " .. points .. " talent point" .. (points == 1 and "" or "s") .. " on " .. build.name .. "?\n\n"
    .. table.concat(shown, ", ") .. "\n\nTaking talents back costs gold at a class trainer.")
end

-- Asks before emptying the wishlist.
function UI.AskClearWishlist()
  local n = Wish.Count()
  if n == 0 then
    Print("Your wishlist is already empty.")
    return
  end
  StaticPopupDialogs["WISHWELL_CLEAR"] = StaticPopupDialogs["WISHWELL_CLEAR"] or {
    text = "Take all %d items off your wishlist?",
    button1 = YES or "Yes",
    button2 = NO or "No",
    OnAccept = function()
      local removed = Wish.Clear()
      Print("Wishlist cleared (" .. removed .. " item" .. (removed == 1 and "" or "s") .. ").")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
  StaticPopup_Show("WISHWELL_CLEAR", n)
end

-- Adds every piece of the open set to the wishlist.
function UI.WishWholeSet()
  local set = UI.openSet
  if not set then return end
  local items = {}
  for _, id in ipairs(Sets.Items(set)) do
    tinsert(items, Items.Shipped(id) or { id = id, raid = "" })
  end
  if #items == 0 then
    Print("The items in " .. set.name .. " are not known yet.")
    return
  end
  local added = Wish.AddAll(items)
  Print(added .. " piece" .. (added == 1 and "" or "s") .. " of " .. set.name .. " added to your wishlist.")
end

-- Opens a set: its pieces fill the list and go on the character.
function UI.OpenSet(set)
  UI.openSet = set
  UI.ResetScroll()
  UI.ShowMyGear()
  if set then
    -- Ask the game again if the pieces were not known last time.
    if #set.items == 0 then set.asked = nil end
    for _, id in ipairs(Sets.Items(set)) do UI.TryOn(id) end
  end
  Refresh()
end

-- A set's bonuses: { { pieces needed, what it does }, ... }. Where the data has none they are
-- read off the tooltip of one of its pieces, which lists them as "(2) Set: ...". A bonus you
-- already have shows without its number, and is kept with 0 pieces.
local setTip
function UI.SetBonuses(set)
  if #set.bonus > 0 or set.bonusRead then return set.bonus end
  if setTip == nil then
    local ok, made = pcall(CreateFrame, "GameTooltip", "WishwellSetTip", nil, "GameTooltipTemplate")
    setTip = ok and type(made) == "table" and made or false
  end
  if not setTip then return set.bonus end
  for _, id in ipairs(Sets.Items(set)) do
    setTip:SetOwner(WorldFrame or UIParent, "ANCHOR_NONE")
    setTip:ClearLines()
    local found = {}
    if pcall(setTip.SetHyperlink, setTip, "item:" .. id) then
      for i = 2, tonumber((setTip:NumLines())) or 0 do
        local left = _G["WishwellSetTipTextLeft" .. i]
        local text = type(left) == "table" and left.GetText and Plain(left:GetText()) or nil
        if type(text) == "string" then
          local count, what = strmatch(text, "^%((%d+)%) [^:]+: (.+)$")
          if not count then what = strmatch(text, "^Set: (.+)$") end
          if what then tinsert(found, { tonumber(count) or 0, what }) end
        end
      end
    end
    -- A piece the game has not loaded yet has an empty tooltip: try the next, or again later.
    if #found > 0 then
      set.bonus, set.bonusRead = found, true
      break
    end
  end
  return set.bonus
end

-- Tooltip for a set: its pieces and bonuses.
function UI.SetTooltip(owner, set)
  GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
  GameTooltip:SetText(set.name)
  local ids = Sets.Items(set)
  if #ids > 0 then
    for _, id in ipairs(ids) do GameTooltip:AddLine(Items.Name(id) or ("Item " .. id), 1, 1, 1) end
  elseif set.pieces then
    for _, name in ipairs(set.pieces) do GameTooltip:AddLine(name, 0.6, 0.6, 0.6) end
  end
  for _, bonus in ipairs(UI.SetBonuses(set)) do
    GameTooltip:AddLine((bonus[1] > 0 and ("(" .. bonus[1] .. ") ") or "") .. "Set: " .. bonus[2], 0.1, 1, 0.1, true)
  end
  GameTooltip:Show()
end

function UI.TryOnWishlist()
  UI.ShowMyGear()
  local n = 0
  for _, id in ipairs(Wish.Ids()) do
    UI.TryOn(id)
    n = n + 1
  end
  if n == 0 then Print("Your wishlist is empty. Open the Loot tab and click Wish on the items you want.") end
end

Refresh = function()
  -- The tracker lives outside the window, so it is kept up to date whether the window is open or not.
  if UI.Tracker then UI.Tracker.Refresh() end
  if not frame or not frame:IsShown() then return end
  UI.Rebuild()
  local list = UI.shown
  local wishPage = db.page == "wish"
  local setsPage = db.page == "sets"
  local searching = db.page == "browse" and UI.search and #strtrim(UI.search:GetText() or "") >= 2

  UI.setTitle:SetText(UI.openSet and UI.openSet.name or "Item sets")
  UI.setBack:SetShown(UI.openSet ~= nil)
  UI.setWishAll:SetShown(UI.openSet ~= nil)
  -- The class menu shares its row with Back and Wish all, so it steps aside while a set is open.
  UI.classDrop:SetShown(db.page == "browse" or (setsPage and UI.openSet == nil))
  local classFile, everyone = UI.ClassFilter()
  UIDropDownMenu_SetText(UI.classDrop, everyone and "All classes" or (db.classFilter and db.classFilter ~= "MINE" and ClassLabel(classFile) or "My class"))
  local rarityName = "All rarities"
  for _, r in ipairs(RARITIES) do
    if r[1] == db.rarity then rarityName = r[2] end
  end
  UIDropDownMenu_SetText(UI.rarityDrop, rarityName)
  UIDropDownMenu_SetText(UI.slotDrop, (db.slot and db.slot ~= "ALL") and db.slot or "All slots")
  if db.page == "legacy" then
    frame.status:SetText("Legacy challenges, the ones you are closest to finishing first. Hover one for its steps and reward.")
  elseif db.page == "ask" then
    frame.status:SetText(#UI.talk == 0 and "Type a question, or click an example." or "Wisp answers from Wishwell's own data. It is a look-up, not an AI.")
  elseif db.page == "talents" then
    frame.status:SetText(Talents.Status())
  elseif db.page == "settings" then
    frame.status:SetText("Switch parts of Wishwell on or off. Pick a section; changes take effect straight away.")
  elseif db.page == "prof" then
    frame.status:SetText("What to make to raise your professions. Orange always gives a skill point, yellow usually does.")
  elseif db.page == "alts" then
    local gold = 0
    for _, row in ipairs(list) do gold = gold + (row.char.money or 0) end
    frame.status:SetText(#list .. " character" .. (#list == 1 and "" or "s") .. " on this account have used Wishwell. " .. Train.Money(gold) .. " between them.")
  elseif db.page == "home" then
    local className = Plain((UnitClass("player"))) or ""
    frame.status:SetText("Level " .. Quests.MyLevel() .. " " .. className .. ". Here is what looks most worth your time. Click a line to go there.")
  elseif db.page == "quests" then
    local t = UI.questTotals or {}
    UIDropDownMenu_SetText(UI.questZoneDrop, db.questZone == "HERE" and "Where I am" or (t.label or "Everywhere"))
    if (t.doable or 0) == 0 then
      frame.status:SetText((t.label or "") .. ": nothing to pick up right now.")
    else
      local best = t.best and (t.best.state == "open" or t.best.state == "log") and t.best or nil
      frame.status:SetText((t.label or "") .. ": " .. t.doable .. " quest" .. (t.doable == 1 and "" or "s") .. " you can do now, "
        .. Quests.Number(t.total) .. " XP in all"
        .. (best and (". Best: " .. best.quest[Quests.F.NAME] .. " (" .. Quests.Number(best.xp) .. " XP)") or ""))
    end
  elseif db.page == "train" then
    local totals = UI.trainTotals or {}
    if not Train.Scanned() then
      frame.status:SetText("Visit your class trainer once and this tab fills in.")
    elseif #list == 0 then
      frame.status:SetText("You have trained everything your trainer offers.")
    else
      local parts = {}
      if totals.ready then tinsert(parts, "Ready now: " .. totals.ready.count .. " for " .. Train.Money(totals.ready.total)) end
      if totals.next then tinsert(parts, "Next at level " .. totals.next.level .. ": " .. totals.next.count .. " for " .. Train.Money(totals.next.total)) end
      tinsert(parts, "Everything left: " .. Train.Money(totals.grand or 0))
      frame.status:SetText(table.concat(parts, "  ·  "))
    end
  elseif setsPage and UI.openSet then
    frame.status:SetText("The set is on your character. Reset (under the character) puts your own gear back. Back returns to the set list.")
  elseif setsPage then
    frame.status:SetText("Click a set to see it on your character. Hover a set for its pieces and bonuses.")
  elseif wishPage then
    local n = Wish.Count()
    frame.status:SetText("Your wishlist: " .. n .. " item" .. (n == 1 and "" or "s") .. ". Click a row to try it on. You are told when one drops.")
  elseif searching then
    frame.status:SetText("Searching every raid and dungeon. Click a row to try it on, or Wish to add it to your list.")
  elseif db.page == "browse" and UI.Diff() ~= nil then
    frame.status:SetText(UI.Diff() and "Heroic drops. For the normal dungeon, pick it under Dungeons in the menu. Click a row to try the item on."
      or "Normal drops. For heroic, pick it under Heroic dungeons in the menu. Click a row to try the item on.")
  else
    frame.status:SetText("Click a row to try the item on. Click Wish to add it to your wishlist. Type to search everything.")
  end
  local _, byZone = UI.Scope()
  local oneDiff = db.page == "browse" and not searching and UI.Diff() ~= nil
  UIDropDownMenu_SetText(UI.placeDrop, byZone and ("All in " .. db.zone) or Places.Label(db.browseId, db.heroic))
  UIDropDownMenu_SetText(UI.zoneDrop, byZone and db.zone or "All zones")
  UIDropDownMenu_SetText(UI.bossDrop, UI.boss == "ALL" and "All bosses" or UI.boss)

  local maxOffset = math.max(0, #list - ROWS)
  if UI.offset > maxOffset then UI.offset = maxOffset end
  FauxScrollFrame_Update(UI.scroll, #list, ROWS, ROW_H)
  local treeView = db.page == "talents" and not db.talentList
  local chatView = db.page == "ask"
  local hubView = db.page == "hub"
  if #list == 0 and not treeView and not chatView and not hubView then
    local heading, body
    if db.page == "legacy" then
      heading = "Legacy"
      body = "Wishwell could not read the Legacy challenges. They may not be available on this character yet (Hardcore characters do not have them)."
    elseif db.page == "prof" then
      heading = "No professions yet"
      body = "Learn a profession from a trainer in a city, then open its window once. Wishwell lists the recipes that will raise your skill and whether you have the materials."
    elseif db.page == "quests" then
      heading = "No quests found"
      body = "Nothing matches here for your character.\n\nUntick \"Only what I can do now\" to see quests you are not ready for yet, or pick another zone.\n\nThe list has the Classic quests. The new WoW Forever quests are not in it yet."
    elseif db.page == "train" then
      if Train.Scanned() then
        heading, body = "All trained", "Nothing left to train. Visit your class trainer again after a patch to refresh this list."
      else
        heading = "Spell training"
        body = "Visit your class trainer once.\n\nWishwell reads the trainer's list, then shows every spell you have coming up, the level it unlocks, and what each level will cost you to train.\n\nStill empty after a visit? Stand at the trainer with its window open and type /ww trainer."
      end
    elseif setsPage and UI.openSet then
      heading = UI.openSet.name
      body = "The game has not told us which items are in this set yet.\n\n" .. (UI.openSet.pieces and table.concat(UI.openSet.pieces, "\n") or "")
    elseif setsPage then
      heading, body = "No sets found", "Try a different name, or pick All classes."
    elseif wishPage then
      heading = "Your wishlist"
      body = "Nothing here yet.\n\nOpen the Loot tab (the second icon on the right) and click Wish on the items you want. You will be told when they drop."
    elseif searching then
      heading, body = "Nothing found", "You can also shift-click any item link into the search box, or type an item ID."
    else
      heading = "No loot known yet"
      body = "Nobody has seen what drops here. It fills in as items drop.\n\nYou can shift-click any item link into the search box, or type an item ID."
    end
    UI.emptyTitle:SetText(heading)
    UI.empty:SetText(body)
    UI.emptyTitle:Show()
    UI.empty:Show()
  else
    UI.emptyTitle:Hide()
    UI.empty:Hide()
  end

  for i = 1, ROWS do
    local row = UI.rows[i]
    local item = list[i + UI.offset]
    if item and item.talent then
      row.item = item
      if item.build then
        local role = Talents.ROLE[item.build.role]
        row.icon:SetTexture(role[2])
        row.name:SetTextColor(1, 0.82, 0)
        row.name:SetText(role[1] .. ": " .. item.build.name)
        row.meta:SetText("|cffffffff" .. Talents.TreeText(item.build) .. "|r" .. (item.best and " · |cff40ff40recommended|r" or ""))
        row.wish:SetText(item.chosen and "Change" or "Use")
        row.wish:Show()
        row:SetTint(item.chosen and "heading" or "plain")
      else
        local now = item.first == 0
        row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        row.name:SetTextColor(now and 0.25 or 1, 1, now and 0.25 or 1)
        row.name:SetText(item.name)
        row.meta:SetText("|cffffffff" .. Talents.StepText(item) .. "|r")
        row.wish:Hide()
        row:SetTint(now and "plain" or "dim")
      end
      row:Show()
    elseif item and item.setting then
      local entry = item.entry
      local on = entry.choices and true or Settings.IsOn(entry)
      row.item = item
      row.icon:SetTexture(on and "Interface\\RaidFrame\\ReadyCheck-Ready" or "Interface\\RaidFrame\\ReadyCheck-NotReady")
      row.name:SetTextColor(1, 0.82, 0)
      row.name:SetText(entry.label)
      row.meta:SetText("|cffffffff" .. entry.text .. "|r")
      row.wish:SetText(entry.choices and select(2, Settings.Choice(entry))[2] or (on and "On" or "Off"))
      row.wish:Show()
      row:SetTint(on and "plain" or "dim")
      row:Show()
    elseif item and item.legacy then
      row.item = item
      row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.name:SetTextColor(1, 1, 1)
      row.name:SetText(item.name)
      row.meta:SetText("|cffffd100" .. math.floor(item.progress * 100 + 0.5) .. "% done|r" .. (item.category and (" · " .. item.category) or "")
        .. (type(item.text) == "string" and item.text ~= "" and (" · " .. item.text) or ""))
      row.wish:Hide()
      row:SetTint("plain")
      row:Show()
    elseif item and item.profHead then
      local p = item.prof
      row.item = item
      row.icon:SetTexture(p.icon or "Interface\\Icons\\INV_Misc_Book_09")
      row.name:SetTextColor(1, 0.82, 0)
      row.name:SetText(p.name)
      row.meta:SetText("|cffffffffSkill " .. p.rank .. " of " .. p.max .. "|r" .. (p.max > 0 and p.rank >= p.max and " · |cffff9933at the cap: visit a trainer|r" or ""))
      row.wish:Hide()
      row:SetTint("heading")
      row:Show()
    elseif item and item.recipe then
      local r = item.r
      local color = Prof.DIFF[r.diff] or Prof.DIFF[3]
      row.item = item
      row.icon:SetTexture(r.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.name:SetTextColor(color[1], color[2], color[3])
      row.name:SetText(r.name)
      local meta = Prof.ReagentText(r)
      if item.make > 0 then
        meta = "|cff40ff40You can make " .. item.make .. "|r" .. (meta ~= "" and (" · " .. meta) or "")
      end
      row.meta:SetText(meta)
      row.wish:Hide()
      row:SetTint(item.make > 0 and "plain" or "dim")
      row:Show()
    elseif item and item.npc then
      row.item = item
      row.icon:SetTexture(item.rank and item.rank > 0 and "Interface\\Icons\\Ability_Creature_Cursed_02" or "Interface\\Icons\\INV_Misc_Head_Human_01")
      row.name:SetTextColor(1, 0.82, 0)
      row.name:SetText(item.name .. ((item.max or 0) > 0 and ("  |cffffffffLevel " .. ((item.min and item.min ~= item.max and item.min > 0) and (item.min .. "-" .. item.max) or item.max) .. "|r") or ""))
      local meta = {}
      if item.title then tinsert(meta, item.title) end
      if item.where then tinsert(meta, item.where) end
      for _, role in ipairs(item.roles or {}) do
        if role ~= item.title then tinsert(meta, role) end
      end
      row.meta:SetText("|cffffffff" .. table.concat(meta, " · ") .. "|r")
      if item.map then
        row.wish:SetText("Map")
        row.wish:Show()
      else
        row.wish:Hide()
      end
      row:SetTint("plain")
      row:Show()
    elseif item and item.ask then
      row.item = item
      row.icon:SetTexture(item.icon)
      row.name:SetTextColor(1, 0.82, 0)
      row.name:SetText(item.name)
      row.meta:SetText("|cffffffff" .. item.text .. "|r")
      row.wish:SetText("Ask")
      row.wish:Show()
      row:SetTint("plain")
      row:Show()
    elseif item and item.note then
      row.item = item
      row.icon:SetTexture(item.icon)
      row.name:SetTextColor(0.8, 0.8, 0.8)
      row.name:SetText(item.text)
      row.meta:SetText("")
      row.wish:Hide()
      row:SetTint("plain")
      row:Show()
    elseif item and item.alt then
      local c = item.char
      row.item = item
      row.icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
      local color = type(RAID_CLASS_COLORS) == "table" and c.class and RAID_CLASS_COLORS[c.class] or nil
      if type(color) == "table" and color.r then
        row.name:SetTextColor(color.r, color.g, color.b)
      else
        row.name:SetTextColor(1, 1, 1)
      end
      row.name:SetText(c.name .. "  |cffffffffLevel " .. (c.level or "?") .. (c.class and (" " .. ClassLabel(c.class)) or "") .. "|r"
        .. (item.me and "  |cff808080(this character)|r" or ""))
      local meta = ""
      if type(c.xp) == "number" and type(c.xpMax) == "number" and c.xpMax > c.xp and (c.level or 0) < 60 then
        meta = Quests.Number(c.xpMax - c.xp) .. " XP to level " .. ((c.level or 0) + 1)
          .. " (" .. math.floor(c.xp / c.xpMax * 100) .. "% there) · "
      end
      meta = meta .. Train.Money(c.money or 0) .. " · " .. item.wishes .. " on wishlist"
      if item.spells > 0 then
        meta = meta .. " · " .. item.spells .. " spell" .. (item.spells == 1 and "" or "s") .. " to train (" .. Train.Money(item.cost) .. ")"
      end
      if type(c.goal) == "table" and (c.goal.amount or 0) > 0 then
        meta = meta .. " · saving for " .. (c.goal.name or "a goal")
      end
      row.meta:SetText(meta)
      row.wish:Hide()
      row:SetTint(item.me and "heading" or "plain")
      row:Show()
    elseif item and item.advice then
      row.item = item
      row.icon:SetTexture(item.icon)
      row.name:SetTextColor(1, 0.82, 0)
      row.name:SetText(item.title)
      row.meta:SetText("|cffffffff" .. item.text .. "|r")
      row.wish:SetText("Go")
      row.wish:Show()
      row:SetTint("plain")
      row:Show()
    elseif item and item.questRow then
      local q, F = item.quest, Quests.F
      row.item = item
      row.icon:SetTexture(item.state == "log" and "Interface\\GossipFrame\\ActiveQuestIcon" or "Interface\\GossipFrame\\AvailableQuestIcon")
      row.name:SetText("[" .. q[F.LEVEL] .. "] " .. q[F.NAME])
      local color = GetQuestDifficultyColor and GetQuestDifficultyColor(q[F.LEVEL]) or nil
      if type(color) == "table" and color.r then
        row.name:SetTextColor(color.r, color.g, color.b)
      else
        row.name:SetTextColor(1, 0.82, 0)
      end
      local meta = "|cffffffff" .. Quests.Number(item.xp) .. " XP|r"
      if UI.questTotals and UI.questTotals.everywhere then meta = meta .. " · " .. Quests.ZoneName(q[F.ZONE]) end
      local who = Quests.Who(q)
      if who then meta = meta .. " · " .. who end
      if item.state == "log" then
        meta = meta .. " · |cff40ff40In your log|r"
      elseif item.state == "level" then
        meta = meta .. " · |cffff5555Needs level " .. q[F.MIN] .. "|r"
      elseif item.state == "after" then
        meta = meta .. " · |cffff9933After: " .. (Quests.Blocker(q) or "another quest") .. "|r"
      end
      row.meta:SetText(meta)
      if MapPin.Start(q[F.ID]) then
        row.wish:SetText("Map")
        row.wish:Show()
      else
        row.wish:Hide()
      end
      row:SetTint((item.state == "open" or item.state == "log") and "plain" or "dim")
      row:Show()
    elseif item and item.header then
      -- Training: one level's heading with its total.
      row.item = item
      row.icon:SetTexture("Interface\\Icons\\INV_Misc_Book_11")
      row.name:SetTextColor(1, 1, 1)
      row.name:SetText(item.level == 0 and "|cff40ff40Ready to train now|r" or ("|cffffd100Level " .. item.level .. "|r"))
      row.meta:SetText(item.count .. " spell" .. (item.count == 1 and "" or "s") .. " · total " .. Train.Money(item.total))
      row.wish:Hide()
      row:SetTint("heading")
      row:Show()
    elseif item and item.train then
      -- Training: one spell.
      row.item = item
      row.icon:SetTexture(item.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.name:SetTextColor(1, 1, 1)
      row.name:SetText(item.name .. (item.rank and ("  |cff9d9d9d" .. item.rank .. "|r") or ""))
      row.meta:SetText(Train.Money(item.cost))
      row.wish:Hide()
      row:SetTint("plain")
      row:Show()
    elseif item and item.bonus then
      -- A set, not an item.
      row.wish:Show()
      row.item = item
      local ids = Sets.Items(item)
      local size = Sets.Size(item)
      row.icon:SetTexture(ids[1] and Items.Icon(ids[1]) or "Interface\\Icons\\INV_Misc_QuestionMark")
      row.name:SetText(item.name)
      row.name:SetTextColor(Items.QualityColor(ids[1] and Items.Quality({ id = ids[1] }) or 1))
      if #ids == 0 then
        row.meta:SetText(size .. " pieces · items not known yet")
      elseif #ids < size then
        row.meta:SetText(size .. " pieces · " .. #ids .. " known so far")
      else
        row.meta:SetText(size .. " pieces · " .. #item.bonus .. " set bonus" .. (#item.bonus == 1 and "" or "es"))
      end
      row.wish:SetText("Open")
      row:SetTint("plain")
      row:Show()
    elseif item then
      row.wish:Show()
      row.item = item
      row.icon:SetTexture(Items.Icon(item.id))
      local wished = Wish.Has(item.id)
      row.name:SetText(item.name or ("Looking up item " .. item.id .. "..."))
      row.name:SetTextColor(Items.QualityColor(Items.Quality(item)))
      local meta = Items.Meta(item, wishPage or searching or (db.page == "browse" and byZone), oneDiff)
      local others = WantedBy and WantedBy(item.raid, item.id) or nil
      if others and #others > 0 then meta = meta .. " · |cffffd100Wanted by " .. table.concat(others, ", ") .. "|r" end
      local verdict = UI.verdict and UI.verdict[item.id]
      if verdict == "best" then
        meta = "|cffffd100Best upgrade|r · " .. meta
      elseif verdict == "up" then
        meta = "|cff40ff40Upgrade|r · " .. meta
      end
      row.meta:SetText(meta)
      row.wish:SetText(wished and "Wished" or "Wish")
      if wished then
        row:SetTint("wished")
      elseif not Items.Fits(item) then
        row:SetTint("dim")
      else
        row:SetTint("plain")
      end
      row:Show()
    else
      row.item = nil
      row:Hide()
    end
  end
  if UI.talentApply then
    local points = db.page == "talents" and db.talentList and Talents.Ready() or 0
    UI.talentApply:SetShown(points > 0)
    UI.talentApply:SetText(Talents.Applying() and "Spending..." or ("Spend " .. points .. " point" .. (points == 1 and "" or "s")))
    if UI.talentApply.SetEnabled then UI.talentApply:SetEnabled(not Talents.Applying()) end
  end
  UI.FillSide()
  -- Talents, tree view: the trees take the place of the character and the list.
  if UI.talentPanel then
    UI.talentPanel:SetShown(treeView)
    if treeView then UI.talentPanel:Fill() end
    UI.chat:SetShown(chatView)
    if chatView then UI.chat:Render() end
    UI.hub:SetShown(hubView)
    if hubView then UI.hub:Fill() end
    local whole = treeView or chatView or hubView
    UI.stage:SetShown(not whole)
    UI.listPanel:SetShown(not whole)
    UI.scroll:SetShown(not whole)
    if chatView or hubView then
      for _, btn in ipairs(UI.stageButtons or {}) do btn:Hide() end
    end
    UI.talentToTree:SetShown(db.page == "talents" and not treeView)
    if db.page == "talents" then UI.pageTitle:SetShown(not treeView) end
    if treeView then
      for _, btn in ipairs(UI.stageButtons or {}) do btn:Hide() end
    end
  end
  UI.LayoutRows()
end

-- True if a line of text is too long for its row and ends in "...".
function UI.Cut(text)
  if text.IsTruncated then
    local cut = text:IsTruncated()
    if type(cut) == "boolean" then return cut end
  end
  local full = text.GetUnboundedStringWidth and text:GetUnboundedStringWidth() or nil
  if type(full) ~= "number" then return false end
  return full > (tonumber(text:GetWidth()) or 0) + 1
end

-- Opens a row out to show all of its text, or closes it again. Returns true if it did
-- either, false if the row's text already fits.
function UI.ToggleRow(row)
  if row.open then
    UI.openKey = nil
  elseif UI.Cut(row.name) or UI.Cut(row.meta) then
    UI.openKey = row.key
  else
    return false
  end
  Refresh()
  return true
end

-- Stacks the rows. They are all one height except a row that has been opened out, which
-- is as tall as its text; the rows under it move down and any that no longer fit are
-- left for scrolling.
function UI.LayoutRows()
  local plain = ROW_H - 2
  local heights, openAt = {}, nil
  for i = 1, ROWS do
    local row = UI.rows[i]
    if row:IsShown() then
      row.key = (row.name:GetText() or "") .. "\n" .. (row.meta:GetText() or "")
      row.open = UI.openKey ~= nil and row.key == UI.openKey and not openAt
      row.name:SetWordWrap(row.open)
      row.meta:SetWordWrap(row.open)
      heights[i] = plain
      if row.open then
        openAt = i
        local tall = (tonumber(row.name:GetStringHeight()) or 0) + (tonumber(row.meta:GetStringHeight()) or 0) + 14
        heights[i] = math.max(plain, math.floor(tall + 0.5))
      end
    else
      row.open = false
    end
  end
  -- An opened row near the bottom pushes rows off the top instead, so it is never cut off.
  local limit = ROWS * ROW_H
  local first = 1
  if openAt then
    local used = 0
    for i = 1, openAt do used = used + (heights[i] or 0) + 2 end
    while first < openAt and used > limit do
      used = used - (heights[first] or 0) - 2
      first = first + 1
    end
  end
  local y = 2
  for i = 1, ROWS do
    local row = UI.rows[i]
    if heights[i] then
      if i < first or (y + heights[i] > limit + 2 and i ~= openAt) then
        row:Hide()
      else
        row:SetHeight(heights[i])
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", UI.scroll, "TOPLEFT", 4, -y)
        y = y + heights[i] + 2
      end
    end
  end
end

-- Asks Wisp a question: the question and its answer join the conversation on the Wisp page.
-- UI.talk = { { q = what was asked, rows = the answer }, ... }, oldest first.
-- Questions Wisp had no answer for, newest last. /ww missed lists them.
function UI.Missed(question)
  if not db or type(question) ~= "string" or question == "" then return end
  if type(db.missed) ~= "table" then db.missed = {} end
  for _, old in ipairs(db.missed) do
    if old == question then return end
  end
  tinsert(db.missed, question)
  while #db.missed > 50 do tremove(db.missed, 1) end
end

-- A box with the question ready to copy and send to the author. An addon cannot send it itself.
function UI.Feedback(question)
  StaticPopupDialogs["WISHWELL_FEEDBACK"] = StaticPopupDialogs["WISHWELL_FEEDBACK"] or {
    text = "Thanks! An addon cannot send this for you. Press Ctrl+C to copy it, then send it to the addon's author so Wisp can learn it.",
    button1 = OKAY or "Okay",
    hasEditBox = true,
    editBoxWidth = 340,
    OnShow = function(self, data)
      local box = self.editBox or self.EditBox
      if not box then return end
      box:SetText(data or "")
      box:SetFocus()
      box:HighlightText()
    end,
    EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
    EditBoxOnEnterPressed = function(self) self:GetParent():Hide() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
  }
  UI.lastFeedback = "Wishwell Forever " .. VERSION .. ": Wisp couldn't answer \"" .. tostring(question) .. "\""
  StaticPopup_Show("WISHWELL_FEEDBACK", nil, nil, UI.lastFeedback)
end

function UI.AskNow(question)
  question = strtrim(question or "")
  if question == "" then return end
  local ok, rows = pcall(UI.Ask.Answer, question)
  if not ok then rows = { { note = true, text = "I tripped over that question, sorry: " .. tostring(rows) } } end
  tinsert(UI.talk, { q = question, rows = rows })
  while #UI.talk > 20 do tremove(UI.talk, 1) end
  if db.sound ~= false and PlaySoundFile then pcall(PlaySoundFile, ART .. "Wisp.ogg", "SFX") end
  UI.talkNew = true
  if db.page ~= "ask" or not frame:IsShown() then
    frame:Show()
    UI.ShowPage("ask")
  else
    Refresh()
  end
end

-- A row in an answer was clicked. An NPC: its Map button drops a pin, and the row itself asks
-- about that NPC. Anything else with a name: ask about it.
function UI.AskRow(item, button)
  if item.npc and button and item.map then
    if MapPin.Show({ item.name, item.map, item.x, item.y }, item.name) and frame then
      frame:Hide()
      MapPin.ReturnAfter("ask")
    end
    return
  end
  UI.search:SetText(item.query or item.name)
end

-- A quest row was clicked: show where the quest starts on the world map.
function UI.ShowQuestOnMap(item)
  local q, F = item.quest, Quests.F
  if MapPin.Show(q[F.ID], q[F.NAME]) and frame then
    frame:Hide()
    MapPin.ReturnAfter()
  end
end

MapPin.onReturn = function(page)
  if frame and not frame:IsShown() then
    frame:Show()
    UI.ShowPage(page or "quests")
  end
end

-- What goes in the left-hand panel on tabs with nothing to try on: an icon, a heading and
-- a few lines that sum the tab up. Returns nil on tabs that show the character instead.
function UI.SideText()
  local page = db.page
  local lines = {}
  local function Line(text) tinsert(lines, text) end
  if page == "talents" then
    local build = Talents.Chosen()
    if not build then
      Line("Pick how you want to play from the list: damage, tank or healing.")
      Line("|cff999999Below: your talents as they are now. Pick a build to see where every point goes.|r")
      return "Interface\\Icons\\Ability_Marksmanship", "Talents", lines
    end
    local progress = Talents.Progress(build)
    if progress then
      local nextStep = progress.steps[1]
      local text = progress.placed .. " of " .. progress.total .. " points placed"
      if progress.free > 0 and nextStep and nextStep.first == 0 then
        text = text .. "\n|cff40ff40" .. progress.free .. " point" .. (progress.free == 1 and "" or "s") .. " to spend now|r"
      elseif nextStep and nextStep.first <= MAX_LEVEL then
        text = text .. "\nNext point at level " .. nextStep.first
      elseif not nextStep then
        text = text .. "\n|cff40ff40Build complete|r"
      end
      Line(text)
      if progress.extra > 0 then
        Line("|cffff9933" .. progress.extra .. " point" .. (progress.extra == 1 and " is" or "s are") .. " outside this build (red below). A talent reset at a class trainer frees them.|r")
      end
    end
    return Talents.ROLE[build.role][2], build.name, lines
  elseif page == "train" then
    if not Train.Scanned() then
      Line("Visit your class trainer once and this fills in.")
      Line("Wishwell reads the trainer's list, then shows every spell you have coming and what each level costs.")
    else
      local totals = UI.trainTotals or {}
      local money = GetMoney and Plain(GetMoney()) or nil
      if totals.ready then
        Line("|cff40ff40Ready to train now|r\n" .. totals.ready.count .. " spell" .. (totals.ready.count == 1 and "" or "s") .. " for " .. Train.Money(totals.ready.total))
        if type(money) == "number" then
          Line("You have " .. Train.Money(money) .. (money >= totals.ready.total and ", enough for all of it."
            or (", " .. Train.Money(totals.ready.total - money) .. " short.")))
        end
      else
        Line("Nothing to train right now.")
        if type(money) == "number" then Line("You have " .. Train.Money(money) .. ".") end
      end
      if totals.next then
        Line("|cffffd100Next at level " .. totals.next.level .. "|r\n" .. totals.next.count .. " spell" .. (totals.next.count == 1 and "" or "s") .. " for " .. Train.Money(totals.next.total))
      end
      if (totals.grand or 0) > 0 then Line("|cffffd100Everything left|r\n" .. Train.Money(totals.grand)) end
    end
    return "Interface\\Icons\\INV_Misc_Book_11", "Spell training", lines
  elseif page == "quests" then
    local t = UI.questTotals or {}
    local level = Quests.MyLevel()
    if (t.doable or 0) > 0 then
      Line("|cff40ff40" .. t.doable .. " quest" .. (t.doable == 1 and "" or "s") .. " you can do now|r\n" .. Quests.Number(t.total or 0) .. " XP in all")
      local xp = UnitXP and Plain(UnitXP("player")) or nil
      local xpMax = UnitXPMax and Plain(UnitXPMax("player")) or nil
      if level < MAX_LEVEL and type(xp) == "number" and type(xpMax) == "number" and xpMax > xp then
        local need = xpMax - xp
        local share = (t.total or 0) / need
        Line("|cffffd100Level " .. (level + 1) .. "|r\n" .. Quests.Number(need) .. " XP to go. " .. (share >= 1
          and (share >= 2 and format("These quests are worth about %.1f levels.", share) or "These quests are enough to get there.")
          or ("These quests cover " .. math.floor(share * 100) .. "% of it.")))
      end
      local best = t.best and (t.best.state == "open" or t.best.state == "log") and t.best or nil
      if best then
        Line("|cffffd100Best one|r\n" .. best.quest[Quests.F.NAME] .. "\n" .. Quests.Number(best.xp) .. " XP")
      end
    else
      Line("Nothing to pick up here right now.")
      Line("Untick \"Only what I can do now\" to see what is coming, or pick another zone.")
    end
    Line("|cff999999Map shows where a quest starts. Closing the map brings you back here.|r")
    return "Interface\\Icons\\INV_Misc_Map_01", t.label or "Quests", lines
  elseif page == "ask" then
    Line("Ask about any item, quest, boss, dungeon, raid or item set in WoW Forever.")
    Line("|cffffd100Tip|r\nNames matter more than grammar. \"hogger\" works as well as a full sentence.")
    Line("|cff999999A look-up, not an AI. It works offline.|r")
    return "Interface\\Icons\\INV_Misc_QuestionMark", "Ask Wisp", lines
  elseif page == "prof" then
    local current
    local function Close()
      if not current then return end
      local p = current.prof
      local text = "|cffffd100" .. p.name .. "|r\nSkill " .. p.rank .. " of " .. p.max
      if p.max > 0 and p.rank >= p.max then
        text = text .. "\n|cffff9933At the cap: visit a trainer|r"
      elseif current.ready > 0 then
        text = text .. "\n|cff40ff40" .. current.ready .. " recipe" .. (current.ready == 1 and "" or "s") .. " you can make for skill|r"
      elseif current.recipes > 0 then
        text = text .. "\n" .. current.recipes .. " recipe" .. (current.recipes == 1 and "" or "s") .. " give skill, materials needed"
      end
      Line(text)
      current = nil
    end
    for _, row in ipairs(UI.shown) do
      if row.profHead then
        Close()
        current = { prof = row.prof, recipes = 0, ready = 0 }
      elseif row.recipe and current then
        current.recipes = current.recipes + 1
        if row.make > 0 then current.ready = current.ready + 1 end
      end
    end
    Close()
    if #lines == 0 then Line("Learn a profession from a trainer in a city, then open its window once.") end
    Line("|cff999999Orange recipes always give a skill point, yellow ones usually do.|r")
    return "Interface\\Icons\\Trade_BlackSmithing", "Professions", lines
  end
  return nil
end

-- Shows the tab's summary in the left-hand panel, or the character on the tabs that use it.
function UI.FillSide()
  local side = UI.side
  if not side then return end
  local icon, title, lines = UI.SideText()
  local on = title ~= nil
  side:SetShown(on)
  if UI.model then UI.model:SetShown(not on) end
  for _, btn in ipairs(UI.stageButtons or {}) do btn:SetShown(not on) end
  if not on then return end
  -- The Talents tab gives the icon's room to the trees.
  local trees = db.page == "talents" and side.tree and side.tree:Fill() or false
  if side.tree then side.tree:SetShown(trees) end
  side.icon:SetShown(not trees)
  side.title:ClearAllPoints()
  if trees then
    side.title:SetPoint("TOP", side, "TOP", 0, -14)
  else
    side.title:SetPoint("TOP", side.icon, "BOTTOM", 0, -12)
  end
  side.icon:SetTexture(icon)
  side.title:SetText(title)
  side.body:SetText(table.concat(lines, "\n\n"))
  side.body:Hide()
  -- Each entry is a card: a small gold heading (the first line, when there are two or more)
  -- over the facts in bigger white text.
  side.cards = side.cards or {}
  local previous
  for i, line in ipairs(lines) do
    local card = side.cards[i]
    if not card then
      card = CreateFrame("Frame", nil, side)
      if Smooth() then
        RoundBox(card, 12)
        card:SetBackdropColor(1, 1, 1, 0.05)
        card:SetBackdropBorderColor(1, 0.82, 0.3, 0.14)
      end
      card.head = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      Bigger(card.head, 1)
      card.head:SetPoint("TOPLEFT", 12, -10)
      card.head:SetWidth(246)
      card.head:SetJustifyH("LEFT")
      card.text = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      Bigger(card.text, 3)
      card.text:SetWidth(246)
      card.text:SetJustifyH("LEFT")
      if card.text.SetSpacing then card.text:SetSpacing(3) end
      side.cards[i] = card
    end
    local head, body = strmatch(line, "^(.-)\n(.*)$")
    if not head then head, body = nil, line end
    card.head:SetText(head or "")
    card.head:SetShown(head ~= nil)
    card.text:SetText(body)
    card.text:ClearAllPoints()
    if head then
      card.text:SetPoint("TOPLEFT", card.head, "BOTTOMLEFT", 0, -5)
    else
      card.text:SetPoint("TOPLEFT", 12, -10)
    end
    local tall = (tonumber(card.text:GetStringHeight()) or 14) + 20
    if head then tall = tall + (tonumber(card.head:GetStringHeight()) or 12) + 5 end
    card:SetSize(270, math.floor(tall + 0.5))
    card:ClearAllPoints()
    if previous then
      card:SetPoint("TOP", previous, "BOTTOM", 0, -8)
    else
      card:SetPoint("TOP", side.title, "BOTTOM", 0, -14)
    end
    card:Show()
    previous = card
  end
  for i = #lines + 1, #side.cards do side.cards[i]:Hide() end
end

function UI.ShowPage(name)
  if name ~= "browse" and name ~= "sets" and name ~= "train" and name ~= "quests" and name ~= "wish" and name ~= "alts" and name ~= "prof" and name ~= "talents" and name ~= "settings" and name ~= "ask" and name ~= "legacy" and name ~= "hub" then name = "home" end
  if CloseDropDownMenus then CloseDropDownMenus() end
  if name == "train" then pcall(Train.Scan) end
  -- Clicking the tab you are already on takes you back to its starting view.
  if db.page == name and frame:IsShown() then
    if UI.search:GetText() ~= "" then UI.search:SetText("") end
    if name == "sets" and UI.openSet then
      UI.OpenSet(nil)
      return
    end
  end
  if db.page ~= name then
    UI.ResetScroll()
    UI.openKey = nil
  end
  db.page = name
  if name ~= "hub" then db.lastPage = name end
  UI.browseBits:SetShown(name == "browse")
  UI.wishBits:SetShown(name == "wish")
  UI.setsBits:SetShown(name == "sets")
  UI.trainBits:SetShown(name == "train")
  UI.questBits:SetShown(name == "quests")
  UI.classDrop:SetShown(name == "browse" or name == "sets")
  UI.rarityDrop:SetShown(name == "browse")
  UI.slotDrop:SetShown(name == "browse")
  UI.zoneDrop:SetShown(name == "browse")
  UI.clearBtn:SetShown(name == "browse")
  UI.bestFirst:SetShown(name == "browse")
  UI.homeBits:SetShown(name == "home")
  UI.altBits:SetShown(name == "alts")
  UI.profBits:SetShown(name == "prof")
  UI.pageTitle:SetShown(name == "legacy" or name == "settings" or name == "talents")
  UI.pageTitle:SetText(name == "legacy" and "Legacy" or (name == "talents" and "Talents" or "Settings"))
  local listOnly = name == "train" or name == "home" or name == "alts" or name == "prof" or name == "legacy" or name == "talents" or name == "settings" or name == "ask" or name == "hub"
  UI.search:SetShown(not listOnly)
  UI.searchLabel:SetShown(not listOnly)
  UI.SubNav(name)
  UI.SettingsPills()
  Refresh()
end

-- Raids sit at the top level of the menu. Dungeons have two submenus, normal and heroic,
-- because the two drop different things.
local function FillPlaceMenu(level, menuList)
  level = level or 1
  local dungeons, heroics = false, false
  for _, row in ipairs(Data.instances) do
    local isDungeon = row.kind == "dungeon"
    local hasHeroic = isDungeon and Places.HasHeroic(row.id)
    if isDungeon then dungeons = true end
    if hasHeroic then heroics = true end
    local heroic = menuList == "heroics"
    if (level == 1 and not isDungeon) or (level == 2 and isDungeon and (menuList == "dungeons" or (heroic and hasHeroic))) then
      local info = UIDropDownMenu_CreateInfo()
      info.text = row.name
      info.checked = db.browseId == row.id and (db.heroic == true) == (heroic and hasHeroic)
      info.func = function()
        if CloseDropDownMenus then CloseDropDownMenus() end
        UI.Browse(row.id, heroic)
        UI.ResetScroll()
        Refresh()
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end
  if level == 1 then
    for _, sub in ipairs({ { dungeons, "Dungeons", "dungeons" }, { heroics, "Heroic dungeons", "heroics" } }) do
      if sub[1] then
        local info = UIDropDownMenu_CreateInfo()
        info.text = sub[2]
        info.hasArrow = true
        info.notCheckable = true
        info.keepShownOnClick = true
        info.menuList = sub[3]
        UIDropDownMenu_AddButton(info, level)
      end
    end
  end
end

local function FillBossMenu()
  local info = UIDropDownMenu_CreateInfo()
  info.text = "All bosses"
  info.checked = UI.boss == "ALL"
  info.func = function()
    UI.boss = "ALL"
    UI.ResetScroll()
    Refresh()
  end
  UIDropDownMenu_AddButton(info)
  for _, boss in ipairs(UI.Bosses()) do
    info = UIDropDownMenu_CreateInfo()
    info.text = boss
    info.checked = UI.boss == boss
    info.func = function()
      UI.boss = boss
      UI.ResetScroll()
      Refresh()
    end
    UIDropDownMenu_AddButton(info)
  end
end

function UI.Build()
  if frame then return end
  local template = BackdropTemplateMixin and "BackdropTemplate" or nil
  local LIST_X = 318 -- left edge of the list, to the right of the character preview

  -- The same frame the Professions and Spellbook windows are built on, so the border, title
  -- bar, round portrait and close button are the game's own and match its other pages.
  -- If this version of the game does not have it, fall back to a plain dark panel.
  -- In the smooth look the window is Wishwell's own: dark, rounded, no heavy frame art.
  local smooth = Smooth()
  local okNative, made = false, nil
  if not smooth then okNative, made = pcall(CreateFrame, "Frame", "WishwellFrame", UIParent, "ButtonFrameTemplate") end
  local native = okNative and type(made) == "table" and type(made.SetTitle) == "function"
  if native then
    frame = made
  else
    frame = CreateFrame("Frame", "WishwellFrame", UIParent, template)
    if not smooth then MakeBackdrop(frame, 16) end
  end
  UI.native = native
  -- In the smooth look the window's box reaches a little above the frame itself, which
  -- gives the header a row of its own for the name and the Ask box. Everything below is
  -- placed from the frame as before; the header's top row is placed from this taller box.
  local HEAD = 30 -- how far the box reaches above the frame
  local header = frame
  if smooth and not native then
    header = CreateFrame("Frame", "WishwellShell", frame)
    header:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, HEAD)
    header:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    -- Behind everything else in the window.
    if header.SetFrameLevel then header:SetFrameLevel(tonumber((frame:GetFrameLevel())) or 1) end
    MakeBackdrop(header, 16)
    -- The extra strip drags the window like the rest of it does.
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() frame:StartMoving() end)
    header:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
  end
  frame:SetSize(790, 556)
  -- The size picked in Settings; a little smaller than the game's own windows to begin with.
  Settings.onSize = function() frame:SetScale(Settings.Size()) end
  Settings.onSize()
  frame:SetPoint("CENTER")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  if frame.SetToplevel then frame:SetToplevel(true) end
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetFrameStrata("HIGH")
  frame:Hide()
  -- Esc closes the window. The old way is to add the frame to UISpecialFrames, but in this
  -- client that taints the Esc menu: the game builds its Log Out and Exit buttons while
  -- walking that list, so they end up "owned" by the addon and the game blocks them.
  -- Instead the window listens for Esc itself and lets every other key through.
  if frame.SetPropagateKeyboardInput then
    frame:EnableKeyboard(true)
    frame:SetPropagateKeyboardInput(true)
    frame:SetScript("OnKeyDown", function(self, key)
      -- Key pass-through cannot be changed in combat; UI.CombatKeys switches keyboard off then.
      if InCombatLockdown and InCombatLockdown() then return end
      if key == "ESCAPE" then
        self:SetPropagateKeyboardInput(false) -- swallow this Esc so the game menu stays shut
        self:Hide()
        After(0, function()
          if not (InCombatLockdown and InCombatLockdown()) then frame:SetPropagateKeyboardInput(true) end
        end)
      else
        self:SetPropagateKeyboardInput(true)
      end
    end)
  end

  if native then
    frame:SetTitle("Wishwell Forever")
    if frame.SetPortraitToAsset then frame:SetPortraitToAsset("Interface\\Icons\\INV_Misc_Note_02") end
    -- The template's one big inset is replaced by two of our own (character and list).
    if type(frame.Inset) == "table" and frame.Inset.Hide then frame.Inset:Hide() end
  else
    -- No title bar: the name, and a thin gold line under the header.
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", header, "TOPLEFT", 66, -18)
    title:SetText("Wishwell Forever")
    local rule = frame:CreateTexture(nil, "BORDER")
    rule:SetPoint("TOPLEFT", 12, -54)
    rule:SetPoint("TOPRIGHT", -12, -54)
    rule:SetHeight(1)
    if rule.SetColorTexture then rule:SetColorTexture(0.80, 0.64, 0.26, 0.35) end

    local PORTRAIT = 44
    local portrait = frame:CreateTexture(nil, "OVERLAY")
    portrait:SetSize(PORTRAIT, PORTRAIT)
    portrait:SetPoint("TOPLEFT", header, "TOPLEFT", -12, 12)
    portrait:SetTexture("Interface\\Icons\\INV_Misc_Note_02")
    portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if frame.CreateMaskTexture then
      pcall(function()
        local mask = frame:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(portrait)
        portrait:AddMaskTexture(mask)
      end)
    end
    local ring = frame:CreateTexture(nil, "OVERLAY", nil, 2)
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetSize(PORTRAIT * 53 / 20, PORTRAIT * 53 / 20)
    ring:SetPoint("TOPLEFT", portrait, "TOPLEFT", -PORTRAIT * 7 / 20, PORTRAIT * 5 / 20)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", header, "TOPRIGHT", -2, -2)
  end

  -- A sunken panel like the ones inside the game's windows.
  local function Panel(parent)
    if not smooth then
      local ok, panel = pcall(CreateFrame, "Frame", nil, parent, "InsetFrameTemplate")
      if ok and type(panel) == "table" then return panel end
    end
    local panel = CreateFrame("Frame", nil, parent, template)
    MakeBackdrop(panel, 12)
    if panel.SetBackdropColor then
      panel:SetBackdropColor(0, 0, 0, 0.38)
      panel:SetBackdropBorderColor(0.40, 0.37, 0.31, 0.7)
    end
    return panel
  end

  frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  frame.status:SetPoint("TOPLEFT", 64, -34)
  frame.status:SetWidth(626)
  frame.status:SetJustifyH("LEFT")
  frame.status:SetWordWrap(false)

  -- The list sits in its own sunken panel.
  local listPanel = Panel(frame)
  listPanel:SetPoint("TOPLEFT", LIST_X - 4, -154)
  listPanel:SetPoint("BOTTOMRIGHT", -8, 30)

  -- Left side: the character, wearing whatever has been clicked.
  local stage = Panel(frame)
  stage:SetPoint("TOPLEFT", 10, -64)
  stage:SetSize(298, 432)
  local okModel, model = pcall(CreateFrame, "DressUpModel", "WishwellModel", stage)
  if okModel and model then
    model:SetPoint("TOPLEFT", 4, -4)
    model:SetPoint("BOTTOMRIGHT", -4, 4)
    UI.model = model
    UI.facing = 0
    -- Drag to turn the character.
    model:EnableMouse(true)
    model:SetScript("OnMouseDown", function(self)
      self.dragFrom = GetCursorPosition()
    end)
    model:SetScript("OnMouseUp", function(self) self.dragFrom = nil end)
    model:SetScript("OnUpdate", function(self)
      if not self.dragFrom then return end
      local x = GetCursorPosition()
      UI.facing = UI.facing + (x - self.dragFrom) * 0.02
      self.dragFrom = x
      if self.SetFacing then self:SetFacing(UI.facing) end
    end)
  else
    local sorry = stage:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sorry:SetPoint("CENTER")
    sorry:SetWidth(240)
    sorry:SetText("The character preview is not available in this version of the game.")
  end

  local function StageButton(text, x, width, onClick)
    local btn = UI.MakeButton(nil, frame)
    btn:SetSize(width, 22)
    btn:SetPoint("TOPLEFT", stage, "BOTTOMLEFT", x, -6)
    btn:SetText(text)
    btn:SetScript("OnClick", onClick)
    return btn
  end
  -- Reset comes first: it is the way back to your own gear after trying things on.
  local reset = StageButton("Reset", 0, 84, UI.ShowMyGear)
  reset:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Reset")
    GameTooltip:AddLine("Takes off everything you tried on and shows the gear you are wearing.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  reset:SetScript("OnLeave", function() GameTooltip:Hide() end)
  local tryAll = StageButton("Try on wishlist", 88, 112, UI.TryOnWishlist)
  local undress = StageButton("Undress", 204, 90, function()
    if UI.model and UI.model.Undress then pcall(UI.model.Undress, UI.model) end
  end)
  UI.stageButtons = { reset, tryAll, undress }

  -- On tabs with nothing to try on (talents, training, quests, professions) the character
  -- makes way for a summary of the tab. See UI.SideText.
  local side = CreateFrame("Frame", "WishwellSide", stage)
  side:SetAllPoints(stage)
  side:Hide()
  side.icon = side:CreateTexture(nil, "ARTWORK")
  side.icon:SetSize(56, 56)
  side.icon:SetPoint("TOP", 0, -24)
  side.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  side.title = side:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  Bigger(side.title, 5)
  side.title:SetPoint("TOP", side.icon, "BOTTOM", 0, -12)
  side.title:SetWidth(266)
  side.body = side:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  side.body:SetPoint("TOP", side.title, "BOTTOM", 0, -16)
  side.body:SetWidth(262)
  side.body:SetJustifyH("LEFT")
  if side.body.SetSpacing then side.body:SetSpacing(3) end
  UI.side = side

  -- Talents tab: the three trees side by side, each talent with points placed / points the
  -- build wants. Green is done, yellow still to fill, red is a point the build does not use.
  -- big: the full-width version on the Talents tab's tree view.
  local function MakeTree(parent, frameName, CELL, STEP, TREE_W, big)
  local TIERS = 9
  local tree = CreateFrame("Frame", frameName, parent)
  tree:SetSize(TREE_W * 3, 34 + TIERS * STEP)
  tree.heads, tree.cells = {}, {}
  for tab = 1, 3 do
    local head = tree:CreateFontString(nil, "OVERLAY", big and "GameFontNormalLarge" or "GameFontNormalSmall")
    head:SetPoint("TOPLEFT", (tab - 1) * TREE_W, big and 4 or 0)
    head:SetWidth(TREE_W - 6)
    head:SetJustifyH("CENTER")
    head:SetWordWrap(false)
    local count = tree:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    count:SetPoint("TOP", head, "BOTTOM", 0, -2)
    tree.heads[tab] = { name = head, count = count }
  end
  function tree:Cell(n)
    local cell = self.cells[n]
    if cell then return cell end
    cell = CreateFrame("Button", nil, self)
    cell:SetSize(CELL, CELL)
    -- A coloured edge behind the icon says where the talent stands.
    cell.edge = cell:CreateTexture(nil, "BACKGROUND")
    cell.edge:SetPoint("TOPLEFT", -2, 2)
    cell.edge:SetPoint("BOTTOMRIGHT", 2, -2)
    cell.icon = cell:CreateTexture(nil, "ARTWORK")
    cell.icon:SetAllPoints()
    cell.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    cell.text = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.text:SetPoint("BOTTOMRIGHT", 3, -3)
    local path = cell.text:GetFont()
    if type(path) == "string" then cell.text:SetFont(path, big and 11 or 9, "OUTLINE") end
    cell:SetScript("OnEnter", function(me)
      local t = me.talent
      if not t then return end
      GameTooltip:SetOwner(me, "ANCHOR_RIGHT")
      if not Talents.FillTip(GameTooltip, t.tab, t.index) then
        GameTooltip:SetText(t.name)
        GameTooltip:AddLine("The game gave no description for this talent.", 0.6, 0.6, 0.6, true)
      end
      if t.max then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Points: " .. t.rank .. " of " .. t.max .. ". It takes " .. t.max .. " at most.", 1, 1, 1, true)
      end
      if me.hasBuild then
        if t.plan == 0 then
          GameTooltip:AddLine(t.rank > 0 and "Not in your build: these points could go elsewhere." or "Not in your build.", 1, 0.33, 0.33, true)
        elseif t.rank >= t.plan then
          GameTooltip:AddLine("Your build: " .. t.plan .. " point" .. (t.plan == 1 and "" or "s") .. " here. Done.", 0.25, 1, 0.25, true)
        else
          GameTooltip:AddLine("Your build: " .. t.plan .. " point" .. (t.plan == 1 and "" or "s") .. " here. You have " .. t.rank .. ".", 1, 0.82, 0, true)
        end
      end
      GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
    self.cells[n] = cell
    return cell
  end
  -- Draws the trees. Returns false if the game will not say what the talents are.
  function tree:Fill()
    local trees, build = Talents.Tree()
    if not trees then return false end
    local progress = build and Talents.Progress(build) or nil
    local upNext = progress and progress.steps[1] or nil
    local pad = math.floor((TREE_W - 4 * STEP + (STEP - CELL)) / 2)
    local function Edge(cell, r, g, b, a)
      if cell.edge.SetColorTexture then cell.edge:SetColorTexture(r, g, b, a) end
    end
    local n = 0
    for tab = 1, 3 do
      local t = trees[tab]
      self.heads[tab].name:SetText(t.name)
      self.heads[tab].count:SetText(build and (t.spent .. " / " .. t.planned) or tostring(t.spent))
      for _, talent in ipairs(t.cells) do
        n = n + 1
        local cell = self:Cell(n)
        cell.talent, cell.hasBuild = talent, build ~= nil
        cell:ClearAllPoints()
        cell:SetPoint("TOPLEFT", (tab - 1) * TREE_W + pad + (talent.column - 1) * STEP, -34 - (talent.tier - 1) * STEP)
        cell.upNext = upNext ~= nil and upNext.tab == talent.tab and upNext.index == talent.index
        cell.icon:SetTexture(talent.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        local unused = talent.rank == 0 and talent.plan == 0
        if cell.icon.SetDesaturated then cell.icon:SetDesaturated(unused) end
        cell.icon:SetAlpha(unused and 0.3 or 1)
        if unused then
          cell.text:SetText("")
          Edge(cell, 0, 0, 0, 0)
        elseif not build then
          cell.text:SetText("|cffffffff" .. talent.rank .. "|r")
          Edge(cell, 1, 1, 1, 0.5)
        elseif talent.plan == 0 then
          cell.text:SetText("|cffff4040" .. talent.rank .. "|r")
          Edge(cell, 1, 0.25, 0.25, 0.9)
        else
          local done = talent.rank >= talent.plan
          cell.text:SetText((done and "|cff40ff40" or "|cffffd100") .. talent.rank .. "/" .. talent.plan .. "|r")
          if done then Edge(cell, 0.25, 1, 0.25, 0.9) else Edge(cell, 1, 0.82, 0, 0.9) end
        end
        -- The talent your next point goes into stands out in white.
        if cell.upNext then Edge(cell, 1, 1, 1, 1) end
        cell:Show()
      end
    end
    for i = n + 1, #self.cells do self.cells[i]:Hide() end
    return true
  end
  return tree
  end
  side.tree = MakeTree(side, "WishwellTree", 21, 23, 97, false)
  side.tree:SetPoint("BOTTOM", side, "BOTTOM", 0, 8)

  -- Talents tab, tree view: the whole window given over to the three trees, with the build
  -- picker above them and the buttons that spend points below. "Order list" swaps to the
  -- list of talents in the order to take them.
  local tp = CreateFrame("Frame", "WishwellTalentPanel", frame)
  tp:SetPoint("TOPLEFT", 10, -58)
  tp:SetPoint("BOTTOMRIGHT", -8, 30)
  tp:Hide()
  local tpBack = Panel(tp)
  tpBack:SetAllPoints(tp)
  tp.drop = CreateFrame("Frame", "WishwellBuildDrop", tp, "UIDropDownMenuTemplate")
  tp.drop:SetPoint("TOPLEFT", -6, -4)
  UIDropDownMenu_SetWidth(tp.drop, 230)
  UIDropDownMenu_Initialize(tp.drop, function()
    local seen = {}
    for _, build in ipairs(Talents.Builds()) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = Talents.ROLE[build.role][1] .. ": " .. build.name .. (seen[build.role] and "" or " (recommended)")
      seen[build.role] = true
      local chosen = Talents.Chosen()
      info.checked = chosen ~= nil and chosen.key == build.key
      info.func = function() Talents.Choose(build.key) end
      UIDropDownMenu_AddButton(info)
    end
    local info = UIDropDownMenu_CreateInfo()
    info.text = "No build: just show my talents"
    info.checked = Talents.Chosen() == nil
    info.func = function() Talents.Choose(nil) end
    UIDropDownMenu_AddButton(info)
  end)
  tp.legend = tp:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  tp.legend:SetPoint("LEFT", tp.drop, "RIGHT", 2, 2)
  tp.legend:SetText("|cff40ff40Green|r done   |cffffd100Gold|r to fill   |cffff4040Red|r not in the build   |cffffffffWhite|r your next point")
  tp.toList = UI.MakeButton("WishwellTalentToList", tp)
  tp.toList:SetSize(96, 22)
  tp.toList:SetPoint("TOPRIGHT", -8, -8)
  tp.toList:SetText("Order list")
  tp.toList:SetScript("OnClick", function()
    db.talentList = true
    UI.ResetScroll()
    Refresh()
  end)
  tp.tree = MakeTree(tp, "WishwellBigTree", 34, 39, 250, true)
  tp.tree:SetPoint("TOP", tp, "TOP", 0, -42)
  tp.next = tp:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  tp.next:SetPoint("BOTTOMLEFT", 12, 14)
  tp.next:SetWidth(430)
  tp.next:SetJustifyH("LEFT")
  tp.next:SetWordWrap(false)
  tp.all = UI.MakeButton("WishwellTalentAll", tp)
  tp.all:SetSize(150, 24)
  tp.all:SetPoint("BOTTOMRIGHT", -10, 8)
  tp.all:SetScript("OnClick", function() UI.AskTalents() end)
  tp.one = UI.MakeButton("WishwellTalentOne", tp)
  tp.one:SetSize(140, 24)
  tp.one:SetPoint("RIGHT", tp.all, "LEFT", -6, 0)
  tp.one:SetText("Spend next point")
  tp.one:SetScript("OnClick", function() UI.AskTalents(1) end)
  function tp:Fill()
    local build = Talents.Chosen()
    UIDropDownMenu_SetText(self.drop, build and (Talents.ROLE[build.role][1] .. ": " .. build.name) or "Pick a build")
    self.tree:SetShown(self.tree:Fill())
    local points = Talents.Ready()
    local busy = Talents.Applying()
    self.one:SetShown(points > 0)
    self.all:SetShown(points > 1)
    self.all:SetText(busy and "Spending..." or ("Spend all " .. points .. " points"))
    if self.one.SetEnabled then
      self.one:SetEnabled(not busy)
      self.all:SetEnabled(not busy)
    end
    local progress = build and Talents.Progress(build) or nil
    if not build then
      self.next:SetText("These are your talents as they are now. Pick a build to see where every point goes.")
    elseif not progress then
      self.next:SetText("Wishwell could not read your talents yet. Close this window and open it again.")
    elseif #progress.steps == 0 then
      self.next:SetText("|cff40ff40Your talents match this build.|r")
    else
      local parts = {}
      for i = 1, math.min(#progress.steps, 3) do
        local step = progress.steps[i]
        local when = step.first == 0 and "|cff40ff40now|r" or (step.first > MAX_LEVEL and "|cffff9933after a reset|r" or ("level " .. step.first))
        tinsert(parts, step.name .. " (" .. when .. ")")
      end
      self.next:SetText("|cffffd100Next:|r " .. table.concat(parts, ", "))
    end
  end
  UI.talentPanel = tp

  -- The Wisp page: a conversation. Your questions sit on the right, Wisp's answers on the
  -- left with the things they are about listed under them, and the box to type in is at
  -- the bottom. With nothing asked yet it shows a greeting and examples to click.
  local chat = CreateFrame("Frame", "WishwellChat", frame)
  chat:SetPoint("TOPLEFT", 10, -58)
  chat:SetPoint("BOTTOMRIGHT", -8, 30)
  chat:Hide()
  local chatBack = Panel(chat)
  chatBack:SetAllPoints(chat)
  local WIDE = 700 -- the conversation's width

  -- The wisp itself: the same little flame as on the pop-ups.
  local function WispIcon(parent, size)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(size, size)
    local body = holder:CreateTexture(nil, "ARTWORK")
    body:SetAllPoints()
    body:SetTexture("Interface\\AddOns\\Wishwell\\WispBody.tga", nil, nil, "NEAREST")
    body:SetTexCoord(0, 0.25, 0, 0.25)
    local face = holder:CreateTexture(nil, "OVERLAY")
    face:SetAllPoints()
    face:SetTexture("Interface\\AddOns\\Wishwell\\WispFace.tga", nil, nil, "NEAREST")
    face:SetTexCoord(0.75, 1, 0, 1) -- the happy face
    holder.body, holder.face = body, face
    return holder
  end

  local head = WispIcon(chat, 30)
  head:SetPoint("TOPLEFT", 14, -8)
  chat.name = chat:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  chat.name:SetPoint("LEFT", head, "RIGHT", 8, 0)
  chat.name:SetText("Wisp")
  chat.sub = chat:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  chat.sub:SetPoint("LEFT", chat.name, "RIGHT", 10, -1)
  chat.sub:SetText("knows the loot, quests and item sets of WoW Forever")
  chat.fresh = UI.MakeButton("WishwellChatNew", chat)
  chat.fresh:SetSize(86, 22)
  chat.fresh:SetPoint("TOPRIGHT", -10, -10)
  chat.check = UI.MakeButton("WishwellChatCheck", chat)
  chat.check:SetSize(86, 22)
  chat.check:SetPoint("TOPRIGHT", -102, -10)
  chat.check:SetText("Check me")
  chat.check:SetScript("OnClick", function() UI.AskNow("check my character") end)
  chat.check:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:SetText("Check me")
    GameTooltip:AddLine("Checks your talents, your stats, your gear and your enchants against your build, and lists your biggest upgrades.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  chat.check:SetScript("OnLeave", function() GameTooltip:Hide() end)
  chat.sub:SetPoint("RIGHT", chat, "RIGHT", -200, 0)
  chat.sub:SetJustifyH("LEFT")
  chat.sub:SetWordWrap(false)
  chat.fresh:SetText("New chat")
  chat.fresh:SetScript("OnClick", function()
    wipe(UI.talk)
    Refresh()
  end)

  -- The box to type in, and Send.
  chat.send = UI.MakeButton("WishwellChatSend", chat)
  chat.send:SetSize(70, 30)
  chat.send:SetPoint("BOTTOMRIGHT", -12, 10)
  chat.send:SetText("Ask")
  local input = CreateFrame("EditBox", "WishwellChatInput", chat)
  input:SetHeight(30)
  input:SetPoint("BOTTOMLEFT", 12, 10)
  input:SetPoint("RIGHT", chat.send, "LEFT", -8, 0)
  if smooth then
    RoundBox(input, 15)
    input:SetBackdropColor(0, 0, 0, 0.5)
    input:SetBackdropBorderColor(0.80, 0.64, 0.26, 0.9)
  end
  input:SetAutoFocus(false)
  if input.SetFontObject then input:SetFontObject("GameFontHighlight") end
  if input.SetTextInsets then input:SetTextInsets(16, 14, 0, 0) end
  if input.SetMaxLetters then input:SetMaxLetters(120) end
  input.hint = input:CreateFontString(nil, "OVERLAY", "GameFontDisable")
  input.hint:SetPoint("LEFT", 16, 0)
  input.hint:SetText("Ask Wisp anything")
  input:SetScript("OnTextChanged", function(self) self.hint:SetShown((self:GetText() or "") == "") end)
  input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  local function Send()
    local question = strtrim(input:GetText() or "")
    input:SetText("")
    input.hint:Show()
    if question ~= "" then UI.AskNow(question) end
  end
  input:SetScript("OnEnterPressed", Send)
  chat.send:SetScript("OnClick", Send)
  chat.input = input

  -- The conversation scrolls.
  local okScroll, scroll = pcall(CreateFrame, "ScrollFrame", "WishwellChatScroll", chat, "UIPanelScrollFrameTemplate")
  if not okScroll or type(scroll) ~= "table" then scroll = CreateFrame("ScrollFrame", "WishwellChatScroll", chat) end
  scroll:SetPoint("TOPLEFT", 14, -46)
  scroll:SetPoint("BOTTOMRIGHT", -32, 50)
  local page = CreateFrame("Frame", nil, scroll)
  page:SetSize(WIDE, 10)
  if scroll.SetScrollChild then scroll:SetScrollChild(page) end
  chat.scroll, chat.page = scroll, page

  -- Before anything is asked: a greeting and examples.
  local hello = CreateFrame("Frame", nil, chat)
  hello:SetPoint("TOPLEFT", 14, -46)
  hello:SetPoint("BOTTOMRIGHT", -14, 50)
  local helloIcon = WispIcon(hello, 64)
  helloIcon:SetPoint("TOP", 0, -34)
  hello.title = hello:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  Bigger(hello.title, 8)
  hello.title:SetPoint("TOP", helloIcon, "BOTTOM", 0, -12)
  hello.title:SetText("What do you want to know?")
  hello.chips = {}
  for i, example in ipairs(UI.Ask.EXAMPLES) do
    local chip = UI.MakeButton(nil, hello)
    chip:SetSize(330, 30)
    local column, line = (i - 1) % 2, math.floor((i - 1) / 2)
    chip:SetPoint("TOP", hello.title, "BOTTOM", column == 0 and -170 or 170, -24 - line * 38)
    chip:SetText(example[2])
    chip.chat = { kind = "s", text = example[1], meta = example[2], button = "Ask" }
    chip:SetScript("OnClick", function() UI.AskNow(example[2]) end)
    chip:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:SetText(example[1])
      GameTooltip:Show()
    end)
    chip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    hello.chips[i] = chip
  end
  chat.hello = hello

  -- What one thing in an answer shows as: icon, name, the small print, and its button.
  local function Words(row)
    if row.npc then
      local meta = {}
      if row.title then tinsert(meta, row.title) end
      if row.where then tinsert(meta, row.where) end
      for _, role in ipairs(row.roles or {}) do
        if role ~= row.title then tinsert(meta, role) end
      end
      local level = (row.max or 0) > 0 and ("  |cffffffffLevel " .. ((row.min and row.min ~= row.max and row.min > 0) and (row.min .. "-" .. row.max) or row.max) .. "|r") or ""
      return row.rank and row.rank > 0 and "Interface\\Icons\\Ability_Creature_Cursed_02" or "Interface\\Icons\\INV_Misc_Head_Human_01",
        row.name .. level, table.concat(meta, " · "), row.map and "Map" or nil
    elseif row.advice then
      return row.icon, row.title, row.text, "Go"
    elseif row.feedback then
      return row.icon, row.name, row.text, "Send"
    elseif row.ask then
      return row.icon, row.name, row.text, "Ask"
    elseif row.bonus then
      return "Interface\\Icons\\INV_Chest_Plate04", row.name, Sets.Size(row) .. " pieces", "Open"
    end
    local r, g, b = Items.QualityColor(Items.Quality(row))
    local name = format("|cff%02x%02x%02x%s|r", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5),
      row.name or Items.Name(row.id) or ("Item " .. row.id))
    return Items.Icon(row.id), name, Items.Meta(row, false), Wish.Has(row.id) and "Wished" or "Wish"
  end

  -- Pools: frames are kept and reused from one drawing to the next.
  chat.bubbles, chat.replies, chat.lines = {}, {}, {}
  local function Bubble(n)
    local bubble = chat.bubbles[n]
    if bubble then return bubble end
    bubble = CreateFrame("Frame", nil, page)
    if smooth then
      RoundBox(bubble, 14)
      bubble:SetBackdropColor(0.80, 0.64, 0.26, 0.20)
      bubble:SetBackdropBorderColor(0.80, 0.64, 0.26, 0.55)
    end
    bubble.text = bubble:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    Bigger(bubble.text, 2)
    bubble.text:SetPoint("TOPLEFT", 14, -9)
    bubble.text:SetJustifyH("LEFT")
    chat.bubbles[n] = bubble
    return bubble
  end
  local function Reply(n)
    local reply = chat.replies[n]
    if reply then return reply end
    reply = CreateFrame("Frame", nil, page)
    reply.icon = WispIcon(reply, 26)
    reply.icon:SetPoint("TOPLEFT", 0, 0)
    reply.text = reply:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    Bigger(reply.text, 2)
    reply.text:SetPoint("TOPLEFT", 36, -4)
    reply.text:SetWidth(WIDE - 80)
    reply.text:SetJustifyH("LEFT")
    reply.text:SetTextColor(0.86, 0.84, 0.78) -- off-white: easier on the eyes than pure white, and the colours stand out against it
    if reply.text.SetSpacing then reply.text:SetSpacing(5) end
    chat.replies[n] = reply
    return reply
  end
  local function Line(n)
    local line = chat.lines[n]
    if line then return line end
    line = CreateFrame("Button", nil, page)
    line:SetSize(WIDE - 80, 30)
    if smooth then
      RoundBox(line, 11)
      line:SetBackdropColor(1, 1, 1, 0.045)
      line:SetBackdropBorderColor(1, 1, 1, 0.07)
    end
    if line.SetHighlightTexture then pcall(line.SetHighlightTexture, line, "Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD") end
    line.icon = line:CreateTexture(nil, "ARTWORK")
    line.icon:SetSize(22, 22)
    line.icon:SetPoint("LEFT", 6, 0)
    line.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    line.name = line:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    line.name:SetPoint("LEFT", line.icon, "RIGHT", 8, 0)
    line.name:SetJustifyH("LEFT")
    line.name:SetWordWrap(false)
    line.meta = line:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    line.meta:SetPoint("LEFT", line.name, "RIGHT", 10, 0)
    line.meta:SetPoint("RIGHT", -76, 0)
    line.meta:SetJustifyH("LEFT")
    line.meta:SetWordWrap(false)
    line.go = UI.MakeButton(nil, line)
    line.go:SetSize(62, 20)
    line.go:SetPoint("RIGHT", -6, 0)
    -- Clicking the line asks about the thing; its button does the thing itself.
    line:SetScript("OnClick", function(self)
      local row = self.row
      if not row then return end
      if row.advice then
        row.go()
        return
      end
      if row.feedback then
        UI.Feedback(row.query)
        return
      end
      if row.bonus then
        UI.ShowPage("sets")
        UI.OpenSet(row)
      elseif row.id and not row.npc and IsShiftKeyDown and IsShiftKeyDown() and UI.LinkToChat(row.id) then
        return
      else
        UI.AskNow(row.query or row.name or Items.Name(row.id))
      end
    end)
    line.go:SetScript("OnClick", function()
      local row = line.row
      if not row then return end
      if row.advice then
        row.go()
        return
      end
      if row.feedback then
        UI.Feedback(row.query)
        return
      end
      if row.npc then
        if row.map and MapPin.Show({ row.name, row.map, row.x, row.y }, row.name) then
          frame:Hide()
          MapPin.ReturnAfter("ask")
        end
      elseif row.ask then
        UI.AskNow(row.query or row.name)
      elseif row.bonus then
        UI.ShowPage("sets")
        UI.OpenSet(row)
      else
        Wish.Toggle(row)
        Refresh()
      end
    end)
    line:SetScript("OnEnter", function(self)
      local row = self.row
      if not row or row.npc or row.ask or row.bonus or not row.id then return end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. row.id)
      GameTooltip:Show()
    end)
    line:SetScript("OnLeave", function() GameTooltip:Hide() end)
    chat.lines[n] = line
    return line
  end

  local SHOWN = 8 -- things listed under one answer before "and N more"

  -- Draws the whole conversation. chat.order lists what is on screen, top to bottom.
  function chat:Render()
    local order = {}
    self.order = order
    local talking = #UI.talk > 0
    hello:SetShown(not talking)
    scroll:SetShown(talking)
    self.fresh:SetShown(talking)
    if not talking then
      for _, chip in ipairs(hello.chips) do tinsert(order, chip.chat) end
      return
    end
    local bubbles, replies, lines = 0, 0, 0
    local y = 6
    for _, turn in ipairs(UI.talk) do
      -- What you asked, on the right.
      bubbles = bubbles + 1
      local bubble = Bubble(bubbles)
      bubble.text:SetWidth(0)
      bubble.text:SetText(turn.q)
      local wide = math.min((tonumber(bubble.text:GetStringWidth()) or 100) + 4, 420)
      bubble.text:SetWidth(wide)
      bubble:SetSize(wide + 28, (tonumber(bubble.text:GetStringHeight()) or 14) + 18)
      bubble:ClearAllPoints()
      bubble:SetPoint("TOPRIGHT", page, "TOPRIGHT", -8, -y)
      bubble:Show()
      tinsert(order, { kind = "q", text = turn.q })
      y = y + bubble:GetHeight() + 10

      -- What Wisp says: the answer, then the things it is about.
      local said, things = {}, {}
      for _, row in ipairs(turn.rows) do
        if row.note then tinsert(said, row.text) else tinsert(things, row) end
      end
      -- A second note is the "also called something like that" heading: it goes last.
      local also = #said > 1 and tremove(said) or nil
      replies = replies + 1
      local reply = Reply(replies)
      reply.text:SetText(table.concat(said, "\n\n"))
      local tall = math.max(26, (tonumber(reply.text:GetStringHeight()) or 14) + 8)
      reply:SetSize(WIDE - 40, tall)
      reply:ClearAllPoints()
      reply:SetPoint("TOPLEFT", page, "TOPLEFT", 4, -y)
      reply:Show()
      tinsert(order, { kind = "a", text = table.concat(said, " ") })
      y = y + tall + 6
      for i = 1, math.min(#things, SHOWN) do
        lines = lines + 1
        local line = Line(lines)
        local row = things[i]
        local icon, name, meta, button = Words(row)
        line.row = row
        line.icon:SetTexture(icon)
        line.name:SetText(name)
        line.meta:SetText(meta or "")
        line.go:SetShown(button ~= nil)
        if button then line.go:SetText(button) end
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", page, "TOPLEFT", 40, -y)
        line:Show()
        tinsert(order, { kind = "r", text = name, meta = meta or "", button = button })
        y = y + 34
      end
      if #things > SHOWN then
        replies = replies + 1
        local more = Reply(replies)
        more.icon:Hide()
        more.text:SetText("|cff999999and " .. (#things - SHOWN) .. " more. Ask about one by name to see it.|r")
        more:SetSize(WIDE - 40, 20)
        more:ClearAllPoints()
        more:SetPoint("TOPLEFT", page, "TOPLEFT", 4, -y)
        more:Show()
        y = y + 24
      else
        reply.icon:Show()
      end
      y = y + 12
    end
    for i = bubbles + 1, #self.bubbles do self.bubbles[i]:Hide() end
    for i = replies + 1, #self.replies do self.replies[i]:Hide() end
    for i = lines + 1, #self.lines do self.lines[i]:Hide() end
    page:SetHeight(y + 6)
    -- A new answer scrolls into view.
    if UI.talkNew then
      UI.talkNew = false
      After(0.05, function()
        if scroll.GetVerticalScrollRange and scroll.SetVerticalScroll then
          scroll:SetVerticalScroll(tonumber(scroll:GetVerticalScrollRange()) or 0)
        end
      end)
    end
  end
  UI.chat = chat

  -- The welcome page: the wisp, a greeting, and a tile for each part of Wishwell with a line
  -- about what is waiting there. It is what the window opens on unless Settings says not to.
  local hub = CreateFrame("Frame", "WishwellHub", frame)
  hub:SetPoint("TOPLEFT", 10, -58)
  hub:SetPoint("BOTTOMRIGHT", -8, 30)
  hub:Hide()
  local hubBack = Panel(hub)
  hubBack:SetAllPoints(hub)

  -- The wisp, alive: its flame flickers, it bobs, and it blinks now and then.
  local LINGER = 8 -- seconds a line from the wisp stays up, so it can be read
  hub.wisp = WispIcon(hub, 88)
  hub.wisp:SetPoint("TOP", 0, -12)
  hub.wisp.clock = 0
  hub.wisp:SetScript("OnUpdate", function(self, elapsed)
    self.clock = self.clock + (tonumber(elapsed) or 0)
    local t = self.clock
    local step = math.floor(t * 5) % 16
    local column, line = step % 4, math.floor(step / 4)
    self.body:SetTexCoord(column / 4, (column + 1) / 4, line / 4, (line + 1) / 4)
    local blink = t % 4
    local look = blink > 3.8 and 2 or (blink > 3.7 and 1 or 3)
    self.face:SetTexCoord(look / 4, (look + 1) / 4, 0, 1)
    self:ClearAllPoints()
    self:SetPoint("TOP", hub, "TOP", 0, -12 + math.sin(t * 2.2) * 5)
    -- Time for the wisp to say something new.
    if hub.said and (GetTime and GetTime() or 0) - hub.said >= LINGER then hub:Fill() end
  end)
  hub.hello = hub:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  Bigger(hub.hello, 12)
  hub.hello:SetPoint("TOP", hub, "TOP", 0, -112)
  hub.sub = hub:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  Bigger(hub.sub, 1)
  hub.sub:SetPoint("TOP", hub.hello, "BOTTOM", 0, -8)
  hub.sub:SetTextColor(0.72, 0.70, 0.66)
  hub.say = hub:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  Bigger(hub.say, 2)
  hub.say:SetPoint("TOP", hub.sub, "BOTTOM", 0, -14)
  hub.say:SetTextColor(0.86, 0.84, 0.78)
  hub.foot = hub:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hub.foot:SetPoint("BOTTOM", 0, 12)
  hub.foot:SetText("Click the name at the top of the window to come back here. Settings can switch this page off.")

  local SAYS = {
    "What are we hunting today?",
    "I've been keeping your lists warm.",
    "Pick a tile, or just ask me. I know things.",
    "Loot won't find itself. Well, it won't find you.",
    "Somewhere out there is a boss holding your next upgrade.",
    "Ready when you are. I'm always ready. I don't have legs.",
  }
  -- Each tile: the tab it opens, its name, its picture, and a line about what is waiting.
  local function Level()
    return Quests.MyLevel()
  end
  local TILES = {
    { id = "ask", name = "Wisp", icon = "Interface\\AddOns\\Wishwell\\WispIcon.tga", whole = true, tease = function(n)
      return ({ "Ask me where anything drops.", "\"Check my stats.\" Go on, ask.", "Stuck on a quest? Ask me." })[n % 3 + 1]
    end },
    { id = "home", name = "Next", icon = "Interface\\Icons\\Ability_Hunter_Pathfinding", tease = function()
      local first = Home.Rows()[1]
      return first and first.title or "See what is most worth doing now."
    end },
    { id = "gear", name = "Gear", icon = "Interface\\Icons\\INV_Chest_Plate04", tease = function()
      local wishes = Wish.Count()
      local text = wishes > 0 and (wishes .. " on your wishlist") or "Browse loot and start a wishlist."
      local dungeon = Home.Dungeons(Level(), false)[1]
      if dungeon and dungeon.upgrades > 0 then
        text = text .. "\n|cff40ff40" .. dungeon.upgrades .. " upgrade" .. (dungeon.upgrades == 1 and "" or "s") .. "|r in " .. dungeon.row.name
      end
      return text
    end },
    { id = "quests", name = "Quests", icon = "Interface\\Icons\\INV_Misc_Map_01", tease = function()
      local zoneId, zoneName = Quests.ZoneHere()
      if zoneId then
        local _, total, doable = Quests.List(zoneId, true, "")
        if doable > 0 then
          return "|cff40ff40" .. doable .. " quest" .. (doable == 1 and "" or "s") .. "|r to do in " .. zoneName .. "\n" .. Quests.Number(total) .. " XP"
        end
      end
      return "Nothing to pick up here. See where the XP is."
    end },
    { id = "me", name = "Me", icon = "Interface\\Icons\\INV_Misc_GroupLooking", tease = function()
      local points = Talents.Ready()
      if points > 0 then return "|cff40ff40" .. points .. " talent point" .. (points == 1 and "" or "s") .. "|r to spend" end
      if Train.Scanned() then
        local _, _, ready = Train.Rows()
        if ready then return "|cff40ff40" .. ready.count .. " spell" .. (ready.count == 1 and "" or "s") .. "|r to train" end
      end
      return "Training, professions and your characters."
    end },
  }
  hub.tiles = {}
  for i, def in ipairs(TILES) do
    local tile = CreateFrame("Button", "WishwellHubTile" .. i, hub)
    tile:SetSize(140, 172)
    tile:SetPoint("BOTTOMLEFT", 20 + (i - 1) * 148, 38)
    local function Rest()
      if not tile.SetBackdropColor then return end
      tile:SetBackdropColor(1, 1, 1, 0.05)
      tile:SetBackdropBorderColor(0.80, 0.64, 0.26, 0.45)
    end
    if smooth then
      RoundBox(tile, 16)
      Rest()
    end
    tile.icon = tile:CreateTexture(nil, "ARTWORK")
    tile.icon:SetSize(def.whole and 54 or 46, def.whole and 54 or 46)
    tile.icon:SetPoint("TOP", 0, def.whole and -10 or -16)
    if def.whole then
      tile.icon:SetTexture(def.icon, nil, nil, "NEAREST")
    else
      tile.icon:SetTexture(def.icon)
      tile.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    tile.name = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    Bigger(tile.name, 2)
    tile.name:SetPoint("TOP", 0, -72)
    tile.name:SetText(def.name)
    tile.tease = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    tile.tease:SetPoint("TOP", tile.name, "BOTTOM", 0, -8)
    tile.tease:SetWidth(124)
    tile.tease:SetTextColor(0.80, 0.78, 0.72)
    if tile.tease.SetSpacing then tile.tease:SetSpacing(3) end
    tile:SetScript("OnEnter", function(self)
      if self.SetBackdropColor and smooth then
        self:SetBackdropColor(1, 0.82, 0.3, 0.12)
        self:SetBackdropBorderColor(1, 0.82, 0.3, 1)
      end
    end)
    tile:SetScript("OnLeave", Rest)
    tile:SetScript("OnClick", function() UI.OpenTab(def.id) end)
    tile.def = def
    hub.tiles[i] = tile
  end
  hub.turn = 0
  hub:SetScript("OnShow", function(self) self.arriving = true end)

  -- Fills in the greeting and each tile's line.
  function hub:Fill()
    -- The window redraws often (every time the game loads an item, for one). The wisp's
    -- lines only move on when the page opens, and then every so often.
    local now = GetTime and GetTime() or 0
    if self.arriving or not self.said or now - self.said >= LINGER then
      self.turn = self.turn + 1
      self.said = now
    end
    local me = UnitName and Plain((UnitName("player"))) or nil
    if type(me) ~= "string" or me == "" then me = "adventurer" end
    self.hello:SetText((db.hubSeen and "Welcome back, " or "Welcome to Wishwell, ") .. me .. "!")
    db.hubSeen = true
    local class = Plain((UnitClass("player")))
    local zone = GetRealZoneText and Plain(GetRealZoneText()) or nil
    self.sub:SetText("Level " .. Level() .. (type(class) == "string" and (" " .. class) or "")
      .. (type(zone) == "string" and zone ~= "" and ("  ·  " .. zone) or ""))
    self.say:SetText("\"" .. SAYS[self.turn % #SAYS + 1] .. "\"")
    for _, tile in ipairs(self.tiles) do
      local ok, text = pcall(tile.def.tease, self.turn)
      tile.tease:SetText(ok and type(text) == "string" and text or "")
    end
    frame.status:SetText("Pick a tile, or type a question at the top.")
    -- The tiles drift in one after another when the page opens.
    if self.arriving then
      self.arriving = false
      if UIFrameFadeIn then
        for i, tile in ipairs(self.tiles) do
          tile:SetAlpha(0)
          After(0.07 * i, function()
            if not pcall(UIFrameFadeIn, tile, 0.35, 0, 1) then tile:SetAlpha(1) end
          end)
        end
      end
    end
  end
  UI.hub = hub
  UI.stage, UI.listPanel = stage, listPanel

  -- In the list view, the way back to the trees.
  UI.talentToTree = UI.MakeButton("WishwellTalentToTree", frame)
  UI.talentToTree:SetSize(96, 24)
  UI.talentToTree:SetPoint("TOPLEFT", LIST_X + 182, -100)
  UI.talentToTree:SetText("Tree view")
  UI.talentToTree:SetScript("OnClick", function()
    db.talentList = nil
    Refresh()
  end)
  UI.talentToTree:Hide()

  -- Right side: the list, with different controls above it on each tab.
  UI.browseBits = CreateFrame("Frame", nil, frame)
  UI.browseBits:SetAllPoints(frame)
  UI.wishBits = CreateFrame("Frame", nil, frame)
  UI.wishBits:SetAllPoints(frame)
  UI.setsBits = CreateFrame("Frame", nil, frame)
  UI.setsBits:SetAllPoints(frame)
  -- Legacy, Talents and Settings share one plain heading.
  UI.pageTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  Bigger(UI.pageTitle, 6)
  UI.pageTitle:SetPoint("TOPLEFT", LIST_X + 4, -62)
  UI.pageTitle:Hide()

  -- Settings: a button for each section, so the switches fit on one screen without scrolling.
  UI.settingsPills = {}
  do
    local x = 0
    for _, group in ipairs(Settings.GROUPS) do
      local id, label = group[1], group[2]
      local pill = UI.MakeButton("WishwellSettings_" .. id, frame)
      pill:SetSize(84, 22)
      pill:SetPoint("TOPLEFT", LIST_X + 4 + x, -104)
      pill:SetText(label)
      pill:SetScript("OnClick", function()
        UI.settingsTab = id
        UI.ResetScroll()
        UI.SettingsPills()
        Refresh()
      end)
      pill:Hide()
      UI.settingsPills[id] = pill
      x = x + 88
    end
  end
  -- Shows the buttons on the Settings page only, with the open section lit.
  function UI.SettingsPills()
    local open = UI.settingsTab or "window"
    for id, pill in pairs(UI.settingsPills) do
      pill:SetShown(db.page == "settings")
      if pill.SetBackdropColor and smooth then
        if id == open then
          pill:SetBackdropColor(0.50, 0.38, 0.10, 0.95)
          pill:SetBackdropBorderColor(1, 0.82, 0.3, 1)
        else
          pill:SetBackdropColor(0.12, 0.11, 0.10, 0.9)
          pill:SetBackdropBorderColor(0.45, 0.41, 0.34, 0.8)
        end
      end
    end
  end

  -- Talents: one button that spends the points you have free, in the build's order.
  UI.talentApply = UI.MakeButton("WishwellTalentApply", frame)
  UI.talentApply:SetSize(170, 24)
  UI.talentApply:SetPoint("TOPLEFT", LIST_X + 4, -100)
  UI.talentApply:SetScript("OnClick", function() UI.AskTalents() end)
  UI.talentApply:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Spend my points")
    GameTooltip:AddLine("Puts the talent points you have free into this build, in the order listed. Wishwell asks first, and never spends a point the build does not call for.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  UI.talentApply:SetScript("OnLeave", function() GameTooltip:Hide() end)
  UI.talentApply:Hide()

  -- Ask sits beside Settings in the corner.
  local askBtn = UI.MakeButton("WishwellAskButton", frame)
  askBtn:SetSize(60, 20)
  askBtn:SetPoint("TOPRIGHT", -88, -30)
  askBtn:SetText("Ask")
  askBtn:SetScript("OnClick", function()
    UI.ShowPage("ask")
    if UI.search.SetFocus then UI.search:SetFocus() end
  end)

  -- In the smooth look the header carries an Ask box instead: type a question from any tab
  -- and press Enter.
  if smooth then
    local home = CreateFrame("Button", "WishwellHomeButton", frame)
    home:SetPoint("TOPLEFT", header, "TOPLEFT", -12, 12)
    home:SetSize(214, 58)
    home:SetScript("OnClick", function() UI.ShowPage("hub") end)
    home:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
      GameTooltip:SetText("Welcome page")
      GameTooltip:Show()
    end)
    home:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- It sits on the part of the header people drag the window by, so it drags too.
    home:RegisterForDrag("LeftButton")
    home:SetScript("OnDragStart", function() frame:StartMoving() end)
    home:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    askBtn:Hide()
    local bar = CreateFrame("EditBox", "WishwellAskBar", frame)
    bar:SetSize(440, 32)
    bar:SetPoint("TOPLEFT", header, "TOPLEFT", 214, -11)
    RoundBox(bar, 16)
    bar:SetBackdropColor(0, 0, 0, 0.5)
    bar:SetBackdropBorderColor(0.80, 0.64, 0.26, 0.9)
    bar:SetAutoFocus(false)
    if bar.SetFontObject then bar:SetFontObject("GameFontHighlight") end
    if bar.SetTextInsets then bar:SetTextInsets(36, 14, 0, 0) end
    if bar.SetMaxLetters then bar:SetMaxLetters(90) end
    bar.icon = bar:CreateTexture(nil, "OVERLAY")
    bar.icon:SetSize(16, 16)
    bar.icon:SetPoint("LEFT", 13, -1)
    bar.icon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
    bar.hint = bar:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    Bigger(bar.hint, 1)
    bar.hint:SetPoint("LEFT", 36, 0)
    bar.hint:SetText("Ask Wisp anything: where is Hogger?")
    bar:SetScript("OnTextChanged", function(self)
      self.hint:SetShown((self:GetText() or "") == "")
    end)
    bar:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(1, 0.82, 0.3, 1) end)
    bar:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(0.80, 0.64, 0.26, 0.9) end)
    bar:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    bar:SetScript("OnEnterPressed", function(self)
      local question = strtrim(self:GetText() or "")
      self:SetText("")
      self.hint:Show()
      self:ClearFocus()
      if question ~= "" then
        UI.AskNow(question)
      else
        UI.ShowPage("ask")
      end
    end)
    UI.askBar = bar
  end

  -- Settings are reached from a button in the corner, not a tab: the tab column is full.
  local gear = UI.MakeButton(nil, frame)
  gear:SetSize(74, 20)
  gear:SetPoint("TOPRIGHT", -10, -30)
  gear:SetText("Settings")
  gear:SetScript("OnClick", function() UI.ShowPage("settings") end)

  -- Professions tab.
  UI.profBits = CreateFrame("Frame", nil, frame)
  UI.profBits:SetAllPoints(frame)
  local profTitle = UI.profBits:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  Bigger(profTitle, 6)
  profTitle:SetPoint("TOPLEFT", LIST_X + 4, -62)
  profTitle:SetText("Professions")
  local profNote = UI.profBits:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  profNote:SetPoint("TOPLEFT", LIST_X + 4, -96)
  profNote:SetWidth(430)
  profNote:SetJustifyH("LEFT")
  profNote:SetText("Recipes that will raise your skill, and whether you have the materials. Open a profession window to refresh its list.")

  -- Characters tab.
  UI.altBits = CreateFrame("Frame", nil, frame)
  UI.altBits:SetAllPoints(frame)
  local altTitle = UI.altBits:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  Bigger(altTitle, 6)
  altTitle:SetPoint("TOPLEFT", LIST_X + 4, -62)
  altTitle:SetText("Characters")
  local altNote = UI.altBits:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  altNote:SetPoint("TOPLEFT", LIST_X + 4, -96)
  altNote:SetWidth(430)
  altNote:SetJustifyH("LEFT")
  altNote:SetText("Each of your characters at a glance. One appears here after it has logged in once.")

  -- What next? tab: just a heading; the list does the talking.
  UI.homeBits = CreateFrame("Frame", nil, frame)
  UI.homeBits:SetAllPoints(frame)
  local homeTitle = UI.homeBits:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  Bigger(homeTitle, 6)
  homeTitle:SetPoint("TOPLEFT", LIST_X + 4, -62)
  homeTitle:SetText("What next?")
  local homeNote = UI.homeBits:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  homeNote:SetPoint("TOPLEFT", LIST_X + 4, -96)
  homeNote:SetWidth(430)
  homeNote:SetJustifyH("LEFT")
  homeNote:SetText("The best quest, zone, dungeon and spells for your character right now.")

  -- Quests tab: a zone menu (where I am, everywhere, or one zone) and one tick box.
  UI.questBits = CreateFrame("Frame", nil, frame)
  UI.questBits:SetAllPoints(frame)
  UI.questZoneDrop = CreateFrame("Frame", "WishwellQuestZoneDrop", UI.questBits, "UIDropDownMenuTemplate")
  UI.questZoneDrop:SetPoint("TOPLEFT", LIST_X - 16, -54)
  UIDropDownMenu_SetWidth(UI.questZoneDrop, 200)
  UIDropDownMenu_Initialize(UI.questZoneDrop, function(_, level, menuList)
    level = level or 1
    local function Pick(text, value, checked)
      local info = UIDropDownMenu_CreateInfo()
      info.text = text
      info.checked = checked
      info.func = function()
        if CloseDropDownMenus then CloseDropDownMenus() end
        db.questZone = value
        UI.ResetScroll()
        Refresh()
      end
      UIDropDownMenu_AddButton(info, level)
    end
    if level == 1 then
      Pick("Where I am", "HERE", db.questZone == "HERE")
      Pick("Everywhere", "ALL", db.questZone == "ALL")
      for _, group in ipairs({ "Eastern Kingdoms", "Kalimdor", "Dungeons and raids", "Other" }) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = group
        info.hasArrow = true
        info.notCheckable = true
        info.keepShownOnClick = true
        info.menuList = group
        UIDropDownMenu_AddButton(info, level)
      end
    else
      local zones = {}
      for id, zone in pairs(Data.questZones or {}) do
        if zone[2] == menuList then tinsert(zones, { id, zone[1] }) end
      end
      table.sort(zones, function(a, b) return a[2] < b[2] end)
      for _, zone in ipairs(zones) do Pick(zone[2], zone[1], db.questZone == zone[1]) end
    end
  end)
  UI.questNow = CreateFrame("CheckButton", "WishwellQuestNow", UI.questBits, "UICheckButtonTemplate")
  UI.questNow:SetSize(24, 24)
  UI.questNow:SetPoint("TOPLEFT", LIST_X + 4, -86)
  UI.questNow.label = UI.questNow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  UI.questNow.label:SetPoint("LEFT", UI.questNow, "RIGHT", 2, 1)
  UI.questNow.label:SetText("Only what I can do now")
  -- The quest guide: a small window that stays up while you play.
  local guideBtn = UI.MakeButton("WishwellGuideButton", UI.questBits)
  guideBtn:SetSize(100, 22)
  guideBtn:SetPoint("TOPLEFT", LIST_X + 330, -58)
  guideBtn:SetText("Guide me")
  guideBtn:SetScript("OnClick", function()
    UI.Guide.Show(true)
    frame:Hide()
  end)
  guideBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Guide me")
    GameTooltip:AddLine("Opens a small window that walks you through your quests: the nearest thing to kill, collect, hand in or pick up, then the next. It stays up while you play. /ww guide opens and closes it.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  guideBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Without that, there is nothing for it to point at.
  if type(Data.questStarts) ~= "table" then guideBtn:Hide() end
  UI.questNow:SetChecked(db.questNow ~= false)
  UI.questNow:SetScript("OnClick", function(self)
    db.questNow = self:GetChecked() and true or false
    UI.ResetScroll()
    Refresh()
  end)
  local questNote = UI.questBits:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  questNote:SetPoint("LEFT", UI.questNow.label, "RIGHT", 12, 0)
  questNote:SetText("Best XP for your level first.")

  UI.trainBits = CreateFrame("Frame", nil, frame)
  UI.trainBits:SetAllPoints(frame)
  -- Page headings are big and white with gold text under them, like the Guild page.
  local trainTitle = UI.trainBits:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  Bigger(trainTitle, 6)
  trainTitle:SetPoint("TOPLEFT", LIST_X + 4, -62)
  trainTitle:SetText("Spells to train")
  local trainNote = UI.trainBits:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  trainNote:SetPoint("TOPLEFT", LIST_X + 4, -96)
  trainNote:SetWidth(430)
  trainNote:SetJustifyH("LEFT")
  trainNote:SetText("Prices are what your trainer charges you. Visit the trainer again to refresh them.")

  -- Sets tab header: the open set's name (hover for bonuses) and a way back to the list.
  local setHead = CreateFrame("Button", nil, UI.setsBits)
  setHead:SetPoint("TOPLEFT", LIST_X + 4, -58)
  setHead:SetSize(330, 22)
  UI.setTitle = setHead:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  Bigger(UI.setTitle, 4)
  UI.setTitle:SetPoint("LEFT")
  UI.setTitle:SetText("Item sets")
  setHead:SetScript("OnEnter", function(self)
    if UI.openSet then UI.SetTooltip(self, UI.openSet) end
  end)
  setHead:SetScript("OnLeave", function() GameTooltip:Hide() end)
  -- Back sits on its own row, right above the list, where the eye goes after opening a set.
  UI.setBack = UI.MakeButton(nil, UI.setsBits)
  UI.setBack:SetSize(130, 22)
  UI.setBack:SetPoint("TOPLEFT", LIST_X + 4, -86)
  UI.setBack:SetText("< Back to all sets")
  UI.setBack:SetScript("OnClick", function() UI.OpenSet(nil) end)
  UI.setWishAll = UI.MakeButton(nil, UI.setsBits)
  UI.setWishAll:SetSize(90, 22)
  UI.setWishAll:SetPoint("LEFT", UI.setBack, "RIGHT", 6, 0)
  UI.setWishAll:SetText("Wish all")
  UI.setWishAll:SetScript("OnClick", UI.WishWholeSet)

  UI.placeDrop = CreateFrame("Frame", "WishwellPlaceDrop", UI.browseBits, "UIDropDownMenuTemplate")
  UI.placeDrop:SetPoint("TOPLEFT", LIST_X - 16, -54)
  UIDropDownMenu_SetWidth(UI.placeDrop, 190)
  UIDropDownMenu_Initialize(UI.placeDrop, function(_, level, menuList) FillPlaceMenu(level, menuList) end)

  UI.bossDrop = CreateFrame("Frame", "WishwellBossDrop", UI.browseBits, "UIDropDownMenuTemplate")
  UI.bossDrop:SetPoint("LEFT", UI.placeDrop, "RIGHT", -16, 0)
  UIDropDownMenu_SetWidth(UI.bossDrop, 170)
  UIDropDownMenu_Initialize(UI.bossDrop, FillBossMenu)

  local wishTitle = UI.wishBits:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  Bigger(wishTitle, 6)
  wishTitle:SetPoint("TOPLEFT", LIST_X + 4, -62)
  wishTitle:SetText("My wishlist")

  local clearWish = UI.MakeButton(nil, UI.wishBits)
  clearWish:SetSize(120, 22)
  clearWish:SetPoint("TOPLEFT", LIST_X + 314, -64)
  clearWish:SetText("Clear wishlist")
  clearWish:SetScript("OnClick", UI.AskClearWishlist)

  local okSearch, searchBox = pcall(CreateFrame, "EditBox", "WishwellSearch", frame, "SearchBoxTemplate")
  local nativeSearch = okSearch and type(searchBox) == "table"
  UI.search = nativeSearch and searchBox or CreateFrame("EditBox", "WishwellSearch", frame, "InputBoxTemplate")
  UI.search:SetSize(220, 20)
  UI.search:SetPoint("TOPLEFT", LIST_X + 8, -128)
  UI.search:SetAutoFocus(false)
  -- HookScript keeps the template's own handling (the "Search" hint and the clear button).
  UI.search[nativeSearch and "HookScript" or "SetScript"](UI.search, "OnTextChanged", function()
    -- Typing while a set is open means "search the sets again".
    if db.page == "sets" and UI.openSet and strtrim(UI.search:GetText() or "") ~= "" then UI.openSet = nil end
    UI.ResetScroll()
    Refresh()
  end)
  -- Shift-clicking an item anywhere while the search box is focused looks that item up.
  if hooksecurefunc then
    local function TakeLink(text)
      if UI.search:HasFocus() and type(text) == "string" and ParseItemId(text) then UI.search:SetText(text) end
    end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then
      hooksecurefunc(ChatFrameUtil, "InsertLink", TakeLink)
    elseif ChatEdit_InsertLink then
      hooksecurefunc("ChatEdit_InsertLink", TakeLink)
    end
  end
  local searchLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  UI.searchLabel = searchLabel
  searchLabel:SetPoint("BOTTOMLEFT", UI.search, "TOPLEFT", -4, 1)
  -- The game's search box already shows "Search" inside itself.
  searchLabel:SetText(nativeSearch and "" or "Search")

  -- Filter row: class, rarity, slot. (The raid/dungeon and boss menus are the row above.)
  local function FilterDrop(name, x, width, fill)
    local drop = CreateFrame("Frame", name, frame, "UIDropDownMenuTemplate")
    drop:SetPoint("TOPLEFT", LIST_X - 16 + x, -84)
    UIDropDownMenu_SetWidth(drop, width)
    UIDropDownMenu_Initialize(drop, fill)
    return drop
  end
  local function Choice(text, checked, pick, r, g, b)
    local info = UIDropDownMenu_CreateInfo()
    info.text = text
    info.checked = checked
    if r then
      info.colorCode = format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
    end
    info.func = function()
      pick()
      UI.ResetScroll()
      Refresh()
    end
    UIDropDownMenu_AddButton(info)
  end

  UI.zoneDrop = FilterDrop("WishwellZoneDrop", 0, 80, function()
    Choice("All zones", (db.zone or "ALL") == "ALL", function() db.zone = "ALL" end)
    for _, zone in ipairs(UI.Zones()) do
      Choice(zone, db.zone == zone, function()
        db.zone = zone
        UI.boss = "ALL"
      end)
    end
  end)
  UI.classDrop = FilterDrop("WishwellClassDrop", 110, 80, function()
    Choice("My class", (db.classFilter or "MINE") == "MINE", function() db.classFilter = "MINE" end)
    Choice("All classes", db.classFilter == "ALL", function() db.classFilter = "ALL" end)
    for _, classFile in ipairs(CLASS_ORDER) do
      local c = type(RAID_CLASS_COLORS) == "table" and RAID_CLASS_COLORS[classFile]
      Choice(ClassLabel(classFile), db.classFilter == classFile, function() db.classFilter = classFile end,
        c and c.r, c and c.g, c and c.b)
    end
  end)
  UI.rarityDrop = FilterDrop("WishwellRarityDrop", 220, 80, function()
    Choice("All rarities", (db.rarity or 0) == 0, function() db.rarity = 0 end)
    for _, r in ipairs(RARITIES) do
      Choice(r[2], db.rarity == r[1], function() db.rarity = r[1] end, Items.QualityColor(r[1]))
    end
  end)
  UI.slotDrop = FilterDrop("WishwellSlotDrop", 330, 80, function()
    Choice("All slots", (db.slot or "ALL") == "ALL", function() db.slot = "ALL" end)
    for _, slot in ipairs(SLOTS) do
      Choice(slot, db.slot == slot, function() db.slot = slot end)
    end
  end)

  UI.clearBtn = UI.MakeButton(nil, frame)
  UI.clearBtn:SetSize(104, 22)
  UI.clearBtn:SetPoint("LEFT", UI.search, "RIGHT", 10, 0)
  UI.clearBtn:SetText("Clear filters")
  UI.clearBtn:SetScript("OnClick", UI.ClearFilters)

  UI.bestFirst = CreateFrame("CheckButton", "WishwellBestFirst", frame, "UICheckButtonTemplate")
  UI.bestFirst:SetSize(24, 24)
  UI.bestFirst:SetPoint("LEFT", UI.clearBtn, "RIGHT", 4, 0)
  UI.bestFirst.label = UI.bestFirst:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  UI.bestFirst.label:SetPoint("LEFT", UI.bestFirst, "RIGHT", 0, 1)
  UI.bestFirst.label:SetText("Upgrades first")
  UI.bestFirst:SetChecked(db.bestFirst and true or false)
  UI.bestFirst:SetScript("OnClick", function(self)
    db.bestFirst = self:GetChecked() and true or false
    UI.ResetScroll()
    Refresh()
  end)
  UI.bestFirst:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Upgrades first")
    GameTooltip:AddLine("Puts the items that improve your current gear the most at the top. Hover an item to see exactly what would change.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  UI.bestFirst:SetScript("OnLeave", function() GameTooltip:Hide() end)

  UI.scroll = CreateFrame("ScrollFrame", "WishwellScroll", frame, "FauxScrollFrameTemplate")
  UI.scroll:SetPoint("TOPLEFT", LIST_X, -158)
  UI.scroll:SetPoint("RIGHT", -32, 0)
  UI.scroll:SetHeight(ROWS * ROW_H + 4)
  UI.scroll:SetScript("OnVerticalScroll", function(self, offset)
    FauxScrollFrame_OnVerticalScroll(self, offset, ROW_H, function()
      UI.offset = FauxScrollFrame_GetOffset(self)
      Refresh()
    end)
  end)
  -- When the list is empty: a big white heading with gold text under it, centred.
  UI.emptyTitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  Bigger(UI.emptyTitle, 10)
  UI.emptyTitle:SetPoint("TOP", listPanel, "TOP", 0, -70)
  UI.empty = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  UI.empty:SetPoint("TOP", UI.emptyTitle, "BOTTOM", 0, -14)
  UI.empty:SetWidth(380)
  UI.empty:SetJustifyH("CENTER")

  for i = 1, ROWS do
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(430, ROW_H - 2)
    row:SetPoint("TOPLEFT", UI.scroll, "TOPLEFT", 4, -2 - (i - 1) * ROW_H)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints(row)
    row.stripe = (i % 2 == 0) and 0.06 or 0
    if row.SetHighlightTexture then
      pcall(row.SetHighlightTexture, row, "Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    end
    -- Tints the row: plain (striped), wished (gold), not for your class (dimmed), heading.
    function row:SetTint(kind)
      local bg = self.bg
      if not bg.SetColorTexture then return end
      if kind == "wished" then
        bg:SetColorTexture(1, 0.82, 0, 0.16)
      elseif kind == "dim" then
        bg:SetColorTexture(0, 0, 0, 0.45)
      elseif kind == "heading" then
        bg:SetColorTexture(1, 0.82, 0, 0.10)
      else
        bg:SetColorTexture(1, 1, 1, self.stripe)
      end
    end
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(30, 30)
    -- Everything hangs from the top of the row, so the row can grow downwards when its
    -- text is opened out (see UI.LayoutRows).
    row.icon:SetPoint("TOPLEFT", 4, -4)
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    Bigger(row.name, 1)
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
    row.name:SetPoint("TOPRIGHT", row, "TOPRIGHT", -74, -5)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    row.meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    row.meta:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
    row.meta:SetPoint("TOPRIGHT", row.name, "BOTTOMRIGHT", 0, -3)
    row.meta:SetJustifyH("LEFT")
    row.meta:SetWordWrap(false)
    -- Clicking the row tries the item on, or opens the set. If the row's text does not fit
    -- (it ends in "..."), the click opens the row out to show all of it instead, and the
    -- next click closes it; the row's button still does the usual thing.
    row:SetScript("OnClick", function(self)
      local item = self.item
      if not item then return end
      -- Shift-click puts the item's link into the chat box, like everywhere else in the game.
      if item.id and not item.bonus and not item.train and IsShiftKeyDown and IsShiftKeyDown() and UI.LinkToChat(item.id) then return end
      local plainItem = not (item.advice or item.setting or item.talent or item.alt or item.recipe or item.profHead
        or item.note or item.questRow or item.header or item.train or item.bonus or item.npc or item.ask or item.legacy)
      if UI.ToggleRow(self) and not plainItem then return end
      if item.advice then
        item.go()
      elseif item.npc or item.ask then
        UI.AskRow(item)
      elseif item.setting then
        Settings.Toggle(item.entry)
      elseif item.talent then
        if item.build then UI.ResetScroll() end
        Talents.Click(item)
      elseif item.questRow then
        UI.ShowQuestOnMap(item)
      elseif item.bonus then
        UI.OpenSet(item)
      elseif plainItem then
        UI.TryOn(item.id)
      end
    end)
    row:SetScript("OnEnter", function(self)
      if self.item and self.item.talent then
        -- The game's own talent tooltip, with what the next rank does.
        if not self.item.build and self.item.tab and self.item.index then
          GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
          if not Talents.FillTip(GameTooltip, self.item.tab, self.item.index) then GameTooltip:SetText(self.item.name or "Talent") end
          GameTooltip:Show()
        end
        return
      end
      if self.item and self.item.recipe then
        local r = self.item.r
        local color = Prof.DIFF[r.diff] or Prof.DIFF[3]
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(r.name)
        GameTooltip:AddLine("This recipe " .. color[4] .. ".", color[1], color[2], color[3])
        for _, reagent in ipairs(r.reagents or {}) do
          local have = 0
          local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
          if fn then
            local ok, n = pcall(fn, reagent[1])
            have = ok and tonumber(Plain(n)) or 0
          end
          local enough = have >= reagent[2]
          GameTooltip:AddLine((Items.Name(reagent[1]) or ("item " .. reagent[1])) .. ": " .. have .. " of " .. reagent[2],
            enough and 0.25 or 1, enough and 1 or 0.33, enough and 0.25 or 0.33)
        end
        GameTooltip:Show()
        return
      end
      if self.item and self.item.legacy then
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.item.name)
        if type(self.item.text) == "string" and self.item.text ~= "" then GameTooltip:AddLine(self.item.text, 1, 1, 1, true) end
        if GetAchievementNumCriteria and GetAchievementCriteriaInfo then
          local n = tonumber(Plain(GetAchievementNumCriteria(self.item.id))) or 0
          for i = 1, math.min(n, 12) do
            local text, _, done, have, need = GetAchievementCriteriaInfo(self.item.id, i)
            text, done, have, need = Plain(text), Plain(done), Plain(have), Plain(need)
            if type(text) == "string" and text ~= "" then
              local count = (not done and type(have) == "number" and type(need) == "number" and need > 1) and (" (" .. have .. " of " .. need .. ")") or ""
              GameTooltip:AddLine((done and "Done: " or "To do: ") .. text .. count, done and 0.25 or 1, done and 1 or 0.82, done and 0.25 or 0)
            end
          end
        end
        if type(self.item.reward) == "string" and self.item.reward ~= "" then GameTooltip:AddLine(self.item.reward, 0.25, 1, 0.25, true) end
        GameTooltip:Show()
        return
      end
      if self.item and (self.item.advice or self.item.alt or self.item.profHead or self.item.note or self.item.setting) then return end
      if self.item and self.item.questRow then
        local q, F = self.item.quest, Quests.F
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(q[F.NAME])
        GameTooltip:AddLine("Level " .. q[F.LEVEL] .. " quest in " .. Quests.ZoneName(q[F.ZONE]) .. ". You can take it from level " .. q[F.MIN] .. ".", 1, 1, 1, true)
        GameTooltip:AddLine(Quests.Number(self.item.xp) .. " XP at your level", 0.25, 1, 0.25)
        if self.item.xp < q[F.XP] then
          GameTooltip:AddLine("Worth " .. Quests.Number(q[F.XP]) .. " XP at full value. It pays less the further you are above its level.", 0.8, 0.8, 0.8, true)
        end
        local who = Quests.Who(q)
        if who then GameTooltip:AddLine(who, 1, 0.82, 0) end
        local blocker = Quests.Blocker(q)
        if blocker then GameTooltip:AddLine("Finish first: " .. blocker, 1, 0.6, 0.2) end
        local giver = MapPin.Start(q[F.ID])
        if giver then
          GameTooltip:AddLine("Starts with " .. giver .. ". Click to see where on the map.", 0.6, 0.8, 1, true)
        end
        GameTooltip:Show()
        return
      end
      if not self.item or self.item.header or self.item.train or self.item.npc or self.item.ask or self.item.note then return end
      if self.item.bonus then
        UI.SetTooltip(self, self.item)
        return
      end
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      UI.ownTooltip = true -- our own rows explain the comparison in full, below
      pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. self.item.id)
      UI.ownTooltip = false
      -- What changes if you swap this in for what you are wearing.
      local result = Items.Fits(self.item) and Compare.Item(self.item) or nil
      if result then
        GameTooltip:AddLine(" ")
        local verdict = Compare.Verdict(result)
        if verdict == "up" then
          GameTooltip:AddLine("Looks like an upgrade for you", 0.25, 1, 0.25)
        elseif verdict == "down" then
          GameTooltip:AddLine("Not an upgrade for you", 1, 0.33, 0.33)
        else
          GameTooltip:AddLine("About the same as what you have", 0.8, 0.8, 0.8)
        end
        local why = Compare.Why(result, Plain((UnitClass("player"))))
        if why then GameTooltip:AddLine(why, 1, 1, 1, true) end
        if result.pair then
          GameTooltip:AddLine("You're holding a two-hander. This is one half of what would replace it, so the other hand would add to these numbers.", 1, 0.6, 0.2, true)
        end
        GameTooltip:AddLine(result.against and ("Compared with " .. result.against .. ":") or "That slot is empty, so you gain:", 1, 0.82, 0)
        if #result.diffs == 0 then
          GameTooltip:AddLine("No stat changes", 0.8, 0.8, 0.8)
        end
        for i = 1, math.min(#result.diffs, 10) do
          local diff = result.diffs[i]
          GameTooltip:AddLine(Compare.ChangeText(diff) .. "  |cff999999" .. Compare.Matters(diff[3], diff[4], diff[5]) .. "|r")
        end
      end
      -- How often it drops.
      local rate = Items.Rate(self.item)
      if rate.classic or rate.kills then
        GameTooltip:AddLine(" ")
        if rate.classic then
          GameTooltip:AddLine("Drop chance: " .. rate.classic .. "% (Classic rate)", 1, 1, 1)
        end
        if rate.kills then
          GameTooltip:AddLine("You have seen it drop " .. rate.seen .. " time" .. (rate.seen == 1 and "" or "s") .. " in "
            .. rate.kills .. " kill" .. (rate.kills == 1 and "" or "s") .. " of " .. (self.item.boss or "this boss") .. ".", 1, 1, 1, true)
        end
        if rate.chance then
          GameTooltip:AddLine("On average " .. Items.Runs(rate.chance) .. " to see it.", 0.8, 0.8, 0.8)
        end
      end
      GameTooltip:AddLine("Click to try it on", 1, 0.82, 0)
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- The button at the end of the row adds it to the wishlist or takes it off.
    row.wish = UI.MakeButton(nil, row)
    row.wish:SetSize(64, 20)
    row.wish:SetPoint("TOPRIGHT", -4, -9)
    row.wish:SetText("Wish")
    row.wish:SetScript("OnClick", function()
      if not row.item then return end
      if row.item.advice then
        row.item.go()
      elseif row.item.npc or row.item.ask then
        UI.AskRow(row.item, true)
      elseif row.item.talent then
        UI.ResetScroll()
        Talents.Click(row.item)
      elseif row.item.questRow then
        UI.ShowQuestOnMap(row.item)
      elseif row.item.setting then
        Settings.Toggle(row.item.entry)
      elseif row.item.alt or row.item.recipe or row.item.profHead or row.item.note or row.item.legacy then
        return
      elseif row.item.bonus then
        UI.OpenSet(row.item)
      else
        Wish.Toggle(row.item)
      end
    end)
    UI.rows[i] = row
  end

  -- Tabs: square icon buttons down the right edge.
  -- Five tabs. Gear and Me each hold several pages; the page is picked from the small
  -- buttons in the header (see UI.SubNav), and the tab remembers which one was open last.
  local tabDefs = {
    { id = "ask", label = "Wisp", tip = "Ask Wisp", icon = "Interface\\AddOns\\Wishwell\\WispIcon.tga", whole = true, pages = { "ask" } },
    { id = "home", label = "Next", tip = "What next?", icon = "Interface\\Icons\\Ability_Hunter_Pathfinding", pages = { "home" } },
    { id = "gear", label = "Gear", tip = "Loot, your wishlist and item sets", icon = "Interface\\Icons\\INV_Chest_Plate04", pages = { "browse", "wish", "sets" } },
    { id = "quests", label = "Quests", tip = "Quests", icon = "Interface\\Icons\\INV_Misc_Map_01", pages = { "quests" } },
    { id = "me", label = "Me", tip = "Spell training, professions, Legacy and your characters", icon = "Interface\\Icons\\INV_Misc_GroupLooking", pages = { "talents", "train", "prof", "legacy", "alts" } },
  }
  -- WoW Forever's talents are not shipped yet, so that page stays out of the tabs until they are.
  if type(Data.talents) ~= "table" then
    for _, def in ipairs(tabDefs) do
      for at = #def.pages, 1, -1 do
        if def.pages[at] == "talents" then tremove(def.pages, at) end
      end
    end
  end
  UI.groupOf = {}
  for _, def in ipairs(tabDefs) do
    for _, pageName in ipairs(def.pages) do UI.groupOf[pageName] = def end
  end
  -- A tab opens the page of its group that was open last; clicking the tab you are on
  -- takes that page back to its starting view.
  local function OpenGroup(def)
    local now = UI.groupOf[db.page]
    if now == def and frame:IsShown() then
      UI.ShowPage(db.page)
    else
      UI.ShowPage(type(db.lastIn) == "table" and UI.groupOf[db.lastIn[def.id]] == def and db.lastIn[def.id] or def.pages[1])
    end
  end
  function UI.OpenTab(id)
    for _, def in ipairs(tabDefs) do
      if def.id == id then
        OpenGroup(def)
        return
      end
    end
  end

  -- The pages of the open group, as small buttons in the header beside Settings.
  local PAGE_NAME = { browse = "Loot", wish = "Wishlist", sets = "Sets", talents = "Talents", train = "Training", prof = "Professions", legacy = "Legacy", alts = "Characters" }
  local PAGE_WIDE = { browse = 54, wish = 70, sets = 50, talents = 66, train = 72, prof = 92, legacy = 62, alts = 88 }
  local pills = {}
  function UI.SubNav(name)
    local def = UI.groupOf[name]
    local list = def and #def.pages > 1 and def.pages or {}
    local wide = 0
    -- Laid out right to left, ending just left of the Settings button.
    for i = #list, 1, -1 do
      local pageName = list[i]
      local pill = pills[pageName]
      if not pill then
        pill = UI.MakeButton("WishwellPage_" .. pageName, frame)
        pill:SetHeight(20)
        pill:SetText(PAGE_NAME[pageName])
        pill:SetScript("OnClick", function() UI.ShowPage(pageName) end)
        pills[pageName] = pill
      end
      pill:SetWidth(PAGE_WIDE[pageName])
      pill:ClearAllPoints()
      pill:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -92 - wide, -30)
      wide = wide + PAGE_WIDE[pageName] + 4
      -- The page you are on is lit; the others are dimmed.
      if pill.SetBackdropColor and smooth then
        if pageName == name then
          pill:SetBackdropColor(0.50, 0.38, 0.10, 0.95)
          pill:SetBackdropBorderColor(1, 0.82, 0.3, 1)
        else
          pill:SetBackdropColor(0.12, 0.11, 0.10, 0.9)
          pill:SetBackdropBorderColor(0.45, 0.41, 0.34, 0.8)
        end
      end
      pill:Show()
    end
    for pageName, pill in pairs(pills) do
      if UI.groupOf[pageName] ~= def or #list == 0 then pill:Hide() end
    end
    -- The line of text in the header gives way to them.
    frame.status:SetWidth(790 - 64 - 100 - wide)
    for id, tab in pairs(UI.tabs) do tab:SetOn(def ~= nil and def.id == id) end
    if def then
      if type(db.lastIn) ~= "table" then db.lastIn = {} end
      db.lastIn[def.id] = name
    end
  end
  UI.tabs = {}
  local previous
  for i, def in ipairs(tabDefs) do
    -- The Character window's side tab. It is a plain frame that reports mouse-ups itself.
    local okTab, tab = false, nil
    if not smooth then okTab, tab = pcall(CreateFrame, "Frame", nil, frame, "LargeSideTabButtonTemplate") end
    if not smooth and okTab and type(tab) == "table" and type(tab.SetCustomOnMouseUpHandler) == "function" and type(tab.Icon) == "table" then
      if previous then
        tab:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -3)
      else
        tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", 0, -30)
      end
      tab.tooltipText = def.tip
      tab.Icon:SetTexture(def.icon)
      if tab.SetFillToInterior then tab:SetFillToInterior(true, 38) end
      tab.click = function() OpenGroup(def) end
      tab:SetCustomOnMouseUpHandler(function(_, button, upInside)
        if button == "LeftButton" and upInside then tab.click() end
      end)
      function tab:SetOn(on) self:SetChecked(on) end
    else
      -- An icon with its name under it.
      local TAB_W, TAB_H, TAB_GAP, TAB_TOP = 62, 62, 6, -34
      tab = CreateFrame("Button", nil, frame, template)
      tab:SetSize(TAB_W, TAB_H)
      tab:SetPoint("TOPLEFT", frame, "TOPRIGHT", 2, TAB_TOP - (i - 1) * (TAB_H + TAB_GAP))
      MakeBackdrop(tab, 10)
      tab.icon = tab:CreateTexture(nil, "ARTWORK")
      tab.icon:SetSize(32, 32)
      tab.icon:SetPoint("TOP", 0, -7)
      -- The wisp is pixel art with nothing to trim; the game's icons have a border that is cut off.
      if def.whole then
        tab.icon:SetSize(38, 38)
        tab.icon:SetPoint("TOP", 0, -3)
        tab.icon:SetTexture(def.icon, nil, nil, "NEAREST")
      else
        tab.icon:SetTexture(def.icon)
        tab.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      end
      tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      tab.label:SetPoint("BOTTOM", 0, 7)
      tab.label:SetText(def.label)
      tab.click = function() OpenGroup(def) end
      tab:SetScript("OnClick", tab.click)
      tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(def.tip)
        GameTooltip:Show()
      end)
      tab:SetScript("OnLeave", function() GameTooltip:Hide() end)
      function tab:SetOn(on)
        if not self.SetBackdropBorderColor then return end
        if on then
          self:SetBackdropBorderColor(1, 0.82, 0, 1)
          self:SetBackdropColor(0.20, 0.16, 0.08, 0.96)
          self.icon:SetVertexColor(1, 1, 1)
          self.label:SetTextColor(1, 0.82, 0)
        else
          self:SetBackdropBorderColor(0.35, 0.32, 0.28, 1)
          self:SetBackdropColor(0.06, 0.06, 0.08, 0.96)
          if def.whole then self.icon:SetVertexColor(0.85, 0.85, 0.85) else self.icon:SetVertexColor(0.6, 0.6, 0.6) end
          self.label:SetTextColor(0.6, 0.6, 0.6)
        end
      end
    end
    previous = tab
    UI.tabs[def.id] = tab
  end
  frame.tabs = UI.tabs

  -- The game's "combat started" event is the normal way the window closes. This watches as
  -- well, in case the event is missed (it can be, in the moment after a loading screen).
  local watcher = CreateFrame("Frame", nil, frame)
  watcher.clock = 0
  watcher:SetScript("OnUpdate", function(self, elapsed)
    self.clock = self.clock + (tonumber(elapsed) or 0)
    if self.clock < 0.25 then return end
    self.clock = 0
    if UI.Fighting() then UI.CloseForCombat() end
  end)
  frame:SetScript("OnShow", function()
    UI.heldOpen = UI.Fighting()
    UI.CombatKeys()
    UI.ShowMyGear()
    Refresh()
  end)
end

-- In combat the window must not hold on to the keyboard at all, or it could eat your key
-- presses: it stops listening when a fight starts and listens again when it ends.
-- A fight has started: the window and the dungeon pop-up get out of the way (Settings,
-- "Close in combat"). A window opened in the middle of a fight was opened on purpose, so
-- that one stays until the fight is over.
function UI.CloseForCombat()
  if not db or db.combatClose == false then return end
  if WishwellToast and WishwellToast:IsShown() then WishwellToast:Hide() end
  if not frame or not frame:IsShown() or UI.heldOpen then return end
  if CloseDropDownMenus then CloseDropDownMenus() end
  if UI.askBar and UI.askBar.ClearFocus then UI.askBar:ClearFocus() end
  if UI.search and UI.search.ClearFocus then UI.search:ClearFocus() end
  if UI.chat and UI.chat.input.ClearFocus then UI.chat.input:ClearFocus() end
  frame:Hide()
end

-- True while the character is fighting.
function UI.Fighting()
  if InCombatLockdown and InCombatLockdown() then return true end
  return UnitAffectingCombat and Plain(UnitAffectingCombat("player")) == true or false
end

function UI.CombatKeys()
  if not frame or not frame.SetPropagateKeyboardInput then return end
  local fighting = InCombatLockdown and InCombatLockdown()
  frame:EnableKeyboard(not fighting)
  if not fighting then frame:SetPropagateKeyboardInput(true) end
end

function Wishwell_Toggle(page)
  if not db then return end
  UI.Build()
  if frame:IsShown() and not page then
    frame:Hide()
    return
  end
  if not frame:IsShown() then UI.heldOpen = UI.Fighting() end
  frame:Show()
  -- With no page asked for: the welcome page, or where you left off if that is switched off.
  if not page then
    if db.hub ~= false then
      page = "hub"
    else
      page = db.page ~= "hub" and db.page or db.lastPage or "home"
    end
  end
  UI.ShowPage(page)
end

-- ---------------------------------------------------------------------------
-- The little pop-up when you walk into a raid or dungeon: what drops here for your class,
-- wishlist items first. Click it to open the loot list; it fades by itself.

local Toast = {}
do
  local LINES = 5
  local toast
  local token = 0 -- only the newest pop-up's timers may hide it

  local function Build()
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    toast = CreateFrame("Button", "WishwellToast", UIParent, template)
    toast:SetSize(330, 100)
    toast:SetPoint("TOP", UIParent, "TOP", 0, -150)
    toast:SetFrameStrata("HIGH")
    MakeBackdrop(toast, 17)
    if toast.SetBackdropBorderColor then toast:SetBackdropBorderColor(0.9, 0.72, 0.25, Smooth() and 0.75 or 1) end
    toast:Hide()

    toast.icon = toast:CreateTexture(nil, "ARTWORK")
    toast.icon:SetSize(36, 36)
    toast.icon:SetPoint("TOPLEFT", 12, -12)
    toast.icon:SetTexture("Interface\\Icons\\INV_Misc_Note_02")
    toast.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if toast.CreateMaskTexture then
      pcall(function()
        local mask = toast:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(toast.icon)
        toast.icon:AddMaskTexture(mask)
      end)
    end
    toast.title = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    toast.title:SetPoint("TOPLEFT", toast.icon, "TOPRIGHT", 10, -1)
    toast.title:SetPoint("RIGHT", -12, 0)
    toast.title:SetJustifyH("LEFT")
    toast.title:SetWordWrap(false)
    toast.sub = toast:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    toast.sub:SetPoint("TOPLEFT", toast.title, "BOTTOMLEFT", 0, -3)
    toast.sub:SetPoint("RIGHT", -12, 0)
    toast.sub:SetJustifyH("LEFT")

    toast.lines = {}
    for i = 1, LINES do
      local line = {}
      line.icon = toast:CreateTexture(nil, "ARTWORK")
      line.icon:SetSize(18, 18)
      line.icon:SetPoint("TOPLEFT", 14, -58 - (i - 1) * 22)
      line.text = toast:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      line.text:SetPoint("LEFT", line.icon, "RIGHT", 6, 0)
      line.text:SetPoint("RIGHT", toast, "RIGHT", -12, 0)
      line.text:SetJustifyH("LEFT")
      line.text:SetWordWrap(false)
      toast.lines[i] = line
    end
    toast.foot = toast:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    toast.foot:SetPoint("BOTTOMLEFT", 14, 10)

    -- In the smooth look the pop-up is something the wisp says: the wisp sits on its corner,
    -- the heading is in gold beside it, and each line is a bullet point, not an icon.
    if Smooth() then
      toast:SetWidth(350)
      toast.icon:Hide()
      toast.title:ClearAllPoints()
      toast.title:SetPoint("TOPLEFT", 64, -16)
      toast.title:SetPoint("RIGHT", -16, 0)
      toast.title:SetTextColor(1, 0.82, 0)
      toast.sub:SetTextColor(0.86, 0.84, 0.78)
      for _, line in ipairs(toast.lines) do
        line.icon:SetSize(7, 7)
        line.icon:SetTexture(ART .. "Round.tga")
        line.icon:SetVertexColor(1, 0.82, 0.3, 0.9)
        line.text:ClearAllPoints()
        line.text:SetPoint("LEFT", line.icon, "RIGHT", 9, 0)
        line.text:SetPoint("RIGHT", toast, "RIGHT", -14, 0)
      end
      toast.foot:ClearAllPoints()
      toast.foot:SetPoint("BOTTOMLEFT", 22, 12)
    end

    toast:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    toast:SetScript("OnClick", function(self, button)
      self:Hide()
      if button == "LeftButton" and self.onClick then self.onClick() end
    end)
    toast:SetScript("OnEnter", function(self) self.hover = true end)
    toast:SetScript("OnLeave", function(self) self.hover = false end)

    -- The Raid Night wisp, drifting in a slow loop around the box.
    local WISP = 48 -- the 32x32 pixel-art sprite at 1.5x
    local wisp = CreateFrame("Frame", nil, toast)
    wisp:SetSize(WISP, WISP)
    local level = toast:GetFrameLevel()
    wisp:SetFrameLevel((type(level) == "number" and level or 1) + 5)
    wisp.body = wisp:CreateTexture(nil, "ARTWORK")
    wisp.body:SetAllPoints(wisp)
    wisp.body:SetTexture("Interface\\AddOns\\Wishwell\\WispBody.tga", nil, nil, "NEAREST")
    wisp.face = wisp:CreateTexture(nil, "OVERLAY")
    wisp.face:SetAllPoints(wisp)
    wisp.face:SetTexture("Interface\\AddOns\\Wishwell\\WispFace.tga", nil, nil, "NEAREST")
    local function Cell(tex, index, cols, rows)
      local c = index % cols
      local r = math.floor(index / cols)
      tex:SetTexCoord(c / cols, (c + 1) / cols, r / rows, (r + 1) / rows)
    end
    Cell(wisp.body, 0, 4, 4)
    Cell(wisp.face, 0, 4, 1)
    wisp.clock = 0
    wisp:SetScript("OnUpdate", function(self, elapsed)
      self.clock = self.clock + (tonumber(elapsed) or 0)
      local t = self.clock
      -- WispBody.tga is a 4x4 sheet of flame frames, played choppily like a virtual pet.
      local step = math.floor(t * 4) % 16
      Cell(self.body, step, 4, 4)
      -- WispFace.tga: open, half, closed, happy. Happy when something here is for you;
      -- otherwise it blinks now and then.
      local face = 0
      if self.happy then
        face = 3
      else
        local blink = t % 4
        if blink > 3.8 then face = 2 elseif blink > 3.7 then face = 1 end
      end
      Cell(self.face, face, 4, 1)
      -- In the smooth look it perches on the corner of its speech bubble, bobbing.
      if Smooth() then
        self:ClearAllPoints()
        self:SetPoint("CENTER", toast, "TOPLEFT", 34, -30 + math.sin(t * 2.2) * 4)
        return
      end
      -- One lap around the box every twelve seconds or so, with a little bob.
      local angle = t * 0.52
      local w, h = tonumber(toast:GetWidth()) or 330, tonumber(toast:GetHeight()) or 100
      local x = math.cos(angle) * (w / 2 + 14)
      local y = math.sin(angle) * (h / 2 + 12) + math.sin(t * 3) * 3
      self:ClearAllPoints()
      self:SetPoint("CENTER", toast, "CENTER", x, y)
    end)
    toast.wisp = wisp

    -- A small hop when it appears.
    pcall(function()
      local hop = toast:CreateAnimationGroup()
      local down = hop:CreateAnimation("Translation")
      down:SetOffset(0, -12)
      down:SetDuration(0.16)
      down:SetOrder(1)
      down:SetSmoothing("OUT")
      local up = hop:CreateAnimation("Translation")
      up:SetOffset(0, 12)
      up:SetDuration(0.22)
      up:SetOrder(2)
      up:SetSmoothing("IN_OUT")
      toast.hop = hop
    end)
  end

  local function FadeAway(mine)
    if mine ~= token or not toast:IsShown() then return end
    if toast.hover then
      -- Don't take it away while the mouse is on it.
      After(2, function() FadeAway(mine) end)
      return
    end
    if UIFrameFadeOut then
      pcall(UIFrameFadeOut, toast, 0.8, 1, 0)
      After(0.9, function()
        if mine == token then toast:Hide() end
      end)
    else
      toast:Hide()
    end
  end

  -- Fills the pop-up and shows it. lines = { { icon, text }, ... }, at most five.
  function Toast.Present(title, sub, lines, foot, happy, onClick)
    if not toast then Build() end
    toast.onClick = onClick
    toast.title:SetText(title)
    toast.sub:SetText(sub)
    local shown = math.min(#lines, LINES)
    for i = 1, LINES do
      local line = toast.lines[i]
      local entry = lines[i]
      if entry then
        if not Smooth() then line.icon:SetTexture(entry.icon) end -- a bullet point in the smooth look
        line.text:SetText(entry.text)
        line.icon:Show()
        line.text:Show()
      else
        line.icon:Hide()
        line.text:Hide()
      end
    end
    toast.foot:SetText(foot)
    -- A long line of text under the title (a tip) wraps, so leave room for it.
    local subHeight = tonumber(toast.sub:GetStringHeight()) or 14
    local top = 44 + math.max(14, subHeight)
    for i = 1, LINES do
      local line = toast.lines[i]
      line.icon:ClearAllPoints()
      if Smooth() then
        line.icon:SetPoint("TOPLEFT", 24, -top - (i - 1) * 22 - 6)
      else
        line.icon:SetPoint("TOPLEFT", 14, -top - (i - 1) * 22)
      end
    end
    toast:SetHeight(top + shown * 22 + 26)
    if toast.wisp then
      toast.wisp.happy = happy and true or false
      toast.wisp:SetShown(db.wisp ~= false)
    end
    token = token + 1
    local mineToken = token
    toast.hover = false
    toast:SetAlpha(1)
    toast:Show()
    if UIFrameFadeIn then pcall(UIFrameFadeIn, toast, 0.35, 0, 1) end
    if toast.hop then pcall(toast.hop.Play, toast.hop) end
    if PlaySound and db.sound ~= false then pcall(PlaySound, (SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_OPEN) or 844) end
    After(onClick and 10 or 14, function() FadeAway(mineToken) end)
  end

  -- heroic: true or false inside a dungeon that has both, so only that list is counted.
  function Toast.Show(placeId, heroic)
    if not toast then Build() end
    local mine, wished, upgrades = {}, 0, 0
    for _, item in ipairs(Items.ForPlace(placeId)) do
      if Items.Fits(item) and Items.InDiff(item, heroic) then
        local has = Wish.Has(item.id)
        if has then wished = wished + 1 end
        local result = Compare.Item(item)
        local up = Compare.Verdict(result) == "up"
        if up then upgrades = upgrades + 1 end
        tinsert(mine, { item = item, wished = has, q = Items.Quality(item) or 0, up = up, score = result and result.score or 0 })
      end
    end
    table.sort(mine, function(a, b)
      if a.wished ~= b.wished then return a.wished end
      if a.up ~= b.up then return a.up end
      if a.score ~= b.score then return a.score > b.score end
      if a.q ~= b.q then return a.q > b.q end
      return a.item.id < b.item.id
    end)

    local sub
    if #mine == 0 then
      sub = "No loot known here yet. It fills in as things drop."
    else
      sub = #mine .. " drop" .. (#mine == 1 and "" or "s") .. " for your class"
        .. (upgrades > 0 and ("  ·  " .. upgrades .. " upgrade" .. (upgrades == 1 and "" or "s")) or "")
        .. (wished > 0 and ("  ·  " .. wished .. " on your wishlist") or "")
    end
    local lines = {}
    for i = 1, math.min(#mine, LINES) do
      local entry = mine[i]
      local item = entry.item
      local r, g, b = Items.QualityColor(entry.q > 0 and entry.q or nil)
      local hex = format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
      tinsert(lines, {
        icon = Items.Icon(item.id),
        text = (entry.wished and "|cffffd100Wish|r  " or "") .. (entry.up and "|cff40ff40Upgrade|r  " or "") .. hex
          .. (item.name or Items.Name(item.id) or ("Item " .. item.id)) .. "|r"
          .. (item.boss and ("  |cff808080" .. item.boss .. "|r") or ""),
      })
    end
    local foot
    if #mine > #lines then
      foot = "+" .. (#mine - #lines) .. " more. Click to see them all."
    else
      foot = "Click to open the loot list. Right-click to close."
    end
    Toast.Present(Places.Label(placeId, heroic), sub, lines, foot, wished > 0 or upgrades > 0, function()
      UI.Browse(placeId, heroic)
      Wishwell_Toggle("browse")
    end)
  end

  -- What a new level opened up: spells, quests, dungeons, and where the XP is.
  function Toast.LevelUp(level)
    level = Plain(level)
    if type(level) ~= "number" or not db or db.popup == false then return end
    local lines = {}
    if Train.Scanned() then
      local count, total = Train.At(level)
      if count > 0 then
        tinsert(lines, { icon = "Interface\\Icons\\INV_Misc_Book_11",
          text = count .. " new spell" .. (count == 1 and "" or "s") .. " to train  |cff808080" .. Train.Money(total) .. "|r" })
      end
    end
    local quests = Quests.NewAt(level)
    if quests > 0 then
      tinsert(lines, { icon = "Interface\\GossipFrame\\AvailableQuestIcon",
        text = quests .. " quest" .. (quests == 1 and "" or "s") .. " you can now pick up" })
    end
    for _, place in ipairs(Data.instances) do
      if place.kind == "dungeon" and place.min == level and #lines < LINES then
        tinsert(lines, { icon = "Interface\\Icons\\INV_Misc_Key_03", text = place.name .. " is now in your level range" })
      end
    end
    local top = Quests.ZoneTotals()[1]
    if top and top.zone > 0 and #lines < LINES then
      tinsert(lines, { icon = "Interface\\Icons\\INV_Misc_Map_01",
        text = "Most quest XP: " .. top.name .. "  |cff808080" .. Quests.Number(top.xp) .. " XP|r" })
    end
    Toast.Present("Level " .. level .. "!", #lines > 0 and "Here is what just opened up." or "Nothing new to train or pick up this level.",
      lines, "Click to see what to do next.", true, function() Wishwell_Toggle("home") end)
  end

  -- A one-time hint from the wisp. Each hint is shown once per account, ever.
  -- The run-down after an update: once for each version, unless switched off. force: show it anyway.
  function Toast.News(force)
    if not db then return false end
    if not force then
      if db.newsSeen == VERSION then return false end
      db.newsSeen = VERSION
      if db.news == false or db.popup == false then return false end
    end
    local lines = {}
    for i = 1, math.min(#NEWS, 5) do tinsert(lines, { icon = ART .. "WispIcon.tga", text = NEWS[i] }) end
    Toast.Present("Wishwell Forever " .. VERSION, "Updated. Here is what's new:", lines, #NEWS > 5 and "Click for the full list." or "", true, function()
      -- The window may never have been opened this session: open it on Wisp first.
      Wishwell_Toggle("ask")
      UI.AskNow("whats new")
    end)
    return true
  end

  function Toast.Tip(key, text)
    if not db or db.hints == false then return end
    if type(db.tipsSeen) ~= "table" then db.tipsSeen = {} end
    if db.tipsSeen[key] then return end
    db.tipsSeen[key] = true
    Print("Tip: " .. text)
    local function Show(tries)
      -- Don't talk over another pop-up; wait for it to go.
      if toast and toast:IsShown() and tries > 0 then
        After(6, function() Show(tries - 1) end)
        return
      end
      Toast.Present("A tip from the wisp", text, {}, "Type /ww hints to turn tips off.", true, nil)
    end
    Show(4)
  end
end

-- ---------------------------------------------------------------------------
-- Watching the game: where we are, what dies, what drops.

local Watch = {}
do
  local KILL_WINDOW = 300       -- seconds after a boss kill that loot still counts as that boss's
  local WORLD_KILL_WINDOW = 120
  local lastKill                -- { boss, at, place } for the most recent boss kill
  local outbox = {}             -- addon messages waiting their turn (the game allows about one a second)
  local outboxRunning = false
  local toShare = {}            -- [placeId][boss] = { ids } seen just now, not yet sent to the group
  local sharePending = false
  local toldAbout = {}          -- made-up places the group has been told about this session
  local lastPlace
  local hinted = {}
  -- db.popped[place and difficulty] = when its loot pop-up was last shown. It is saved, so
  -- typing /reload inside a dungeon does not bring the pop-up back.
  local POP_AGAIN = 30 * 60 -- seconds before the same place may pop up again
  local function Clock()
    -- The real time where the game has it (it carries over a reload); the game clock otherwise.
    if time then return time() end
    return GetTime and GetTime() or 0
  end

  local function Channel()
    if IsInRaid and IsInRaid() then return "RAID" end
    if IsInGroup and IsInGroup() then return "PARTY" end
    return nil
  end

  -- The game blocks addon messages during boss fights; wait those out.
  local function Locked()
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
      return Plain(C_ChatInfo.InChatMessagingLockdown()) == true
    end
    return false
  end

  local function Pump()
    if #outbox == 0 then
      outboxRunning = false
      return
    end
    local channel = Channel()
    if not channel or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
      wipe(outbox)
      outboxRunning = false
      return
    end
    if Locked() then
      After(5, Pump)
      return
    end
    local payload = tremove(outbox, 1)
    local result = C_ChatInfo.SendAddonMessage(PREFIX, payload, channel)
    local lockdown = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.AddOnMessageLockdown
    if lockdown ~= nil and result == lockdown then
      tinsert(outbox, 1, payload)
      After(5, Pump)
      return
    end
    After(1.1, Pump)
  end

  local function Queue(payload)
    if not (C_Timer and C_Timer.After) or #outbox >= 100 then return end
    tinsert(outbox, payload)
    if not outboxRunning then
      outboxRunning = true
      Pump()
    end
  end

  -- L:<place>:<id,id,...>:<boss> tells the group these items drop from that boss.
  local function QueueLearned(placeId, boss, ids)
    local row = Places.Row(placeId)
    if row and row.madeUp and not toldAbout[placeId] then
      -- N describes a raid or dungeon the addon was not shipped with.
      toldAbout[placeId] = true
      Queue("N:" .. placeId .. ":" .. (row.kind == "raid" and "raid" or "dungeon") .. ":" .. row.name)
    end
    local chunk, len = {}, 0
    local function flush()
      if #chunk > 0 then Queue("L:" .. placeId .. ":" .. table.concat(chunk, ",") .. ":" .. boss) end
      chunk, len = {}, 0
    end
    for _, id in ipairs(ids) do
      local text = tostring(id)
      if len + #text + 1 > 180 then flush() end
      tinsert(chunk, text)
      len = len + #text + 1
    end
    flush()
  end

  local function ShareNewDrops()
    sharePending = false
    local pending = toShare
    toShare = {}
    if Channel() then
      for placeId, bosses in pairs(pending) do
        for boss, ids in pairs(bosses) do QueueLearned(placeId, boss, ids) end
      end
    end
    Refresh()
  end

  -- Group members' wishlists for the place we are in, as they sent them. Kept for this session.
  local peers = {}
  local sharePending2 = false

  -- Names of group members who have this item on their wishlist.
  WantedBy = function(placeId, id)
    local names
    for name, peer in pairs(peers) do
      if peer.ids[id] and (placeId == nil or placeId == "" or peer.place == placeId) and Now() - peer.at < 4 * 3600 then
        names = names or {}
        tinsert(names, name)
      end
    end
    if names then table.sort(names) end
    return names
  end

  -- Tells the group what this character wants from the raid or dungeon it is standing in.
  function Watch.ShareWishes()
    if not db or db.share == false or not Channel() then return end
    local placeId = Watch.Here()
    if not placeId then return end
    local ids = Wish.Ids(placeId)
    local parts = {}
    for i = 1, math.min(#ids, 28) do tinsert(parts, tostring(ids[i])) end
    Queue("W:" .. placeId .. ":" .. table.concat(parts, ","))
  end

  -- The same, a few seconds from now, however many times it is asked for.
  function Watch.ShareWishesSoon()
    if sharePending2 then return end
    sharePending2 = true
    After(4, function()
      sharePending2 = false
      pcall(Watch.ShareWishes)
    end)
  end

  function Watch.OnAddonMessage(prefix, message, _, sender)
    prefix, message, sender = Plain(prefix), Plain(message), Plain(sender)
    if prefix ~= PREFIX or type(message) ~= "string" or type(sender) ~= "string" then return end
    local me = Plain(UnitName("player")) or ""
    if strlower(strmatch(sender, "^([^-]+)") or sender) == strlower(me) then return end
    local kind, a, b, c = strsplit(":", message, 4)
    if kind == "W" and a then
      -- A group member's wishlist for the raid or dungeon we are in.
      local name = strmatch(sender, "^([^-]+)") or sender
      local ids, count = {}, 0
      for id in string.gmatch(b or "", "%d+") do
        if count >= 40 then break end
        ids[tonumber(id)] = true
        count = count + 1
      end
      local before = peers[name]
      peers[name] = { place = a, ids = ids, count = count, at = Now() }
      if count > 0 and Places.Known(a) and not (before and before.place == a and before.count == count) then
        Print(name .. " has " .. count .. " wishlist item" .. (count == 1 and "" or "s") .. " in " .. Places.Name(a) .. ".")
      end
      Refresh()
      return
    end
    if kind == "N" and a and c then
      if #a <= 12 and strmatch(a, "^m%d+$") and (b == "raid" or b == "dungeon") then
        local name = CleanLabel(c)
        if name then Places.Add(a, name, b) end
      end
    elseif kind == "L" and a and b and c then
      if Places.Known(a) then
        local boss = CleanLabel(c)
        local added = false
        -- Only for the raid or dungeon you are in yourself, only items the game knows,
        -- and no more than a boss could drop: a group member cannot fill your lists with junk.
        local exists = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
        if boss and Run.place == a then
          local count = 0
          for id in string.gmatch(b, "%d+") do
            count = count + 1
            if count > 40 then break end
            id = tonumber(id)
            if (not exists or Plain((exists(id))) ~= nil) and Items.Remember(a, id, boss) then added = true end
          end
        end
        if added then Refresh() end
      end
    end
  end

  local function PlainName(text)
    return (gsub(strlower(text), "^the ", ""))
  end

  -- The raid or dungeon the character is standing in, as a place id. A place the addon has
  -- never heard of is added on the spot. Second return is the game's instance type.
  local heroicHere = false
  local function Here()
    if not GetInstanceInfo then return nil end
    local name, kind, diff, diffName, _, _, _, mapId = GetInstanceInfo()
    name, kind, diff, diffName, mapId = Plain(name), Plain(kind), Plain(diff), Plain(diffName), Plain(mapId)
    -- 2 is a heroic dungeon; 174 is the same thing on newer Classic clients.
    heroicHere = kind == "party" and (diff == 2 or diff == 174 or (type(diffName) == "string" and diffName == (PLAYER_DIFFICULTY2 or "Heroic")))
    if kind ~= "party" and kind ~= "raid" then return nil, kind end
    local known = Places.ByMap(type(mapId) == "number" and math.floor(mapId) or nil)
    if known then return known, kind end
    if type(name) ~= "string" or name == "" then return nil, kind end
    local want = PlainName(name)
    -- "Coilfang: The Underbog" is The Underbog.
    local short = strmatch(name, ":%s*(.+)$")
    short = short and PlainName(short) or nil
    for _, row in ipairs(Data.instances) do
      if row.kind ~= "world" then
        if PlainName(row.name) == want or PlainName(row.name) == short then return row.id, kind end
        if row.aliases then
          for _, alias in ipairs(row.aliases) do
            if PlainName(alias) == want then return row.id, kind end
          end
        end
      end
    end
    if type(mapId) ~= "number" then return nil, kind end
    local id = "m" .. math.floor(mapId)
    if Places.Known(id) then return id, kind end
    local label = CleanLabel(name)
    if label and Places.Add(id, label, kind == "raid" and "raid" or "dungeon") then return id, kind end
    return nil, kind
  end

  Watch.Here = Here

  function Watch.Kill(bossName, success)
    if success ~= nil and Plain(success) ~= 1 then return end
    local boss = CleanLabel(bossName)
    if not boss then return end
    local placeId, kind = Here()
    if not placeId and kind == "none" then placeId = "world" end
    if not placeId then return end
    Watch.CountKill(placeId, boss)
  end

  -- One boss kill we were there for. The game can announce the same kill twice, and a
  -- corpse can be looted more than once, so a repeat within half a minute is the same kill.
  function Watch.CountKill(placeId, boss)
    if lastKill and lastKill.boss == boss and lastKill.place == placeId and Now() - lastKill.at < 30 then return end
    lastKill = { boss = boss, at = Now(), place = placeId, drops = {} }
    if type(db.kills) ~= "table" then db.kills = {} end
    if type(db.kills[placeId]) ~= "table" then db.kills[placeId] = {} end
    db.kills[placeId][boss] = (tonumber(db.kills[placeId][boss]) or 0) + 1
    if Run.place == placeId then Run.kills = Run.kills + 1 end
  end

  -- An item dropped from the kill we are counting: once per kill, however often it is reported.
  local function CountDrop(placeId, boss, id)
    if boss == "Trash" or not lastKill or lastKill.boss ~= boss or lastKill.place ~= placeId then return end
    if lastKill.drops[id] then return end
    lastKill.drops[id] = true
    if type(db.seen) ~= "table" then db.seen = {} end
    if type(db.seen[placeId]) ~= "table" then db.seen[placeId] = {} end
    db.seen[placeId][id] = (tonumber(db.seen[placeId][id]) or 0) + 1
    if Run.place == placeId then Run.drops = Run.drops + 1 end
  end

  local QUALITY_BY_COLOR = { ff1eff00 = 2, ff0070dd = 3, ffa335ee = 4, ffff8000 = 5 }

  local function Quality(id, link)
    local quality
    if C_Item and C_Item.GetItemQualityByID then quality = Plain(C_Item.GetItemQualityByID(id)) end
    if type(quality) ~= "number" then
      quality = tonumber(strmatch(link, "|cnIQ(%d)"))
        or QUALITY_BY_COLOR[strlower(strmatch(link, "|c(%x%x%x%x%x%x%x%x)") or "")]
    end
    return type(quality) == "number" and quality or nil
  end

  -- One dropped item. Wishlist items always get an alert; rare-or-better drops (and green
  -- drops from dungeon bosses) are remembered for the loot list.
  -- fromCorpse: it was seen in a loot window or roll, so it certainly dropped.
  function Watch.Drop(link, fromCorpse, corpseBoss, isRoll)
    link = Plain(link)
    if type(link) ~= "string" then return end
    local id = tonumber(strmatch(link, "item:(%d+)"))
    if not id then return end
    Wish.Seen(id, link, isRoll)
    local quality = Quality(id, link)
    if not quality or quality < 2 then return end
    local placeId, kind = Here()
    local recent = lastKill
    local boss
    if placeId then
      if recent and (recent.place ~= placeId or Now() - recent.at > KILL_WINDOW) then recent = nil end
      boss = corpseBoss or (recent and recent.boss) or "Trash"
    elseif kind == "none" and corpseBoss then
      placeId, boss = "world", corpseBoss
    elseif kind == "none" and recent and recent.place == "world" and Now() - recent.at <= WORLD_KILL_WINDOW then
      placeId, boss = "world", recent.boss
    else
      return
    end
    -- Low-level dungeon bosses mostly drop greens, so those count, but only from a boss:
    -- green trash drops would bury the list.
    if quality < 3 and not (kind == "party" and boss ~= "Trash") then return end
    if not fromCorpse then
      -- Chat lines also show things people make or disenchant; skip materials and consumables.
      local _, classID = Items.Facts(id)
      if classID == 7 or classID == 0 then return end
    end
    -- A boss with no fight event (most dungeon bosses): looting its corpse is how we know it died.
    if corpseBoss and placeId ~= "world" then Watch.CountKill(placeId, corpseBoss) end
    CountDrop(placeId, boss, id)
    if not Items.Remember(placeId, id, boss) then
      Refresh()
      return
    end
    boss = db.learned[placeId][id]
    if Run.place == placeId and not Items.IsShippedAt(placeId, id) then Run.fresh = Run.fresh + 1 end
    toShare[placeId] = toShare[placeId] or {}
    toShare[placeId][boss] = toShare[placeId][boss] or {}
    tinsert(toShare[placeId][boss], id)
    if not sharePending then
      sharePending = true
      After(3, ShareNewDrops)
    end
  end

  function Watch.LootWindow()
    if not GetNumLootItems or not GetLootSlotLink then return end
    -- Looting a dead boss or rare with no boss-fight event: use its name.
    local corpseBoss
    if UnitExists and Plain(UnitExists("target")) and UnitIsDead and Plain(UnitIsDead("target")) then
      local class = UnitClassification and Plain(UnitClassification("target"))
      local level = UnitLevel and Plain(UnitLevel("target"))
      if class == "worldboss" or class == "rareelite" or class == "rare" or level == -1 then
        corpseBoss = CleanLabel(UnitName("target"))
      end
    end
    local count = Plain(GetNumLootItems())
    if type(count) ~= "number" then return end
    for slot = 1, count do
      local link = GetLootSlotLink(slot)
      local fromCorpse = true
      if GetLootSourceInfo then
        local guid = Plain((GetLootSourceInfo(slot)))
        if type(guid) == "string" and not (strfind(guid, "^Creature") or strfind(guid, "^Vehicle") or strfind(guid, "^GameObject")) then
          fromCorpse = false
        end
      end
      if link then Watch.Drop(link, fromCorpse, fromCorpse and corpseBoss or nil) end
    end
  end

  -- The longest fixed piece of a chat pattern such as "%s receives item: %s.".
  local function FixedPart(fmt)
    if type(fmt) ~= "string" then return nil end
    local best = ""
    for part in gmatch((gsub(fmt, "%%%d?%$?[sd]", "\1")), "[^\1]+") do
      if #part > #best then best = part end
    end
    if #best < 4 then return nil end
    return best
  end

  local notDropPhrases
  local selfLootPhrase

  -- True for chat lines about items that were made, bought or handed over rather than dropped.
  local function IsNotADrop(text)
    if not notDropPhrases then
      notDropPhrases = {}
      for _, key in ipairs({
        "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "LOOT_ITEM_PUSHED", "LOOT_ITEM_PUSHED_MULTIPLE",
        "LOOT_ITEM_CREATED_SELF", "LOOT_ITEM_CREATED_SELF_MULTIPLE", "LOOT_ITEM_CREATED", "LOOT_ITEM_CREATED_MULTIPLE",
      }) do
        local phrase = FixedPart(_G[key])
        if phrase then tinsert(notDropPhrases, phrase) end
      end
    end
    for _, phrase in ipairs(notDropPhrases) do
      if strfind(text, phrase, 1, true) then return true end
    end
    return false
  end

  function Watch.LootChat(text)
    text = Plain(text)
    if type(text) ~= "string" or IsNotADrop(text) then return end
    if selfLootPhrase == nil then selfLootPhrase = FixedPart(LOOT_ITEM_SELF) or false end
    if selfLootPhrase and strfind(text, selfLootPhrase, 1, true) then
      local id = tonumber(strmatch(text, "item:(%d+)"))
      if id then Wish.Got(id, text) end
    end
    Watch.Drop(text, false, nil)
  end

  -- Walking into a raid or dungeon: point the loot list at it and say what is on the wishlist there.
  -- Leaving a raid or dungeon after at least one boss: a short account of the run.
  local function Summarise()
    local placeId = Run.place
    Run.place = nil
    if not placeId or Run.kills == 0 or db.popup == false then return end
    local lines = {}
    local function Line(icon, text) tinsert(lines, { icon = icon, text = text }) end
    for id in pairs(Run.got) do
      if #lines < 3 then Line(Items.Icon(id), "|cff40ff40Got it:|r " .. (Items.Name(id) or ("item " .. id))) end
    end
    for id in pairs(Run.missed) do
      if #lines < 4 then Line(Items.Icon(id), "|cffffd100Dropped, still on your list:|r " .. (Items.Name(id) or ("item " .. id))) end
    end
    if Run.fresh > 0 then
      Line("Interface\\Icons\\INV_Misc_Book_09", Run.fresh .. " new drop" .. (Run.fresh == 1 and "" or "s") .. " added to the loot list")
    end
    local left = #Wish.Ids(placeId)
    if left > 0 then
      Line("Interface\\Icons\\INV_Misc_Note_02", left .. " wishlist item" .. (left == 1 and "" or "s") .. " still to get here")
    end
    Toast.Present(Places.Name(placeId) .. ": run summary",
      Run.kills .. " boss" .. (Run.kills == 1 and "" or "es") .. " down  ·  " .. Run.drops .. " drop" .. (Run.drops == 1 and "" or "s") .. " seen",
      lines, "Click to open the loot list.", next(Run.got) ~= nil, function()
        db.browseId = placeId
        db.zone = "ALL"
        Wishwell_Toggle("browse")
      end)
  end

  function Watch.Place()
    local id = Here()
    if not id then
      -- Dead and outside (released, running back): the run is not over, so say nothing
      -- and let walking back in carry on where it left off.
      if lastPlace and UnitIsDeadOrGhost and Plain(UnitIsDeadOrGhost("player")) == true then return end
      lastPlace = nil
      pcall(Summarise)
      return
    end
    local heroic = nil
    if Places.HasHeroic(id) then heroic = heroicHere end
    local key = id .. (heroic and ":heroic" or "")
    if key == lastPlace then return end
    lastPlace = key
    Run.place, Run.kills, Run.drops, Run.fresh, Run.got, Run.missed = id, 0, 0, 0, {}, {}
    -- Load this place's loot straight away, whether or not the window is ever opened.
    local loading = Items.Preload(id, heroic)
    if db.browseId ~= id or (heroic ~= nil and (db.heroic == true) ~= heroic) then
      UI.Browse(id, heroic)
      UI.ResetScroll()
    end
    -- The pop-up and the chat line show once per visit: not again after a death, on walking
    -- straight back in, or after a /reload.
    if type(db.popped) ~= "table" then db.popped = {} end
    local now = Clock()
    for place, when in pairs(db.popped) do
      if type(when) ~= "number" or now - when >= POP_AGAIN or when > now then db.popped[place] = nil end
    end
    local again = db.popped[key] == nil
    local ids = Wish.Ids(id)
    if not again then
      -- Said already this visit.
    elseif #ids > 0 then
      local names = {}
      for i = 1, math.min(#ids, 6) do tinsert(names, Items.Name(ids[i]) or ("item " .. ids[i])) end
      local more = #ids > #names and (" and " .. (#ids - #names) .. " more") or ""
      Print(Places.Name(id) .. ": " .. #ids .. " wishlist item" .. (#ids == 1 and "" or "s") .. " here - " .. table.concat(names, ", ") .. more .. ".")
    elseif db.popup == false and not hinted[id] then
      hinted[id] = true
      Print("Type /ww to see what drops in " .. Places.Name(id) .. " for your class.")
    end
    if again then db.popped[key] = now end
    if db.popup ~= false and db.lootPopup ~= false and again then
      if loading > 0 then
        -- Give the game a moment to answer, so the pop-up counts upgrades from real stats.
        After(1.5, function()
          if lastPlace == key then pcall(Toast.Show, id, heroic) end
        end)
      else
        pcall(Toast.Show, id, heroic)
      end
    end
    Watch.ShareWishesSoon()
    Refresh()
  end
end

-- ---------------------------------------------------------------------------
-- Upgrade advice everywhere else in the game: on item tooltips (bags, vendors, auction
-- house, loot), on loot rolls, and when a quest offers a choice of rewards.
-- Wishwell only ever says what it thinks. It never rolls, picks or equips for you.

local Advice = {}
do
  local marks = {}

  local function Judge(id, link)
    local item = { id = id, link = link }
    if not Items.Fits(item) then return nil end
    local result = Compare.Item(item)
    return Compare.Verdict(result), result
  end

  local function Changes(result, limit)
    local parts = {}
    for i = 1, math.min(#result.diffs, limit) do tinsert(parts, Compare.ChangeText(result.diffs[i])) end
    return table.concat(parts, "  ")
  end

  -- Adds Wishwell's lines to an item tooltip.
  -- Why the last item tooltip did or did not get Wishwell's lines; /ww tipcheck prints it.
  local last = { hooks = "none", calls = 0, item = nil, said = "No item tooltip has been seen yet." }

  -- True if the tooltip already carries Wishwell's verdict (both hooks can fire for one item).
  local function Stamped(tooltip)
    local name = tooltip.GetName and tooltip:GetName() or nil
    local count = tooltip.NumLines and tonumber((tooltip:NumLines())) or 0
    if type(name) ~= "string" then return false end
    for i = count, 1, -1 do
      local line = _G[name .. "TextLeft" .. i]
      local text = type(line) == "table" and line.GetText and Plain(line:GetText()) or nil
      if type(text) == "string" and strfind(text, "Wishwell: ", 1, true) then return true end
    end
    return false
  end

  function Advice.Report()
    return "Tooltip check: hooked by " .. last.hooks .. ", " .. last.calls .. " item tooltips seen. Last item: "
      .. (last.item or "none") .. ". " .. last.said
  end

  function Advice.Tooltip(tooltip, id, link)
    last.calls = last.calls + 1
    local function Skip(why)
      last.said = why
    end
    if not db or db.tips == false then return Skip("Upgrade tips are switched off in Settings.") end
    if UI.ownTooltip then return end
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    if Stamped(tooltip) then return end
    id = tonumber(Plain(id))
    if not id then return Skip("The game did not say which item it was.") end
    link = Plain(link)
    if type(link) ~= "string" then link = nil end
    last.item = Items.Name(id) or ("item " .. id)
    if InCombatLockdown and InCombatLockdown() then return Skip("You were in combat, so nothing was added.") end
    if Wish.Has(id) then tooltip:AddLine("Wishwell: on your wishlist", 1, 0.82, 0) end
    local verdict, result = Judge(id, link)
    if not verdict then
      local equipLoc = Items.Facts(id)
      if not Items.Fits({ id = id, link = link }) then return Skip("Your class cannot use it.") end
      if not equipLoc or equipLoc == "" then return Skip("It is not something you wear.") end
      return Skip("The game had not loaded its stats yet (slot " .. tostring(equipLoc) .. "). Hover it again.")
    end
    if result.wearing then return Skip("You are wearing it.") end
    if #result.diffs == 0 then return Skip("Its stats are the same as what you are wearing.") end
    Skip("Wishwell's lines were added.")
    -- The same comparison the rows in the Wishwell window show, so the window need not be open.
    tooltip:AddLine(" ")
    if verdict == "up" then
      tooltip:AddLine("Wishwell: upgrade for you", 0.25, 1, 0.25)
    elseif verdict == "down" then
      tooltip:AddLine("Wishwell: not an upgrade for you", 1, 0.33, 0.33)
    else
      tooltip:AddLine("Wishwell: about the same as what you have", 0.8, 0.8, 0.8)
    end
    local why = Compare.Why(result, Plain((UnitClass("player"))))
    if why then tooltip:AddLine("Why: " .. why, 1, 1, 1, true) end
    if result.pair then
      tooltip:AddLine("You're holding a two-hander. This is one half of what would replace it, so the other hand would add to these numbers.", 1, 0.6, 0.2, true)
    end
    tooltip:AddLine(result.against and ("Compared with " .. result.against .. ":") or "That slot is empty, so you gain:", 1, 0.82, 0)
    for i = 1, math.min(#result.diffs, 8) do
      local diff = result.diffs[i]
      tooltip:AddLine(Compare.ChangeText(diff) .. "  |cff999999" .. Compare.Matters(diff[3], diff[4], diff[5]) .. "|r")
    end
    if tooltip.Show and tooltip:IsShown() then tooltip:Show() end -- grow to fit the new lines
  end

  -- Hooks item tooltips, in whichever way this version of the game offers.
  -- Both ways are hooked where the game has both: some versions have the new one but only
  -- call the old one for bags. Advice.Tooltip adds its lines once whichever calls it.
  function Advice.Hook()
    if Advice.hooked then return end
    Advice.hooked = true
    local ways = {}
    local function Run(tooltip, id, link)
      local ok, err = pcall(Advice.Tooltip, tooltip, id, link)
      if not ok then last.said = "Wishwell hit an error: " .. tostring(err) end
    end
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType
      and Enum.TooltipDataType.Item then
      local ok = pcall(TooltipDataProcessor.AddTooltipPostCall, Enum.TooltipDataType.Item, function(tooltip, data)
        if type(data) ~= "table" then return end
        local link
        if TooltipUtil and TooltipUtil.GetDisplayedItem then
          local okLink, _, found = pcall(TooltipUtil.GetDisplayedItem, tooltip)
          if okLink then link = found end
        end
        Run(tooltip, data.id, link)
      end)
      if ok then tinsert(ways, "the new tooltip system") end
    end
    local old = false
    for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
      if type(tooltip) == "table" and tooltip.HookScript then
        local ok = pcall(tooltip.HookScript, tooltip, "OnTooltipSetItem", function(self)
          if not self.GetItem then return end
          local _, link = self:GetItem()
          link = Plain(link)
          local id = type(link) == "string" and strmatch(link, "item:(%d+)") or nil
          if id then Run(self, id, link) end
        end)
        if ok then old = true end
      end
    end
    if old then tinsert(ways, "the old tooltip script") end
    last.hooks = #ways > 0 and table.concat(ways, " and ") or "nothing (this game offers no way)"
  end

  -- A loot roll has started: say so if the item is an upgrade.
  function Advice.Roll(link)
    if not db or db.tips == false then return end
    link = Plain(link)
    if type(link) ~= "string" then return end
    local id = tonumber(strmatch(link, "item:(%d+)"))
    if not id or Wish.Has(id) then return end -- wishlist items already get their own alert
    local verdict, result = Judge(id, link)
    if verdict ~= "up" then return end
    local shown = strmatch(link, "(|c[^|]+|Hitem:[^|]+|h[^|]+|h|r)") or link
    local changes = Changes(result, 3)
    Print("Upgrade for you on this roll: " .. shown .. (changes ~= "" and (" (" .. changes .. ")") or "") .. ". Worth a Need roll.")
  end

  function Advice.ClearMarks()
    for _, mark in ipairs(marks) do mark:Hide() end
    wipe(marks)
  end

  -- Writes a small label on one of the quest reward buttons, if we can find it.
  local function Mark(index, text)
    if not (QuestInfo_GetRewardButton and type(QuestInfoFrame) == "table" and QuestInfoFrame.rewardsFrame) then return end
    local ok, button = pcall(QuestInfo_GetRewardButton, QuestInfoFrame.rewardsFrame, index)
    if not ok or type(button) ~= "table" or not button.CreateFontString then return end
    local mark = rawget(button, "WishwellMark")
    if type(mark) ~= "table" then
      mark = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      mark:SetPoint("BOTTOMRIGHT", -4, 3)
      button.WishwellMark = mark
    end
    mark:SetText(text)
    mark:Show()
    tinsert(marks, mark)
  end

  -- A quest is offering a choice of rewards: point out the best one for this character.
  -- If none improves your gear, say which sells for the most.
  function Advice.QuestRewards()
    Advice.ClearMarks()
    if not db or db.tips == false or not GetNumQuestChoices or not GetQuestItemLink then return end
    local count = Plain(GetNumQuestChoices())
    if type(count) ~= "number" or count < 2 then return end
    local best, bestResult, bestLink, richest, richestPrice, richestLink
    local info = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    for i = 1, count do
      local link = Plain(GetQuestItemLink("choice", i))
      local id = type(link) == "string" and tonumber(strmatch(link, "item:(%d+)")) or nil
      if id then
        local verdict, result = Judge(id, link)
        if verdict == "up" and (not bestResult or result.score > bestResult.score) then
          best, bestResult, bestLink = i, result, link
        end
        if info then
          local ok, _, _, _, _, _, _, _, _, _, _, price = pcall(info, link)
          price = ok and Plain(price) or nil
          if type(price) == "number" and price > 0 and (not richestPrice or price > richestPrice) then
            richest, richestPrice, richestLink = i, price, link
          end
        end
      end
    end
    if best then
      local changes = Changes(bestResult, 3)
      Print("Best reward for you: " .. bestLink .. (changes ~= "" and (" (" .. changes .. ")") or "") .. ".")
      Mark(best, "|cff40ff40Best for you|r")
    elseif richest then
      Print("None of these rewards improves your gear. " .. richestLink .. " sells for the most (" .. Train.Money(richestPrice) .. ").")
      Mark(richest, "|cffffd100Sells best|r")
    end
  end
end

-- ---------------------------------------------------------------------------
-- The quest guide: a small window that walks you through your quests, nearest stop first,
-- saying how far the next one is and which way. A stop is one of:
--   a quest giver with something for you (pick up),
--   what a quest in your log still asks for: a creature to kill, something to collect or use,
--   or whoever a finished quest is handed in to.
-- Where things are comes from world data that the WoW Forever addon does not ship yet, so
-- here it only knows quest givers, and only where Data.questStarts says where they stand.

local Guide = {}
do
  local box
  local route = {}
  local skipped = {}

  -- Where the player is on the map they are on: map id, x, y (0 to 100), or nil.
  local function Me()
    if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then return nil end
    local map = Plain(C_Map.GetBestMapForUnit("player"))
    if type(map) ~= "number" then return nil end
    local ok, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
    if not ok or type(pos) ~= "table" or not pos.GetXY then return nil end
    local x, y = pos:GetXY()
    x, y = Plain(x), Plain(y)
    if type(x) ~= "number" or type(y) ~= "number" or (x == 0 and y == 0) then return nil end
    return map, x * 100, y * 100
  end

  -- A spot on a map in the world's own yards (north, west), or nil if the game will not say.
  local function World(map, x, y)
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local ok, _, pos = pcall(C_Map.GetWorldPosFromMapPos, map, CreateVector2D(x / 100, y / 100))
    if not ok or type(pos) ~= "table" or not pos.GetXY then return nil end
    local north, west = pos:GetXY()
    north, west = Plain(north), Plain(west)
    if type(north) ~= "number" or type(west) ~= "number" then return nil end
    return north, west
  end

  -- The quests in the log: { { id, done, goals = { { text, done }, ... } }, ... }.
  -- goals are the game's own objective lines ("Cabal Initiate slain: 0/2").
  function Guide.Log()
    local list = {}
    local count = GetNumQuestLogEntries and tonumber((GetNumQuestLogEntries())) or 0
    for i = 1, count do
      local id, complete
      if GetQuestLogTitle then
        local _, _, _, isHeader, _, isComplete, _, questId = GetQuestLogTitle(i)
        if not Plain(isHeader) then id, complete = Plain(questId), Plain(isComplete) end
      elseif C_QuestLog and C_QuestLog.GetInfo then
        local ok, info = pcall(C_QuestLog.GetInfo, i)
        if ok and type(info) == "table" and not info.isHeader then id = Plain(info.questID) end
      end
      if type(id) == "number" and id > 0 and complete ~= -1 then
        local done = complete == 1 or complete == true
        if not done and C_QuestLog and C_QuestLog.IsComplete then done = Plain(C_QuestLog.IsComplete(id)) == true end
        local goals = {}
        if C_QuestLog and C_QuestLog.GetQuestObjectives then
          local ok, found = pcall(C_QuestLog.GetQuestObjectives, id)
          if ok and type(found) == "table" then
            for _, goal in ipairs(found) do
              if type(goal) == "table" then
                local text = Plain(goal.text)
                tinsert(goals, { text = type(text) == "string" and text or "", done = Plain(goal.finished) == true })
              end
            end
          end
        elseif GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
          for j = 1, tonumber((GetNumQuestLeaderBoards(i))) or 0 do
            local text, _, finished = GetQuestLogLeaderBoard(j, i)
            text, finished = Plain(text), Plain(finished)
            tinsert(goals, { text = type(text) == "string" and text or "", done = finished == true or finished == 1 })
          end
        end
        tinsert(list, { id = id, done = done, goals = goals })
      end
    end
    return list
  end

  -- Works out the stops and puts them in order: the nearest first, then the nearest to that
  -- one, and so on. Stops on other maps go last. Quests from one giver, or handed in to one
  -- person, share a stop.
  function Guide.Plan()
    wipe(route)
    local zoneId, zoneName = Quests.ZoneHere()
    Guide.zone = zoneName
    local F = Quests.F
    local stops, byKey = {}, {}
    -- kind: "pickup", "kill", "collect", "use" or "turnin". Returns the stop, or nil if skipped.
    local function Stop(kind, who, map, x, y)
      if type(map) ~= "number" or map <= 0 or type(x) ~= "number" or x < 0 then return nil end
      local key = kind .. ":" .. who .. ":" .. map .. ":" .. x .. ":" .. y
      if skipped[key] then return nil end
      local stop = byKey[key]
      if not stop then
        stop = { kind = kind, key = key, giver = who, map = map, x = x, y = y, quests = {}, names = {}, xp = 0 }
        byKey[key] = stop
        tinsert(stops, stop)
      end
      return stop
    end

    -- Quests to pick up in this zone.
    if zoneId then
      for _, row in ipairs((Quests.List(zoneId, true, ""))) do
        if row.state == "open" then
          local giver, map, x, y = MapPin.Start(row.quest[F.ID])
          local stop = giver and Stop("pickup", giver, map, x, y)
          if stop then
            tinsert(stop.quests, row)
            stop.xp = stop.xp + row.xp
          end
        end
      end
    end

    -- What the quests in the log still need, and where the finished ones go.
    local world = Ask.World()
    if world then
      local function MapOf(area)
        local info = world.areas[area]
        return info and info[2] or 0
      end
      for _, entry in ipairs(Guide.Log()) do
        local w, q = world.quests[entry.id], Quests.ById(entry.id)
        if w and q then
          local quest = q[F.NAME]
          -- The game's own line for a target, found by the target's name.
          local function Goal(name)
            local want = strlower(name)
            for _, goal in ipairs(entry.goals) do
              if strfind(strlower(goal.text), want, 1, true) then return goal end
            end
            return nil
          end
          local function Need(stop, goal, what)
            if not stop then return end
            tinsert(stop.names, quest)
            stop.goal = stop.goal or (goal and goal.text ~= "" and goal.text or what)
          end
          if entry.done then
            local stop
            if type(w[1]) == "number" and w[1] > 0 and world.npcs[w[1]] then
              local n = world.npcs[w[1]]
              stop = Stop("turnin", n[1], MapOf(n[4]), n[5], n[6])
            elseif type(w[1]) == "number" and w[1] < 0 and world.objects[-w[1]] then
              local o = world.objects[-w[1]]
              stop = Stop("turnin", o[1], MapOf(o[2]), o[3], o[4])
            end
            if stop then tinsert(stop.names, quest) end
          else
            for _, npcId in ipairs(type(w[2]) == "table" and w[2] or {}) do
              local n = world.npcs[npcId]
              local goal = n and Goal(n[1])
              if n and not (goal and goal.done) then
                local stop = Stop("kill", n[1], MapOf(n[4]), n[5], n[6])
                if stop then stop.spots = n[11] end
                Need(stop, goal, n[1])
              end
            end
            for _, objectId in ipairs(type(w[3]) == "table" and w[3] or {}) do
              local o = world.objects[objectId]
              local goal = o and Goal(o[1])
              if o and not (goal and goal.done) then Need(Stop("use", o[1], MapOf(o[2]), o[3], o[4]), goal, o[1]) end
            end
            for _, itemId in ipairs(type(w[4]) == "table" and w[4] or {}) do
              local item = world.items[itemId]
              local goal = item and Goal(item[1])
              if item and not (goal and goal.done) then
                -- Where it comes from: whoever drops it, else what it is found in, else who sells it.
                local stop
                local dropper = type(item[4]) == "table" and world.npcs[item[4][1]] or nil
                local holder = type(item[8]) == "table" and world.objects[item[8][1]] or nil
                local seller = type(item[6]) == "table" and world.npcs[item[6][1]] or nil
                if dropper then
                  stop = Stop("collect", dropper[1], MapOf(dropper[4]), dropper[5], dropper[6])
                  if stop then stop.spots = dropper[11] end
                elseif holder then
                  stop = Stop("collect", holder[1], MapOf(holder[2]), holder[3], holder[4])
                elseif seller then
                  stop = Stop("collect", seller[1], MapOf(seller[4]), seller[5], seller[6])
                  if stop then stop.sold = true end
                end
                Need(stop, goal, item[1])
              end
            end
          end
        end
      end
    end

    local map, cx, cy = Me()
    while #stops > 0 do
      local best, bestD
      for i, stop in ipairs(stops) do
        -- Maps are wider than they are tall, so a step north or south counts for less.
        local d = (map and stop.map == map) and ((stop.x - cx) ^ 2 + ((stop.y - cy) * 0.67) ^ 2) or (1e9 - stop.xp)
        if not bestD or d < bestD then best, bestD = i, d end
      end
      local stop = tremove(stops, best)
      if map and stop.map == map then cx, cy = stop.x, stop.y end
      tinsert(route, stop)
    end
    return route
  end

  -- How far the stop is and which way: yards (or nil), and the angle to turn the arrow by
  -- (or nil), anticlockwise from straight ahead.
  function Guide.Bearing(stop)
    local map, px, py = Me()
    if not map then return nil end
    local north, west
    local pn, pw = World(map, px, py)
    local tn, tw = World(stop.map, stop.x, stop.y)
    local yards
    if pn and tn then
      north, west = tn - pn, tw - pw
      yards = math.sqrt(north * north + west * west)
    elseif stop.map == map then
      north, west = -(stop.y - py), -(stop.x - px) * 1.5
    else
      return nil
    end
    local facing = GetPlayerFacing and Plain(GetPlayerFacing()) or nil
    if type(facing) ~= "number" then return yards, nil end
    local turn = (math.atan2 or math.atan)(west, north) - facing
    while turn > math.pi do turn = turn - 2 * math.pi end
    while turn <= -math.pi do turn = turn + 2 * math.pi end
    return yards, turn
  end

  local function Way(turn)
    local a = math.abs(turn)
    if a < math.pi / 4 then return "ahead" end
    if a > math.pi * 3 / 4 then return "behind you" end
    return turn > 0 and "to your left" or "to your right"
  end

  local function Tick()
    local stop = route[1]
    if not box or not stop then return end
    local yards, turn = Guide.Bearing(stop)
    local parts = {}
    -- Something that roams is "here" from further off than someone standing still.
    local roams = (stop.spots or 1) > 1
    local here = yards ~= nil and yards < (roams and 45 or 12)
    if yards then
      tinsert(parts, here and (roams and "|cff40ff40They are around here|r" or "|cff40ff40You are here|r") or ("|cffffffff" .. Quests.Number(yards) .. "|r yd"))
    end
    if turn and not here then tinsert(parts, Way(turn)) end
    if #parts == 0 then
      local name
      if C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, stop.map)
        name = ok and type(info) == "table" and Plain(info.name) or nil
      end
      tinsert(parts, type(name) == "string" and ("in " .. name) or "on another map")
    end
    box.dist:SetText(table.concat(parts, "  ·  "))
    box.arrow:SetShown(turn ~= nil and not here)
    if turn and box.arrow.SetRotation then box.arrow:SetRotation(turn) end
  end

  local function Build()
    if box then return end
    local template = BackdropTemplateMixin and "BackdropTemplate" or nil
    box = CreateFrame("Frame", "WishwellGuide", UIParent, template)
    box:SetSize(320, 188)
    box:SetPoint("RIGHT", UIParent, "RIGHT", -220, 60)
    box:SetFrameStrata("MEDIUM")
    MakeBackdrop(box)
    if box.SetBackdropBorderColor then box:SetBackdropBorderColor(0.9, 0.72, 0.25, 1) end
    box:SetMovable(true)
    box:EnableMouse(true)
    box:RegisterForDrag("LeftButton")
    box:SetScript("OnDragStart", box.StartMoving)
    box:SetScript("OnDragStop", box.StopMovingOrSizing)
    if box.SetClampedToScreen then box:SetClampedToScreen(true) end
    box:Hide()

    box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    box.title:SetPoint("TOPLEFT", 14, -12)
    box.count = box:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    box.count:SetPoint("TOPRIGHT", -34, -15)
    local close = CreateFrame("Button", nil, box, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 2, 2)
    close:SetScript("OnClick", function() Guide.Show(false) end)
    box.line = box:CreateTexture(nil, "ARTWORK")
    box.line:SetPoint("TOPLEFT", 12, -36)
    box.line:SetPoint("TOPRIGHT", -12, -36)
    box.line:SetHeight(1)
    if box.line.SetColorTexture then box.line:SetColorTexture(0.9, 0.72, 0.25, 0.5) end

    box.arrow = box:CreateTexture(nil, "ARTWORK")
    box.arrow:SetSize(40, 40)
    box.arrow:SetPoint("TOPLEFT", 12, -44)
    box.arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
    box.giver = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    box.giver:SetPoint("TOPLEFT", 60, -44)
    box.giver:SetPoint("RIGHT", -12, 0)
    box.giver:SetJustifyH("LEFT")
    box.giver:SetWordWrap(false)
    box.dist = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    box.dist:SetPoint("TOPLEFT", box.giver, "BOTTOMLEFT", 0, -4)
    box.quests = box:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    box.quests:SetPoint("TOPLEFT", 14, -92)
    box.quests:SetWidth(292)
    box.quests:SetJustifyH("LEFT")
    if box.quests.SetSpacing then box.quests:SetSpacing(2) end

    local function Button(text, width, onClick)
      local btn = UI.MakeButton(nil, box)
      btn:SetSize(width, 22)
      btn:SetText(text)
      btn:SetScript("OnClick", onClick)
      return btn
    end
    box.skip = Button("Skip", 70, function()
      local stop = route[1]
      if not stop then return end
      skipped[stop.key] = true
      Guide.Refresh()
    end)
    box.skip:SetPoint("BOTTOMRIGHT", -10, 10)
    box.map = Button("Map", 70, function()
      local stop = route[1]
      if stop then MapPin.Show({ stop.giver, stop.map, stop.x, stop.y }, stop.giver) end
    end)
    box.map:SetPoint("RIGHT", box.skip, "LEFT", -4, 0)
    box.all = Button("Quest list", 90, function() Wishwell_Toggle("quests") end)
    box.all:SetPoint("BOTTOMLEFT", 10, 10)

    box.clock = 0
    box:SetScript("OnUpdate", function(self, elapsed)
      self.clock = self.clock + (tonumber(elapsed) or 0)
      if self.clock < 0.15 then return end
      self.clock = 0
      Tick()
    end)
    Guide.box = box
  end

  -- What a stop asks of you, in a word.
  local KIND = {
    pickup = "|cffffd100Pick up|r", kill = "|cffff7070Kill|r", collect = "|cffff7070Collect|r",
    use = "|cffff7070Use|r", turnin = "|cff40ff40Hand in|r",
  }

  -- Plans the route again and redraws the window.
  function Guide.Refresh()
    if not box or not box:IsShown() then return end
    Guide.Plan()
    local F = Quests.F
    local stop = route[1]
    box.title:SetText(Guide.zone and (gsub(Guide.zone, "^%l", string.upper)) or "Quest guide")
    if not stop then
      box.count:SetText("")
      box.giver:SetText("Nothing to do here")
      box.dist:SetText("")
      box.arrow:Hide()
      box.quests:SetText(next(skipped) and "You have done, or skipped, every stop Wishwell knows of here. Close and reopen the guide to see the skipped ones again."
        or "Nothing to pick up, do or hand in that Wishwell knows of. Try another zone: the Quests tab shows where the most XP is waiting.")
      box.skip:Hide()
      box.map:Hide()
      return
    end
    box.count:SetText(#route .. " stop" .. (#route == 1 and "" or "s") .. " left")
    box.giver:SetText(stop.giver)
    local lines = {}
    if stop.kind == "pickup" then
      tinsert(lines, KIND.pickup)
      for i = 1, math.min(#stop.quests, 3) do
        local row = stop.quests[i]
        tinsert(lines, "|cffffd100[" .. row.quest[F.LEVEL] .. "]|r " .. row.quest[F.NAME] .. "  |cff999999" .. Quests.Number(row.xp) .. " XP|r")
      end
      if #stop.quests > 3 then tinsert(lines, "|cff999999and " .. (#stop.quests - 3) .. " more|r") end
    else
      local quests = table.concat(stop.names, ", ", 1, math.min(#stop.names, 3)) .. (#stop.names > 3 and (" and " .. (#stop.names - 3) .. " more") or "")
      if stop.kind == "turnin" then
        tinsert(lines, KIND.turnin .. "  " .. quests)
      else
        tinsert(lines, KIND[stop.kind] .. "  " .. (stop.goal or stop.giver))
        if stop.kind == "collect" then
          tinsert(lines, "|cff999999" .. (stop.sold and "sold by " or "from ") .. stop.giver .. "|r")
        end
        tinsert(lines, "|cff999999for|r " .. quests)
        if (stop.spots or 1) > 1 then
          tinsert(lines, "|cff999999Roams " .. stop.spots .. " spots; the arrow points at the middle.|r")
        end
      end
    end
    box.quests:SetText(table.concat(lines, "\n"))
    box.skip:Show()
    box.map:Show()
    Tick()
  end

  -- A moment later, once the game has caught up with a quest being taken or a zone changing.
  function Guide.Soon()
    if not box or not box:IsShown() or Guide.waiting then return end
    Guide.waiting = true
    After(1.2, function()
      Guide.waiting = false
      Guide.Refresh()
    end)
  end

  function Guide.Show(on)
    Build()
    if on == nil then on = not box:IsShown() end
    db.guide = on and true or nil
    if on then
      wipe(skipped)
      box:Show()
      Guide.Refresh()
    else
      box:Hide()
    end
  end
end
UI.Guide = Guide

-- The wishlist tracker: a small list of your wishlist that stays on screen while you play,
-- like the quest tracker. Drag it anywhere; it remembers where. What drops in the raid or
-- dungeon you are standing in comes first. db.tracker = false switches it off.

local Tracker = {}
do
  local box
  local LINES = 8

  local function Build()
    box = CreateFrame("Frame", "WishwellTracker", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    box:SetSize(240, 40)
    box:SetFrameStrata("LOW")
    local at = db.trackerAt
    if type(at) == "table" and type(at[1]) == "string" then
      box:SetPoint(at[1], UIParent, type(at[2]) == "string" and at[2] or at[1], tonumber(at[3]) or 0, tonumber(at[4]) or 0)
    else
      box:SetPoint("RIGHT", UIParent, "RIGHT", -60, -140)
    end
    MakeBackdrop(box, 10)
    if box.SetBackdropColor then
      box:SetBackdropColor(0.05, 0.05, 0.07, 0.72)
      box:SetBackdropBorderColor(0.80, 0.64, 0.26, 0.55)
    end
    box:SetMovable(true)
    box:EnableMouse(true)
    box:RegisterForDrag("LeftButton")
    if box.SetClampedToScreen then box:SetClampedToScreen(true) end
    local function Drag() box:StartMoving() end
    local function Drop()
      box:StopMovingOrSizing()
      local point, _, relative, x, y = box:GetPoint(1)
      if type(point) == "string" then db.trackerAt = { point, relative, x, y } end
    end
    box:SetScript("OnDragStart", Drag)
    box:SetScript("OnDragStop", Drop)
    box:Hide()

    box.icon = box:CreateTexture(nil, "ARTWORK")
    box.icon:SetSize(24, 24)
    box.icon:SetPoint("TOPLEFT", 8, -6)
    box.icon:SetTexture(ART .. "WispIcon.tga", nil, nil, "NEAREST")
    box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    box.title:SetPoint("LEFT", box.icon, "RIGHT", 6, 0)
    box.title:SetText("Wishlist")
    box.count = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    box.count:SetPoint("LEFT", box.title, "RIGHT", 6, 0)

    -- Fold it down to its heading, or put it away.
    local function Corner(name, text, x, tip, onClick)
      local btn = CreateFrame("Button", name, box)
      btn:SetSize(18, 18)
      btn:SetPoint("TOPRIGHT", x, -8)
      btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      btn.text:SetPoint("CENTER")
      btn.text:SetText(text)
      btn:SetScript("OnClick", onClick)
      btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(tip)
        GameTooltip:Show()
      end)
      btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
      return btn
    end
    box.fold = Corner("WishwellTrackerFold", "-", -28, "Fold or unfold the list", function()
      db.trackerFolded = not db.trackerFolded or nil
      Tracker.Refresh()
    end)
    box.close = Corner("WishwellTrackerClose", "x", -8, "Put the tracker away", function()
      Tracker.Show(false)
      Print("Wishlist tracker put away. /ww tracker brings it back, and so does Settings.")
    end)

    box.lines = {}
    for i = 1, LINES do
      local line = CreateFrame("Button", nil, box)
      line:SetSize(224, 30)
      line:SetPoint("TOPLEFT", 8, -34 - (i - 1) * 32)
      if line.SetHighlightTexture then pcall(line.SetHighlightTexture, line, "Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD") end
      line.icon = line:CreateTexture(nil, "ARTWORK")
      line.icon:SetSize(26, 26)
      line.icon:SetPoint("LEFT", 0, 0)
      line.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      line.name = line:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      line.name:SetPoint("TOPLEFT", line.icon, "TOPRIGHT", 6, 0)
      line.name:SetWidth(190)
      line.name:SetJustifyH("LEFT")
      line.name:SetWordWrap(false)
      line.meta = line:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      line.meta:SetPoint("TOPLEFT", line.name, "BOTTOMLEFT", 0, -2)
      line.meta:SetWidth(190)
      line.meta:SetJustifyH("LEFT")
      line.meta:SetWordWrap(false)
      -- Hover for the item; click to open the wishlist; shift-click to link it in chat.
      line:SetScript("OnEnter", function(self)
        if not self.id then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. self.id)
        GameTooltip:Show()
      end)
      line:SetScript("OnLeave", function() GameTooltip:Hide() end)
      line:SetScript("OnClick", function(self)
        if self.id and IsShiftKeyDown and IsShiftKeyDown() and UI.LinkToChat(self.id) then return end
        Wishwell_Toggle("wish")
      end)
      line:RegisterForDrag("LeftButton")
      line:SetScript("OnDragStart", Drag)
      line:SetScript("OnDragStop", Drop)
      box.lines[i] = line
    end
    box.more = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    Tracker.box = box
  end

  -- Shows what is on the wishlist now. Cheap to call; called whenever the list might have changed.
  function Tracker.Refresh()
    if not db then return end
    local ids = Wish.Ids()
    local want = db.tracker ~= false and #ids > 0
    if not box then
      if not want then return end
      Build()
    end
    box:SetShown(want)
    if not want then return end
    local here = Watch.Here and Watch.Here() or nil
    local list = {}
    for order, id in ipairs(ids) do
      local place = Wish.From(id)
      local row = Items.Row(id, place)
      tinsert(list, { id = id, row = row, here = here ~= nil and place == here, order = order })
    end
    table.sort(list, function(a, b)
      if a.here ~= b.here then return a.here end
      return a.order < b.order
    end)
    box.count:SetText("(" .. #list .. ")")
    box.fold.text:SetText(db.trackerFolded and "+" or "-")
    local shown = db.trackerFolded and 0 or math.min(#list, LINES)
    for i = 1, LINES do
      local line = box.lines[i]
      local entry = list[i]
      if i <= shown and entry then
        local row = entry.row
        line.id = entry.id
        line.icon:SetTexture(Items.Icon(entry.id))
        local r, g, b = Items.QualityColor(Items.Quality(row))
        line.name:SetText(row.name or Items.Name(entry.id) or "Loading...")
        line.name:SetTextColor(r, g, b)
        local parts = {}
        if entry.here then tinsert(parts, "|cff40ff40Drops here|r") end
        if row.boss and not row.custom then tinsert(parts, row.boss) end
        if row.raid and row.raid ~= "" and not entry.here then tinsert(parts, Places.Name(row.raid)) end
        local rate = Items.RateText(row)
        if rate then tinsert(parts, rate) end
        line.meta:SetText(table.concat(parts, " · "))
        line:Show()
      else
        line.id = nil
        line:Hide()
      end
    end
    local hidden = db.trackerFolded and 0 or (#list - shown)
    if hidden > 0 then
      box.more:ClearAllPoints()
      box.more:SetPoint("BOTTOMLEFT", 10, 8)
      box.more:SetText("and " .. hidden .. " more. Click one to see them all.")
      box.more:Show()
    else
      box.more:Hide()
    end
    box:SetHeight(36 + shown * 32 + (hidden > 0 and 18 or 0) + (shown > 0 and 4 or 0))
  end

  -- A moment later: for when the game has only just learned an item's name.
  function Tracker.Soon()
    if Tracker.waiting or not box or not box:IsShown() then return end
    Tracker.waiting = true
    After(0.6, function()
      Tracker.waiting = false
      Tracker.Refresh()
    end)
  end

  function Tracker.Show(on)
    if on == nil then on = db.tracker == false end
    db.tracker = on and true or false
    Tracker.Refresh()
  end
end
UI.Tracker = Tracker

-- ---------------------------------------------------------------------------
-- Pinned recipes. With a profession window open the wisp sits by its corner with a "Pin recipe"
-- button. A pinned recipe stays on screen, with how many of each material you have and need,
-- after the window is closed: for shopping at the auction house without it open.
-- db.pins[character] = { { name, icon, make, reagents = { { id, name, icon, count }, ... } }, ... }

local Pins = {}
do
  local box, prompt
  local MAX_PINS = 6
  local HEADS, LINES = 6, 30

  local function Mine()
    if type(db.pins) ~= "table" then db.pins = {} end
    local key = Chars.Key()
    if type(db.pins[key]) ~= "table" then db.pins[key] = {} end
    return db.pins[key]
  end

  local function Count(id)
    local fn = (C_Item and C_Item.GetItemCount) or GetItemCount
    if not fn then return 0 end
    local ok, n = pcall(fn, id)
    return ok and tonumber(Plain(n)) or 0
  end

  -- The recipe open in the profession window: the same shape as a pin, or nil.
  function Pins.Selected()
    local api = C_TradeSkillUI
    if not api or not api.GetRecipeInfo then return nil end
    local id
    local page = type(ProfessionsFrame) == "table" and ProfessionsFrame.CraftingPage or nil
    local form = type(page) == "table" and page.SchematicForm or nil
    if type(form) == "table" then
      local info = form.currentRecipeInfo
      if type(info) ~= "table" and form.GetRecipeInfo then
        local ok, got = pcall(form.GetRecipeInfo, form)
        info = ok and got or nil
      end
      id = type(info) == "table" and Plain(info.recipeID) or nil
    end
    -- The older style of window keeps it on its recipe list.
    if type(id) ~= "number" and type(TradeSkillFrame) == "table" then
      local list = TradeSkillFrame.RecipeList
      if type(list) == "table" and list.GetSelectedRecipeID then
        local ok, got = pcall(list.GetSelectedRecipeID, list)
        id = ok and Plain(got) or nil
      end
      if type(id) ~= "number" then id = Plain(TradeSkillFrame.selectedSkill) end
    end
    if type(id) ~= "number" or id <= 0 then return nil end
    local ok, recipe = pcall(api.GetRecipeInfo, id)
    if not ok or type(recipe) ~= "table" or type(Plain(recipe.name)) ~= "string" then return nil end
    local pin = { name = Plain(recipe.name), icon = Plain(recipe.icon), make = 1, reagents = {} }
    if api.GetRecipeSchematic then
      local fine, schematic = pcall(api.GetRecipeSchematic, id, false)
      if fine and type(schematic) == "table" and type(schematic.reagentSlotSchematics) == "table" then
        for _, slot in ipairs(schematic.reagentSlotSchematics) do
          local first = type(slot) == "table" and type(slot.reagents) == "table" and slot.reagents[1] or nil
          local itemId = type(first) == "table" and Plain(first.itemID) or nil
          local need = type(slot) == "table" and Plain(slot.quantityRequired) or nil
          if type(itemId) == "number" and type(need) == "number" and need > 0 and Plain(slot.required) ~= false then
            tinsert(pin.reagents, { id = itemId, name = Items.Name(itemId), count = need })
          end
        end
      end
    elseif api.GetRecipeNumReagents and api.GetRecipeReagentItemLink then
      for r = 1, tonumber(Plain(api.GetRecipeNumReagents(id))) or 0 do
        local link = Plain(api.GetRecipeReagentItemLink(id, r))
        local itemId = type(link) == "string" and tonumber(strmatch(link, "item:(%d+)")) or nil
        local need = 1
        if api.GetRecipeReagentInfo then
          local _, _, count = api.GetRecipeReagentInfo(id, r)
          need = tonumber(Plain(count)) or 1
        end
        if itemId then tinsert(pin.reagents, { id = itemId, name = strmatch(link, "%[(.-)%]"), count = need }) end
      end
    end
    return pin
  end

  -- Pins the selected recipe. Says why if it cannot.
  function Pins.PinSelected()
    local pin = Pins.Selected()
    if not pin then
      Print("Click a recipe in the list first, then Pin recipe.")
      return false
    end
    local mine = Mine()
    for _, have in ipairs(mine) do
      if have.name == pin.name then
        Print(pin.name .. " is already pinned.")
        db.pinsHidden = nil
        Pins.Refresh()
        return false
      end
    end
    if #mine >= MAX_PINS then
      Print("That's " .. MAX_PINS .. " recipes pinned already. Unpin one first (the x beside it).")
      return false
    end
    tinsert(mine, pin)
    db.pinsHidden = nil
    Pins.Refresh()
    Print("Pinned " .. pin.name .. ". It stays on screen when you close this window. Drag it wherever you like.")
    return true
  end

  local function Build()
    box = CreateFrame("Frame", "WishwellPins", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    box:SetSize(250, 40)
    box:SetFrameStrata("MEDIUM")
    local at = db.pinsAt
    if type(at) == "table" and type(at[1]) == "string" then
      box:SetPoint(at[1], UIParent, type(at[2]) == "string" and at[2] or at[1], tonumber(at[3]) or 0, tonumber(at[4]) or 0)
    else
      box:SetPoint("LEFT", UIParent, "LEFT", 60, 60)
    end
    MakeBackdrop(box, 10)
    if box.SetBackdropColor then
      box:SetBackdropColor(0.05, 0.05, 0.07, 0.80)
      box:SetBackdropBorderColor(0.80, 0.64, 0.26, 0.55)
    end
    box:SetMovable(true)
    box:EnableMouse(true)
    box:RegisterForDrag("LeftButton")
    if box.SetClampedToScreen then box:SetClampedToScreen(true) end
    local function Drag() box:StartMoving() end
    local function Drop()
      box:StopMovingOrSizing()
      local point, _, relative, x, y = box:GetPoint(1)
      if type(point) == "string" then db.pinsAt = { point, relative, x, y } end
    end
    box:SetScript("OnDragStart", Drag)
    box:SetScript("OnDragStop", Drop)
    box:Hide()
    box.icon = box:CreateTexture(nil, "ARTWORK")
    box.icon:SetSize(24, 24)
    box.icon:SetPoint("TOPLEFT", 8, -6)
    box.icon:SetTexture(ART .. "WispIcon.tga", nil, nil, "NEAREST")
    box.title = box:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    box.title:SetPoint("LEFT", box.icon, "RIGHT", 6, 0)
    box.title:SetText("Pinned recipes")

    local function Small(parent, text, tip, onClick)
      local btn = CreateFrame("Button", nil, parent)
      btn:SetSize(16, 16)
      btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      btn.text:SetPoint("CENTER")
      btn.text:SetText(text)
      btn:SetScript("OnClick", onClick)
      btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(tip)
        GameTooltip:Show()
      end)
      btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
      return btn
    end
    box.close = Small(box, "x", "Put the pinned recipes away. /ww pins brings them back.", function()
      db.pinsHidden = true
      Pins.Refresh()
      Print("Pinned recipes put away. /ww pins brings them back.")
    end)
    box.close:SetPoint("TOPRIGHT", -8, -9)

    -- A heading for each recipe: its icon and name, how many to make, and a way to unpin it.
    box.heads = {}
    for i = 1, HEADS do
      local head = CreateFrame("Frame", nil, box)
      head:SetSize(234, 22)
      head.icon = head:CreateTexture(nil, "ARTWORK")
      head.icon:SetSize(20, 20)
      head.icon:SetPoint("LEFT", 0, 0)
      head.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      head.name = head:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      head.name:SetPoint("LEFT", head.icon, "RIGHT", 6, 0)
      head.name:SetWidth(134)
      head.name:SetJustifyH("LEFT")
      head.name:SetWordWrap(false)
      head.drop = Small(head, "x", "Unpin this recipe", function()
        local mine = Mine()
        if head.index and mine[head.index] then tremove(mine, head.index) end
        Pins.Refresh()
      end)
      head.drop:SetPoint("RIGHT", 0, 0)
      head.more = Small(head, "+", "Make one more", function()
        local pin = head.index and Mine()[head.index]
        if pin then pin.make = math.min(99, (pin.make or 1) + 1) end
        Pins.Refresh()
      end)
      head.more:SetPoint("RIGHT", head.drop, "LEFT", -4, 0)
      head.count = head:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      head.count:SetPoint("RIGHT", head.more, "LEFT", -2, 0)
      head.fewer = Small(head, "-", "Make one fewer", function()
        local pin = head.index and Mine()[head.index]
        if pin then pin.make = math.max(1, (pin.make or 1) - 1) end
        Pins.Refresh()
      end)
      head.fewer:SetPoint("RIGHT", head.count, "LEFT", -2, 0)
      box.heads[i] = head
    end
    -- A line for each material: how many you have of how many you need.
    box.lines = {}
    for i = 1, LINES do
      local line = CreateFrame("Button", nil, box)
      line:SetSize(224, 18)
      if line.SetHighlightTexture then pcall(line.SetHighlightTexture, line, "Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD") end
      line.icon = line:CreateTexture(nil, "ARTWORK")
      line.icon:SetSize(16, 16)
      line.icon:SetPoint("LEFT", 0, 0)
      line.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      line.text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      line.text:SetPoint("LEFT", line.icon, "RIGHT", 6, 0)
      line.text:SetWidth(198)
      line.text:SetJustifyH("LEFT")
      line.text:SetWordWrap(false)
      line:SetScript("OnEnter", function(self)
        if not self.id then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. self.id)
        GameTooltip:AddLine("Click to put its name in the box you are typing in, such as the auction house search.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
      end)
      line:SetScript("OnLeave", function() GameTooltip:Hide() end)
      line:SetScript("OnClick", function(self)
        if self.id then UI.LinkToChat(self.id) end
      end)
      line:RegisterForDrag("LeftButton")
      line:SetScript("OnDragStart", Drag)
      line:SetScript("OnDragStop", Drop)
      box.lines[i] = line
    end
    Pins.box = box
  end

  -- Redraws the pinned recipes with what is in the bags now.
  function Pins.Refresh()
    if not db then return end
    local mine = Mine()
    local want = #mine > 0 and not db.pinsHidden
    if not box then
      if not want then return end
      Build()
    end
    box:SetShown(want)
    if not want then return end
    local y, used = 34, 0
    for i = 1, HEADS do
      local head = box.heads[i]
      local pin = mine[i]
      if pin then
        local make = pin.make or 1
        local ready = true
        local first = used + 1
        for _, reagent in ipairs(pin.reagents) do
          if used < LINES then
            used = used + 1
            local line = box.lines[used]
            local have, need = Count(reagent.id), (reagent.count or 1) * make
            if have < need then ready = false end
            line.id = reagent.id
            line.icon:SetTexture(reagent.icon or Items.Icon(reagent.id))
            line.text:SetText((have >= need and "|cff40ff40" or "|cffff7070") .. have .. "/" .. need .. "|r  " .. (reagent.name or Items.Name(reagent.id) or ("item " .. reagent.id)))
          end
        end
        head.index = i
        head.icon:SetTexture(pin.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        head.name:SetText(pin.name)
        head.name:SetTextColor(ready and 0.25 or 1, ready and 1 or 0.82, ready and 0.25 or 0)
        head.count:SetText("x" .. make)
        head:ClearAllPoints()
        head:SetPoint("TOPLEFT", 8, -y)
        head:Show()
        y = y + 24
        for n = first, used do
          local line = box.lines[n]
          line:ClearAllPoints()
          line:SetPoint("TOPLEFT", 18, -y)
          line:Show()
          y = y + 19
        end
        y = y + 6
      else
        head.index = nil
        head:Hide()
      end
    end
    for n = used + 1, LINES do
      box.lines[n].id = nil
      box.lines[n]:Hide()
    end
    box:SetHeight(y + 4)
  end

  -- The wisp and its button, by the corner of the profession window that has just opened.
  function Pins.Prompt()
    if not db or db.pinPrompt == false then return end
    local host = (type(ProfessionsFrame) == "table" and ProfessionsFrame.IsShown and ProfessionsFrame:IsShown() and ProfessionsFrame)
      or (type(TradeSkillFrame) == "table" and TradeSkillFrame.IsShown and TradeSkillFrame:IsShown() and TradeSkillFrame) or nil
    if not prompt then
      prompt = CreateFrame("Frame", "WishwellPinPrompt", UIParent)
      prompt:SetSize(140, 30)
      prompt:SetFrameStrata("HIGH")
      prompt.wisp = prompt:CreateTexture(nil, "ARTWORK")
      prompt.wisp:SetSize(30, 30)
      prompt.wisp:SetPoint("LEFT", 0, 0)
      prompt.wisp:SetTexture(ART .. "WispIcon.tga", nil, nil, "NEAREST")
      prompt.pin = UI.MakeButton("WishwellPinButton", prompt)
      prompt.pin:SetSize(104, 24)
      prompt.pin:SetPoint("LEFT", prompt.wisp, "RIGHT", 4, 0)
      prompt.pin:SetText("Pin recipe")
      prompt.pin:SetScript("OnClick", function() Pins.PinSelected() end)
      prompt.pin:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Pin recipe")
        GameTooltip:AddLine("Keeps the recipe you have selected on screen, with how many of each material you have and need, after you close this window. Handy at the auction house.", 1, 1, 1, true)
        GameTooltip:Show()
      end)
      prompt.pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
      -- A gentle bob, so it reads as the wisp and not part of the window.
      prompt.clock = 0
      prompt:SetScript("OnUpdate", function(self, elapsed)
        self.clock = self.clock + (tonumber(elapsed) or 0)
        self.wisp:ClearAllPoints()
        self.wisp:SetPoint("LEFT", 0, math.sin(self.clock * 2.2) * 2)
      end)
    end
    -- Riding on the profession window, it goes away when that closes.
    prompt:SetParent(host or UIParent)
    prompt:ClearAllPoints()
    if host then
      prompt:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", -4, 2)
    else
      prompt:SetPoint("TOP", UIParent, "TOP", 0, -120)
    end
    prompt:Show()
    Toast.Tip("pins", "Pin recipe, above the profession window, keeps a recipe and its materials on screen after you close the window. Handy at the auction house.")
  end

  function Pins.Toggle()
    db.pinsHidden = not db.pinsHidden or nil
    Pins.Refresh()
    return not db.pinsHidden
  end
end
UI.Pins = Pins

-- Minimap button, events, slash commands

local minimapButton

local function PlaceMinimapButton()
  local angle = math.rad(db.minimapAngle or 190)
  -- Sit just outside the minimap's rim, whatever size the minimap is in this game.
  local width = tonumber(Minimap:GetWidth()) or 140
  local radius = width / 2 + 12
  minimapButton:ClearAllPoints()
  minimapButton:SetPoint("CENTER", Minimap, "CENTER", radius * math.cos(angle), radius * math.sin(angle))
end

local function SetupMinimapButton()
  if minimapButton or not Minimap then return end
  -- Minimap addons (SexyMap, HidingBar and the like) only look after buttons made through
  -- LibDBIcon, which most addons carry. Use it when it is there; otherwise make our own.
  local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
  local dbIcon = LibStub and LibStub("LibDBIcon-1.0", true)
  if ldb and dbIcon then
    local ok = pcall(function()
      if type(db.minimapIcon) ~= "table" then db.minimapIcon = {} end
      db.minimapIcon.hide = db.minimapHidden and true or false
      local launcher = ldb:NewDataObject("Wishwell", {
        type = "launcher",
        text = "Wishwell Forever",
        icon = "Interface\\Icons\\INV_Misc_Note_02",
        OnClick = function() Wishwell_Toggle() end,
        OnTooltipShow = function(tip)
          tip:AddLine("Wishwell Forever")
          tip:AddLine("Click to open. Drag to move.", 1, 1, 1)
        end,
      })
      dbIcon:Register("Wishwell", launcher, db.minimapIcon)
    end)
    if ok then
      minimapButton = {
        SetShown = function(_, shown)
          db.minimapIcon.hide = not shown
          if shown then dbIcon:Show("Wishwell") else dbIcon:Hide("Wishwell") end
        end,
      }
      Settings.onMinimap = function() minimapButton:SetShown(not db.minimapHidden) end
      return
    end
  end
  local btn = CreateFrame("Button", "WishwellMinimapButton", Minimap)
  minimapButton = btn
  btn:SetSize(31, 31)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local icon = btn:CreateTexture(nil, "ARTWORK")
  icon:SetSize(20, 20)
  icon:SetPoint("TOPLEFT", 7, -5)
  icon:SetTexture("Interface\\Icons\\INV_Misc_Note_02")
  icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  local border = btn:CreateTexture(nil, "OVERLAY")
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetSize(53, 53)
  border:SetPoint("TOPLEFT")
  btn:RegisterForDrag("LeftButton")
  btn:SetScript("OnClick", function() Wishwell_Toggle() end)
  btn:SetScript("OnDragStart", function(self)
    self:SetScript("OnUpdate", function()
      local mx, my = Minimap:GetCenter()
      local cx, cy = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      db.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
      PlaceMinimapButton()
    end)
  end)
  btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
  btn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Wishwell Forever")
    GameTooltip:AddLine("Click to open. Drag to move.", 1, 1, 1)
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  PlaceMinimapButton()
  btn:SetShown(not db.minimapHidden)
  Settings.onMinimap = function() btn:SetShown(not db.minimapHidden) end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")
for _, name in ipairs({
  "CHAT_MSG_ADDON", "ENCOUNTER_END", "BOSS_KILL", "LOOT_OPENED", "START_LOOT_ROLL", "CHAT_MSG_LOOT",
  "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "GET_ITEM_INFO_RECEIVED",
  "TRAINER_SHOW", "TRAINER_UPDATE", "TRAINER_CLOSED", "PLAYER_LEVEL_UP", "PLAYER_EQUIPMENT_CHANGED",
  "QUEST_TURNED_IN", "QUEST_ACCEPTED", "QUEST_REMOVED", "QUEST_COMPLETE", "QUEST_FINISHED", "QUEST_LOG_UPDATE",
  "PLAYER_MONEY", "GROUP_ROSTER_UPDATE", "PLAYER_XP_UPDATE", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
  "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE", "SKILL_LINES_CHANGED", "BAG_UPDATE_DELAYED",
  "CHARACTER_POINTS_CHANGED",
}) do
  pcall(events.RegisterEvent, events, name)
end

local redrawPending = false

events:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5)
  if strsub(event, 1, 6) == "QUEST_" or event == "PLAYER_LEVEL_UP" or event == "PLAYER_ENTERING_WORLD" then Quests.Fresh() end
  if event == "ADDON_LOADED" then
    if arg1 ~= "Wishwell" then return end
    local firstRun = WishwellDB == nil
    WishwellDB = WishwellDB or {}
    db = WishwellDB
    if firstRun then db.newsSeen = VERSION end
    -- Raids and dungeons added in game come back before anything checks place ids.
    local saved = type(db.madeUp) == "table" and db.madeUp or {}
    db.madeUp = {}
    for id, row in pairs(saved) do
      if type(id) == "string" and strmatch(id, "^m%d+$") and type(row) == "table" then
        local real = Places.ByMap(tonumber(strsub(id, 2)))
        if real then
          -- An older version did not recognise this dungeon and filed it as a new place.
          -- Move what it learned there to the real one.
          for _, key in ipairs({ "learned", "kills", "seen" }) do
            local all = db[key]
            if type(all) == "table" and type(all[id]) == "table" then
              if type(all[real]) ~= "table" then all[real] = {} end
              for k, v in pairs(all[id]) do
                if all[real][k] == nil then all[real][k] = v end
              end
              all[id] = nil
            end
          end
          if type(db.wish) == "table" then
            for _, list in pairs(db.wish) do
              if type(list) == "table" then
                for item, place in pairs(list) do
                  if place == id then list[item] = real end
                end
              end
            end
          end
          if db.browseId == id then db.browseId = real end
        else
          local name = CleanLabel(row.name)
          if name then Places.Add(id, name, row.kind == "raid" and "raid" or "dungeon") end
        end
      end
    end
    if type(db.learned) ~= "table" then db.learned = {} end
    for id, list in pairs(db.learned) do
      if type(list) ~= "table" or not Places.Known(id) then db.learned[id] = nil end
    end
    if type(db.wish) ~= "table" then db.wish = {} end
    if not Places.Known(db.browseId) then db.browseId = Data.instances[1] and Data.instances[1].id end
    if type(db.kills) ~= "table" then db.kills = {} end
    if type(db.seen) ~= "table" then db.seen = {} end
    -- "Show all classes" used to be a tick box.
    if db.showAll then db.classFilter = "ALL" end
    db.showAll = nil
    if db.classFilter ~= "ALL" and db.classFilter ~= "MINE" then
      local valid = false
      for _, classFile in ipairs(CLASS_ORDER) do
        if classFile == db.classFilter then valid = true end
      end
      if not valid then db.classFilter = "MINE" end
    end
    db.rarity = tonumber(db.rarity) or 0
    if type(db.slot) ~= "string" then db.slot = "ALL" end
    if type(db.zone) ~= "string" then db.zone = "ALL" end
    if db.questZone ~= "ALL" and type(db.questZone) ~= "number" then db.questZone = "HERE" end
    pcall(Quests.LoadLearned)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end
    return
  end
  if not db then return end
  if event == "PLAYER_LOGIN" then
    local _, class = UnitClass("player")
    playerClass = Plain(class)
    SetupMinimapButton()
    -- Once the game has settled after logging in, start loading the loot.
    After(10, function() pcall(Items.PreloadAll) end)
    After(4, function() pcall(Tracker.Refresh) end)
    After(8, function() pcall(Toast.News) end)
    After(4, function() pcall(Pins.Refresh) end)
    -- The quest guide comes back if it was open last time.
    if db.guide then After(3, function() pcall(Guide.Show, true) end) end
    Chars.Save()
    pcall(Advice.Hook)
    After(8, function()
      Toast.Tip("welcome", "Type /ww or click the minimap button to open Wishwell. The first tab, What next?, shows the best quest, dungeon and spells for you right now.")
    end)
  elseif event == "CHAT_MSG_ADDON" then
    pcall(Watch.OnAddonMessage, arg1, arg2, arg3, arg4)
  elseif event == "ENCOUNTER_END" then
    pcall(Watch.Kill, arg2, arg5)
  elseif event == "BOSS_KILL" then
    pcall(Watch.Kill, arg2, nil)
  elseif event == "LOOT_OPENED" then
    pcall(Watch.LootWindow)
  elseif event == "START_LOOT_ROLL" then
    if GetLootRollItemLink then
      local ok, link = pcall(GetLootRollItemLink, arg1)
      if ok then
        pcall(Watch.Drop, link, true, nil, true)
        pcall(Advice.Roll, link)
        Toast.Tip("roll", "Rolling on loot: Need is for gear you will wear now, Greed is for everything else. Wishwell says in chat when a roll is an upgrade for you.")
      end
    end
  elseif event == "QUEST_COMPLETE" then
    -- The reward buttons are drawn a moment after the event.
    After(0.1, function() pcall(Advice.QuestRewards) end)
    if GetNumQuestChoices and (tonumber(Plain(GetNumQuestChoices())) or 0) >= 2 then
      Toast.Tip("reward", "You can only pick one of these rewards. Wishwell labels the best one for your character and says why in chat.")
    end
  elseif event == "QUEST_LOG_UPDATE" then
    -- A kill counted or an item looted: the guide may have a new nearest stop.
    Guide.Soon()
  elseif event == "QUEST_FINISHED" then
    pcall(Advice.ClearMarks)
  elseif event == "CHAT_MSG_LOOT" then
    pcall(Watch.LootChat, arg1)
  elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
    -- The game needs a moment after a loading screen before it knows where we are.
    After(2, function()
      pcall(Watch.Place)
      Refresh() -- the Quests tab follows the zone you are in
      Guide.Refresh()
    end)
  elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
    -- A fight has started: get the window out of the way.
    if event == "PLAYER_REGEN_DISABLED" then UI.CloseForCombat() end
    if event == "PLAYER_REGEN_ENABLED" then UI.heldOpen = false end
    -- The lockdown flag flips just after these events, so look again a moment later too.
    UI.CombatKeys()
    After(0.1, UI.CombatKeys)
  elseif event == "PLAYER_XP_UPDATE" then
    Chars.Save()
    if frame and frame:IsShown() and db.page == "alts" then Refresh() end
  elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_LIST_UPDATE" then
    if event == "TRADE_SKILL_SHOW" then pcall(Pins.Prompt) end
    Prof.ScanSoon()
  elseif event == "CHARACTER_POINTS_CHANGED" then
    Compare.GearChanged()
    Talents.PointsChanged()
    if frame and frame:IsShown() and (db.page == "talents" or db.page == "home") then Refresh() end
  elseif event == "SKILL_LINES_CHANGED" or event == "BAG_UPDATE_DELAYED" then
    if event == "BAG_UPDATE_DELAYED" then pcall(Pins.Refresh) end
    -- A skill point, or new materials in your bags, changes what is worth making.
    if frame and frame:IsShown() and db.page == "prof" then Refresh() end
  elseif event == "PLAYER_MONEY" then
    Chars.Save()
    if frame and frame:IsShown() and (db.page == "home" or db.page == "alts") then Refresh() end
  elseif event == "GROUP_ROSTER_UPDATE" then
    -- Someone joined: let them know what we want here.
    Watch.ShareWishesSoon()
  elseif event == "PLAYER_EQUIPMENT_CHANGED" then
    Compare.GearChanged()
    Refresh()
  elseif event == "TRAINER_SHOW" then
    pcall(Train.Opened)
    After(2, function()
      if Train.Scanned() then
        Toast.Tip("trainer", "Wishwell has read your trainer's list. The Spell training tab now shows what every level will cost you.")
      end
    end)
  elseif event == "TRAINER_UPDATE" then
    pcall(Train.Updated)
  elseif event == "TRAINER_CLOSED" then
    pcall(Train.Closed)
  elseif event == "PLAYER_LEVEL_UP" or event == "QUEST_TURNED_IN" or event == "QUEST_ACCEPTED" or event == "QUEST_REMOVED" then
    Guide.Soon()
    if event == "QUEST_ACCEPTED" then
      -- Older clients pass (log index, quest id); newer ones pass just the quest id.
      local questId = arg2 or arg1
      After(1, function()
        pcall(Quests.Learn, questId)
        Refresh()
      end)
    end
    if event == "PLAYER_LEVEL_UP" then
      Quests.LeveledTo(arg1)
      if type(Plain(arg1)) == "number" then Chars.Me().level = Plain(arg1) end
      pcall(Train.LevelUp, arg1)
      pcall(Toast.LevelUp, arg1)
    end
    Refresh()
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    Tracker.Soon()
    -- An item we wanted on the character has loaded: put it on now.
    if type(arg1) == "number" and UI.pendingTry[arg1] and arg2 ~= false then UI.TryOn(arg1) end
    -- An item name we asked for has loaded; redraw once shortly after.
    if frame and frame:IsShown() and not redrawPending then
      redrawPending = true
      After(0.2, function()
        redrawPending = false
        Refresh()
      end)
    end
  end
end)

SLASH_WISHWELL1 = "/ww"
SLASH_WISHWELL2 = "/wishwell"
SLASH_WISHWELL3 = "/wishlist"
SlashCmdList.WISHWELL = function(msg)
  if not db then return end
  Quests.Fresh()
  msg = strlower(strtrim(msg or ""))
  if msg == "ask" or strsub(msg, 1, 4) == "ask " then
    Wishwell_Toggle("ask")
    UI.AskNow(strsub(msg, 5))
    return
  end
  if msg == "pins" or msg == "pin" then
    if #(type(db.pins) == "table" and db.pins[Chars.Key()] or {}) == 0 then
      Print("Nothing is pinned yet. Open a profession window, pick a recipe, and click Pin recipe above it.")
    else
      Print(Pins.Toggle() and "Pinned recipes shown." or "Pinned recipes put away.")
    end
    return
  end
  if msg == "news" or msg == "whats new" or msg == "changelog" then
    Toast.News(true)
    return
  end
  if msg == "missed" then
    local missed = type(db.missed) == "table" and db.missed or {}
    if #missed == 0 then
      Print("Wisp has answered everything so far.")
    else
      Print("Questions Wisp could not answer (" .. #missed .. "):")
      for _, question in ipairs(missed) do Print("  " .. question) end
    end
    return
  end
  if msg == "tracker" then
    Tracker.Show()
    Print(db.tracker and "Wishlist tracker on. Drag it wherever you like." or "Wishlist tracker off.")
    return
  end
  if msg == "guide" then
    Guide.Show()
    return
  end
  if msg == "tipcheck" then
    Print(Advice.Report())
    return
  end
  if msg == "minimap" then
    db.minimapHidden = not db.minimapHidden
    if minimapButton then minimapButton:SetShown(not db.minimapHidden) end
    Print(db.minimapHidden and "Minimap button hidden. Type /ww minimap to bring it back." or "Minimap button shown.")
  elseif msg == "sound" then
    db.sound = db.sound == false
    Print(db.sound and "Wishlist alert sound on." or "Wishlist alert sound off.")
  elseif msg == "loot" or msg == "browse" then
    Wishwell_Toggle("browse")
  elseif msg == "sets" then
    Wishwell_Toggle("sets")
  elseif msg == "next" or msg == "home" then
    Wishwell_Toggle("home")
  elseif msg == "wishlist" or msg == "wish" then
    Wishwell_Toggle("wish")
  elseif msg == "quests" or msg == "quest" then
    Wishwell_Toggle("quests")
  elseif msg == "train" or msg == "spells" or msg == "training" then
    Wishwell_Toggle("train")
  elseif msg == "clear" then
    UI.AskClearWishlist()
  elseif msg == "settings" or msg == "options" or msg == "config" then
    Wishwell_Toggle("settings")
  elseif msg == "legacy" then
    Wishwell_Toggle("legacy")
  elseif msg == "link" then
    -- Puts your wishlist for this dungeon (or your whole list) into the chat box, ready to send.
    local ids = Wish.Ids(Watch.Here())
    if #ids == 0 then ids = Wish.Ids() end
    if #ids == 0 then
      Print("Your wishlist is empty.")
    else
      local sent = 0
      for i = 1, math.min(#ids, 3) do
        if UI.LinkToChat(ids[i]) then sent = sent + 1 end
      end
      if sent == 0 then Print("Open the chat box first (press Enter), then type /ww link again.") end
    end
  elseif msg == "talents" or msg == "talent" then
    Wishwell_Toggle("talents")
  elseif msg == "prof" or msg == "professions" then
    Wishwell_Toggle("prof")
  elseif msg == "alts" or msg == "characters" then
    Wishwell_Toggle("alts")
  elseif msg == "share" then
    db.share = db.share == false
    Print(db.share and "Your wishlist for the dungeon you are in is shared with your group." or "Your wishlist is no longer shared with your group.")
  elseif strmatch(msg, "^goal") then
    local amount, name = strmatch(msg, "^goal%s+([%d%.]+)%s*(.*)$")
    if strmatch(msg, "^goal%s+off") or amount == "0" then
      Chars.SetGoal(0)
      Print("Gold goal switched off.")
    elseif amount then
      local goal = Chars.SetGoal(tonumber(amount), name ~= "" and name or nil)
      if goal then Print("Saving for " .. goal.name .. ": " .. Train.Money(goal.amount) .. ".") end
    else
      Print("Type /ww goal 100 Epic mount to set a gold goal, or /ww goal off.")
    end
    Refresh()
  elseif msg == "hints" then
    db.hints = db.hints == false
    Print(db.hints and "First-time tips from the wisp are on." or "First-time tips are off.")
  elseif msg == "tips" or msg == "tooltips" then
    db.tips = db.tips == false
    Print(db.tips and "Upgrade tips on tooltips, rolls and quest rewards are on." or "Upgrade tips are off outside the Wishwell window.")
  elseif msg == "wisp" then
    db.wisp = db.wisp == false
    Print(db.wisp and "The wisp is back on the dungeon pop-up." or "The wisp is hidden.")
  elseif msg == "popup" then
    db.popup = db.popup == false
    Print(db.popup and "Dungeon pop-up on." or "Dungeon pop-up off. You get a chat line instead.")
  elseif msg == "trainer" then
    pcall(Train.Opened)
    Train.Report()
  elseif msg == "help" then
    Print("/ww opens the window. /ww loot opens the loot list. /ww sets opens item sets. /ww train opens spell training. /ww quests opens the quest list. /ww clear empties your wishlist. /ww popup switches the dungeon pop-up. /ww tips switches upgrade tips on tooltips. /ww next opens What next?. /ww alts shows your characters. /ww prof shows professions. /ww talents shows which talent to take next. /ww settings opens the switches. /ww link puts your wishlist in the chat box. /ww goal 100 sets a gold goal. /ww share switches group wishlist sharing. /ww hints switches first-time tips. /ww sound and /ww minimap switch those on or off.")
  else
    Wishwell_Toggle()
  end
end
