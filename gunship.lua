-- Gunship: fully automatic Big Cannons on a moving Sable ship.
--
-- The computer sits on the ship with every Cannon Mount and a radar on its
-- wired network. It picks a target from the radar, works out the shell arc
-- (gravity, drag, lead, your own ship's speed), aims every cannon that can
-- bear, and fires each one only once its barrel is within AIM_MARGIN.
--
-- Keys: A arm/safe   N next target   C auto target   F fire ready cannons
--       X ignore this target for good (parts of your own ship)   U un-ignore all
--       T test: swing every cannon through a few angles (no firing, ignores targets)
-- While SAFE the cannons still aim, so you can check them without shooting.

CANNON_SPEED = 8          -- shell speed in blocks/tick: 2 per Powder Charge (4 charges = 8)
BARREL_LENGTH = 4         -- blocks from the mount to the muzzle
GRAVITY = -0.05           -- shell physics (Big Cannons default for HE, AP and solid shot)
DRAG = 0.01
AIM_MARGIN = 1.0          -- degrees: a cannon fires only when its barrel is this close
RELOAD = 6                -- seconds between shots of one cannon (match your autoloader)
STAGGER = 0.75            -- seconds between any two shots (recoil rocks the ship)
MAX_ROCK = 8              -- hold fire while the ship turns/rocks faster than this (deg/s)
MAX_RANGE = 400
MIN_RANGE = 20
TARGETS = { SABLE = true, PLAYER = false, HOSTILE = false, MOB = false, ANIMAL = false }
OWN_SHIP_RADIUS = 20      -- tracks this close to your ship's center are never targets
LOCK_MEMORY = 15          -- keep following a target this many seconds after the radar last swept it
ARC = 160                 -- each cannon's firing arc in degrees, centred on its side of the ship
ARCS = {}                 -- per cannon, e.g. ARCS["cannon_mount_0"] = { center = 90, width = 120 }
YAW_OFFSET = 0            -- calibration if every cannon points the same wrong way
PITCH_SIGN = 1            -- -1 if the barrels aim down when they should aim up
MOUNT_UP = true           -- false if the mounts hang upside down
AUTO_UPDATE = true

if fs and fs.exists("/config.lua") then
  local f, err = loadfile("/config.lua", nil, _ENV)
  if not f then error("/config.lua: " .. err, 0) end
  f()
end

-- ============================================================ math

VERSION = "1.4.0"
local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
local sin, cos, sqrt, abs, deg, rad = math.sin, math.cos, math.sqrt, math.abs, math.deg, math.rad
local LOOP = 0.15
local MAX_TICKS = 400

local function now() return os.clock() end
local function wrap(a) return (a + 180) % 360 - 180 end
local function len(v) return sqrt(v.x * v.x + v.y * v.y + v.z * v.z) end

local function qrot(q, v)
  local tx = 2 * (q.y * v.z - q.z * v.y)
  local ty = 2 * (q.z * v.x - q.x * v.z)
  local tz = 2 * (q.x * v.y - q.y * v.x)
  return { x = v.x + q.w * tx + (q.y * tz - q.z * ty),
           y = v.y + q.w * ty + (q.z * tx - q.x * tz),
           z = v.z + q.w * tz + (q.x * ty - q.y * tx) }
end
local function qinv(q) return { x = -q.x, y = -q.y, z = -q.z, w = q.w } end
local function qmul(a, b)
  return { w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
           x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
           y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
           z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w }
end

-- Minecraft yaw: 0 = +Z (south), 90 = -X (west)
local function yawOf(v) return deg(atan2(-v.x, v.z)) end
local function pitchOf(v) return deg(atan2(v.y, sqrt(v.x * v.x + v.z * v.z))) end
local function dirOf(yaw, pitch)
  local y, p = rad(yaw), rad(pitch)
  return { x = -sin(y) * cos(p), y = sin(p), z = cos(y) * cos(p) }
end
local function angleBetween(a, b)
  local d = (a.x * b.x + a.y * b.y + a.z * b.z) / (len(a) * len(b))
  if d > 1 then d = 1 elseif d < -1 then d = -1 end
  return deg(math.acos(d))
end

-- Shell flight in the vertical plane, the way Big Cannons steps it each tick:
-- force = gravity - drag * velocity; pos += v + force/2; v += force.
-- Returns the height at horizontal distance R and the ticks it took.
local function heightAt(pitch, R)
  local p = rad(pitch)
  local vx, vy = CANNON_SPEED * cos(p), CANNON_SPEED * sin(p)
  local x, y = BARREL_LENGTH * cos(p), BARREL_LENGTH * sin(p)
  if x >= R then return y - (x - R) * math.tan(p), 0 end
  for t = 1, MAX_TICKS do
    local fx, fy = -vx * DRAG, -vy * DRAG + GRAVITY
    local nx, ny = x + vx + fx / 2, y + vy + fy / 2
    if nx >= R then
      local f = (R - x) / (nx - x)
      return y + (ny - y) * f, t - 1 + f
    end
    x, y, vx, vy = nx, ny, vx + fx, vy + fy
    if vx < 0.01 then return nil end
  end
  return nil
end

-- Low-arc pitch that puts the shell at height H after R blocks.
local function solvePitch(R, H)
  local lo, hi = -40, 45
  local yHi = heightAt(hi, R)
  if not yHi or yHi < H then return nil, "too far" end
  local yLo = heightAt(lo, R)
  if yLo and yLo > H then return nil, "too steep down" end
  for _ = 1, 18 do
    local mid = (lo + hi) / 2
    local y = heightAt(mid, R)
    if y and y >= H then hi = mid else lo = mid end
  end
  local _, t = heightAt(hi, R)
  return hi, t
end

-- How far an inherited velocity carries the shell in T ticks (drag slows it too).
local function carried(T)
  if DRAG <= 0 then return T end
  return (1 - (1 - DRAG) ^ T) / DRAG
end

-- ============================================================ hardware

if not (sublevel and sublevel.isInPlotGrid and sublevel.isInPlotGrid()) then
  printError("This computer isn't on a Sable ship (needs CC: Sable).")
  return
end

local mounts, radar, monitor = {}, nil, nil
local shipId = nil
do
  local ok, id = pcall(sublevel.getUniqueId)
  if ok and id then shipId = tostring(id) end
end

local function hasMethod(name, m)
  for _, x in ipairs(peripheral.getMethods(name) or {}) do
    if x == m then return true end
  end
  return false
end

local function findHardware()
  local seen, list = {}, {}
  for _, n in ipairs(peripheral.getNames()) do
    if not seen[n] then
      seen[n] = true
      list[#list + 1] = n
    end
  end
  local old = {}
  for _, m in ipairs(mounts) do old[m.name] = m end
  mounts, radar, monitor = {}, nil, nil
  for _, n in ipairs(list) do
    local t = peripheral.getType(n)
    if t == "cannon_mount" then
      mounts[#mounts + 1] = old[n] or { name = n, lastShot = -999, state = "starting" }
    elseif hasMethod(n, "getSelectedTrack") then
      monitor = monitor or n
    elseif hasMethod(n, "getTracks") and hasMethod(n, "getRange") then
      radar = radar or n
    end
  end
  table.sort(mounts, function(a, b) return a.name < b.name end)
end

-- ============================================================ ship pose

local pose = nil                    -- { pos, q, rp, scale, t }
local shipVel = { x = 0, y = 0, z = 0 }  -- blocks/tick
local rock = 0                      -- deg/s
-- Sable velocities (own ship + radar SABLE tracks) are blocks per second or
-- per tick; learned by comparing the reported velocity with real movement.
local velScale = nil
local velVotes = { [1] = 0, [20] = 0 }

local function vec(t)
  if type(t) ~= "table" then return nil end
  local x, y, z = tonumber(t.x), tonumber(t.y), tonumber(t.z)
  if not (x and y and z) then return nil end
  return { x = x, y = y, z = z }
end

local function readPose()
  local ok, p = pcall(sublevel.getLogicalPose)
  if not ok or type(p) ~= "table" or not p.position then return false end
  local o = p.orientation or {}
  local q = { x = o.x or 0, y = o.y or 0, z = o.z or 0, w = o.w or 1 }
  local t = now()
  if pose and t > pose.t then
    local dt = (t - pose.t) * 20
    local moved = { x = (p.position.x - pose.pos.x) / dt, y = (p.position.y - pose.pos.y) / dt, z = (p.position.z - pose.pos.z) / dt }
    local okV, api = pcall(sublevel.getLinearVelocity)
    api = okV and vec(api) or nil
    if api and not velScale and len(moved) > 0.05 then
      local r = len(api) / len(moved)
      for _, k in ipairs({ 1, 20 }) do
        if r > k * 0.7 and r < k * 1.3 then
          velVotes[k] = velVotes[k] + 1
          if velVotes[k] >= 5 then velScale = k end
        end
      end
    end
    if api and velScale then
      shipVel = { x = api.x / velScale, y = api.y / velScale, z = api.z / velScale }
    else
      local a = 0.5
      shipVel = { x = shipVel.x * (1 - a) + moved.x * a, y = shipVel.y * (1 - a) + moved.y * a, z = shipVel.z * (1 - a) + moved.z * a }
    end
    local dq = qmul(q, qinv(pose.q))
    local w = math.min(1, abs(dq.w))
    rock = rock * 0.5 + deg(2 * math.acos(w)) / (t - pose.t) * 0.5
  end
  pose = { pos = p.position, q = q, rp = p.rotationPoint or p.position, scale = p.scale or { x = 1, y = 1, z = 1 }, t = t }
  return true
end

local function toWorld(lp)
  local s = pose.scale
  local r = qrot(pose.q, { x = (lp.x - pose.rp.x) * (s.x or 1), y = (lp.y - pose.rp.y) * (s.y or 1), z = (lp.z - pose.rp.z) * (s.z or 1) })
  return { x = r.x + pose.pos.x, y = r.y + pose.pos.y, z = r.z + pose.pos.z }
end

-- ============================================================ targets

local tracks = {}      -- eligible tracks this scan, nearest first
local seen = {}        -- id -> { p, t, v } for speed estimates
local lockId = nil
local IGNORE_FILE = "/gunship_ignore"
local ignored = {}
do
  if fs.exists(IGNORE_FILE) then
    local f = fs.open(IGNORE_FILE, "r")
    local t = textutils.unserialize(f.readAll())
    f.close()
    if type(t) == "table" then ignored = t end
  end
end
local function saveIgnored()
  local f = fs.open(IGNORE_FILE, "w")
  f.write(textutils.serialize(ignored))
  f.close()
end
local manualPick = false
local radarError = nil
local lostMsg, lostAt = nil, -999

-- Radar tracks carry scannedTime; once its units are known (game ticks or
-- ms) positions are dated by the scan itself, not by when we read them.
local scanUnit, scanOffset = nil, nil   -- scanned units per tick, clock ticks - scan ticks

local function scanTicks(st) return st / scanUnit end

-- Target velocity in blocks/tick: the radar's own reading when it has one
-- (entities report per tick; Sable ships use the learned unit), else the
-- movement measured between sweeps.
local function trackVel(s)
  if s.rv then
    local k = 1
    if s.cat == "SABLE" then
      k = velScale
      if not k then
        -- unit not learned yet: pick the one that matches what we measured
        local m, r = len(s.v), len(s.rv)
        if (s.vn or 0) >= 1 and m > 0.02 and abs(r / 20 - m) > abs(r - m) then k = 1 else k = 20 end
      end
    end
    return { x = s.rv.x / k, y = s.rv.y / k, z = s.rv.z / k }
  end
  return s.v
end

-- Where the target will be `ahead` ticks from now. Follows its turn (an arc
-- at the measured turn rate) instead of a straight line.
local function trackPos(s, ahead)
  local age = now() - s.t
  if scanUnit and s.st then age = (now() * 20 - (scanTicks(s.st) + scanOffset)) / 20 end
  local a = math.max(0, math.min(age, LOCK_MEMORY)) * 20 + (ahead or 0)
  local v = trackVel(s)
  local w = s.turn or 0
  local dx, dz
  if abs(w) < 1e-5 then
    dx, dz = v.x * a, v.z * a
  else
    local sn, cs = sin(w * a) / w, (1 - cos(w * a)) / w
    dx = sn * v.x - cs * v.z
    dz = sn * v.z + cs * v.x
  end
  return { x = s.p.x + dx, y = s.p.y + v.y * a, z = s.p.z + dz }
end

local function isOwnShip(t)
  if shipId and t.id ~= nil and tostring(t.id) == shipId then return true end
  local dx, dy, dz = t.position.x - pose.pos.x, t.position.y - pose.pos.y, t.position.z - pose.pos.z
  return dx * dx + dy * dy + dz * dz < OWN_SHIP_RADIUS * OWN_SHIP_RADIUS
end

local function scan()
  if not radar then
    tracks = {}
    return
  end
  local ok, list = pcall(peripheral.call, radar, "getTracks")
  if not ok or type(list) ~= "table" then
    radarError = tostring(list)
    tracks = {}
    return
  end
  radarError = nil
  local t = now()
  local out = {}
  for _, tr in pairs(list) do
    if type(tr) == "table" and tr.position and tr.id ~= nil then
      local id = tostring(tr.id)
      local s = seen[id]
      local p = tr.position
      local st = tonumber(tr.scannedTime)
      if not s then
        s = { p = p, t = t, v = { x = 0, y = 0, z = 0 }, st = st }
        seen[id] = s
      elseif p.x ~= s.p.x or p.y ~= s.p.y or p.z ~= s.p.z then
        local dt = (t - s.t) * 20
        if st and s.st and st > s.st then
          if not scanUnit and dt > 0 then
            local r = (st - s.st) / dt
            if r > 0.5 and r < 2 then scanUnit = 1 elseif r > 25 and r < 100 then scanUnit = 50 end
          end
          if scanUnit then dt = scanTicks(st - s.st) end
        end
        if scanUnit and st then
          local off = t * 20 - scanTicks(st)
          if not scanOffset or off < scanOffset then scanOffset = off end
        end
        s.st = st
        if dt > 0 then
          s.vn = (s.vn or 0) + 1
          local a = 0.6
          s.v = { x = s.v.x * (1 - a) + (p.x - s.p.x) / dt * a,
                  y = s.v.y * (1 - a) + (p.y - s.p.y) / dt * a,
                  z = s.v.z * (1 - a) + (p.z - s.p.z) / dt * a }
        end
        s.p, s.t = p, t
      end
      s.seenAt = t
      if tr.velocity then
        -- the velocity belongs to the scan, so only take it with a new position
        local rv = vec(tr.velocity)
        if rv and (not s.rvAt or s.t ~= s.rvAt) then
          -- turn rate from how the heading changed since the last scan
          local tick = (scanUnit and s.st and scanTicks(s.st)) or s.t * 20
          if s.rv and s.rvTick and tick > s.rvTick then
            local a, b = s.rv, rv
            local sa, sb = sqrt(a.x * a.x + a.z * a.z), sqrt(b.x * b.x + b.z * b.z)
            if sa > 0 and sb > 0 and sa > 0.05 * sb then
              local w = atan2(a.x * b.z - a.z * b.x, a.x * b.x + a.z * b.z) / (tick - s.rvTick)
              local cap = rad(30) / 20
              if w > cap then w = cap elseif w < -cap then w = -cap end
              s.turn = (s.turn or 0) * 0.4 + w * 0.6
            end
          end
          s.rv, s.rvAt, s.rvTick = rv, s.t, tick
        end
      end
      s.cat = tostring(tr.category)
      s.kind = tostring(tr.entityType or "")
      s.ok = TARGETS[s.cat] and not isOwnShip(tr)
      if s.ok and not ignored[id] then
        local d = len({ x = p.x - pose.pos.x, y = p.y - pose.pos.y, z = p.z - pose.pos.z })
        if d >= MIN_RANGE and d <= MAX_RANGE then
          out[#out + 1] = { id = id, d = d, s = s }
        end
      end
    end
  end
  for id, s in pairs(seen) do
    if t - (s.seenAt or 0) > LOCK_MEMORY + 5 then seen[id] = nil end
  end
  table.sort(out, function(a, b) return a.d < b.d end)
  tracks = out
end

local function pickTarget()
  -- a target clicked on the radar monitor wins
  if monitor then
    local ok, sel = pcall(peripheral.call, monitor, "getSelectedTrack")
    if ok and type(sel) == "table" and sel.id ~= nil then
      for _, tr in ipairs(tracks) do
        if tr.id == tostring(sel.id) then
          lockId, manualPick = tr.id, true
          return tr
        end
      end
    end
  end
  for _, tr in ipairs(tracks) do
    if tr.id == lockId then return tr end
  end
  -- a Radar Bearing only lists what its dish swept recently: keep the lock
  -- through the gaps and follow the target's predicted position
  local s = lockId and seen[lockId]
  if s and s.ok and not ignored[lockId] and now() - s.seenAt <= LOCK_MEMORY then
    local p = trackPos(s)
    local d = len({ x = p.x - pose.pos.x, y = p.y - pose.pos.y, z = p.z - pose.pos.z })
    if d <= MAX_RANGE then return { id = lockId, d = d, s = s, memory = true } end
  end
  if lockId then
    local why = "gone from radar"
    if ignored[lockId] then why = "ignored (X)"
    elseif s and not s.ok then why = "now counts as your ship / not a target type"
    elseif s and now() - s.seenAt > LOCK_MEMORY then why = string.format("not on radar for %ds (LOCK_MEMORY)", LOCK_MEMORY)
    elseif s then why = "out of range (MAX_RANGE)" end
    lostMsg, lostAt = "Lost target: " .. why, now()
  end
  manualPick = false
  local tr = tracks[1]
  lockId = tr and tr.id or nil
  return tr
end

local function nextTarget()
  if #tracks == 0 then return end
  local i = 0
  for k, tr in ipairs(tracks) do
    if tr.id == lockId then i = k end
  end
  lockId = tracks[i % #tracks + 1].id
  manualPick = true
end

-- ============================================================ aiming

local armed = false
local lastAnyShot = -999
local target = nil
local forceFire = false
local testMode, testStart = false, 0
local TEST_POSES = { { 0, 15 }, { 30, 5 }, { -30, 5 }, { 0, 0 } }

-- side of the ship each mount is on, from its offset to the ship's center
local function arcFor(m)
  local o = ARCS[m.name]
  if o then return o.center or 0, o.width or ARC end
  local rel = { x = m.localPos.x - pose.rp.x, z = m.localPos.z - pose.rp.z }
  local side
  if abs(rel.x) >= abs(rel.z) then side = { x = rel.x >= 0 and 1 or -1, y = 0, z = 0 }
  else side = { x = 0, y = 0, z = rel.z >= 0 and 1 or -1 } end
  return yawOf(side), ARC
end

-- needed world direction for mount m to hit target tr, or nil + reason
local function solve(m, tr)
  local P = trackPos(tr.s)
  local S = m.world
  local T = len({ x = P.x - S.x, y = P.y - S.y, z = P.z - S.z }) / CANNON_SPEED
  local yaw, pitch
  for _ = 1, 4 do
    local c = carried(T)
    local A = trackPos(tr.s, T)
    local ax = A.x - shipVel.x * c - S.x
    local ay = A.y - shipVel.y * c - S.y
    local az = A.z - shipVel.z * c - S.z
    local p, t = solvePitch(sqrt(ax * ax + az * az), ay)
    if not p then return nil, t end
    yaw, pitch, T = yawOf({ x = ax, y = 0, z = az }), p, t
  end
  return dirOf(yaw, pitch), T
end

local function readMount(m)
  local ok, info = pcall(peripheral.call, m.name, "getInfo")
  if ok and type(info) == "table" then m.info = info else m.info = nil end
end

local function release(m)
  if m.trigger then
    pcall(peripheral.call, m.name, "fire", false)
    m.trigger = false
  end
end

local function aimMount(m)
  release(m)
  m.flight, m.err, m.wantYaw, m.wantPitch = nil, nil, nil, nil
  local info = m.info
  if not info then
    m.state = "no reply"
    return
  end
  -- turning computer control on resets the mount's target to where it
  -- points now, so the angles are re-sent below whenever they differ
  if not info.computerControl then pcall(peripheral.call, m.name, "setComputerControl", true) end
  if not info.assembled then
    m.state = "not assembled"
    if armed then pcall(peripheral.call, m.name, "assemble", true) end
    return
  end
  m.localPos = { x = info.x + 0.5, y = info.y + (MOUNT_UP and 1.5 or -0.5), z = info.z + 0.5 }
  m.world = toWorld(m.localPos)
  m.err = nil
  if testMode then
    local i = math.floor((now() - testStart) / 4) % #TEST_POSES + 1
    local center = arcFor(m)
    local ty, tp = wrap(center + TEST_POSES[i][1] + YAW_OFFSET), TEST_POSES[i][2] * PITCH_SIGN
    m.wantYaw, m.wantPitch = ty, tp
    local ok, err = pcall(peripheral.call, m.name, "setTargetAngles", ty, tp)
    local ys, ps = tonumber(info.yawShaftSpeed), tonumber(info.pitchShaftSpeed)
    if not ok then m.state = "error: " .. tostring(err)
    elseif ys == 0 then m.state = "no yaw power"
    elseif ps == 0 then m.state = "no pitch power"
    else m.state = string.format("TEST %d/%d", i, #TEST_POSES) end
    return
  end
  if not target then
    m.state = "no target"
    return
  end
  local need, why = solve(m, target)
  if not need then
    m.state = why
    return
  end
  m.flight = why
  -- into the ship's frame: the mount turns with the ship
  local lv = qrot(qinv(pose.q), need)
  local yaw, pitch = yawOf(lv), pitchOf(lv)
  local center, width = arcFor(m)
  if abs(wrap(yaw - center)) > width / 2 then
    m.state = "other side"
    return
  end
  local sendYaw, sendPitch = wrap(yaw + YAW_OFFSET), pitch * PITCH_SIGN
  m.wantYaw, m.wantPitch = sendYaw, sendPitch
  -- compare with what the mount says its target is (it clamps pitch to the
  -- cannon's limits, so a pitch it can't reach is just re-sent each loop)
  local ty, tp = tonumber(info.targetYaw), tonumber(info.targetPitch)
  if not info.computerControl or not ty or not tp or abs(wrap(sendYaw - ty)) > 0.05 or abs(sendPitch - tp) > 0.05 then
    local ok, err = pcall(peripheral.call, m.name, "setTargetAngles", sendYaw, sendPitch)
    m.sendError = (not ok) and tostring(err) or nil
  end
  -- where the barrel really points now, in the world
  local have = qrot(pose.q, dirOf((info.yaw or 0) - YAW_OFFSET, (info.pitch or 0) * PITCH_SIGN))
  m.err = angleBetween(have, need)
  if m.err > AIM_MARGIN then
    -- a mount turns at its shafts' speed: no rotation, no movement
    local ys, ps = tonumber(info.yawShaftSpeed), tonumber(info.pitchShaftSpeed)
    local dYaw = abs(wrap((info.yaw or 0) - sendYaw))
    local dPitch = abs((info.pitch or 0) - sendPitch)
    if m.sendError then
      m.state = "error: " .. m.sendError
    elseif ys == 0 and dYaw > AIM_MARGIN then
      m.state = "no yaw power"
    elseif ps == 0 and dPitch > AIM_MARGIN then
      m.state = "no pitch power"
    elseif tp and abs(tp - sendPitch) > 0.5 and abs((info.pitch or 0) - tp) < 0.5 then
      m.state = "pitch limit"
    else
      m.state = "aiming"
    end
    return
  end
  local t = now()
  if t - m.lastShot < RELOAD then
    m.state = string.format("reload %.0fs", RELOAD - (t - m.lastShot))
  elseif not armed and not forceFire then
    m.state = "on target"
  elseif rock > MAX_ROCK and not forceFire then
    m.state = "ship rocking"
  elseif t - lastAnyShot < STAGGER then
    m.state = "on target"
  else
    -- claim the slot before the call yields, so two cannons can't both fire
    m.lastShot, lastAnyShot = t, t
    m.trigger = true
    pcall(peripheral.call, m.name, "fire", true)
    m.shots = (m.shots or 0) + 1
    m.state = "FIRE"
  end
end

-- ============================================================ screen

local function draw()
  local w = term.getSize()
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  term.setTextColor(colors.yellow)
  write("Gunship " .. VERSION .. "  ")
  if armed then
    term.setTextColor(colors.red)
    write("ARMED")
  else
    term.setTextColor(colors.lime)
    write("SAFE (aiming only)")
  end
  term.setTextColor(colors.white)
  print("")
  print(string.format("Radar: %s   tracks %d   rock %.1f deg/s", radar or "NONE", #tracks, rock))
  print(string.format("Ship speed %.1f m/s  (velocity units %s)", len(shipVel) * 20,
    velScale and (velScale == 20 and "per second" or "per tick") or "learning"))
  if radarError then
    term.setTextColor(colors.red)
    print("Radar error: " .. radarError)
    term.setTextColor(colors.white)
  end
  print("")
  if target then
    local s = target.s
    local spd = len(trackVel(s)) * 20
    term.setTextColor(colors.orange)
    print(string.format("Target: %s %s  %.0fm  %.0f m/s %s", s.cat, s.kind:sub(1, 14), target.d, spd,
      manualPick and "[picked]" or "[auto]"))
    local ago = now() - s.seenAt
    print(string.format("  %+.0f blocks above you   id %s   %s", s.p.y - pose.pos.y, target.id:sub(1, 8),
      target.memory and string.format("radar lost it %.0fs ago", ago) or "on radar"))
    term.setTextColor(colors.white)
  else
    print("Target: none in range")
  end
  if lostMsg and now() - lostAt < 15 then
    term.setTextColor(colors.red)
    print(lostMsg)
    term.setTextColor(colors.white)
  end
  print("")
  for _, m in ipairs(mounts) do
    local col = colors.lightGray
    if m.state == "FIRE" then col = colors.red
    elseif m.state == "on target" then col = colors.lime
    elseif m.state == "aiming" then col = colors.yellow end
    term.setTextColor(col)
    local err = m.err and string.format("%4.1f", m.err) or "   -"
    local line = string.format("%-8s err %s %-13s", m.name:gsub("^cannon_", ""):sub(1, 8), err, (m.state or ""):sub(1, 13))
    if m.info and m.info.yaw then
      line = line .. string.format(" %.0f/%.0f", m.info.yaw, m.info.pitch or 0)
      if m.wantYaw then line = line .. string.format(">%.0f/%.0f", m.wantYaw, m.wantPitch) end
    end
    print(line:sub(1, w))
  end
  term.setTextColor(colors.gray)
  if #mounts > 0 then print("          (yaw/pitch now > wanted)") end
  if #mounts == 0 then
    term.setTextColor(colors.red)
    print("No cannon mounts found (wired modems: right-click them).")
  end
  term.setTextColor(colors.gray)
  local _, h = term.getSize()
  term.setCursorPos(1, h)
  if testMode then
    term.setTextColor(colors.orange)
    write("TEST MODE: cannons swing every 4s.  T to stop")
  else
    write("A arm N next C auto X ignore U unign T test F fire")
  end
  term.setTextColor(colors.white)
end

-- ============================================================ loops

local function mainLoop()
  local lastFind = -999
  while true do
    if now() - lastFind > 5 then
      findHardware()
      lastFind = now()
    end
    if readPose() then
      scan()
      target = pickTarget()
      local jobs = {}
      for _, m in ipairs(mounts) do jobs[#jobs + 1] = function() readMount(m) end end
      if #jobs > 0 then parallel.waitForAll(table.unpack(jobs)) end
      jobs = {}
      for _, m in ipairs(mounts) do jobs[#jobs + 1] = function() aimMount(m) end end
      if #jobs > 0 then parallel.waitForAll(table.unpack(jobs)) end
      forceFire = false
    end
    draw()
    sleep(LOOP)
  end
end

local function keyLoop()
  while true do
    local _, k = os.pullEvent("key")
    if k == keys.a then
      armed = not armed
    elseif k == keys.n then
      nextTarget()
    elseif k == keys.c then
      lockId, manualPick = nil, false
    elseif k == keys.x and lockId then
      ignored[lockId] = true
      saveIgnored()
      lockId, manualPick = nil, false
    elseif k == keys.u then
      ignored = {}
      saveIgnored()
    elseif k == keys.t then
      testMode, testStart = not testMode, now()
    elseif k == keys.f then
      forceFire = true
    end
  end
end

-- updates wait until nothing is being shot at
function readyToUpdate() return not (armed and target) end

findHardware()
for _, m in ipairs(mounts) do pcall(peripheral.call, m.name, "setComputerControl", true) end

-- ============================================================ auto-update

-- Every UPDATE_CHECK_MINUTES this checks GitHub for a newer version. A new
-- version is downloaded, checked that it loads, given your current settings
-- (the UPPERCASE lines at the top of this file), saved, and the computer
-- reboots into it. Set AUTO_UPDATE = false at the top to turn this off.
local UPDATE_REPO = "levisnakes/cc-gunship"
local UPDATE_FILE = "gunship.lua"
local UPDATE_CHECK_MINUTES = 15
local PROGRAM_PATH = (shell and shell.getRunningProgram()) or "startup.lua"
local SHA_FILE = "/.version_" .. UPDATE_FILE

-- Settings are the top-of-file assignments to UPPERCASE names, before the
-- first "local" line or "-- ====" section. Tables can span several lines.
local function splitSettings(src)
  local settings, rest = {}, {}
  local inSettings = true
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if inSettings and (line:match("^local ") or line:match("^%-%- ====")) then inSettings = false end
    table.insert(inSettings and settings or rest, line)
  end
  return settings, rest
end

local function braceDelta(line)
  local code = line:gsub('"[^"]*"', ""):gsub("%-%-.*$", "")
  local _, opens = code:gsub("{", "")
  local _, closes = code:gsub("}", "")
  return opens - closes
end

-- [NAME] = the full statement text, possibly several lines
local function statements(lines)
  local out = {}
  local i = 1
  while i <= #lines do
    local name = lines[i]:match("^([%u_][%u%d_]*)%s*=")
    if name then
      local block = { lines[i] }
      local depth = braceDelta(lines[i])
      while depth > 0 and i < #lines do
        i = i + 1
        table.insert(block, lines[i])
        depth = depth + braceDelta(lines[i])
      end
      out[name] = table.concat(block, "\n")
    end
    i = i + 1
  end
  return out
end

-- New file, with each setting that already exists replaced by your value.
local function mergeSettings(oldSrc, newSrc)
  local oldSettings = statements((splitSettings(oldSrc)))
  local newSettings, rest = splitSettings(newSrc)
  local out = {}
  local i = 1
  while i <= #newSettings do
    local line = newSettings[i]
    local name = line:match("^([%u_][%u%d_]*)%s*=")
    if name and oldSettings[name] then
      table.insert(out, oldSettings[name])
      local depth = braceDelta(line)
      while depth > 0 and i < #newSettings do
        i = i + 1
        depth = depth + braceDelta(newSettings[i])
      end
    else
      table.insert(out, line)
    end
    i = i + 1
  end
  for _, line in ipairs(rest) do table.insert(out, line) end
  local merged = table.concat(out, "\n")
  -- splitting added one trailing newline's worth of empty line; match the source
  if newSrc:sub(-1) == "\n" and merged:sub(-1) ~= "\n" then merged = merged .. "\n" end
  return (merged:gsub("\n\n$", "\n"))
end

local function fetch(url, headers)
  local ok, h = pcall(http.get, url, headers)
  if not ok or not h then return nil end
  local body = h.readAll()
  h.close()
  return body
end

local function readText(path)
  if not fs.exists(path) then return nil end
  local f = fs.open(path, "r")
  local t = f.readAll()
  f.close()
  return t
end

local function writeText(path, text)
  local f = fs.open(path, "w")
  f.write(text)
  f.close()
end

local function checkForUpdate(atBoot)
  if AUTO_UPDATE == false or not http then return end
  local sha = fetch("https://api.github.com/repos/" .. UPDATE_REPO .. "/commits/main",
    { ["Accept"] = "application/vnd.github.sha", ["User-Agent"] = "cc-auto-update" })
  if not sha then return end
  sha = sha:match("^%s*(%x+)%s*$")
  if not sha or #sha < 40 or readText(SHA_FILE) == sha then return end

  local newSrc = fetch("https://raw.githubusercontent.com/" .. UPDATE_REPO .. "/" .. sha .. "/" .. UPDATE_FILE)
  if not newSrc or not load(newSrc, UPDATE_FILE) then return end
  local oldSrc = readText(PROGRAM_PATH)
  if not oldSrc then return end
  local merged = mergeSettings(oldSrc, newSrc)
  if not load(merged, UPDATE_FILE) then return end
  if merged == oldSrc then
    writeText(SHA_FILE, sha)
    return
  end

  -- at boot nothing is running yet, so there is nothing to wait for
  while not atBoot and not readyToUpdate() do sleep(5) end
  writeText(PROGRAM_PATH .. ".old", oldSrc)
  writeText(PROGRAM_PATH, merged)
  writeText(SHA_FILE, sha)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Updated to " .. sha:sub(1, 7) .. ", restarting...")
  if not atBoot then sleep(1) end
  os.reboot()
end

local function updateLoop()
  while true do
    sleep(UPDATE_CHECK_MINUTES * 60)
    pcall(checkForUpdate)
  end
end

-- Check for a new version as soon as the computer starts, before the
-- program runs, so a restart always picks up the latest version.
local function bootUpdate()
  if AUTO_UPDATE == false or not http then return end
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  print("Checking for updates...")
  pcall(checkForUpdate, true)
end


bootUpdate()
parallel.waitForAny(mainLoop, keyLoop, updateLoop)
for _, m in ipairs(mounts) do pcall(peripheral.call, m.name, "fire", false) end
