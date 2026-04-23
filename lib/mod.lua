--- mod.lua — gridproxy: bridge a monome grid to a device-mode mext target.
--
-- Captures the norns grid (including midigrid), forwards key events
-- over CDC serial as mext messages, and relays LED data from the
-- remote device back to the physical grid.
--
-- Uses norns' native serial API (matron) — no luaposix dependency.
-- Serial device auto-connects when plugged in; the mod menu shows
-- status and allows enabling/disabling the bridge.
--
-- Protocol detection: the Workshop Computer's device_mode_detect_protocol()
-- waits up to 500ms for a first byte after CDC connects.  If no byte
-- arrives, it defaults to mext mode.  This mod stays silent during that
-- window, so no special handshake byte is needed.
--
-- Install: ;install https://github.com/dessertplanet/gridproxy
-- Then enable in SYSTEM > MODS and restart.

local mod    = require 'core/mods'
local serial = require 'gridproxy/lib/serial'
local mext   = require 'gridproxy/lib/mext'

local m = {}

-- -------------------------------------------------------------------
-- State
-- -------------------------------------------------------------------

local state = {
  -- grid
  grid_dev  = nil,      -- norns grid device
  grid_cols = 16,       -- discovered grid width
  grid_rows = 8,        -- discovered grid height

  -- bridge
  active    = false,    -- true when bridge is running
  serial_connected = false,
  serial_name = nil,

  -- LED buffer (device → grid): 16×16 max, 0–15 levels
  leds      = {},

  -- mext decoder
  decoder   = nil,

  -- health
  health_metro  = nil,
  health_rate   = 1.0,
}

-- Menu navigation
local FOCUS_ACTION = 1
local FOCUS_COUNT  = 1
local menu_focus   = 1

-- -------------------------------------------------------------------
-- Forward declarations
-- -------------------------------------------------------------------

local clear_leds, set_led
local on_grid_key
local handle_discovery, apply_level_map, refresh_grid
local process_serial_data
local grid_connect, grid_disconnect, grid_health_check
local start_bridge, stop_bridge
local health_tick
local grid_lock, grid_unlock

-- Saved original grid.connect for restore on bridge stop
local _original_grid_connect = nil

-- -------------------------------------------------------------------
-- Grid lock: prevent scripts from stealing the grid while bridge is active
-- -------------------------------------------------------------------

-- -------------------------------------------------------------------
-- Grid lock: prevent scripts from stealing the grid while bridge is active.
-- We patch both grid.connect (returns dummy) AND the vport's output
-- methods (led/all/refresh) so scripts with existing references can't
-- flicker the display.
-- -------------------------------------------------------------------

local _dummy_grid = {
  name = "gridproxy (locked)",
  cols = 0,
  rows = 0,
  port = 0,
  device = nil,
  key = function() end,
  led = function() end,
  all = function() end,
  refresh = function() end,
  intensity = function() end,
  rotation = function() end,
  tilt_enable = function() end,
  tilt = nil,
}

-- When true, grid output methods are allowed (only set during our refresh_grid)
local _grid_output_allowed = false

-- Saved original vport methods
local _saved_vport_methods = {}

grid_lock = function()
  if _original_grid_connect then return end  -- already locked

  -- 1) Patch grid.connect to return dummy
  _original_grid_connect = grid.connect
  grid.connect = function(n)
    return _dummy_grid
  end

  -- 2) Patch all vport output methods so only gridproxy can write
  for i = 1, 4 do
    local vp = grid.vports[i]
    if vp then
      _saved_vport_methods[i] = {
        led = vp.led,
        all = vp.all,
        refresh = vp.refresh,
      }
      local orig_led = vp.led
      local orig_all = vp.all
      local orig_refresh = vp.refresh
      vp.led = function(self, ...)
        if _grid_output_allowed then return orig_led(self, ...) end
      end
      vp.all = function(self, ...)
        if _grid_output_allowed then return orig_all(self, ...) end
      end
      vp.refresh = function(self, ...)
        if _grid_output_allowed then return orig_refresh(self, ...) end
      end
    end
  end
end

grid_unlock = function()
  -- Restore grid.connect
  if _original_grid_connect then
    grid.connect = _original_grid_connect
    _original_grid_connect = nil
  end

  -- Restore vport output methods
  for i = 1, 4 do
    local vp = grid.vports[i]
    if vp and _saved_vport_methods[i] then
      vp.led = _saved_vport_methods[i].led
      vp.all = _saved_vport_methods[i].all
      vp.refresh = _saved_vport_methods[i].refresh
    end
  end
  _saved_vport_methods = {}
