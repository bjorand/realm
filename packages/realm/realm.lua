-- realm: an online isometric world. The island, its village, its wolves and
-- the other players come from a realm server (github.com/bjorand/realm-server);
-- the colors and sprites come from realm.lib, built by tools/artgen. The video
-- card draws the world (the iso library), this program only moves the camera
-- and the people.
--
--   realm [host[:port]] [name]   both are remembered for the next time
--
-- A click walks, attacks a wolf or talks to a villager; arrows (or ZQSD/WASD)
-- walk, 1-9 pick in a menu, J opens the quest journal, H drinks a potion,
-- T lights or puts out a torch, Space stops fighting, C switches the view
-- between jumping near the edges
-- and following every step, F3 shows the frame rate and the network lag,
-- Esc closes a menu or the journal, or quits.
--
-- The server keeps the time of day: the world darkens to a blue night and
-- warms at dawn and dusk (the palette is dimmed, the text is not). On the
-- video card V6, the torches people carry light the dark around them.
--
-- Copyright (c) 2026 Vendetta 84. All rights reserved. See LICENSE.

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

if arg[1] then store.set("realm_srv", arg[1]) end
if arg[2] then store.set("realm_name", arg[2]) end
local server = store.get("realm_srv", "localhost:" .. PORT)
local name = store.get("realm_name", "")

-- ---------------------------------------------------------------- library

-- realm.lib holds every sprite of the game, raw and run-length, each
-- deflated on its own (zlib.inflate reads one from the file). The video
-- card V5 draws square ground diamonds, lets objects in front of the
-- player show through a circle around them, and keeps 128 sprites in a
-- 48 KB store: the ones this scene needs are packed into it, the people
-- and plain sprites first, then the variants ("tree/1") that fit; a
-- variant left out is drawn as its "/0". V6 also draws the view outside
-- the lights in night colors, kept at DARK in the store.
local STORE, PIXELS, MAX_SPRITES, DARK  -- from iso.info(); DARK: nil before V6
local MAP_BYTES = 8192
local SEE_R = 34  -- the see-through circle around the player's body

local libPath, libPal
local lib = {}           -- name -> {w, h, ax, ay, off}

local function openLibrary()
  for _, p in ipairs({"/pkg/realm/realm.lib", "realm.lib", "/realm.lib"}) do
    if fs.exists(p) then libPath = p end
  end
  if not libPath then error("realm.lib not found") end
  local f = fs.open(libPath)
  local head = f:read(263)
  if head:sub(1, 5) ~= "RLIB\3" then error(libPath .. ": not a realm library") end
  local n = string.unpack("<I2", head, 6)
  libPal = head:sub(8, 263)
  local idx, pos = f:read(n * 50), 1  -- an entry is at most 50 bytes
  f:close()
  for _ = 1, n do
    local l = idx:byte(pos)
    local w, h, ax, ay, _, off, roff, rlen = string.unpack("<BBBBBI4I4I4", idx, pos + 1 + l)
    lib[idx:sub(pos + 1, pos + l)] = {w = w, h = h, ax = ax, ay = ay, off = off, roff = roff,
                                      rlen = rlen}
    pos = pos + 18 + l
  end
  local info = iso.info and iso.info()
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

