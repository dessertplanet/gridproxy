# gridproxy

A norns mod that bridges a monome grid (or midigrid) to an external device-mode [mext](https://monome.org/docs/serialosc/osc/) target over USB CDC serial.

Designed for the [Workshop Computer](https://github.com/TomWhitwell/Workshop_Computer) MLR card, but works with any device that speaks the monome mext protocol over a CDC serial port.

## Installation

In maiden REPL:

```
;install https://github.com/dessertplanet/gridproxy
```

Then enable in **SYSTEM > MODS > GRIDPROXY** and restart norns.

## Usage

1. Connect your Workshop Computer (or other mext device) to norns via USB
2. Go to **SYSTEM > MODS > GRIDPROXY**
3. **E3** to select the serial port (ttyACM*)
4. **K3** on CONNECT to start the bridge
5. Grid keys are forwarded to the device; device LED data is displayed on the grid

## Controls

| Control | Action |
|---------|--------|
| **E2** | Navigate menu items |
| **E3** | Select serial port |
| **K3** | Connect / Disconnect / Rescan ports |
| **K2** | Exit menu |

## How it works

- Captures the norns grid via `grid.connect(1)` (compatible with monome grids and midigrid)
- Forwards key presses as mext key events over CDC serial
- Decodes mext LED commands (level_map, led_all, intensity) from the device and displays them on the grid
- Responds to mext discovery queries with the physical grid's dimensions
- Auto-reconnects if the serial device is unplugged and re-plugged
- Detects grid hot-plug/unplug

## Protocol

The mod stays silent for the first 500ms after opening the serial port, allowing the device's protocol detection to default to mext mode (rather than sample-manager mode).

All key events are padded to 64 bytes with `0xFF` for USB bulk packet alignment. Discovery responses are sent unpadded, matching the monome mext specification.

## Compatibility

- **Grids:** monome 64, 128, 256; midigrid (Launchpad, etc.)
- **Devices:** any CDC ACM device speaking the monome mext protocol
- **Tested with:** Workshop Computer MLR card (device mode)

## Files

```
lib/
  mod.lua    — norns mod: grid capture, LED relay, menu UI, reconnect
  mext.lua   — mext protocol encoder/decoder
  serial.lua — serial port abstraction (luaposix)
```