end

-- -------------------------------------------------------------------
-- LED buffer
-- -------------------------------------------------------------------

clear_leds = function()
  for y = 0, 15 do
    state.leds[y] = state.leds[y] or {}
    for x = 0, 15 do
      state.leds[y][x] = 0
    end
  end
end

set_led = function(x, y, level)
  if y >= 0 and y <= 15 and x >= 0 and x <= 15 then
    state.leds[y] = state.leds[y] or {}
    state.leds[y][x] = level
  end
end

-- -------------------------------------------------------------------
-- Grid → serial: key forwarding
-- -------------------------------------------------------------------

on_grid_key = function(x, y, z)
  if not serial.is_connected() then return end
  -- norns grid delivers 1-based coords; mext uses 0-based
  local msg = mext.encode_key(x - 1, y - 1, z)
  serial.write(msg)
end

-- -------------------------------------------------------------------
-- Serial → grid: LED relay + discovery
-- -------------------------------------------------------------------

handle_discovery = function(query_byte)
  if not serial.is_connected() then return end

  if query_byte == mext.SYS_QUERY then
    serial.write(mext.pad64(mext.encode_query_response()))
  elseif query_byte == mext.SYS_ID then
    serial.write(mext.pad64(mext.encode_id("gridproxy")))
  elseif query_byte == mext.SYS_SIZE_REQ then
    serial.write(mext.pad64(mext.encode_grid_size(state.grid_cols, state.grid_rows)))
  end
end

apply_level_map = function(msg)
  for r = 0, 7 do
    for c = 0, 7 do
      local level = msg.levels[r * 8 + c + 1] or 0
      set_led(msg.x_off + c, msg.y_off + r, level)
    end
  end
end

refresh_grid = function()
  local g = state.grid_dev
  if not g then return end

  -- Allow our output through the vport gate
  _grid_output_allowed = true

  -- LED buffer is 0-based (mext coords); grid:led() is 1-based
  for y = 0, state.grid_rows - 1 do
    for x = 0, state.grid_cols - 1 do
      g:led(x + 1, y + 1, state.leds[y][x] or 0)
    end
  end
  g:refresh()

  _grid_output_allowed = false
end

-- -------------------------------------------------------------------
-- Process incoming serial data (called from serial event callback)
-- -------------------------------------------------------------------

process_serial_data = function(data)
  if not state.active or not state.decoder then return end

  local messages = state.decoder:feed(data)
  local needs_refresh = false

  for _, msg in ipairs(messages) do
    if msg.type == mext.MSG_DISCOVERY_QUERY then
      handle_discovery(msg.query)

    elseif msg.type == mext.MSG_LEVEL_MAP then
      apply_level_map(msg)
      needs_refresh = true

    elseif msg.type == mext.MSG_LED_ALL_OFF then
      clear_leds()
      needs_refresh = true

    elseif msg.type == mext.MSG_LED_ALL then
      for y = 0, 15 do
        for x = 0, 15 do
          state.leds[y][x] = msg.level
        end
      end
      needs_refresh = true

    elseif msg.type == mext.MSG_LED_INTENSITY then
      -- grid varibright handles intensity via levels; ignore

    elseif msg.type == mext.MSG_LED_SET then
      set_led(msg.x, msg.y, msg.level)
      needs_refresh = true
    end
  end

  if needs_refresh then
    refresh_grid()
  end
end

-- -------------------------------------------------------------------
-- Grid capture (with hot-plug re-attach)
-- -------------------------------------------------------------------

grid_connect = function()
  -- Always use the real grid.connect, even if we've monkeypatched it
  local real_connect = _original_grid_connect or grid.connect
  local g = real_connect(1)
  if not g then return end

  state.grid_dev = g
  state.grid_cols = g.cols or 16
  state.grid_rows = g.rows or 8

  g.key = function(x, y, z)
    on_grid_key(x, y, z)
  end

  print("gridproxy: grid attached (" ..
    state.grid_cols .. "x" .. state.grid_rows .. ")")
end

grid_disconnect = function()
  if state.grid_dev then
    pcall(function()
      _grid_output_allowed = true
      state.grid_dev:all(0)
      state.grid_dev:refresh()
      _grid_output_allowed = false
    end)
    state.grid_dev.key = nil
    state.grid_dev = nil
    print("gridproxy: grid detached")
  end
end

grid_health_check = function()
  if not state.active then return end

  if state.grid_dev then
    if state.grid_dev.name == "none" or not state.grid_dev.device then
      print("gridproxy: grid disappeared, releasing")
      grid_disconnect()
    end
  end

  if not state.grid_dev then
    grid_connect()
  end
