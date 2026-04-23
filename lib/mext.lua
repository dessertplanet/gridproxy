--- mext.lua — monome mext protocol codec for gridproxy.
--
-- Encodes grid→device messages (key events, discovery responses)
-- and decodes device→grid messages (LED commands, discovery queries).
--
-- The Workshop Computer's mext implementation pads all LED/key writes
-- to 64 bytes with 0xFF.  The RX parser skips 0xFF between messages.
-- Discovery queries are sent unpadded.
--
-- Message directions (from our perspective as grid proxy):
--   TX (we send to device): key events, discovery responses
--   RX (device sends to us): LED commands, discovery queries
--
-- Usage:
--   local mext = require 'gridproxy/lib/mext'
--   local bytes = mext.encode_key(3, 2, 1)   -- key down at (3,2)
--   local msgs  = mext.decode(raw_bytes)      -- parse incoming stream

local mext = {}

-- -------------------------------------------------------------------
-- Constants
-- -------------------------------------------------------------------

-- System (addr 0x0)
mext.SYS_QUERY        = 0x00  -- query response / subsystem query
mext.SYS_ID           = 0x01  -- device id / id query
mext.SYS_GRID_OFFSET  = 0x02  -- grid offset
mext.SYS_GRID_SIZE    = 0x03  -- grid size response
mext.SYS_ADDR         = 0x04  -- addr
mext.SYS_SIZE_REQ     = 0x05  -- grid size request (query)
mext.SYS_VERSION      = 0x0F  -- firmware version

-- Key grid (addr 0x2)
mext.KEY_UP           = 0x20  -- key released
mext.KEY_DOWN         = 0x21  -- key pressed

-- LED (addr 0x1) — device→grid direction
mext.LED_OFF          = 0x10  -- single LED off
mext.LED_ON           = 0x11  -- single LED on
mext.LED_ALL_OFF      = 0x12  -- all LEDs off
mext.LED_ALL_ON       = 0x13  -- all LEDs on
mext.LED_MAP          = 0x14  -- binary 8×8 map
mext.LED_ROW          = 0x15  -- binary row
mext.LED_COL          = 0x16  -- binary column
mext.LED_INTENSITY    = 0x17  -- global intensity
mext.LED_SET          = 0x18  -- single LED level (0–15)
mext.LED_ALL          = 0x19  -- all LEDs to level
mext.LEVEL_MAP        = 0x1A  -- 8×8 level map (the main one)
mext.LEVEL_ROW        = 0x1B  -- level row
mext.LEVEL_COL        = 0x1C  -- level column

-- Decoded message types (returned by decode)
mext.MSG_DISCOVERY_QUERY = "discovery_query"
mext.MSG_LEVEL_MAP       = "level_map"
mext.MSG_LED_ALL_OFF     = "led_all_off"
mext.MSG_LED_ALL         = "led_all"
mext.MSG_LED_INTENSITY   = "led_intensity"
mext.MSG_LED_SET         = "led_set"
mext.MSG_UNKNOWN         = "unknown"

-- -------------------------------------------------------------------
-- TX: encode messages we send TO the device
-- -------------------------------------------------------------------

--- Pad data to 64 bytes with 0xFF.
-- @param data string Raw message bytes
-- @return string 64-byte padded message
function mext.pad64(data)
  local len = #data
  if len >= 64 then return data:sub(1, 64) end
  return data .. string.rep("\xFF", 64 - len)
end

--- Encode a grid key event.
-- Padded to 64 bytes for USB bulk alignment.
-- @param x number Column (0-based)
-- @param y number Row (0-based)
-- @param z number 1 = pressed, 0 = released
-- @return string 64-byte padded mext message
function mext.encode_key(x, y, z)
  local header = z == 1 and mext.KEY_DOWN or mext.KEY_UP
  return mext.pad64(string.char(header, x, y))
end

--- Encode a grid size response (sent during discovery).
-- NOT padded — discovery responses are sent unpadded to match viii.
-- @param cols number Grid width (e.g. 16)
-- @param rows number Grid height (e.g. 8)
-- @return string 3-byte mext message
function mext.encode_grid_size(cols, rows)
  return string.char(mext.SYS_GRID_SIZE, cols, rows)
end

--- Encode a subsystem query response.
-- Reports grid subsystem (0x01) with count 1.
-- @return string 3-byte mext message
function mext.encode_query_response()
  -- subsystem 0x01 = grid, count = 1
  return string.char(mext.SYS_QUERY, 0x01, 0x01)
end

--- Encode an ID response.
-- 33 bytes: header + 32-char ID string (NUL-padded).
-- @param id string Device identifier (max 32 chars)
-- @return string 33-byte mext message
function mext.encode_id(id)
  id = id or "gridproxy"
  if #id > 32 then id = id:sub(1, 32) end
  if #id < 32 then id = id .. string.rep("\0", 32 - #id) end
  return string.char(mext.SYS_ID) .. id
end

-- -------------------------------------------------------------------
-- RX: decode messages we receive FROM the device
-- -------------------------------------------------------------------

