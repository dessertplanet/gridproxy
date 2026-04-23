--- serial.lua — Serial port abstraction for CDC ACM devices on norns.
--
-- Uses luaposix for non-blocking I/O.  CDC ACM ignores baud rate
-- but stty still requires one; the actual USB transfer rate is
-- determined by the host controller.
--
-- Usage:
--   local serial = require 'gridproxy/lib/serial'
--   local ports = serial.scan()
--   local port = serial.open(ports[1])
--   serial.write(port, "\x21\x03\x04")  -- mext key down
--   local data = serial.read(port)       -- non-blocking
--   serial.close(port)

local unistd = require("posix.unistd")
local fcntl  = require("posix.fcntl")

local serial = {}

--- Scan for available CDC ACM serial ports.
-- @return table Array of device paths (e.g. {"/dev/ttyACM0"})
function serial.scan()
  local ports = {}
  local handle = io.popen("ls /dev/ttyACM* 2>/dev/null")
  if handle then
    for line in handle:lines() do
      table.insert(ports, line)
    end
    handle:close()
  end
  return ports
end

--- Open and configure a serial port for raw binary communication.
-- CDC ACM devices don't use hardware baud/parity, but the port
-- must be set to raw mode with no echo or line processing.
-- @param path string Device path (e.g. "/dev/ttyACM0")
-- @return table|nil Port handle, or nil on failure
function serial.open(path)
  -- configure: raw mode, no echo, no canonical processing
  os.execute(string.format(
    'stty -F "%s" 115200 raw -echo -echoe -echok -echoctl -echonl '
    .. '-icanon -isig -iexten -opost -onlcr -icrnl -ixon -ixoff '
    .. '2>/dev/null', path))

  local fd = fcntl.open(path,
    fcntl.O_RDWR + fcntl.O_NOCTTY + fcntl.O_NONBLOCK)

  if not fd or fd < 0 then
    print("gridproxy/serial: failed to open " .. path)
    return nil
  end

  return {
    fd = fd,
    path = path,
    connected = true,
  }
end

--- Write raw bytes to the port.
-- @param port table Port handle from serial.open()
-- @param data string Byte string to write
-- @return boolean true on success
function serial.write(port, data)
  if not port or not port.connected or port.fd < 0 then
    return false
  end
  local n, err = unistd.write(port.fd, data)
  if not n then
    print("gridproxy/serial: write error: " .. tostring(err))
    port.connected = false
    return false
  end
  return true
end

--- Non-blocking read from the port.
-- Returns immediately with whatever bytes are available, or nil
-- if none.  On a real error (not EAGAIN), marks the port disconnected.
-- @param port table Port handle from serial.open()
-- @param maxlen number Maximum bytes to read (default 256)
-- @return string|nil Data read, or nil if nothing available
function serial.read(port, maxlen)
  if not port or not port.connected or port.fd < 0 then
    return nil
  end
  maxlen = maxlen or 256
  local data, err = unistd.read(port.fd, maxlen)
  if data and #data > 0 then
    return data
  end
  -- nil or empty string: EAGAIN (no data) is normal with O_NONBLOCK
  if err and err ~= "Resource temporarily unavailable" then
    print("gridproxy/serial: read error: " .. tostring(err))
    port.connected = false
  end
  return nil
end

--- Close the serial port.
-- @param port table Port handle from serial.open()
function serial.close(port)
  if port and port.fd >= 0 then
    unistd.close(port.fd)
    port.fd = -1
    port.connected = false
  end
end

return serial
