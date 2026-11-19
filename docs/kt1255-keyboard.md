# ThinkPad Compact Bluetooth Keyboard (KT-1255)

Goal: swap Fn and left Ctrl. Status: blocked on hardware (a 3.3 V USB-UART
adapter). Measured on shitbox, 2026-11-19.

## Identity

- Bluetooth HID `17EF:6048`, address `90:7F:61:15:3E:BD`, kernel driver
  `hid-lenovo` (cptkbd path). FCC ID `E8HKT-1255` (Chicony).
- The wired sibling KU-1255 is `17EF:6047`, a different board. Every
  published Fn/Ctrl firmware swap targets the KU-1255 only.

## Pairing

The first pairing stored no bond, so BlueZ rejected the keyboard with
`hidp_add_connection() Rejected connection from !bonded device`. Pair with an
agent that can display a passkey, and type the passkey on the keyboard
within about 30 s:

```
bluetoothctl
agent KeyboardDisplay
default-agent
scan on
pair 90:7F:61:15:3E:BD   # type the printed passkey on the keyboard, Enter
trust 90:7F:61:15:3E:BD
```

`connect` then fails with `br-connection-create-socket`. That is harmless:
the keyboard has already connected itself.

## What the keyboard sends (hidraw capture)

- Report descriptor: report IDs `01` keyboard, `02` mouse, `10` consumer,
  `11` wireless, `12` system, `13` battery + 7-byte vendor feature (reads all
  zero), `15`/`16`/`17` vendor inputs, `18` 8-byte vendor output (commands).
- **Fn press:** one empty keyboard report (`01 00 00 00 …`).
  **Fn release:** nothing. The host therefore cannot tell whether Fn is held,
  so a userspace Fn→Ctrl remap is impossible. Physical Ctrl → Fn layer is
  possible in software, but it is only half a swap.
- Fn+F1: consumer report `10 e2 00` (mute), then `10 00 00`.
- Fn+Esc: vendor report `15 00 02`, then `15 00 00`. The driver toggles
  Fn-lock on it.
- Known commands are output report `18 <cmd> <val>`: `01 03` native
  F7/F9/F11, `02 xx` sensitivity, `05 0|1` Fn-lock, `09 0|1` native middle
  button. No other command is documented.

## USB

The micro-USB port charges only. U3 is a Broadcom **BCM20730** (Cortex-M3
Bluetooth HID SoC with keyscan, no USB PHY), and no chip on the board has
USB. No hidden mode can make it enumerate.

## Hardware and the firmware route

FCC internal photos: <https://fccid.io/E8HKT-1255>.

- U3 BCM20730 A1KFBG, 24 MHz crystal. ROM firmware plus patches and
  configuration in external non-volatile memory (EEPROM or serial flash; chip
  not yet identified).
- U2 48-pin QFN "147A6 HF372 7AV1": the TrackPoint controller. Removing it
  leaves the keys working (<http://bdm.cc/2016/06/lenovo-bluetooth-keyboard-repairs/>).
- Main board `001-21255L-C02`. The back has a 6-pad row at the edge:
  `DGND DIS_B VBATT RX GND TX`, plus test pads `SDA`, `SCL`, `CS`, and the
  key matrix as `R0`–`R7` and `S0`–`S15`.

Adapter to buy: Kjell & Company, Luxorparts USB till seriell-adapter för
Arduino, art.nr 88064 (FT232RL, 5 V/3.3 V switch, sold in about 95 stores).
Set the switch to 3.3 V. Mail-order fallback: Electrokit CP2102, fixed
3.3 V, 59 SEK.

Plan once a 3.3 V adapter is here:

1. Open the keyboard. Find and photograph the memory chip next to U3, and
   note its marking.
2. Connect adapter GND, TX→RX and RX→TX to the pad row. Never connect 5 V.
   Keep the keyboard on battery and leave the adapter VCC unconnected.
3. Try Broadcom HCI over UART (H4/H5, 115200) and read the memory with a
   BCM2073x tool. Fallback: read an I2C EEPROM directly on `SDA`/`SCL`.
4. Find the keyscan table in the dump. The Fn key position is the open
   question: on the TrackPoint Keyboard II, Fn is on its own GPIO outside the
   matrix (<https://github.com/lentinj/tp-compact-keyboard/issues/53>).
   This board may do the same.

Back up the full dump before any write.

## References

- <https://github.com/lentinj/tp-compact-keyboard> (clone in `~/Code/tp-compact-keyboard`)
- KU-1255 swap, for comparison: <https://github.com/haborite/ku1255-firmware-modifier>,
  <https://habr.com/en/articles/742110/>
- `drivers/hid/hid-lenovo.c`, `lenovo_send_cmd_cptkbd`