local function light()
  if not clock then return 16, 16, 16 end
  for i = 2, #LIGHT do
    local m1, a, m2, b = LIGHT[i - 1][1], LIGHT[i - 1][2], LIGHT[i][1], LIGHT[i][2]
    if clock < m2 then
      local function mix(j) return (a[j] * (m2 - clock) + b[j] * (clock - m1) + (m2 - m1) // 2) // (m2 - m1) end
      return mix(1), mix(2), mix(3)
    end
  end
  return table.unpack(NIGHT)
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
local function night() return DARK and lightKey() ~= 16 << 10 | 16 << 5 | 16 end

local function palette()
  if night() then return colors(table.unpack(TORCH)) end
  return colors(light())
end

-- Sends the colors of the hour to the store.
local function applyLight()
  iso.load(palette())
  if night() then iso.load(colors(light()), DARK) end
  lightLevel = lightKey()
end

-- ------------------------------------------------------------------ world

local MAP = 0
local tileset, ntiles = {}, 0  -- tile code -> sprite name, from the server
local codes = nil        -- the server's tiles: ground code, object code
local blocked = {}       -- [y * MAP + x]: water or an object
local bases = {}         -- people's sprites in this scene: "person", "wolf"
local slotOf = {}        -- sprite name -> store slot

-- F3: frames per second and a graph of the network lag in the top left
-- corner, made of people: bars 2 to 16 dots high and labels.
local overlay = false
local OVERLAY = {"blank", "meter2", "meter4", "meter6", "meter8", "meter10", "meter12",
                 "meter14", "meter16"}
local LAG_SAMPLES, LAG_STEP = 16, 20  -- one bar a second, 2 dots per 20 ms
local lags = {}                       -- the last samples, oldest first; false: lost
local pingSent, fps = nil, 0
local reachUp = 0                     -- tallest sprite above its foot, in the store
local sceneDirty = false

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
  sceneDirty = true
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

-- The sprites of the scene, most needed first.
local function wanted()
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
  local people = sortedKeys(bases)
  table.insert(people, 1, "person")
  for _, b in ipairs(people) do add(b .. "/0", first) end
  for code = 0, ntiles - 1 do
    local n = tileset[code]
    if not n:match("/%d+$") or n:match("/0$") then add(n, first) end
  end
  for _, b in ipairs(people) do
    add(b .. "/1", frames)
    add(b .. "/2", frames)
  end
  for code = 0, ntiles - 1 do add(tileset[code], variants) end
  local function size(n)
    local s = lib[n]
    return s.rlen > 0 and math.min(s.rlen, s.w * s.h) or s.w * s.h
  end
  table.sort(variants, function(a, b)
    local sa, sb = size(a), size(b)
    return sa < sb or (sa == sb and a < b)
  end)
  for _, n in ipairs(frames) do first[#first + 1] = n end
  for _, n in ipairs(variants) do first[#first + 1] = n end
  return first
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

-- Packs the scene's sprites into the store and sends it with the map.
local function buildStore()
  local entries, pixels, used = {}, {}, PIXELS
  slotOf, reachUp = {}, 0
  for _, n in ipairs(wanted()) do
    local s = lib[n]
    local at, len, flags = s.off, s.w * s.h, 0
    if s.rlen > 0 and s.rlen < len then at, len, flags = s.roff, s.rlen, 1 end
    if #entries < MAX_SPRITES and used + len <= STORE then
      local _, data = zlib.inflate(libPath, at)
      pixels[#pixels + 1] = data
      slotOf[n] = #entries
      reachUp = math.max(reachUp, s.ay)
      entries[#entries + 1] = string.pack("<BBBBI3B", s.w, s.h, s.ax, s.ay, used, flags)
      used = used + len
    end
  end
  local function tableOf(first, last)
    local t = table.concat(entries, "", first, math.min(last, #entries))
    return t .. string.rep("\0", 8 * (last - first + 1) - #t)
  end
  local store = palette() .. tableOf(1, 64) .. string.rep("\255", MAP_BYTES) .. tableOf(65, 128)
  iso.load(store .. table.concat(pixels))
  applyLight()
  storeReady = true
  if codes then iso.map(MAP, MAP, remap()) end
  sceneDirty = false
end

-- ----------------------------------------------------------------- people

local ents, myId = {}, nil

local function person(kind, sprite, name, x, y, color)
  if not bases[sprite] and sprite ~= "person" then
    bases[sprite] = true
    sceneDirty = true
  end
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

local function setHP(p, hp, maxhp)
  p.hp, p.maxhp = hp, maxhp
  -- A wounded monster shows its health instead of its name (8 characters).
  if p.kind == "wolf" and hp < maxhp then
    p.name = string.format("%d/%d", hp, maxhp)
  else
    p.name = p.base
  end
end

-- ------------------------------------------------------------------- game

local me = {hp = 0, maxhp = 0, gold = 0, inv = {}, weapon = nil,
            quest = "none", kills = 0, need = 0}
local target = nil     -- id of the wolf being fought
local menu = nil       -- text of the open menu
local journal = nil    -- the quest log entry, from the server
local journalOpen = false
local notice, noticeUntil = nil, 0

local function say(text, ms)
  notice, noticeUntil = text, sys.millis() + (ms or 5000)
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
  say(why, 5000)
  nextTry = sys.millis() + 5000
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
  if id == myId then sound.play("die:d=8,o=4,b=160:g,e,c") end
end

function handlers.hp(a)
  local p = ents[tonumber(a[1])]
  if p then setHP(p, tonumber(a[2]), tonumber(a[3])) end
end

function handlers.hit(a)
  local src, dst, dmg = tonumber(a[1]), tonumber(a[2]), tonumber(a[3])
  if src ~= myId and dst ~= myId then return end
  if dmg == 0 then
    say(string.format("%s misses %s.", nameOf(src), nameOf(dst)), 2000)
    sound.tone(330, 20)
  else
    say(string.format("%s hits %s for %d.", nameOf(src), nameOf(dst), dmg), 2000)
    sound.tone(dst == myId and 160 or 660, 40)
  end
  -- Hit first: fight back at what bites.
  if dst == myId and not target and ents[src] and ents[src].kind == "wolf" then target = src end
end

function handlers.stats(a)
  me.hp, me.maxhp, me.gold = tonumber(a[1]), tonumber(a[2]), tonumber(a[3])
end

function handlers.inv(a)
  me.inv, me.weapon = {}, nil
  for item, n in (a[1] or ""):gmatch("(%w+):(%w+)") do
    if n == "equipped" then me.weapon = item else me.inv[item] = tonumber(n) end
  end
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
    addLag(sys.millis() - t)
    pingSent = nil
  end
end

function handlers.light(a)
  local p = ents[tonumber(a[1])]
  if p then p.lit = a[2] == "1" end
end

function handlers.say(a, rest) say(rest) end

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
  local s, err = net.connect(host, port, 3000)
  if not s then
    disconnect("Cannot reach " .. server .. ": " .. tostring(err) .. ". Retrying...")
    return
  end
  sock, inbuf = s, ""
  send("hello %d %s", PROTOCOL, name)
end

local function pump()
  while sock do
    local data = sock:recv()
    if data == nil then
      disconnect("Disconnected from " .. server .. ". Retrying...")
      return
    end
    if data == "" then break end
    inbuf = inbuf .. data
  end
  local start = 1
  while true do
    local i = inbuf:find("\n", start, true)
    if not i then break end
    handle(inbuf:sub(start, i - 1))
    start = i + 1
  end
  inbuf = inbuf:sub(start)
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

local function clickTo(mx, my)
  if my >= VIEW_H or not myId then return end
  -- Inverse of the projection: a = x - y, b = x + y.
  local a, b = (mx + camX - HW) / HW, (my + camY - HH) / HH
  local x, y = math.floor((a + b) / 2 + .5), math.floor((b - a) / 2 + .5)
  local id, p = personAt(mx, my)
  if not p then id, p = entityAt(x, y) end
  if p and p.kind == "wolf" then
    target = id
    send("attack %d", id)
  elseif p and (p.kind == "npc" or p.kind == "merchant") then
    send("talk %d", id)
  elseif walkable(x, y) then
    send("go %d %d", x, y)
    sound.tone(880, 15)
  else
    sound.tone(220, 40)
  end
end

-- Direction held on the keyboard, as a map step: up on the screen is one
-- tile back on both axes.
local function heldStep()
  local sx, sy = 0, 0
  if key.held("up") or key.held("w") or key.held("z") then sy = sy - 1 end
  if key.held("down") or key.held("s") then sy = sy + 1 end
  if key.held("left") or key.held("a") or key.held("q") then sx = sx - 1 end
  if key.held("right") or key.held("d") then sx = sx + 1 end
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
  if menu then return menu .. "  Esc" end
  if journalOpen then
    -- Servers before the journal only tell the quest's state.
    local entry = journal or (me.quest == "active" and string.format("Wolves slain for Ada: %d/%d.",
      me.kills, me.need)) or (me.quest == "done" and "Ada's quest is done.") or "No quest yet."
    return "Journal  " .. entry .. "  J: close"
  end
  if notice and sys.millis() < noticeUntil then return notice end
  local quest = me.quest == "active" and string.format("Wolves %d/%d", me.kills, me.need)
    or me.quest == "done" and "Quest done" or "Quest: see Ada"
  local fight = ""
  local t = target and ents[target]
  if t then fight = string.format("  Fighting %s %d/%d", t.base, t.hp, t.maxhp) end
  local time = clock and string.format("  %02d:%02d", clock // 60, clock % 60) or ""
  local p, torch = ents[myId], ""
  if p and p.lit then
    torch = "  Torch lit"
  elseif (me.inv.torch or 0) > 0 or (me.inv.match or 0) > 0 then
    torch = string.format("  Torches %d Matches %d", me.inv.torch or 0, me.inv.match or 0)
  end
  return string.format("%s%s  HP %d/%d  Gold %d  Potions %d%s%s  %s%s  H: potion  T: torch  J: journal",
                       name, time, me.hp, me.maxhp, me.gold, me.inv.potion or 0,
                       me.weapon and "  Sword" or "", torch, quest, fight)
end

local function frame()
  local list = {}
  local p0 = myId and ents[myId]
  for id, p in pairs(ents) do
    local f = 0
    if p.step > 0 then f = 1 + (p.x + p.y + p.step * 2 // STEPS) % 2 end
    local d = p0 and math.max(math.abs(p.x - p0.x), math.abs(p.y - p0.y)) or 0
    local sprite = resolve(p.sprite .. "/" .. f) or resolve("person/" .. f)
    if not storeReady or not sprite then goto next end
    list[#list + 1] = {sprite = sprite, x = footX(p), y = footY(p),
                       depth = math.max(p.x + p.y, p.tx + p.ty), flip = p.left,
                       tunic = p.tunic, name = p.name, d = id == myId and -1 or d}
    ::next::
  end
  if overlay and storeReady and MAP > 0 then
    -- The video card draws 16-line strips, each with the diagonals that can
    -- reach it: the bars stay in the strip of lines 32-47 and take its last
    -- diagonal, so they come after everything drawn there.
    local depth = math.min(2 * MAP - 2, (camY + 48 + reachUp) // HH + 1)
    local function put(sprite, sx, sy, tunic, label)
      local slot = slotOf[sprite]
      if slot then
        list[#list + 1] = {sprite = slot, x = camX + sx, y = camY + sy, depth = depth,
                           tunic = tunic or 0, name = label, d = -2}
      end
    end
    local last = lags[#lags]
    put("blank", 24, 30, nil, last and (last .. "ms") or "--ms")
    put("blank", 74, 30, nil, fps .. "fps")
    for i, ms in ipairs(lags) do
      local h, rgb = 16, "e04040"
      if ms then
        h = math.min(16, math.max(2, 2 * ((ms + LAG_STEP - 1) // LAG_STEP)))
        rgb = ms < 80 and "40c060" or ms < 200 and "e0c040" or "e04040"
      end
      put("meter" .. h, 8 + 4 * (i - 1), 47, tunicOf(rgb))
    end
  end
  if #list > MAX_PEOPLE then
    table.sort(list, function(a, b) return a.d < b.d end)
    for i = #list, MAX_PEOPLE + 1, -1 do list[i] = nil end
  end
  -- The torches, the nearest first.
  local lights = {}
  if night() then
    local lit = {}
    for id, p in pairs(ents) do
      if p.lit then
        local d = p0 and math.max(math.abs(p.x - p0.x), math.abs(p.y - p0.y)) or 0
        lit[#lit + 1] = {x = footX(p), y = footY(p) - 20, r = TORCH_R, d = id == myId and -1 or d}
      end
    end
    table.sort(lit, function(a, b) return a.d < b.d end)
    for i = 1, math.min(#lit, 8) do lights[i] = lit[i] end
  end
  -- Trees and walls in front of the player let them show through.
  local see
  if p0 then
    see = {x = footX(p0), y = footY(p0) - 20, r = SEE_R,
           depth = math.max(p0.x + p0.y, p0.tx + p0.ty)}
  end
  iso.frame{x = camX, y = camY, people = list, deep = DEEP, recolor = TUNIC,
            text = TEXT, line = LINE, fg = PHOS, bg = HUD_BG, tile = 2 * HH, see = see,
            night = night() or nil, lights = lights, status = hud():sub(1, STATUS_LEN)}
end

-- Asks for a name on the status line until a valid one is typed.
local function askName()
  local typed = ""
  while true do
    iso.frame{x = 0, y = 0, people = {}, deep = DEEP, recolor = TUNIC, text = TEXT,
              line = LINE, fg = PHOS, bg = HUD_BG,
              status = "VENDETTA REALM  Your name (2-12 letters, digits, - or _): " .. typed .. "_"}
    local e = key.poll()
    while e do
      if e.type == "key" and e.key == "esc" then return nil
      elseif e.type == "key" and e.key == "enter" and typed:match("^%a[%w_-]+$") then return typed
      elseif e.type == "key" and e.key == "backspace" then typed = typed:sub(1, -2)
      elseif e.type == "char" and #typed < 12 and e.ch:match("^[%w_-]$") then typed = typed .. e.ch
      end
      e = key.poll()
    end
    sys.yield()
  end
end

-- ------------------------------------------------------------------- main

openLibrary()
W, VIEW_H = iso.open()
if name == "" then
  name = askName()
  if not name then iso.close() return end
  store.set("realm_name", name)
end
mouse.show(true)

local last, quit = sys.millis(), false
local lastWalk, lastPing, ticks, ticksAt = 0, 0, 0, sys.millis()
while not quit do
  local now = sys.millis()
  if not sock and now >= nextTry then
    frame()  -- shows "connecting" while net.connect blocks
    connect()
  end
  pump()
  if sceneDirty and codes then buildStore() end
  -- The light changes a few dozen times a day: only the colors go again.
  if storeReady and lightLevel ~= lightKey() then applyLight() end

  local e = key.poll()
  while e do
    local ch = e.type == "char" and e.ch:lower()
    if e.type == "key" and e.key == "esc" then
      if menu then
        menu = nil
        send("choose 0")
      elseif journalOpen then
        journalOpen = false
      else
        quit = true
      end
    elseif menu and ch and ch:match("^%d$") then
      send("choose %s", ch)
    elseif ch == "c" then
      follow = not follow
      frameCamera(true)
    elseif ch == "h" then
      send("use potion")
    elseif ch == "t" then
      send("use torch")
    elseif ch == "j" then
      journalOpen = not journalOpen
    elseif e.type == "key" and e.key == "f3" then
      overlay = not overlay
      sceneDirty = true  -- the graph's sprites come into the store
    elseif ch == " " or (e.type == "key" and e.key == "space") then
      target = nil
      send("peace")
    elseif e.type == "mouse" and e.down and e.button == 0 then
      clickTo(mouse.pos())
    elseif e.type == "key" and ARROWS[e.key] then
      -- A key press walks one tile even without held-key reports.
      local sx, sy = ARROWS[e.key][1], ARROWS[e.key][2]
      walkToward(sx + sy, sy - sx)
      lastWalk = now
    end
    e = key.poll()
  end

  if now - last >= FRAME_MS then
    last = now
    local dx, dy = heldStep()
    if (dx ~= 0 or dy ~= 0) and now - lastWalk >= 150 then
      walkToward(dx, dy)
      lastWalk = now
    end
    for _, p in pairs(ents) do advance(p) end
    frameCamera(false)
    ticks = ticks + 1
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
  frame()
  sys.yield()
end
if sock then sock:close() end
iso.close()