end

-- -------------------------------------------------------------------
-- Bridge start / stop
-- -------------------------------------------------------------------

start_bridge = function()
  if state.active then return end
  state.active = true

  state.decoder = mext.decoder()
  clear_leds()

  -- wire up serial callbacks
  serial.on_data = process_serial_data

  serial.on_connect = function()
    state.serial_connected = true
    state.serial_name = serial.device_name() or "?"
    print("gridproxy: serial connected — " .. state.serial_name)
    state.decoder = mext.decoder()
    clear_leds()
    grid_connect()
    mod.menu.redraw()
  end

  serial.on_disconnect = function()
    print("gridproxy: serial disconnected")
    state.serial_connected = false
    state.serial_name = nil
    state.decoder = mext.decoder()
    clear_leds()
    if state.grid_dev then
      pcall(function()
        _grid_output_allowed = true
        state.grid_dev:all(0)
        state.grid_dev:refresh()
        _grid_output_allowed = false
      end)
    end
    mod.menu.redraw()
  end

  -- register serial handler (auto-detects CDC ACM devices)
  serial.setup()

  -- If serial was already connected before bridge start, reflect that now.
  if serial.is_connected() then
    state.serial_connected = true
    state.serial_name = serial.device_name() or "?"
    print("gridproxy: serial already connected — " .. state.serial_name)
  else
    state.serial_connected = false
    state.serial_name = nil
  end

  -- capture grid if already present
  grid_connect()

  -- lock grid so scripts get a dummy device
  grid_lock()

  -- health timer for grid hot-plug
  if not state.health_metro then
    state.health_metro = metro.init()
    state.health_metro.time = state.health_rate
    state.health_metro.event = function()
      health_tick()
    end
    state.health_metro:start()
  end

  print("gridproxy: bridge started")
end

stop_bridge = function()
  if not state.active then return end
  state.active = false

  -- unlock grid so scripts can use it again
  grid_unlock()

  if state.health_metro then
    state.health_metro:stop()
    state.health_metro = nil
  end

  grid_disconnect()
  clear_leds()

  serial.on_data = nil
  serial.on_connect = nil
  serial.on_disconnect = nil

  state.decoder = nil

  print("gridproxy: bridge stopped")
end

-- -------------------------------------------------------------------
-- Health tick
-- -------------------------------------------------------------------

health_tick = function()
  grid_health_check()
end

-- -------------------------------------------------------------------
-- Mod hooks — auto-start bridge when mod is loaded
-- -------------------------------------------------------------------

mod.hook.register("system_post_startup", "gridproxy", function()
  clear_leds()
  -- stopped by default; user starts bridge from mod menu
  serial.setup()
end)

-- Re-capture the grid after any script loads (scripts may call
-- grid.connect() which overwrites our key callback).
mod.hook.register("script_post_init", "gridproxy_grid_recapture", function()
  if state.active then
    grid_connect()
  end
end)

-- Also re-capture after script cleanup, in case the outgoing script
-- released or reset the grid device.
mod.hook.register("script_post_cleanup", "gridproxy_grid_recapture_cleanup", function()
  if state.active then
    grid_connect()
  end
end)

-- -------------------------------------------------------------------
-- Mod menu page
-- -------------------------------------------------------------------

m.init = function() end
m.deinit = function() end

m.key = function(n, z)
  if z == 0 then return end

  if n == 2 then
    mod.menu.exit()
  elseif n == 3 then
    if state.active then stop_bridge() else start_bridge() end
    mod.menu.redraw()
  end
end

m.enc = function(n, d)
  -- single-item menu, nothing to scroll
end

m.redraw = function()
  screen.clear()

  -- title
  screen.level(15)
  screen.move(64, 10)
  screen.text_center("GRIDPROXY")

  -- bridge toggle
  screen.level(15)
  screen.move(4, 28)
  screen.text(state.active and "> STOP BRIDGE" or "> START BRIDGE")

  -- serial status
  screen.level(7)
  screen.move(4, 42)
  if state.serial_connected then
    screen.text("serial: " .. (state.serial_name or "connected"))
  else
    screen.text("serial: waiting for device...")
  end

  -- grid status
  screen.move(4, 52)
  if state.grid_dev then
    screen.text("grid: " .. state.grid_cols .. "x" .. state.grid_rows)
  else
    screen.text("grid: not connected")
  end

  screen.update()
end

mod.menu.register(mod.this_name, m)

return m
