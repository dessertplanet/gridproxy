--- mod.lua — gridproxy: bridge a monome grid to a device-mode mext target.
--
-- Captures the norns grid (including midigrid), forwards key events
-- over CDC serial as mext messages, and relays LED data from the
-- remote device back to the physical grid.
--
-- Protocol detection: the Workshop Computer's device_mode_detect_protocol()
-- waits up to 500ms for a first byte after CDC connects.  If no byte
-- arrives, it defaults to mext mode.  This mod stays silent during that
-- window, so no special handshake byte is needed.
--
-- Install: copy the gridproxy/ folder to ~/dust/code/ on norns,
-- enable in SYSTEM > MODS, then restart.

local mod    = require 'core/mods'
local serial = require 'gridproxy/lib/serial'
local mext   = require 'gridproxy/lib/mext'

local m = {}

-- -------------------------------------------------------------------
-- State
-- -------------------------------------------------------------------

local state = {
  -- serial
  ports     = {},       -- available serial port paths
  port_idx  = 1,        -- selected port in menu list
  port      = nil,      -- active serial connection (from serial.open)
  port_path = nil,      -- path of the connected port (for reconnect)
  enabled   = false,    -- true when user has activated the bridge

  -- grid
  grid_dev  = nil,      -- norns grid device
  grid_cols = 16,       -- discovered grid width
  grid_rows = 8,        -- discovered grid height

  -- LED buffer (device → grid): 16×16 max, 0–15 levels
  leds      = {},

  -- mext decoder
  decoder   = nil,

  -- polling
  poll_metro   = nil,    -- serial read + LED refresh metro
  poll_rate    = 0.004,  -- ~250 Hz serial poll (4 ms)

  -- health / reconnect
  health_metro    = nil,     -- slow timer for disconnect detection + reconnect
  health_rate     = 1.0,     -- 1 Hz health check
  read_count      = 0,       -- successful reads since last health tick
  silent_ticks    = 0,       -- consecutive health ticks with no data
  max_silent      = 10,      -- disconnect after 10s silence
  reconnect_wait  = 0,       -- countdown ticks before reconnect attempt

  -- discovery state
  discovery_sent  = false,
  connect_time    = 0,       -- os.clock() when serial was opened
}

-- Menu navigation
local FOCUS_PORT   = 1
local FOCUS_ACTION = 2
local FOCUS_COUNT  = 2
local menu_focus   = 1

-- -------------------------------------------------------------------
-- Forward declarations (Lua requires locals be declared before use)
-- -------------------------------------------------------------------

local clear_leds, set_led
local on_grid_key
local handle_discovery, apply_level_map, refresh_grid, poll_serial
local grid_connect, grid_disconnect, grid_health_check
local handle_serial_lost, health_tick
local port_label, rescan
local start_polling, stop_polling, start_health, stop_health
local serial_connect, connect, disconnect

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
  if not state.port or not state.port.connected then return end
  -- norns grid delivers 1-based coords; mext uses 0-based
  local msg = mext.encode_key(x - 1, y - 1, z)
  serial.write(state.port, msg)
end

-- -------------------------------------------------------------------
-- Serial → grid: LED relay + discovery
-- -------------------------------------------------------------------

handle_discovery = function(query_byte)
  if not state.port or not state.port.connected then return end

  if query_byte == mext.SYS_QUERY then
    serial.write(state.port, mext.encode_query_response())
  elseif query_byte == mext.SYS_ID then
    serial.write(state.port, mext.encode_id("gridproxy"))
  elseif query_byte == mext.SYS_SIZE_REQ then
    serial.write(state.port, mext.encode_grid_size(state.grid_cols, state.grid_rows))
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

  -- LED buffer is 0-based (mext coords); grid:led() is 1-based
  for y = 0, state.grid_rows - 1 do
    for x = 0, state.grid_cols - 1 do
      g:led(x + 1, y + 1, state.leds[y][x] or 0)
    end
  end
  g:refresh()
end

-- -------------------------------------------------------------------
-- Polling / health timer helpers
-- -------------------------------------------------------------------

start_polling = function()
  if state.poll_metro then return end
  state.poll_metro = metro.init()
  state.poll_metro.time = state.poll_rate
  state.poll_metro.event = function()
    poll_serial()
  end
  state.poll_metro:start()
end

stop_polling = function()
  if state.poll_metro then
    state.poll_metro:stop()
    state.poll_metro = nil
  end
end

start_health = function()
  if state.health_metro then return end
  state.health_metro = metro.init()
  state.health_metro.time = state.health_rate
  state.health_metro.event = function()
    health_tick()
  end
  state.health_metro:start()
end

stop_health = function()
  if state.health_metro then
    state.health_metro:stop()
    state.health_metro = nil
  end
end

-- -------------------------------------------------------------------
-- Port helpers
-- -------------------------------------------------------------------

port_label = function(path)
  return path and (path:match("/dev/(.+)") or path) or "(none)"
end

rescan = function()
  state.ports = serial.scan()
  if state.port_idx > #state.ports then
    state.port_idx = math.max(1, #state.ports)
  end
end

-- -------------------------------------------------------------------
-- Grid capture (with hot-plug re-attach)
-- -------------------------------------------------------------------

grid_connect = function()
  local g = grid.connect(1)
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
      state.grid_dev:all(0)
      state.grid_dev:refresh()
    end)
    state.grid_dev.key = nil
    state.grid_dev = nil
    print("gridproxy: grid detached")
  end
end

grid_health_check = function()
  if not state.enabled then return end

  if state.grid_dev then
    -- norns sets device.name to "none" when unplugged
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
-- Serial connection
-- -------------------------------------------------------------------

