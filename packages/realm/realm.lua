-- realm: an online isometric world. The island, its village, its wolves and
-- the other players come from a realm server (github.com/bjorand/realm-server);
-- the colors and sprites come from realm.lib, built by tools/artgen. The video
-- card draws the world (the iso library), this program only moves the camera
-- and the people.
--
--   realm [host[:port]] [name]   both are remembered for the next time
--
-- A click walks, attacks a wolf or talks to a villager; arrows (or ZQSD/WASD)
-- walk, 1-9 pick in a menu, H drinks a potion, Space stops fighting, C
-- switches the view between jumping near the edges and following every step,
-- Esc closes a menu or quits.
--
-- Copyright (c) 2026 Vendetta 84. All rights reserved. See LICENSE.

local PROTOCOL = 2
local PORT = 7878
local HW, HH = 16, 8   -- half a ground diamond
local STEPS = 6        -- frames to walk one tile, the server's 200 ms
local FRAME_MS = 33
local MAX_PEOPLE = 32  -- what the video card draws
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

-- realm.lib holds every sprite of the game. The video card's store holds
-- 64 sprites and 32 KB: the ones this scene needs are packed into it, the
-- people and plain sprites first, then the variants ("tree/1") that fit;
-- a variant left out is drawn as its "/0".
local STORE, PIXELS, MAX_SPRITES, MAP_BYTES = 32768, 8960, 64, 8192

local libPath, libPal
local lib = {}           -- name -> {w, h, ax, ay, off}

local function openLibrary()
  for _, p in ipairs({"/pkg/realm/realm.lib", "realm.lib", "/realm.lib"}) do
    if fs.exists(p) then libPath = p end
  end
  if not libPath then error("realm.lib not found") end
  local f = fs.open(libPath)
  local head = f:read(263)
  if head:sub(1, 5) ~= "RLIB\1" then error(libPath .. ": not a realm library") end
  local n = string.unpack("<I2", head, 6)
  libPal = head:sub(8, 263)
  local idx, pos = f:read(n * 42), 1  -- an entry is at most 42 bytes
  f:close()
  for _ = 1, n do
    local l = idx:byte(pos)
    local w, h, ax, ay, _, off = string.unpack("<BBBBBI4", idx, pos + 1 + l)
    lib[idx:sub(pos + 1, pos + l)] = {w = w, h = h, ax = ax, ay = ay, off = off}
    pos = pos + 10 + l
  end
end

-- Tunics: each color the server gives a person gets two palette entries
-- from 64 on, the color and its shade.
local tunicList, tunicSlot = {}, {}
local storeReady = false

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
  if storeReady then
    -- Rare after login: each call sends the whole store again.
    iso.color(tunic, c)
    iso.color(tunic + 1, shadeOf(c))
  end
  return tunic
end

local function palette()
  local pal = {string.unpack(string.rep("<I2", 128), libPal)}
  pal[129] = nil  -- the position string.unpack returns
  for i, c in ipairs(tunicList) do
    pal[TUNICS + 2 * i - 1] = rgb565(c)
    pal[TUNICS + 2 * i] = rgb565(shadeOf(c))
  end
  return string.pack(string.rep("<I2", 128), table.unpack(pal))
end

-- ------------------------------------------------------------------ world

local MAP = 0
local tileset, ntiles = {}, 0  -- tile code -> sprite name, from the server
local codes = nil        -- the server's tiles: ground code, object code
local blocked = {}       -- [y * MAP + x]: water or an object
local bases = {}         -- people's sprites in this scene: "person", "wolf"
local slotOf = {}        -- sprite name -> store slot
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
  table.sort(variants, function(a, b)
    local sa, sb = lib[a].w * lib[a].h, lib[b].w * lib[b].h
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
  local f = fs.open(libPath)
  local entries, pixels, used = {}, {}, PIXELS
  slotOf = {}
  for _, n in ipairs(wanted()) do
    local s = lib[n]
    if #entries < MAX_SPRITES and used + s.w * s.h <= STORE then
      f:seek(s.off)
      pixels[#pixels + 1] = f:read(s.w * s.h)
      slotOf[n] = #entries
      entries[#entries + 1] = string.pack("<BBBBI4", s.w, s.h, s.ax, s.ay, used)
      used = used + s.w * s.h
    end
  end
  f:close()
  iso.load(palette() .. table.concat(entries) .. string.rep("\0", 8 * (MAX_SPRITES - #entries))
           .. string.rep("\255", MAP_BYTES) .. table.concat(pixels))
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
          step = 0, left = false, tunic = tunicOf(color), hp = 0, maxhp = 0}
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
  sock, inbuf, ents, myId, target, menu = nil, "", {}, nil, nil, nil
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

local function clickTo(mx, my)
  if my >= VIEW_H or not myId then return end
  -- Inverse of the projection: a = x - y, b = x + y.
  local a, b = (mx + camX - HW) / HW, (my + camY - HH) / HH
  local x, y = math.floor((a + b) / 2 + .5), math.floor((b - a) / 2 + .5)
  local id, p = entityAt(x, y)
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
  if notice and sys.millis() < noticeUntil then return notice end
  local quest = me.quest == "active" and string.format("Wolves %d/%d", me.kills, me.need)
    or me.quest == "done" and "Quest done" or "Quest: see Ada"
  local fight = ""
  local t = target and ents[target]
  if t then fight = string.format("  Fighting %s %d/%d", t.base, t.hp, t.maxhp) end
  return string.format("%s  HP %d/%d  Gold %d  Potions %d%s  %s%s  Click: walk/fight/talk  H: potion",
                       name, me.hp, me.maxhp, me.gold, me.inv.potion or 0,
                       me.weapon and "  Sword" or "", quest, fight)
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
  if #list > MAX_PEOPLE then
    table.sort(list, function(a, b) return a.d < b.d end)
    for i = #list, MAX_PEOPLE + 1, -1 do list[i] = nil end
  end
  iso.frame{x = camX, y = camY, people = list, deep = DEEP, recolor = TUNIC,
            text = TEXT, line = LINE, fg = PHOS, bg = HUD_BG,
            status = hud():sub(1, STATUS_LEN)}
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
local lastWalk = 0
while not quit do
  local now = sys.millis()
  if not sock and now >= nextTry then
    frame()  -- shows "connecting" while net.connect blocks
    connect()
  end
  pump()
  if sceneDirty and codes then buildStore() end

  local e = key.poll()
  while e do
    local ch = e.type == "char" and e.ch:lower()
    if e.type == "key" and e.key == "esc" then
      if menu then
        menu = nil
        send("choose 0")
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
  end
  frame()
  sys.yield()
end
if sock then sock:close() end
iso.close()
