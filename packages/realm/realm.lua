-- realm: an online isometric world. The island, its village, its wolves and
-- the other players come from a realm server (github.com/bjorand/realm-server);
-- the colors and sprites come from realm.lib, built by tools/artgen. The video
-- card draws the world (the iso library), this program only moves the camera
-- and the people.
--
--   realm [host[:port]] [name]   both are remembered for the next time
--
-- A click walks, attacks a monster (players punch, or swing their blade once
-- they own one), talks to a villager, opens a dead player's body or reads a
-- resurrection scroll over a ghost; arrows (or ZQSD/WASD)
-- walk, 1-9 pick in a menu, J opens the quest journal, H drinks a potion,
-- T lights or puts out a torch, I (or a click on the bag in the corner)
-- opens the bag (a click on a piece of gear puts it on), E what you wear
-- (a click takes it off), P the character sheet (1-4 spend a level's point), Enter says something to everyone (over your head), Space
-- stops fighting, C switches the view
-- between jumping near the edges
-- and following every step, F3 shows the frame rate and the network lag,
-- Esc closes a menu, the journal or the bag, or quits.
--
-- The dead walk as ghosts, as in Ultima Online: their bag and gold stay on
-- their body, which anyone may loot, until the altar on the square or a
-- friend's scroll brings them back to life.
--
-- The server keeps the time of day: the world darkens to a blue night and
-- warms at dawn and dusk (the palette is dimmed, the text is not). On the
-- video card V6, the torches people carry light the dark around them.
--
-- Copyright (c) 2026 Vendetta 84. All rights reserved. See LICENSE.

local VERSION = "0.18.1"  -- the version in package.lua, shown on the splash screen
local PROTOCOL = 2
local PORT = 7878
local HW, HH = 16, 16  -- half a ground diamond: square, as in Ultima Online
local STEPS = 6        -- frames to walk one tile, the server's 200 ms
local FRAME_MS = 33
local MAX_PEOPLE = 64  -- what the video card draws (iso.info)
local STATUS_LEN = 106
local NONE, MIRROR = 255, 128

-- Colors of the realm palette (art/palette.txt).
local DEEP, LINE, TUNIC, TEXT, HUD_BG, PHOS = 9, 30, 33, 37, 38, 39
local TUNICS = 64      -- each person's tunic and its shade, set here

-- ----------------------------------------------------------------- config

if arg[1] then termina.store.set("realm_srv", arg[1]) end
if arg[2] then termina.store.set("realm_name", arg[2]) end
local server = termina.store.get("realm_srv", "localhost:" .. PORT)
local name = termina.store.get("realm_name", "")

-- ---------------------------------------------------------------- library

-- realm.lib holds every sprite of the game, raw and run-length, each
-- deflated on its own (zlib.inflate reads one from the file). The video
-- card V5 draws square ground diamonds, lets objects in front of the
-- player show through a circle around them, and keeps 128 sprites in a
-- 48 KB store. The store follows the camera: it holds the sprites of the
-- tiles in and around the view and of the people present, the plain ones
-- first, then the frames, then the variants ("tree/1") that fit; a variant
-- left out is drawn as its "/0". V6 also draws the view outside the
-- lights in night colors, kept at DARK in the store. V11 keeps the pixels
-- of every sprite in its flash (the library): the store then holds only the
-- sprites' entries, and a view is limited to 128 sprites, not to 39 KB.
local STORE, PIXELS, MAX_SPRITES, DARK  -- from iso.info(); DARK: nil before V6
local MAP_BYTES = 8192
local SEE_R = 34  -- the see-through circle around the player's body

local libPath, libPal
local lib = {}           -- name -> {w, h, ax, ay, off}

local function openLibrary()
  for _, p in ipairs({"/pkg/realm/realm.lib", "realm.lib", "/realm.lib"}) do
    if termina.fs.exists(p) then libPath = p end
  end
  if not libPath then error("realm.lib not found") end
  local f = termina.fs.open(libPath)
  local head = f:read(263)
  if head:sub(1, 5) ~= "RLIB\3" then error(libPath .. ": not a realm library") end
  local n = string.unpack("<I2", head, 6)
  libPal = head:sub(8, 263)
  local idx, pos = f:read(n * 50), 1  -- an entry is at most 50 bytes
  f:close()
  for _ = 1, n do
    local l = idx:byte(pos)
    local w, h, ax, ay, kind, off, roff, rlen = string.unpack("<BBBBBI4I4I4", idx, pos + 1 + l)
    lib[idx:sub(pos + 1, pos + l)] = {w = w, h = h, ax = ax, ay = ay, kind = kind, off = off,
                                      roff = roff, rlen = rlen}
    pos = pos + 18 + l
  end
  local info = termina.iso.info and termina.iso.info()
  if not (info and info.tile and info.see) then
    error("realm needs the video card V5: flash both boards with the firmware of 2026-10-31 on")
  end
  STORE, PIXELS, MAX_SPRITES, MAX_PEOPLE = info.store, info.pixels, info.sprites, info.people
  DARK = info.light and info.dark
end

-- Tunics: each color the server gives a person gets two palette entries
-- from 64 on, the color and its shade.
local tunicList, tunicSlot = {}, {}
local storeReady = false
local lightLevel = nil  -- the light of the store's palette (see palette)

local function shadeOf(c)
  local r, g, b = c >> 16, c >> 8 & 0xFF, c & 0xFF
  return (r // 2 + 8) << 16 | (g // 2 + 4) << 8 | (b // 2 + 8)
end

local function rgb565(c)
  return (c >> 19 & 0x1F) << 11 | (c >> 10 & 0x3F) << 5 | (c >> 3 & 0x1F)
end

local function tunicOf(rgb)
  if tunicSlot[rgb] then return tunicSlot[rgb] end
  if #tunicList >= 32 then return TUNICS end
  local c = tonumber(rgb, 16) or 0x808080
  tunicList[#tunicList + 1] = c
  local tunic = TUNICS + 2 * (#tunicList - 1)
  tunicSlot[rgb] = tunic
  -- Rare after login: the main loop sends the palette again, lit.
  if storeReady then lightLevel = nil end
  return tunic
end

-- Day and night: the time of day from the server (minutes since midnight;
-- nil before it tells, then it is always day) lights the palette. Each key
-- is a minute and the red, green and blue light in sixteenths, between
-- which the light goes linearly.
local clock = nil
local NIGHT = {6, 7, 11}
local LIGHT = {{0, NIGHT}, {300, NIGHT}, {360, {16, 13, 11}}, {420, {16, 16, 16}},
               {1140, {16, 16, 16}}, {1200, {16, 12, 10}}, {1260, NIGHT}, {1440, NIGHT}}
local LIT = {[LINE] = true, [TEXT] = true, [HUD_BG] = true, [PHOS] = true}  -- never dimmed

local lightAt, lightRGB = false, nil  -- light() for the clock lightAt
local function light()
  if not clock then return 16, 16, 16 end
  if lightAt == clock then return table.unpack(lightRGB) end
  lightAt, lightRGB = clock, {table.unpack(NIGHT)}
  for i = 2, #LIGHT do
    local m1, a, m2, b = LIGHT[i - 1][1], LIGHT[i - 1][2], LIGHT[i][1], LIGHT[i][2]
    if clock < m2 then
      local function mix(j) return (a[j] * (m2 - clock) + b[j] * (clock - m1) + (m2 - m1) // 2) // (m2 - m1) end
      lightRGB = {mix(1), mix(2), mix(3)}
      break
    end
  end
  return table.unpack(lightRGB)
end

local function lightKey()
  local r, g, b = light()
  return r << 10 | g << 5 | b
end

local function dim(c, r, g, b)
  return ((c >> 11) * r // 16) << 11 | ((c >> 5 & 0x3F) * g // 16) << 5 | (c & 0x1F) * b // 16
end

-- The palette lit by r, g, b sixteenths.
local function colors(r, g, b)
  local pal = {string.unpack(string.rep("<I2", 128), libPal)}
  pal[129] = nil  -- the position string.unpack returns
  for i, c in ipairs(tunicList) do
    pal[TUNICS + 2 * i - 1] = rgb565(c)
    pal[TUNICS + 2 * i] = rgb565(shadeOf(c))
  end
  for i = 1, 127 do
    if not LIT[i] then pal[i + 1] = dim(pal[i + 1], r, g, b) end
  end
  return string.pack(string.rep("<I2", 128), table.unpack(pal))
end

-- Torches: on V6 the store's colors are those of torchlight while it is
-- not full day, and the night colors those of the hour; the card draws the
-- view outside the lights with the night colors. Before V6 the whole view
-- takes the colors of the hour.
local TORCH = {16, 15, 13}  -- warm light
local TORCH_R = 100         -- world dots, about 3 tiles
local OPAQUE = 2            -- sprite flag: walls stop the torchlight (video V9)
local function night() return DARK and lightKey() ~= 16 << 10 | 16 << 5 | 16 end

local function palette()
  if night() then return colors(table.unpack(TORCH)) end
  return colors(light())
end

-- Sends the colors of the hour to the store.
local function applyLight()
  termina.iso.load(palette())
  if night() then termina.iso.load(colors(light()), DARK) end
  lightLevel = lightKey()
end

-- ------------------------------------------------------------------ world

local MAP = 0
local tileset, ntiles = {}, 0  -- tile code -> sprite name, from the server
local codes = nil        -- the server's tiles: ground code, object code
local blocked = {}       -- [y * MAP + x]: water or an object
local slotOf = {}        -- sprite name -> store slot
local ents, myId = {}, nil

-- F3: frames per second and a graph of the network lag in the top left
-- corner, made of people: bars 2 to 16 dots high and labels.
local overlay = false
local OVERLAY = {"blank", "meter2", "meter4", "meter6", "meter8", "meter10", "meter12",
                 "meter14", "meter16"}
-- The bag: a button in the bottom right corner and, open, a grid of 16x16
-- slots above it, drawn as people like the graph. The icons of what the
-- player owns stay in the store (see wanted).
local LAG_SAMPLES, LAG_STEP = 16, 20  -- one bar a second, 2 dots per 20 ms
local lags = {}                       -- the last samples, oldest first; false: lost
local pingSent, fps = nil, 0
local reachUp = 0                     -- tallest sprite above its foot, in the store
local sceneDirty = false
-- The store as it follows the camera (see updateStore): the camera's chunk
-- and the tile codes around it, whether it may lack a sprite (someone new
-- came, a window opened), its sprites, bytes of pixels and the wanted
-- sprites left out (for F3), and each sprite's pixels, inflated once. lib:
-- the card holds the library, each sprite's pixels at libOff[name].
local stream = {key = nil, region = {}, check = false, bytes = 0, count = 0, out = 0, pixels = {},
                lib = false, libOff = {}}

local function walkable(x, y)
  return MAP > 0 and x >= 0 and y >= 0 and x < MAP and y < MAP and not blocked[y * MAP + x]
end

local function loadMap(w, h, hex)
  codes = hex:gsub("%x%x", function(c) return string.char(tonumber(c, 16)) end)
  MAP = w
  for i = 0, w * h - 1 do
    local g, o = codes:byte(2 * i + 1, 2 * i + 2)
    local ground, object = tileset[g] or "", o ~= NONE and tileset[o & 127] or ""
    blocked[i] = ground:match("^water") or (object ~= "" and not object:match("^flowers")) or nil
  end
  sceneDirty, stream.key = true, nil
end

-- The slot of a sprite, or of its "/0" when the variant did not fit.
local function resolve(n)
  return slotOf[n] or slotOf[(n:match("^(.*)/%d+$") or n) .. "/0"]
end

local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- The tile codes in and around the view of w x h dots from the camera
-- (cx, cy): MARGIN tiles beyond each side, which also covers the tall
-- objects whose foot is below it.
local function regionCodes(cx, cy, w, h)
  local MARGIN = 6
  local u0, u1 = cx // HW - MARGIN, (cx + w) // HW + MARGIN
  local v0, v1 = cy // HH - MARGIN, (cy + h) // HH + MARGIN
  local found = {}
  for y = 0, MAP - 1 do
    for x = math.max(0, u0 + y), math.min(MAP - 1, u1 + y) do
      if x + y >= v0 and x + y <= v1 then
        local g, o = codes:byte(2 * (y * MAP + x) + 1, 2 * (y * MAP + x) + 2)
        found[g] = true
        if o ~= NONE then found[o & 127] = true end
      end
    end
  end
  return found
end

-- The sprites the store should hold, most needed first: the people
-- present, the plain sprites of the region, the icons of what the player
-- owns (always there, so that opening the bag or the gear changes nothing
-- in the store); then the players' frames (walking, punch, sword raised,
-- slash), the others' walking; then the region's variants, the objects'
-- before the grounds' (a tree changing shape shows more than grass), each
-- the smallest first.
local function wanted(region, icons)
  local first, frames, variants, seen = {}, {}, {}, {}
  local function add(n, list)
    if lib[n] and not seen[n] then
      seen[n] = true
      list[#list + 1] = n
    end
  end
  if overlay then
    for _, n in ipairs(OVERLAY) do add(n, first) end
  end
  local bases = {}
  for _, p in pairs(ents) do bases[p.sprite] = true end
  bases.person = nil
  local people = sortedKeys(bases)
  table.insert(people, 1, "person")
  for _, b in ipairs(people) do add(b .. "/0", first) end
  add("blank", first)  -- labels and chat bubbles
  add("bag", first)
  local inView = sortedKeys(region)
  for _, code in ipairs(inView) do
    local n = tileset[code]
    if n and (not n:match("/%d+$") or n:match("/0$")) then add(n, first) end
  end
  for _, n in ipairs(icons) do add(n, first) end
  for f = 1, 5 do add("person/" .. f, frames) end
  for _, b in ipairs(people) do
    add(b .. "/1", frames)
    add(b .. "/2", frames)
  end
  for _, code in ipairs(inView) do
    if tileset[code] then add(tileset[code], variants) end
  end
  local function size(n)
    local s = lib[n]
    return s.rlen > 0 and math.min(s.rlen, s.w * s.h) or s.w * s.h
  end
  table.sort(variants, function(a, b)
    local ga, gb = lib[a].kind == 0, lib[b].kind == 0  -- grounds last
    if ga ~= gb then return gb end
    local sa, sb = size(a), size(b)
    return sa < sb or (sa == sb and a < b)
  end)
  for _, n in ipairs(frames) do first[#first + 1] = n end
  for _, n in ipairs(variants) do first[#first + 1] = n end
  return first
end

-- Where a sprite's pixels are in the library, how many and its flags:
-- run-length when they are smaller so.
local function pixelsOf(s)
  local len = s.w * s.h
  if s.rlen > 0 and s.rlen < len then return s.roff, s.rlen, 1 end
  return s.off, len, 0
end

-- The sprites of a wanted list that fit the store, in order.
local function packPlan(names)
  local plan, used = {}, PIXELS
  for _, n in ipairs(names) do
    local _, len = pixelsOf(lib[n])
    if #plan < MAX_SPRITES and (stream.lib or used + len <= STORE) then
      plan[#plan + 1] = n
      used = used + len
    end
  end
  return plan
end

-- The server's tiles with store slots in place of tile codes.
local function remap()
  local slot = {}
  for code = 0, ntiles - 1 do slot[code] = resolve(tileset[code]) end
  local grass, out = resolve("grass/0") or 0, {}
  for i = 1, #codes, 2 do
    local g, o = codes:byte(i, i + 1)
    local s = o ~= NONE and slot[o & 127]
    out[#out + 1] = string.char(slot[g] or grass, s and (s | (o & MIRROR)) or NONE)
  end
  return table.concat(out)
end

-- Packs a plan's sprites into the store and sends it with the map.
local function buildStore(plan)
  local entries, pixels, used = {}, {}, PIXELS
  slotOf, reachUp = {}, 0
  for _, n in ipairs(plan) do
    local s = lib[n]
    local at, len, flags = pixelsOf(s)
    if n == "wall" then flags = flags | OPAQUE end
    slotOf[n] = #entries
    reachUp = math.max(reachUp, s.ay)
    if stream.lib then
      -- VLINK_ISO_LIB (4): the pixels are in the card's library.
      entries[#entries + 1] = string.pack("<BBBBI3B", s.w, s.h, s.ax, s.ay, stream.libOff[n],
                                          flags | 4)
    else
      if not stream.pixels[n] then
        local _, data = termina.zlib.inflate(libPath, at)
        stream.pixels[n] = data
      end
      pixels[#pixels + 1] = stream.pixels[n]
      entries[#entries + 1] = string.pack("<BBBBI3B", s.w, s.h, s.ax, s.ay, used, flags)
      used = used + len
    end
  end
  stream.bytes, stream.count = used - PIXELS, #entries
  local function tableOf(first, last)
    local t = table.concat(entries, "", first, math.min(last, #entries))
    return t .. string.rep("\0", 8 * (last - first + 1) - #t)
  end
  local store = palette() .. tableOf(1, 64) .. string.rep("\255", MAP_BYTES) .. tableOf(65, 128)
  termina.iso.load(store .. table.concat(pixels))
  applyLight()
  storeReady = true
  if codes then termina.iso.map(MAP, MAP, remap()) end
  sceneDirty = false
end

-- ----------------------------------------------------------------- people

local function person(kind, sprite, name, x, y, color)
  if not slotOf[sprite .. "/0"] then stream.check = true end
  return {kind = kind, sprite = sprite, base = name, name = name, x = x, y = y, tx = x, ty = y,
          step = 0, left = false, tunic = tunicOf(color), hp = 0, maxhp = 0, lit = false}
end

-- Foot point in world dots.
local function footX(p)
  local a, b = (p.x - p.y) * HW, (p.tx - p.ty) * HW
  return HW + a + (b - a) * p.step // STEPS
end
local function footY(p)
  local a, b = (p.x + p.y) * HH, (p.tx + p.ty) * HH
  return HH + a + (b - a) * p.step // STEPS
end

-- The tile a person stands on, or is stepping to.
local function dest(p) return p.tx, p.ty end

-- The server moved p: a step to a neighbor is walked, anything else jumps.
local function moveTo(p, x, y)
  if p.step > 0 then p.x, p.y, p.step = p.tx, p.ty, 0 end
  local dx, dy = x - p.x, y - p.y
  if math.max(math.abs(dx), math.abs(dy)) == 1 then
    p.tx, p.ty = x, y
    if dx ~= dy then p.left = dx - dy < 0 end  -- direction on the screen
    p.step = 1
  else
    p.x, p.y, p.tx, p.ty = x, y, x, y
  end
end

local function advance(p)
  if p.step == 0 then return end
  p.step = p.step + 1
  if p.step > STEPS then
    p.x, p.y, p.step = p.tx, p.ty, 0
  end
end

-- Monsters are whatever is not a person: wolves, skeletons, the boss and
-- kinds of later servers.
local PEOPLE = {player = true, npc = true, merchant = true, corpse = true}
local function isMonster(p) return p and not PEOPLE[p.kind] end

local function setHP(p, hp, maxhp)
  p.hp, p.maxhp = hp, maxhp
  -- A wounded monster shows its health instead of its name (8 characters).
  if isMonster(p) and hp < maxhp then
    p.name = string.format("%d/%d", hp, maxhp)
  else
    p.name = p.base
  end
end

-- ------------------------------------------------------------------- game

local me = {hp = 0, maxhp = 0, gold = 0, inv = {}, weapon = nil, ghost = false,
            quest = "none", kills = 0, need = 0,
            level = nil, xp = 0, next = 0, points = 0, attr = {}, dmg = {0, 0}, hit = 0, armor = 0,
            gear = nil}  -- gear: the item in each slot, from servers with slots
local SLOTS = {"weapon", "head", "body", "shield", "feet", "ring"}
local ITEMS = {}  -- name -> what the server says the piece of gear is
local gearOpen = false
local ATTRS = {"str", "dex", "vit", "int"}  -- the order of the sheet and of 1-4
local sheetOpen = false
local target = nil     -- id of the wolf being fought
local menu = nil       -- text of the open menu
local journal = nil    -- the quest log entry, from the server
local journalOpen = false
local notice, noticeUntil = nil, 0
local bagOpen = false
local bagSeen = false                  -- the first inv after login is no pickup
local pickup, pickupUntil = nil, 0     -- "+1 pelt" beside the bag button
local typing = nil                     -- the chat line being typed; nil: not typing
local CHAT_LEN = 60                    -- the server cuts longer lines

local function say(text, ms)
  notice, noticeUntil = text, termina.sys.millis() + (ms or 5000)
end

local function nameOf(id)
  if id == myId then return "you" end
  local p = ents[id]
  return p and p.base or "?"
end

-- ---------------------------------------------------------------- network

local sock, inbuf, nextTry = nil, "", 0

local function send(fmt, ...)
  if sock then sock:send(string.format(fmt, ...) .. "\n") end
end

local function disconnect(why)
  if sock then sock:close() end
  sock, inbuf, ents, myId, target, menu, clock = nil, "", {}, nil, nil, nil, nil
  typing = nil
  bagSeen, me.ghost = false, false
  say(why, 5000)
  nextTry = termina.sys.millis() + 5000
end

local handlers = {}

function handlers.welcome(a) myId = tonumber(a[1]) end

function handlers.tileset(a)
  tileset, ntiles = {}, #a
  for i, n in ipairs(a) do tileset[i - 1] = n end
end

function handlers.map(a, rest)
  local w, h, hex = rest:match("^(%d+) (%d+) (%x+)$")
  if hex then loadMap(tonumber(w), tonumber(h), hex) end
end

function handlers.spawn(a)
  local id = tonumber(a[1])
  ents[id] = person(a[2], a[3], a[7] or "?", tonumber(a[4]), tonumber(a[5]), a[6])
end

function handlers.move(a)
  local p = ents[tonumber(a[1])]
  if p then moveTo(p, tonumber(a[2]), tonumber(a[3])) end
end

function handlers.despawn(a)
  local id = tonumber(a[1])
  ents[id] = nil
  if target == id then target = nil end
end

function handlers.die(a)
  local id = tonumber(a[1])
  if target == id then target = nil end
  if id == myId then termina.sound.play("die:d=8,o=4,b=160:g,e,c") end
end

-- A player became a ghost (1) or lives again (0), on servers with ghosts.
-- Ghosts are drawn as a pale sheet, or as themselves with an old library.
function handlers.ghost(a)
  local id, p = tonumber(a[1]), ents[tonumber(a[1])]
  if not p then return end
  p.ghost = a[2] == "1"
  p.sprite = p.ghost and lib["ghost/0"] and "ghost" or "person"
  if p.ghost and not slotOf["ghost/0"] then stream.check = true end
  if id == myId then
    if not p.ghost and me.ghost then termina.sound.play("alive:d=8,o=5,b=160:c,e,g,c6") end
    me.ghost = p.ghost
  end
end

function handlers.hp(a)
  local p = ents[tonumber(a[1])]
  if p then setHP(p, tonumber(a[2]), tonumber(a[3])) end
end

-- Swings: the frames of each weapon, each until its millisecond.
local SWINGS = {fist = {{3, 200}}, sword = {{4, 120}, {5, 320}}}

-- Starts p's swing at the target with the weapon the server names (servers
-- before it only tell the player's own one) and turns p toward the target.
local function swing(p, t, weapon)
  if not SWINGS[weapon] then weapon = "sword" end  -- every blade swings like it
  p.swing = {at = termina.sys.millis(), weapon = weapon}
  local dx, dy = t.tx - p.tx, t.ty - p.ty
  if dx ~= dy then p.left = dx - dy < 0 end
end

function handlers.hit(a)
  local src, dst, dmg = tonumber(a[1]), tonumber(a[2]), tonumber(a[3])
  local p, t = ents[src], ents[dst]
  if p and t and p.kind == "player" then
    swing(p, t, a[4] or (src == myId and me.weapon) or "fist")
  end
  if src ~= myId and dst ~= myId then return end
  if dmg == 0 then
    say(string.format("%s misses %s.", nameOf(src), nameOf(dst)), 2000)
    termina.sound.tone(330, 20)
  else
    say(string.format("%s hits %s for %d.", nameOf(src), nameOf(dst), dmg), 2000)
    termina.sound.tone(dst == myId and 160 or 660, 40)
  end
  -- Hit first: fight back at what bites.
  if dst == myId and not target and isMonster(ents[src]) then target = src end
end

function handlers.stats(a)
  me.hp, me.maxhp, me.gold = tonumber(a[1]), tonumber(a[2]), tonumber(a[3])
end

-- What goes into the bag (a wolf's pelt, what Tom sells) pops up beside
-- its button.
function handlers.inv(a)
  local old, oldWeapon, got = me.inv, me.weapon, nil
  me.inv, me.weapon = {}, nil
  for item, n in (a[1] or ""):gmatch("(%w+):(%w+)") do
    if n == "equipped" then me.weapon = item else me.inv[item] = tonumber(n) end
  end
  for item, n in pairs(me.inv) do
    if n > (old[item] or 0) then got = string.format("+%d %s", n - (old[item] or 0), item) end
  end
  if me.weapon and me.weapon ~= oldWeapon then got = "+" .. me.weapon end
  if got and bagSeen then
    pickup, pickupUntil = got:sub(1, 8), termina.sys.millis() + 2000
    termina.sound.play("pickup:d=16,o=5,b=200:c,e,g")
  end
  bagSeen = true
end

-- The character sheet, from servers with levels.
function handlers.sheet(a)
  local n = {}
  for i = 1, 12 do n[i] = tonumber(a[i]) or 0 end
  me.level, me.xp, me.next, me.points = n[1], n[2], n[3], n[4]
  me.attr = {n[5], n[6], n[7], n[8]}
  me.dmg, me.hit, me.armor = {n[9], n[10]}, n[11], n[12]
end

-- What a piece of gear is: name slot dmgmin dmgmax armor str dex need price
-- label.
function handlers.item(a, rest)
  local label = rest:match("^%S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
  if not label then return end
  local n = {}
  for i = 3, 9 do n[i] = tonumber(a[i]) or 0 end
  ITEMS[a[1]] = {slot = a[2], dmg = {n[3], n[4]}, armor = n[5], str = n[6], dex = n[7],
                 need = n[8], price = n[9], label = label}
end

function handlers.gear(a)
  me.gear = {}
  for i = 1, #SLOTS do me.gear[i] = a[i] ~= "-" and a[i] or nil end
end

function handlers.quest(a)
  me.quest, me.kills, me.need = a[1], tonumber(a[2]), tonumber(a[3])
end

function handlers.journal(a, rest) journal = rest end

function handlers.time(a)
  local m = tonumber(a[1])
  if m and m >= 0 and m < 1440 then clock = m end
end

local function addLag(ms)
  lags[#lags + 1] = ms
  if #lags > LAG_SAMPLES then table.remove(lags, 1) end
end

function handlers.pong(a)
  local t = tonumber(a[1])
  if t and t == pingSent then
    addLag(termina.sys.millis() - t)
    pingSent = nil
  end
end

function handlers.light(a)
  local p = ents[tonumber(a[1])]
  if p then p.lit = a[2] == "1" end
end

function handlers.say(a, rest) say(rest) end

-- Cuts a chat line into lines of at most BUBBLE_W characters, between words
-- when it can.
local BUBBLE_W = 24
local function wrap(text)
  local lines, line = {}, ""
  for word in text:gmatch("%S+") do
    while #word > BUBBLE_W do
      if line ~= "" then lines[#lines + 1], line = line, "" end
      lines[#lines + 1], word = word:sub(1, BUBBLE_W), word:sub(BUBBLE_W + 1)
    end
    if line == "" then line = word
    elseif #line + 1 + #word <= BUBBLE_W then line = line .. " " .. word
    else lines[#lines + 1], line = line, word end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

-- Someone reached a level: it shows over their head like a chat line.
function handlers.level(a)
  local id, n = tonumber(a[1]), tonumber(a[2])
  local p = id and ents[id]
  if not p or not n then return end
  p.chat = {lines = {"Level " .. n .. "!"}, untilMs = termina.sys.millis() + 4000}
  if id == myId then termina.sound.play("level:d=8,o=5,b=180:c,e,g,2c6") end
end

-- What a player says shows over their head for a while, and on the status
-- line when someone else said it.
function handlers.chat(a, rest)
  local id, text = rest:match("^(%d+) (.+)$")
  local p = id and ents[tonumber(id)]
  if not p then return end
  p.chat = {lines = wrap(text), untilMs = termina.sys.millis() + 4000 + 100 * #text}
  if tonumber(id) ~= myId then
    say(p.base .. ": " .. text, 8000)
    termina.sound.tone(990, 10)
  end
end

function handlers.menu(a, rest)
  menu = rest ~= "" and rest or nil
end

local function handle(line)
  local cmd, rest = line:match("^(%S+) ?(.*)$")
  local f = handlers[cmd]
  if not f then return end
  local a = {}
  for w in rest:gmatch("%S+") do a[#a + 1] = w end
  f(a, rest)
end

local function connect()
  local host, port = server:match("^(.-):(%d+)$")
  host, port = host or server, tonumber(port) or PORT
  local s, err = termina.net.connect(host, port, 3000)
  if not s then
    disconnect("Cannot reach " .. server .. ": " .. tostring(err) .. ". Retrying...")
    return
  end
  sock, inbuf = s, ""
  send("hello %d %s", PROTOCOL, name)
end

-- Reads what the server sent and runs its lines; true if any came.
local function pump()
  local chunks = {inbuf}
  while sock do
    local data = sock:recv()
    if data == nil then
      disconnect("Disconnected from " .. server .. ". Retrying...")
      return true
    end
    if data == "" then break end
    chunks[#chunks + 1] = data  -- joined once: a map line is about 16 KB
  end
  if #chunks == 1 then return false end
  inbuf = table.concat(chunks)
  local start = 1
  while true do
    local i = inbuf:find("\n", start, true)
    if not i then break end
    handle(inbuf:sub(start, i - 1))
    start = i + 1
  end
  inbuf = inbuf:sub(start)
  return true
end

-- ----------------------------------------------------------------- screen

local W, VIEW_H = 0, 0
local camX, camY, follow = 0, 0, false

-- Keeps the player in view: recenters near the edges, or always.
local function frameCamera(force)
  local p = myId and ents[myId]
  if not p then return end
  local sx, sy = footX(p) - camX, footY(p) - camY
  local out = sx < W / 5 or sx > W * 4 / 5 or sy < VIEW_H / 4 or sy > VIEW_H * 4 / 5
  if force or follow or out then
    camX, camY = footX(p) - W // 2, footY(p) - VIEW_H // 2
  end
end

local function entityAt(x, y)
  for id, p in pairs(ents) do
    if id ~= myId and ((p.x == x and p.y == y) or (p.tx == x and p.ty == y)) then
      return id, p
    end
  end
end

-- The person drawn under the mouse, the front most one: people stand tall
-- above their tile, so a click on a body is usually on a tile behind it.
local function personAt(mx, my)
  local best, bestId, bestDepth
  for id, p in pairs(ents) do
    local s = lib[p.sprite .. "/0"] or lib["person/0"]
    if id ~= myId and s then
      local fx, fy = footX(p) - camX, footY(p) - camY
      local left = p.left and fx - (s.w - 1 - s.ax) or fx - s.ax
      local depth = math.max(p.x + p.y, p.tx + p.ty)
      if mx >= left and mx < left + s.w and my >= fy - s.ay and my < fy - s.ay + s.h
          and (not best or depth > bestDepth) then
        best, bestId, bestDepth = p, id, depth
      end
    end
  end
  return bestId, best
end

-- The object on a tile, by its sprite name: "altar".
local function objectAt(x, y)
  if not codes or x < 0 or y < 0 or x >= MAP or y >= MAP then return nil end
  local o = codes:byte(2 * (y * MAP + x) + 2)
  return o ~= NONE and tileset[o & 127] or nil
end

-- The walkable tile next to (x, y) nearest to the player, or nil.
local function besideOf(x, y)
  local p = ents[myId]
  local best, bx, by
  for dy = -1, 1 do
    for dx = -1, 1 do
      local nx, ny = x + dx, y + dy
      if walkable(nx, ny) then
        local d = math.max(math.abs(nx - p.tx), math.abs(ny - p.ty))
        if not best or d < best then best, bx, by = d, nx, ny end
      end
    end
  end
  return bx, by
end

local function clickTo(mx, my)
  if my >= VIEW_H or not myId then return end
  -- Inverse of the projection: a = x - y, b = x + y.
  local a, b = (mx + camX - HW) / HW, (my + camY - HH) / HH
  local x, y = math.floor((a + b) / 2 + .5), math.floor((b - a) / 2 + .5)
  local id, p = personAt(mx, my)
  if not p then id, p = entityAt(x, y) end
  if me.ghost and not walkable(x, y) and objectAt(x, y) == "altar" then
    x, y = besideOf(x, y)  -- the altar brings back the ghosts beside it
    if x then send("go %d %d", x, y) end
  elseif isMonster(p) then
    target = id
    send("attack %d", id)
  elseif p and (p.kind == "npc" or p.kind == "merchant" or p.kind == "corpse" or p.ghost) then
    send("talk %d", id)
  elseif walkable(x, y) then
    send("go %d %d", x, y)
    termina.sound.tone(880, 15)
  else
    termina.sound.tone(220, 40)
  end
end

-- Direction held on the keyboard, as a map step: up on the screen is one
-- tile back on both axes.
local function heldStep()
  local sx, sy = 0, 0
  if termina.key.held("up") or termina.key.held("w") or termina.key.held("z") then sy = sy - 1 end
  if termina.key.held("down") or termina.key.held("s") then sy = sy + 1 end
  if termina.key.held("left") or termina.key.held("a") or termina.key.held("q") then sx = sx - 1 end
  if termina.key.held("right") or termina.key.held("d") then sx = sx + 1 end
  local function sign(v) return v > 0 and 1 or v < 0 and -1 or 0 end
  return sign(sx + sy), sign(sy - sx)
end

-- Asks the server to walk that way, two tiles ahead when it can so that
-- held keys walk without stopping between tiles.
local function walkToward(dx, dy)
  local p = myId and ents[myId]
  if not p or (dx == 0 and dy == 0) then return end
  local x, y = dest(p)
  for n = 2, 1, -1 do
    if walkable(x + n * dx, y + n * dy) then
      send("go %d %d", x + n * dx, y + n * dy)
      return
    end
  end
end

local ARROWS = {up = {0, -1}, down = {0, 1}, left = {-1, 0}, right = {1, 0}}

local function hud()
  if not sock or not myId then
    if notice then return notice end
    return "VENDETTA REALM  connecting to " .. server .. " as " .. name .. "...  Esc: quit"
  end
  if typing then return "Say: " .. typing .. "_  Enter: send  Esc: cancel" end
  if menu then return menu .. "  Esc" end
  if journalOpen then
    -- Servers before the journal only tell the quest's state.
    local entry = journal or (me.quest == "active" and string.format("Wolves slain for Ada: %d/%d.",
      me.kills, me.need)) or (me.quest == "done" and "Ada's quest is done.") or "No quest yet."
    return "Journal  " .. entry .. "  J: close"
  end
  if notice and termina.sys.millis() < noticeUntil then return notice end
  local quest = me.quest == "active" and string.format("Wolves %d/%d", me.kills, me.need)
    or me.quest == "done" and "Quest done" or "Quest: see Ada"
  local fight = ""
  local t = target and ents[target]
  if t then fight = string.format("  Fighting %s %d/%d", t.base, t.hp, t.maxhp) end
  local time = clock and string.format("  %02d:%02d", clock // 60, clock % 60) or ""
  -- The rest of what the player owns is in the bag.
  local p = ents[myId]
  local torch = p and p.lit and "  Torch lit" or ""
  local level = me.level and (" Lv" .. me.level) or ""
  if me.points > 0 then level = string.format("%s  +%d point: P", level, me.points) end
  if me.ghost then
    return string.format("%s%s%s  GHOST  Walk to the altar on the square, or find a friend with a scroll.",
                         name, level, time)
  end
  return string.format("%s%s%s  HP %d/%d  Gold %d  Potions %d%s  %s%s  H: potion  T: torch  I: bag  E: gear  P: sheet  J: journal",
                       name, level, time, me.hp, me.maxhp, me.gold, me.inv.potion or 0, torch, quest, fight)
end

-- The bag on the screen. The video card draws 16-line strips, each with the
-- diagonals that can reach it: a sprite of the bag stays within one strip
-- (16 dots high, its top on a multiple of 16) and takes the strip's last
-- diagonal, so it comes after everything drawn there. A slot is 24 dots
-- wide, the item on the left and its count on the right; the button 16.
local BAG_COLS, BAG_ROWS, SLOT, SLOT_W = 4, 3, 16, 24
local BAG_ORDER = {"potion", "scroll", "torch", "match", "pelt"}  -- after gold and the weapon
local BAG_ABOUT = {
  gold = "Gold. Tom sells potions, torches and matches, Bram the smith gear.",
  sword = "Your sword: it hits harder than fists.",
  graveblade = "The grave blade, taken from the Revenant: the best blade there is.",
  pelt = "Wolf pelts. Tom buys them.",
  scroll = "Resurrection scrolls: click a ghost to bring it back to life.",
}
local BAG_USE = {potion = "use potion", torch = "use torch", match = "use torch"}

-- The button's top left corner, above the status line at the right edge.
local function bagButton()
  return W - SLOT - 4, (VIEW_H // SLOT - 1) * SLOT
end

-- The slots of the open bag, left to right and top to bottom: {x, y, item,
-- count} on the screen; item is nil in an empty slot.
local function bagSlots()
  local items = {{"gold", me.gold}}
  -- What is worn is in the gear window, on servers with slots.
  if me.weapon and not me.gear then items[#items + 1] = {me.weapon} end
  local listed = {}
  for _, item in ipairs(BAG_ORDER) do
    listed[item] = true
    if (me.inv[item] or 0) > 0 then items[#items + 1] = {item, me.inv[item]} end
  end
  for _, item in ipairs(sortedKeys(me.inv)) do
    if not listed[item] and me.inv[item] > 0 then items[#items + 1] = {item, me.inv[item]} end
  end
  local bx, by = bagButton()
  local slots = {}
  for i = 0, BAG_COLS * BAG_ROWS - 1 do
    local it = items[i + 1] or {}
    slots[#slots + 1] = {x = bx + SLOT - (BAG_COLS - i % BAG_COLS) * SLOT_W,
                         y = by - (BAG_ROWS - i // BAG_COLS) * SLOT, item = it[1], count = it[2]}
  end
  return slots
end

local function inside(mx, my, x, y, w) return mx >= x and mx < x + w and my >= y and my < y + SLOT end

-- A click on the bag: the button opens or closes it, a potion or a torch
-- is used, anything else is described. True if the click was on the bag.
local function bagClick(mx, my)
  local bx, by = bagButton()
  if inside(mx, my, bx, by, SLOT) then
    bagOpen = not bagOpen
    return true
  end
  if not bagOpen then return false end
  for _, s in ipairs(bagSlots()) do
    if inside(mx, my, s.x, s.y, SLOT_W) then
      if s.item and BAG_USE[s.item] then
        send(BAG_USE[s.item])
      elseif s.item and ITEMS[s.item] and me.gear then
        send("equip %s", s.item)
      elseif s.item then
        say(BAG_ABOUT[s.item] or string.format("%s: %d.", s.item, s.count or 1), 3000)
      end
      return true
    end
  end
  return false
end

-- The frame of p's swing at now, and how far it leans in, in dots; nil when
-- it is over.
local function swingFrame(p, now)
  local s = p.swing
  local ms = now - s.at
  for i, step in ipairs(SWINGS[s.weapon]) do
    if ms < step[2] then return step[1], i == #SWINGS[s.weapon] and 2 or 0 end
  end
  p.swing = nil
end

-- Sprite names by sprite and frame (walking, then swings), built once.
local spriteNames = setmetatable({}, {__index = function(t, sprite)
  local names = {}
  for f = 0, 5 do names[f] = sprite .. "/" .. f end
  t[sprite] = names
  return names
end})

-- A sprite at (sx, sy) on the screen, over the world: it takes the last
-- diagonal of the 16-line strip its foot is in (see the bag), and stays
-- among the people drawn.
local function screenPut(list, sprite, sx, sy, tunic, label)
  local slot = slotOf[sprite]
  if not slot then return end
  local depth = math.max(0, math.min(2 * MAP - 2, (camY + (sy // 16 + 1) * 16 + reachUp) // HH + 1))
  list[#list + 1] = {sprite = slot, x = camX + sx, y = camY + sy, depth = depth,
                     tunic = tunic or 0, name = label, d = -2}
end

-- Text alone, its middle at sx and its top at sy - 10: a blank person on
-- no diagonal, which the card never draws but whose name goes over all.
local function screenLabel(list, sx, sy, text)
  local slot = slotOf.blank
  if not slot then return end
  list[#list + 1] = {sprite = slot, x = camX + sx, y = camY + sy, depth = 255,
                     tunic = 0, name = text, d = -2}
end

-- A line of text from sx on the left: the card draws 8 characters a label,
-- so the line is labels side by side.
local function screenText(list, sx, sy, text)
  for c = 1, #text, 8 do
    local chunk = text:sub(c, c + 7)
    screenLabel(list, sx + 6 * (c - 1) + 3 * #chunk, sy, chunk)
  end
end

-- The character sheet, on the left of the view: its lines, and for each the
-- attribute it raises when clicked.
local SHEET_X, SHEET_Y, SHEET_LINE = 8, 72, 12
local function sheetLines()
  local lines = {{name .. "  Level " .. (me.level or 1)},
                 {me.next > 0 and string.format("XP %d/%d", me.xp, me.next) or "XP max"},
                 {string.format("HP %d/%d  Armor %d", me.hp, me.maxhp, me.armor)}}
  local extra = {string.format("dmg %d-%d", me.dmg[1], me.dmg[2]), string.format("hit %d%%", me.hit)}
  for i, attr in ipairs(ATTRS) do
    local l = string.format("%d %s %2d", i, attr:upper(), me.attr[i] or 0)
    if extra[i] then l = l .. "  " .. extra[i] end
    lines[#lines + 1] = {l, attr}
  end
  lines[#lines + 1] = {me.points > 0 and string.format("Points %d: 1-4 or click", me.points)
                       or "No point to spend"}
  lines[#lines + 1] = {"P: close"}
  return lines
end

-- A click on a line of the open sheet raises its attribute. True if the
-- click was on the sheet.
local function sheetClick(mx, my)
  if not sheetOpen then return false end
  for i, l in ipairs(sheetLines()) do
    local top = SHEET_Y + (i - 1) * SHEET_LINE - 11
    if mx >= SHEET_X - 1 and mx < SHEET_X + 6 * #l[1] + 1 and my >= top and my < top + SHEET_LINE then
      if l[2] and me.points > 0 then send("raise %s", l[2]) end
      return true
    end
  end
  return false
end

-- What you wear, on E: a row per slot in the top right corner, its item
-- (as in the bag) and what it does. The rows are 16 dots high, their tops
-- on multiples of 16, like the bag's.
local GEAR_Y = 32
local function gearX() return W - 150 end

-- What a piece of gear does, in a few characters.
local function gearText(slot, name)
  local it = ITEMS[name]
  if not it then return slot .. ": -" end
  local t = it.label
  if it.slot == "weapon" then t = string.format("%s %d-%d", t, it.dmg[1], it.dmg[2]) end
  if it.armor > 0 then t = string.format("%s +%d", t, it.armor) end
  if it.str > 0 then t = string.format("%s +%d STR", t, it.str) end
  if it.dex > 0 then t = string.format("%s +%d DEX", t, it.dex) end
  return t
end

-- The window's rows: {y, sprite, text, slot}; the slot is set on the rows
-- a click takes off.
local function gearRows()
  local rows = {{GEAR_Y, nil, string.format("Gear  armor %d", me.armor)}}
  for i, slot in ipairs(SLOTS) do
    local name = me.gear[i]
    rows[#rows + 1] = {GEAR_Y + SLOT * i, name and "item-" .. name or "slot", gearText(slot, name),
                       name and slot}
  end
  rows[#rows + 1] = {GEAR_Y + SLOT * (#SLOTS + 1), nil, "Click: take off"}
  rows[#rows + 1] = {GEAR_Y + SLOT * (#SLOTS + 2), nil, "Bag (I): put on"}
  return rows
end

-- A click on a worn item takes it off. True if the click was on the window.
local function gearClick(mx, my)
  if not gearOpen or not me.gear then return false end
  for _, r in ipairs(gearRows()) do
    if inside(mx, my, gearX(), r[1], SLOT_W + 4 + 6 * #r[3]) then
      if r[4] then send("unequip %s", r[4]) end
      return true
    end
  end
  return false
end

local function frame()
  local list = {}
  local p0 = myId and ents[myId]
  local now = termina.sys.millis()
  for id, p in pairs(ents) do
    local f, lean, x, y = 0, 0, footX(p), footY(p)
    if p.step > 0 then f = 1 + (p.x + p.y + p.step * 2 // STEPS) % 2 end
    if p.swing then
      local sf, l = swingFrame(p, now)
      if sf and slotOf[spriteNames.person[sf]] then f, lean = sf, l end
    end
    -- The strike leans the way p faces, on the screen only.
    if p.left then x = x - lean else x = x + lean end
    local d = p0 and math.max(math.abs(p.x - p0.x), math.abs(p.y - p0.y)) or 0
    local sprite = resolve(spriteNames[p.sprite][f]) or resolve(spriteNames.person[f])
    if not storeReady or not sprite then goto next end
    list[#list + 1] = {sprite = sprite, x = x, y = y,
                       depth = math.max(p.x + p.y, p.tx + p.ty), flip = p.left,
                       tunic = p.tunic, name = p.name, d = id == myId and -1 or d}
    ::next::
  end
  if overlay and storeReady and MAP > 0 then
    -- The bars stay in the strip of lines 32-47.
    local last = lags[#lags]
    screenLabel(list, 24, 30, last and (last .. "ms") or "--ms")
    screenLabel(list, 74, 30, fps .. "fps")
    -- The store: KB of pixels and sprites in it.
    screenLabel(list, 124, 30, stream.lib and "lib/" .. stream.count
                               or string.format("%dK/%d", stream.bytes // 1024, stream.count))
    if stream.out > 0 then screenLabel(list, 174, 30, stream.out .. " out") end
    for i, ms in ipairs(lags) do
      local h, rgb = 16, "e04040"
      if ms then
        h = math.min(16, math.max(2, 2 * ((ms + LAG_STEP - 1) // LAG_STEP)))
        rgb = ms < 80 and "40c060" or ms < 200 and "e0c040" or "e04040"
      end
      screenPut(list, "meter" .. h, 8 + 4 * (i - 1), 47, tunicOf(rgb))
    end
  end
  if storeReady and MAP > 0 then
    local bx, by = bagButton()
    screenPut(list, "bag", bx, by + SLOT - 1)
    if pickup and now < pickupUntil then
      screenLabel(list, bx - 4 - 3 * #pickup, by + 14, pickup)
    end
    if sheetOpen and me.level then
      for i, l in ipairs(sheetLines()) do
        screenText(list, SHEET_X, SHEET_Y + (i - 1) * SHEET_LINE, l[1])
      end
    end
    if gearOpen and me.gear then
      for _, r in ipairs(gearRows()) do
        if r[2] then
          local sprite = slotOf[r[2]] and r[2] or "item-misc"
          screenPut(list, sprite, gearX(), r[1] + SLOT - 1)
          screenText(list, gearX() + SLOT_W + 4, r[1] + 14, r[3])
        else
          screenText(list, gearX(), r[1] + 14, r[3])
        end
      end
    end
    if bagOpen then
      for _, s in ipairs(bagSlots()) do
        local item = s.item and "item-" .. s.item
        local sprite = item and (slotOf[item] and item or "item-misc")
        screenPut(list, sprite or "slot", s.x, s.y + SLOT - 1)
        -- The count on the right, its text 4 dots below the slot's top.
        if s.count then
          local n = tostring(s.count)
          screenLabel(list, s.x + SLOT_W - 2 - 3 * #n, s.y + 14, n)
        end
      end
    end
  end
  if #list > MAX_PEOPLE then
    table.sort(list, function(a, b) return a.d < b.d end)
    for i = #list, MAX_PEOPLE + 1, -1 do list[i] = nil end
  end
  -- Chat bubbles over the heads, in what is left of the people the card
  -- draws, the nearest speaker first. A label holds 8 characters: each line
  -- is made of labels side by side, and the last line sits above the name.
  if storeReady and slotOf.blank then
    local speakers = {}
    for id, p in pairs(ents) do
      if p.chat and now >= p.chat.untilMs then p.chat = nil end
      if p.chat then
        local d = p0 and math.max(math.abs(p.x - p0.x), math.abs(p.y - p0.y)) or 0
        speakers[#speakers + 1] = {p = p, d = id == myId and -1 or d}
      end
    end
    table.sort(speakers, function(a, b) return a.d < b.d end)
    for _, sp in ipairs(speakers) do
      local p, lines = sp.p, sp.p.chat.lines
      local need = 0
      for _, l in ipairs(lines) do need = need + (#l + 7) // 8 end
      if #list + need > MAX_PEOPLE then break end
      local s = lib[p.sprite .. "/0"] or lib["person/0"]
      local cx, top = footX(p) - camX, footY(p) - camY - (s and s.ay or 0)
      for i, l in ipairs(lines) do
        screenText(list, cx - 3 * #l, top - 11 * (#lines - i + 1), l)
      end
    end
  end
  -- The torches, the nearest first.
  local lights = {}
  if night() then
    local lit = {}
    for id, p in pairs(ents) do
      if p.lit then
        local d = p0 and math.max(math.abs(p.x - p0.x), math.abs(p.y - p0.y)) or 0
        -- Its tile, the nearer of the two while it steps: walls stop it.
        local near = p.step * 2 < STEPS
        lit[#lit + 1] = {x = footX(p), y = footY(p) - 20, r = TORCH_R, d = id == myId and -1 or d,
                         tx = near and p.x or p.tx, ty = near and p.y or p.ty}
      end
    end
    table.sort(lit, function(a, b) return a.d < b.d end)
    -- The open bag keeps its colors: it takes the first two lights, one on
    -- each half of the grid.
    if bagOpen then
      local bx, by = bagButton()
      local half = BAG_COLS * SLOT_W // 2
      for i = 1, 2 do
        table.insert(lit, 1, {x = camX + bx + SLOT - (2 * i - 1) * half // 2,
                              y = camY + by - BAG_ROWS * SLOT // 2, r = 30})
      end
    end
    -- The gear window's items too, with two more.
    if gearOpen and me.gear then
      for i = 1, 2 do
        table.insert(lit, 1, {x = camX + gearX() + SLOT_W // 2, y = camY + GEAR_Y + SLOT * (3 * i - 1),
                              r = 34})
      end
    end
    for i = 1, math.min(#lit, 8) do lights[i] = lit[i] end
  end
  -- Trees and walls in front of the player let them show through.
  local see
  if p0 then
    see = {x = footX(p0), y = footY(p0) - 20, r = SEE_R,
           depth = math.max(p0.x + p0.y, p0.tx + p0.ty)}
  end
  termina.iso.frame{x = camX, y = camY, people = list, deep = DEEP, recolor = TUNIC,
            text = TEXT, line = LINE, fg = PHOS, bg = HUD_BG, tile = 2 * HH, see = see,
            night = night() or nil, lights = lights, status = hud():sub(1, STATUS_LEN)}
end

-- The splash screen, in text mode before the game takes the screen: the
-- title, and the version on the bottom row. Row 0 is the system's bar.
local LOGO = {
  "██████  ███████  █████  ██      ███    ███",
  "██   ██ ██      ██   ██ ██      ████  ████",
  "██████  █████   ███████ ██      ██ ████ ██",
  "██   ██ ██      ██   ██ ██      ██  ██  ██",
  "██   ██ ███████ ██   ██ ███████ ██      ██",
}
local SPLASH_MS = 2500

local function splash()
  local cols, rows = termina.term.cols(), termina.term.rows()
  local function center(y, text, attr)
    termina.term.put(math.max(0, (cols - utf8.len(text)) // 2), y, text, attr)
  end
  termina.term.showcursor(false)
  termina.term.cls()
  local top = math.max(1, (rows - #LOGO - 6) // 2)
  center(top, "VENDETTA 84 PRESENTS", 0x08)
  for i, line in ipairs(LOGO) do center(top + 1 + i, line, 0x0F) end
  center(top + #LOGO + 2, string.rep("░▒▓", 14), 0x08)
  center(top + #LOGO + 4, "An online isometric world", 0x07)
  termina.term.fill(rows - 1, " ", 0x70)
  center(rows - 1, "realm " .. VERSION, 0x70)
  while termina.key.poll() do end  -- the Enter that started realm does not skip it
  return termina.sys.millis()
end

-- Keeps the splash up until SPLASH_MS after it was drawn; a key or a click
-- skips the wait.
local function endSplash(shown)
  while termina.sys.millis() - shown < SPLASH_MS do
    local e = termina.key.poll()
    if e and (e.type == "key" or e.type == "char" or (e.type == "mouse" and e.down)) then break end
    termina.sys.yield()
  end
  termina.term.cls()
  termina.term.showcursor(true)
end

-- Asks for a name on the status line until a valid one is typed.
local function askName()
  local typed = ""
  while true do
    termina.iso.frame{x = 0, y = 0, people = {}, deep = DEEP, recolor = TUNIC, text = TEXT,
              line = LINE, fg = PHOS, bg = HUD_BG,
              status = "VENDETTA REALM  Your name (2-12 letters, digits, - or _): " .. typed .. "_"}
    local e = termina.key.poll()
    while e do
      if e.type == "key" and e.key == "esc" then return nil
      elseif e.type == "key" and e.key == "enter" and typed:match("^%a[%w_-]+$") then return typed
      elseif e.type == "key" and e.key == "backspace" then typed = typed:sub(1, -2)
      elseif e.type == "char" and #typed < 12 and e.ch:match("^[%w_-]$") then typed = typed .. e.ch
      end
      e = termina.key.poll()
    end
    termina.sys.yield()
  end
end

-- The icons of what the player owns, and of the bag and gear windows.
local function ownIcons()
  local icons = {"slot", "item-misc", "item-gold"}
  local function own(item)
    if item and lib["item-" .. item] then icons[#icons + 1] = "item-" .. item end
  end
  for _, item in ipairs(sortedKeys(me.inv)) do
    if me.inv[item] > 0 then own(item) end
  end
  for i = 1, #SLOTS do own(me.gear and me.gear[i]) end
  own(me.weapon)
  return icons
end

-- The store follows the camera: the region is computed again each 4 tiles
-- it moves (less than the region's margin), or when the player's belongings
-- or the graph change, and the store is built again only when it lacks a
-- sprite it should hold.
local function updateStore()
  if not codes then return end
  local icons = ownIcons()
  local key = string.format("%d %d %s %s", camX // (4 * HW), camY // (4 * HH),
                            table.concat(icons, " "), overlay)
  if key ~= stream.key then
    stream.region, stream.key, stream.check = regionCodes(camX, camY, W, VIEW_H), key, true
  end
  if not (sceneDirty or stream.check) then return end
  stream.check = false
  local want = wanted(stream.region, icons)
  local plan = packPlan(want)
  stream.out = #want - #plan
  for _, n in ipairs(plan) do
    if not slotOf[n] then sceneDirty = true end
  end
  if sceneDirty then buildStore(plan) end
end

-- On a card V11, every sprite's pixels go to its flash once per version of
-- realm.lib, known by a hash of them (FNV-1a, a word at a time); the card
-- keeps them across restarts.
local function useLibrary()
  local li = termina.iso.library and termina.iso.library()
  if not li then return end
  local parts, at, h = {}, 0, 0x811C9DC5
  for _, n in ipairs(sortedKeys(lib)) do
    local off, len = pixelsOf(lib[n])
    local _, data = termina.zlib.inflate(libPath, off)
    stream.libOff[n] = at
    parts[#parts + 1] = data
    at = at + len
  end
  local blob = table.concat(parts)
  parts = nil
  for i = 1, #blob - 3, 4 do
    h = ((h ~ string.unpack("<i4", blob, i)) * 16777619) & 0xFFFFFFFF
  end
  local id = string.format("realm %08x %d", h, #blob)
  if li.id ~= id then
    if #blob > li.room then return end
    termina.term.cls()
    termina.term.put(2, 2, "Loading the art into the video card (once per version)...", 0x07)
    -- Once more if it failed: the card keeps nothing of a writing cut short.
    if not termina.iso.library(id, blob) and not termina.iso.library(id, blob) then return end
  end
  stream.lib = true
end

-- ------------------------------------------------------------------- main

local shown = splash()
local ok, err = pcall(openLibrary)
endSplash(shown)
if not ok then error(err, 0) end
useLibrary()
W, VIEW_H = termina.iso.open()
if name == "" then
  name = askName()
  if not name then termina.iso.close() return end
  termina.store.set("realm_name", name)
end
termina.mouse.show(true)

-- A frame goes when something may have changed: a tick, a key, a line from
-- the server; and at least every REDRAW_MS for what the clock changes (a
-- notice that ends).
local REDRAW_MS = 250
local last, quit, drawn, changed = termina.sys.millis(), false, 0, true
local lastWalk, lastPing, ticks, ticksAt = 0, 0, 0, termina.sys.millis()
while not quit do
  local now = termina.sys.millis()
  if not sock and now >= nextTry then
    frame()  -- shows "connecting" while net.connect blocks
    connect()
  end
  if pump() then changed = true end
  updateStore()
  -- The light changes a few dozen times a day: only the colors go again.
  if storeReady and lightLevel ~= lightKey() then applyLight() end

  local e = termina.key.poll()
  while e do
    changed = true
    local ch = e.type == "char" and e.ch:lower()
    -- While a chat line is typed, the keys write it; a click still plays.
    if typing and e.type ~= "mouse" then
      if e.type == "key" and e.key == "esc" then
        typing = nil
      elseif e.type == "key" and e.key == "enter" then
        if typing:match("%S") then send("chat %s", typing) end
        typing = nil
      elseif e.type == "key" and e.key == "backspace" then
        typing = typing:sub(1, -2)
      elseif e.type == "char" and #e.ch == 1 and e.ch:byte() >= 32 and e.ch:byte() <= 126
          and #typing < CHAT_LEN then
        typing = typing .. e.ch
      end
    elseif e.type == "key" and e.key == "enter" and sock and myId and not menu then
      typing = ""
    elseif e.type == "key" and e.key == "esc" then
      if menu then
        menu = nil
        send("choose 0")
      elseif journalOpen then
        journalOpen = false
      elseif sheetOpen then
        sheetOpen = false
      elseif gearOpen then
        gearOpen = false
      elseif bagOpen then
        bagOpen = false
      else
        quit = true
      end
    elseif menu and ch and ch:match("^%d$") then
      send("choose %s", ch)
    elseif sheetOpen and ch and ATTRS[tonumber(ch:match("^[1-4]$") or "")] then
      if me.points > 0 then send("raise %s", ATTRS[tonumber(ch)]) end
    elseif ch == "p" then
      sheetOpen = not sheetOpen
    elseif ch == "e" then
      gearOpen = not gearOpen
    elseif ch == "c" then
      follow = not follow
      frameCamera(true)
    elseif ch == "h" then
      send("use potion")
    elseif ch == "t" then
      send("use torch")
    elseif ch == "j" then
      journalOpen = not journalOpen
    elseif ch == "i" then
      bagOpen = not bagOpen
    elseif e.type == "key" and e.key == "f3" then
      overlay = not overlay
    elseif ch == " " or (e.type == "key" and e.key == "space") then
      target = nil
      send("peace")
    elseif e.type == "mouse" and e.down and e.button == 0 then
      local mx, my = termina.mouse.pos()
      if not sheetClick(mx, my) and not gearClick(mx, my) and not bagClick(mx, my) then
        clickTo(mx, my)
      end
    elseif e.type == "key" and ARROWS[e.key] then
      -- A key press walks one tile even without held-key reports.
      local sx, sy = ARROWS[e.key][1], ARROWS[e.key][2]
      walkToward(sx + sy, sy - sx)
      lastWalk = now
    end
    e = termina.key.poll()
  end

  if now - last >= FRAME_MS then
    last = now
    local dx, dy = 0, 0
    if not typing then dx, dy = heldStep() end
    if (dx ~= 0 or dy ~= 0) and now - lastWalk >= 150 then
      walkToward(dx, dy)
      lastWalk = now
    end
    for _, p in pairs(ents) do advance(p) end
    frameCamera(false)
    ticks = ticks + 1
    changed = true
  end
  if now - ticksAt >= 1000 then
    fps, ticks, ticksAt = ticks * 1000 // (now - ticksAt), 0, now
  end
  -- A ping a second while the graph shows; one unanswered for 3 s is lost.
  if overlay and sock and myId and now - lastPing >= 1000 then
    if pingSent and now - pingSent >= 3000 then
      addLag(false)
      pingSent = nil
    end
    if not pingSent then
      pingSent, lastPing = now, now
      send("ping %d", now)
    end
  end
  if changed or now - drawn >= REDRAW_MS then
    frame()
    changed, drawn = false, now
  end
  termina.sys.yield()
end
if sock then sock:close() end
termina.iso.close()