--- Return expected total message length for a device→grid header byte.
-- These are the LED commands and discovery queries the device sends.
-- @param header number Header byte
-- @return number Total message length including header
local function device_msg_len(header)
  local addr = header >> 4
  local cmd  = header & 0x0F

  if addr == 0x0 then
    -- system / discovery queries
    if cmd == 0x0 then return 1 end  -- query caps (outgoing query)
    if cmd == 0x1 then return 1 end  -- query id
    if cmd == 0x5 then return 1 end  -- query grid size
    return 1
  elseif addr == 0x1 then
    -- LED commands
    if cmd == 0x0 then return 3 end  -- LED off: [hdr, x, y]
    if cmd == 0x1 then return 3 end  -- LED on: [hdr, x, y]
    if cmd == 0x2 then return 1 end  -- all off
    if cmd == 0x3 then return 1 end  -- all on
    if cmd == 0x4 then return 11 end -- MAP: [hdr, x, y, 8 bytes]
    if cmd == 0x5 then return 4 end  -- ROW: [hdr, x, y, bitmask]
    if cmd == 0x6 then return 4 end  -- COL: [hdr, x, y, bitmask]
    if cmd == 0x7 then return 2 end  -- intensity: [hdr, level]
    if cmd == 0x8 then return 4 end  -- LED set: [hdr, x, y, level]
    if cmd == 0x9 then return 2 end  -- LED all: [hdr, level]
    if cmd == 0xA then return 35 end -- LEVEL_MAP: [hdr, x, y, 32 bytes]
    if cmd == 0xB then return 10 end -- LEVEL_ROW: [hdr, x, y, 8 levels]
    if cmd == 0xC then return 10 end -- LEVEL_COL: [hdr, x, y, 8 levels]
    return 1
  end

  return 1  -- unknown: consume single byte
end

--- Create a new streaming decoder.
-- Call decoder:feed(data) with raw bytes; it returns a table of
-- decoded messages each time.
-- @return table Decoder instance
function mext.decoder()
  local d = {
    buf      = {},    -- accumulated bytes for current message
    expected = 0,     -- total bytes expected for current message
  }

  --- Feed raw bytes into the decoder.
  -- @param data string Raw bytes from serial port
  -- @return table Array of decoded message tables
  function d:feed(data)
    local messages = {}

    for i = 1, #data do
      local byte = data:byte(i)

      if self.expected == 0 then
        -- waiting for header — skip 0xFF padding
        if byte == 0xFF then
          -- skip
        else
          self.buf = { byte }
          self.expected = device_msg_len(byte)

          if self.expected <= 1 then
            local msg = self:_dispatch()
            if msg then table.insert(messages, msg) end
            self.expected = 0
            self.buf = {}
          end
        end
      else
        table.insert(self.buf, byte)

        if #self.buf >= self.expected then
          local msg = self:_dispatch()
          if msg then table.insert(messages, msg) end
          self.expected = 0
          self.buf = {}
        end
      end
    end

    return messages
  end

  --- Dispatch a complete message buffer.
  -- @return table|nil Decoded message, or nil if unrecognised
  function d:_dispatch()
    local header = self.buf[1]
    local addr   = header >> 4
    local cmd    = header & 0x0F

    if addr == 0x0 then
      -- system / discovery queries from device
      if cmd == 0x0 or cmd == 0x1 or cmd == 0x5 then
        return {
          type  = mext.MSG_DISCOVERY_QUERY,
          query = header,
        }
      end
      return nil  -- other system messages — ignore

    elseif addr == 0x1 then
      if cmd == 0xA and #self.buf >= 35 then
        -- LEVEL_MAP: unpack 32 bytes → 64 nybble levels
        local x_off = self.buf[2]
        local y_off = self.buf[3]
        local levels = {}
        for j = 0, 31 do
          local packed = self.buf[4 + j]
          local hi = (packed >> 4) & 0x0F
          local lo = packed & 0x0F
          levels[j * 2 + 1] = hi
          levels[j * 2 + 2] = lo
        end
        return {
          type   = mext.MSG_LEVEL_MAP,
          x_off  = x_off,
          y_off  = y_off,
          levels = levels,  -- [1..64] row-major 8×8
        }

      elseif cmd == 0x2 then
        return { type = mext.MSG_LED_ALL_OFF }

      elseif cmd == 0x3 then
        return { type = mext.MSG_LED_ALL_OFF }  -- all on treated same for simplicity

      elseif cmd == 0x7 and #self.buf >= 2 then
        return {
          type  = mext.MSG_LED_INTENSITY,
          level = self.buf[2] & 0x0F,
        }

      elseif cmd == 0x9 and #self.buf >= 2 then
        return {
          type  = mext.MSG_LED_ALL,
          level = self.buf[2] & 0x0F,
        }

      elseif cmd == 0x8 and #self.buf >= 4 then
        return {
          type  = mext.MSG_LED_SET,
          x     = self.buf[2],
          y     = self.buf[3],
          level = self.buf[4] & 0x0F,
        }
      end

      return { type = mext.MSG_UNKNOWN, header = header }
    end

    return { type = mext.MSG_UNKNOWN, header = header }
  end

  return d
end

return mext
