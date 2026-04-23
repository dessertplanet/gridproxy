--- serial.lua — Serial transport using norns core/serial (matron native).
--
-- Wraps norns' built-in serial handler API for CDC ACM devices.
-- No luaposix required — matron handles open/close/termios natively.
--
-- The serial handler matches CDC ACM devices (Workshop Computer shows
-- up as a "Pico" or CDC ACM device).  When connected, data arrives
-- via the event callback and is buffered for the mod to consume.
--
-- Usage:
--   local serial = require 'gridproxy/lib/serial'
--   serial.on_connect = function() ... end
--   serial.on_disconnect = function() ... end
--   serial.on_data = function(data) ... end
--   serial.setup()                   -- register handler
--   serial.write(data)              -- send bytes
--   serial.is_connected()           -- check state

local norns_serial = require 'core/serial'

local serial = {}

-- -------------------------------------------------------------------
-- State
-- -------------------------------------------------------------------

local state = {
  dev        = nil,    -- opaque device pointer from matron
  dev_id     = nil,    -- device id string
  dev_name   = nil,    -- device name
  connected  = false,
  setup_done = false,
}

-- -------------------------------------------------------------------
-- Callbacks (set by mod.lua)
-- -------------------------------------------------------------------

serial.on_connect    = nil   -- function()
serial.on_disconnect = nil   -- function()
serial.on_data       = nil   -- function(data_string)

-- -------------------------------------------------------------------
-- Public API
-- -------------------------------------------------------------------

--- Register the serial handler with norns.
-- Call once at mod startup. The handler auto-detects CDC ACM devices.
function serial.setup()
  if state.setup_done then return end
  state.setup_done = true

  norns_serial.add_handler({
    id = "gridproxy",

    match = function(attrs)
      -- Match any CDC ACM device. The Workshop Computer / RP2040
      -- typically shows as vendor "Raspberry_Pi" or similar.
      -- CDC ACM devices that don't match other handlers will land here.
      -- Accept all — the user selects which port via the mod menu.
      --
      -- For now, accept broad: any device that presents a serial port.
      -- If this is too greedy, narrow to specific VID/PID later.
      return true
    end,

    configure = function(term)
      -- Raw binary mode: disable all processing
      term.iflag = 0     -- no input processing
      term.oflag = 0     -- no output processing
      term.lflag = 0     -- no local flags (no echo, no canonical)
      term.cflag = norns_serial.cflag.CS8
                 + norns_serial.cflag.CREAD
                 + norns_serial.cflag.CLOCAL
      -- CDC ACM ignores baud rate, but set something reasonable
      term.ispeed = norns_serial.speed.B115200
      term.ospeed = norns_serial.speed.B115200
      return term
    end,

    add = function(id, name, dev)
      print("gridproxy/serial: device connected — " .. name .. " (id=" .. tostring(id) .. ")")
      state.dev = dev
      state.dev_id = id
      state.dev_name = name
      state.connected = true
      if serial.on_connect then
        serial.on_connect()
      end
    end,

    remove = function(id)
      if state.dev_id == id then
        print("gridproxy/serial: device disconnected — " .. tostring(state.dev_name))
        state.dev = nil
        state.dev_id = nil
        state.dev_name = nil
        state.connected = false
        if serial.on_disconnect then
          serial.on_disconnect()
        end
      end
    end,

    event = function(id, data)
      if state.dev_id == id and serial.on_data then
        serial.on_data(data)
      end
    end,
  })
end

--- Write raw bytes to the connected serial device.
-- @param data string Byte string to send
-- @return boolean true if write was attempted
function serial.write(data)
  if not state.connected or not state.dev then
    return false
  end
  norns_serial.send(state.dev, data)
  return true
end

--- Check if a serial device is currently connected.
-- @return boolean
function serial.is_connected()
  return state.connected
end

--- Get the connected device name (for display).
-- @return string|nil
function serial.device_name()
  return state.dev_name
end

return serial
