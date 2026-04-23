# gridproxy

A norns mod that bridges a monome grid (or midigrid) to an external device-mode [mext](https://monome.org/docs/serialosc/) target over USB CDC serial.

Designed for the [Workshop Computer](https://github.com/TomWhitwell/Workshop_Computer) MLR card, but works with any device that speaks the monome mext protocol over a CDC serial port.

## Installation

In maiden REPL:

```
;install https://github.com/dessertplanet/gridproxy
```

Then enable in **SYSTEM > MODS**, scroll to **GRIDPROXY**, use **E3** to enable, and restart norns.

## Usage

1. Connect your Workshop Computer (or other mext device) to norns via USB
2. Navigate to **SYSTEM > MODS**, highlight **GRIDPROXY**, press **K3** to open the config page
3. Press **K3** on **START BRIDGE** to activate
4. Grid keys are forwarded to the device; device LED data is displayed on the grid
5. Press **K3** on **STOP BRIDGE** to deactivate; **K2** to exit

The bridge starts stopped by default. The serial device auto-connects when plugged in — no port selection needed.

## Controls

| Control | Action |
|---------|--------|
| **K3** | Start / Stop bridge |
| **K2** | Exit mod menu |

## How it works

- Captures the norns grid via `grid.connect(1)` (compatible with monome grids and midigrid)
- Forwards key presses as mext key events over CDC serial (padded to 64 bytes)
- Decodes mext LED commands (`level_map`, `led_all`, `intensity`) from the device and displays them on the grid
- Responds to mext discovery queries with the physical grid's dimensions
- Auto-detects the Workshop Computer via norns' native serial handler API
- Detects grid hot-plug/unplug and re-attaches automatically

## Device compatibility

The serial handler matches devices by USB descriptor:
- `MLRws` or `Workshop` in the model name
- Raspberry Pi Pico-style CDC ACM devices

To support other mext devices, the match function in `lib/serial.lua` can be broadened.

## Protocol notes

- All key events and discovery responses are padded to 64 bytes with `0xFF` for USB bulk packet alignment
- The device firmware must use `tud_mounted()` (not `tud_cdc_n_connected()`) for the CDC read guard, since norns' matron serial handler does not assert DTR

## Compatibility

- **Grids:** monome 64, 128, 256; midigrid (Launchpad, etc.)
- **Devices:** any CDC ACM device speaking the monome mext protocol
- **Tested with:** Workshop Computer MLRws card (device mode)

## Files

```
lib/
  mod.lua    — norns mod: grid capture, LED relay, menu UI, health check
  mext.lua   — mext protocol encoder/decoder
  serial.lua — serial transport (norns native serial API)
```

## License

MIT