--- Open serial, init decoder, capture grid, start polling.
serial_connect = function(path)
  if state.port then return true end

  state.port = serial.open(path)
  if not state.port then
    print("gridproxy: connection failed for " .. path)
    return false
  end

  state.port_path = path
  state.connect_time = os.clock()
  state.read_count = 0
  state.silent_ticks = 0
  state.reconnect_wait = 0

  print("gridproxy: serial connected to " .. path)

  state.decoder = mext.decoder()
  state.discovery_sent = false
  clear_leds()

  grid_connect()
  start_polling()
  start_health()
  return true
end

-- -------------------------------------------------------------------
-- Serial disconnect detection
-- -------------------------------------------------------------------

handle_serial_lost = function()
  stop_polling()
  stop_health()

  if state.port then
    pcall(serial.close, state.port)
    state.port = nil
  end
  state.decoder = nil

  -- if still enabled, start health timer for reconnect attempts
  if state.enabled then
    state.reconnect_wait = 3
    start_health()
  end
end

-- -------------------------------------------------------------------
-- Serial poll
-- -------------------------------------------------------------------

poll_serial = function()
  if not state.port or not state.port.connected then return end

  local data = serial.read(state.port, 512)
  if not data then
    if state.port and not state.port.connected then
      print("gridproxy: serial read error — port lost")
      handle_serial_lost()
    end
    return
  end

  state.read_count = state.read_count + 1

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
-- Health tick (1 Hz: silence detection, reconnect, grid hot-plug)
-- -------------------------------------------------------------------

health_tick = function()
  grid_health_check()

  if not state.enabled then return end

  -- serial connected: check for silence / disconnect
  if state.port then
    if not state.port.connected then
      print("gridproxy: serial port flagged disconnected")
      handle_serial_lost()
      return
    end

    if state.read_count == 0 then
      state.silent_ticks = state.silent_ticks + 1
    else
      state.silent_ticks = 0
    end
    state.read_count = 0

    -- don't consider silence in first 3s (device protocol detection window)
    local elapsed = os.clock() - state.connect_time
    if elapsed < 3.0 then
      state.silent_ticks = 0
    end

    if state.silent_ticks > state.max_silent then
      print("gridproxy: no data for " .. state.max_silent .. "s — assuming disconnect")
      handle_serial_lost()
    end
    return
  end

  -- serial not connected: attempt reconnect
  if state.reconnect_wait > 0 then
    state.reconnect_wait = state.reconnect_wait - 1
    return
  end

  if state.port_path then
    local f = io.open(state.port_path, "r")
    if f then
      f:close()
      serial_connect(state.port_path)
    else
      rescan()
      state.reconnect_wait = 3
    end
  end
end

-- -------------------------------------------------------------------
-- User-facing connect / disconnect
-- -------------------------------------------------------------------

connect = function()
  if state.port then return end
  if #state.ports == 0 or state.port_idx > #state.ports then return end

  local path = state.ports[state.port_idx]
  if serial_connect(path) then
    state.enabled = true
  end
end

disconnect = function()
  state.enabled = false
  stop_polling()
  stop_health()
  grid_disconnect()

  if state.port then
    print("gridproxy: disconnecting from " .. state.port.path)
    serial.close(state.port)
    state.port = nil
  end

  state.decoder = nil
  state.discovery_sent = false
  state.port_path = nil
  state.silent_ticks = 0
  state.read_count = 0
  state.reconnect_wait = 0
end

-- -------------------------------------------------------------------
-- Mod hooks
-- -------------------------------------------------------------------

mod.hook.register("system_post_startup", "gridproxy", function()
  rescan()
  clear_leds()
  print("gridproxy: started, " .. #state.ports .. " port(s) found")
end)

-- -------------------------------------------------------------------
-- Mod menu page
-- -------------------------------------------------------------------

m.init = function()
  rescan()
end

m.deinit = function()
  -- keep connection alive when leaving menu
end

m.key = function(n, z)
  if z == 0 then return end

  if n == 2 then
    mod.menu.exit()
  elseif n == 3 then
    if menu_focus == FOCUS_PORT then
      rescan()
    elseif menu_focus == FOCUS_ACTION then
      if state.port then disconnect() else connect() end
    end
  end
end

m.enc = function(n, d)
  if n == 2 then
    menu_focus = util.clamp(menu_focus + d, 1, FOCUS_COUNT)
  elseif n == 3 then
    if menu_focus == FOCUS_PORT and not state.port then
      state.port_idx = util.clamp(state.port_idx + d, 1, math.max(1, #state.ports))
    end
  end
end

m.redraw = function()
  screen.clear()

  -- title
  screen.level(15)
  screen.move(64, 10)
  screen.text_center("GRIDPROXY")

  -- port selection
  local name = "(none)"
  if #state.ports > 0 and state.port_idx <= #state.ports then
    name = port_label(state.ports[state.port_idx])
  end
  screen.level(menu_focus == FOCUS_PORT and 15 or 4)
  screen.move(4, 28)
  screen.text("PORT: " .. name)
  if #state.ports > 1 then
    screen.move(124, 28)
    screen.text_right(state.port_idx .. "/" .. #state.ports)
  end

  -- connect / disconnect button
  screen.level(menu_focus == FOCUS_ACTION and 15 or 4)
  screen.move(4, 40)
  screen.text(state.port and "> DISCONNECT" or "> CONNECT")

  -- status line
  screen.level(7)
  screen.move(4, 56)
  if state.port and state.port.connected then
    local grid_str = state.grid_dev and
      (" | grid " .. state.grid_cols .. "x" .. state.grid_rows) or " | no grid"
    screen.text("connected" .. grid_str)
  elseif state.enabled and not state.port then
    screen.text("reconnecting...")
  elseif state.port then
    screen.text("status: error")
  else
    screen.text("status: idle")
  end

  screen.update()
end

return m
