# serato-dj808-linux

Makes **Roland DJ-808** and **Roland DJ-505** (and likely other Roland/BOSS USB MIDI controllers)
work with **Serato DJ Pro** running under **Wine** on Linux.

No Windows. No dual-boot. No VM.

---

## Supported hardware

| Controller | VID | PID | Status |
|---|---|---|---|
| Roland DJ-808 | `0x0582` | `0x01C9` | Working |
| Roland DJ-505 | `0x0582` | `0x0208` | Working |

## Supported Serato versions

| Version | Status |
|---|---|
| 2.5.12 | Fully patched — binary patches + all hooks |
| Others | Hooks and libusb stub applied; binary patches skipped |

> **Note on 4.0.x subscriptions:** Serato DJ Pro 4.0 requires an active
> subscription even if your controller shipped with a perpetual license.
> Version 2.x / 3.x supports perpetual hardware-unlock licenses.
> If you have a perpetual license, install one of those versions instead.

---

## Background

Serato DJ Pro uses `libusb` to identify connected hardware controllers.
Under Wine on Linux, the libusb→kernel USB path relies on `CM_Get_Parent`,
which Wine stubs out. As a result, Serato finds the controller's USB device but
can never read its VID/PID, so the device aggregation loop retries forever
(tens of thousands of times per session) and the controller never connects.

Once USB detection is fixed, two more things are needed for full hardware mode:

- **MIDI identification** — Serato matches the MIDI device to the USB device by
  querying `DRV_QUERYDEVICEINTERFACE`, which must return a USB interface path
  containing the correct VID/PID. Without this, Serato finds the MIDI port but
  treats it as an unknown device.

- **ASIO audio driver** — Serato starts audio through a Roland ASIO COM driver
  (`RDAS*.DLL`). The real driver talks to Roland's kernel USB audio driver,
  which doesn't exist under Wine. A stub DLL implements the full IASIO vtable
  and drives Serato's audio engine via the `bufferSwitch` callback, routing
  output to the default waveOut device.

This patcher applies all of these fixes.

---

## What the patcher does

### 1. Custom `libusb-1.0.dll`
Reads VID/PID directly from Wine's device registry
(`SYSTEM\CurrentControlSet\Enum\USB`) instead of using kernel USB ioctls.
Also checks Linux sysfs to confirm the device is physically present, so
Serato doesn't try to aggregate a controller that isn't plugged in.

### 2. LD_PRELOAD hook
Intercepts `open()`/`openat()` in the Wine loader and redirects specific DLL
paths to our patched copies, without touching your system Wine installation.

### 3. ASIO stub DLLs
Fake Roland ASIO COM drivers that implement the full IASIO vtable:

| DLL | Device | Channels | CLSID |
|---|---|---|---|
| `RDAS1174.DLL` | DJ-808 | 8 in / 8 out | `{D6FB76C2-9C4E-4d46-92F3-649672C65096}` |
| `RDAS1197.DLL` | DJ-505 | 8 in / 6 out | `{8CEA6E64-A172-4bd4-8A9A-0204E73C4005}` |

Both stubs report 1024-sample buffers at 48000 Hz, route output to the default
waveOut device, and use the exact channel names from the real Roland drivers.

### 4. MIDI VID/PID injection (`winealsa.so` patch)
Wine's ALSA MIDI driver reports `wMid=0` / `wPid=0` for all devices.
A patched `winealsa.so` injects the correct Roland VID/PID into the MIDI
capabilities structs based on the ALSA port name, and overrides
`DRV_QUERYDEVICEINTERFACE` to return the correct USB interface path:

```
\\?\USB#VID_0582&PID_01C9#512&256&1&6#{A5DCBF10-6530-11D2-901F-00C04FB951ED}  (DJ-808)
\\?\USB#VID_0582&PID_0208#512&256&1&0#{A5DCBF10-6530-11D2-901F-00C04FB951ED}  (DJ-505)
```

Serato parses this path to extract the VID/PID of the MIDI device and match
it against the USB device it detected. Without this, MIDI and USB are never
associated and hardware mode never activates.

### 5. Binary patches to `Serato DJ Pro.exe` *(version-specific)*
Five NOP patches bypass vtable gate-checks in the USB aggregation function.
These checks return 0 when no MIDI connection is established yet, causing the
aggregation loop to skip its device search entirely. The patches make the
searches run unconditionally on the first attempt.

### 6. OAuth URI handler
Registers `seratodjpro://` as a Linux xdg scheme so that the login flow
(Firefox → `id.serato.com` → redirect back to app) completes instead of
silently failing.

---

## Requirements

| Package | Purpose |
|---|---|
| `wine` (WineHQ stable ≥ 10) | Runs Serato |
| `gcc` | Builds the LD_PRELOAD hook and winealsa patch |
| `mingw-w64` | Cross-compiles the libusb + ASIO stubs (Windows DLLs) |
| `python3` | Applies binary patches |
| `xdg-utils` | Registers the OAuth URI handler |

On Debian/Ubuntu:
```bash
sudo apt install wine-stable gcc mingw-w64 python3 xdg-utils
```

---

## Usage

1. Install Serato DJ Pro for Windows into your Wine prefix as normal.
2. Run the patcher:

```bash
chmod +x patch.sh
./patch.sh
```

3. Launch Serato:

```bash
~/.local/bin/serato-dj-pro
```

Or use the **Serato DJ Pro** shortcut in your application menu.

---

### Patcher options

| Flag | Default | Description |
|---|---|---|
| `--wineprefix PATH` | `~/.wine` | Path to the Wine prefix where Serato is installed |
| `--wine-bin PATH` | `wine` (from `$PATH`) | Path to the Wine binary, e.g. `/opt/wine-stable/bin/wine` |
| `--music-dir PATH` | *(current Wine "My Music" mapping)* | Linux path to your music library root — the directory that contains (or should contain) your `_Serato_` folder. Sets Wine's "My Music" shell folder so crates and library data are written to the right place. If you have an existing Serato library on an external drive, point this at the drive root, e.g. `/media/youruser/MyDrive`. |
| `--dry-run` | off | Print every action without making any changes |
| `--help` / `-h` | | Show usage and exit |

**Common examples:**

```bash
# Non-default Wine prefix and binary (e.g. WineHQ stable alongside system Wine)
./patch.sh --wineprefix ~/.wine-serato --wine-bin /opt/wine-stable/bin/wine

# Point Serato at an external drive music library
./patch.sh --music-dir /media/youruser/MyDrive

# Preview everything without touching anything
./patch.sh --dry-run
```

> **Re-running the patcher is safe.** All steps are idempotent — DLLs are
> rebuilt and redeployed, registry keys are overwritten, and the launch wrapper
> is regenerated. Run it again any time you update Wine or reinstall Serato.

---

### Launch wrapper

The patcher writes `~/.local/bin/serato-dj-pro`, a small script that sets the
required environment and launches Serato:

```bash
export WINEPREFIX=~/.wine
export LD_PRELOAD=~/.local/share/serato-dj808-linux/wine_open_hook.so
exec wine "C:\Program Files\Serato\Serato DJ Pro\Serato DJ Pro.exe"
```

The `LD_PRELOAD` hook is **required** — without it the Wine loader picks up the
system `winmm.dll` instead of the patched copy, and the MIDI device reports the
wrong VID/PID, causing Serato to create split IN/OUT MIDI connections instead of
a single duplex one. That breaks the firmware handshake and hardware mode never
activates.

If you need to launch Serato from a script or another launcher, make sure it
either calls `~/.local/bin/serato-dj-pro` or sets `LD_PRELOAD` itself.

---

## What gets changed

| File | Change |
|---|---|
| `<serato-dir>/libusb-1.0.dll` | Replaced with our stub (original saved as `.orig`) |
| `<serato-dir>/Serato DJ Pro.exe` | Binary-patched (original saved as `.bak_dj808_<ver>`) |
| `<wine-system32>/RDAS1174.DLL` | DJ-808 ASIO stub (built from `rdas808_stub.c`) |
| `<wine-system32>/RDAS1197.DLL` | DJ-505 ASIO stub (built from `rdas505_stub.c`) |
| `~/.local/share/serato-dj808-linux/wine_open_hook.so` | Built and installed |
| `~/.local/share/serato-dj808-linux/x86_64-windows/` | Patched DLLs cache |
| `~/.local/bin/serato-dj-pro` | Launch wrapper script |
| `~/.local/share/applications/serato-dj-pro.desktop` | Desktop shortcut |
| `~/.local/share/applications/seratodjpro-handler.desktop` | OAuth URI handler |
| Wine registry `HKCR\seratodjpro` | OAuth callback scheme |
| Wine registry `HKLM\SOFTWARE\ASIO\DJ-808 ASIO` | ASIO driver registration |
| Wine registry `HKLM\SOFTWARE\ASIO\DJ-505 ASIO` | ASIO driver registration |
| Wine registry `HKLM\SYSTEM\...\Enum\USB\VID_0582&PID_01C9` | USB device entry for DJ-808 |
| Wine registry `HKLM\SYSTEM\...\Enum\USB\VID_0582&PID_0208` | USB device entry for DJ-505 |

---

## Tested on

- Debian 13 (trixie) / Wine 11.0 (WineHQ stable) / kernel 6.12
- Roland DJ-808 (VID `0x0582`, PID `0x01C9`) — Serato DJ Pro 2.5.12
- Roland DJ-505 (VID `0x0582`, PID `0x0208`) — Serato DJ Pro 2.5.12

---

## How the binary patches work

The aggregation function at VA `0x141a3b890` in 2.5.12 has three search paths,
each guarded by a vtable call on the USB device object. The guards check
whether a MIDI connection is already established in the corresponding direction
before running the search. On first connection these all return 0, so no search
ever runs and the loop sleeps and retries indefinitely.

The five patches:

| Name | File offset | Original | Patched | Effect |
|---|---|---|---|---|
| agg9a | `0x1a3fa1a` | `0f 84 …` (JE) | `90 90 90 90 90 90` | bypass direction==3 guard (1) |
| agg9b | `0x1a3fa2d` | `0f 84 …` (JE) | `90 90 90 90 90 90` | bypass direction==3 guard (2) |
| agg10a | `0x1a3bf3b` | `74 11` (JE) | `90 90` | vtable[2] gate — primary search |
| agg10b | `0x1a3c192` | `74 11` (JE) | `90 90` | vtable[3] gate — secondary search |
| agg10c | `0x1a3c4a4` | `74 11` (JE) | `90 90` | vtable[5] gate — tertiary search |

---

## DJ-808 aggregation flow (for contributors)

The full chain that must succeed for Serato to enter hardware mode:

```
libusb USB scan
  → reads HKLM\SYSTEM\...\Enum\USB\VID_0582&PID_01C9\512&256&1&6
  → checks /sys/bus/usb/devices/ to confirm device is physically present
  → fires "New USB Connection" in Serato

Serato aggregation loop  [binary patches required — see below]
  → "New USB device plugged-in: Roland DJ-808"
  → queries MIDI devices for one with matching VID/PID
    → winealsa DRV_QUERYDEVICEINTERFACE returns interface path containing PID_01C9
  → "Firmware supported, device: DJ-808"
  → CNativeMixer : kConnectedMode : hardware=DJ-808
  → Deck Manager : Dual Control enabled : 1

ASIO audio start
  → CoCreateInstance({D6FB76C2-9C4E-4d46-92F3-649672C65096}) → RDAS1174.DLL
  → createBuffers(nch=12)  [4 inputs + 8 outputs]
  → ASIOStart → callback thread begins calling bufferSwitch
  → "Audio Connection to Device: DJ-808 succeeded"
```

Key implementation notes:
- The DJ-808 requires the five `.exe` binary patches (see below). Without them,
  the vtable gate-checks in the aggregation function all return 0 on first
  connection and the loop retries indefinitely (~78,000 times per session).
- `RDAS1174.DLL` reports 4 inputs and 8 outputs (4 stereo pairs, one per deck).
  `MAX_CH=16` in the stub covers the full `nch=12` createBuffers request.
- The DJ-808 MIDI port appears as `direction=duplex` in Serato, same as the
  DJ-505. The USB instance ID suffix is `&6` (vs `&0` for the DJ-505) —
  this comes from the `DRV_QUERYDEVICEINTERFACE` path and must match what is
  registered in the Wine USB registry.
- Audio preferred buffer size is 1024 samples (23 ms). 512 samples causes
  audible crackling under Wine's waveOut timing.

---

## DJ-505 aggregation flow (for contributors)

The full chain that must succeed for Serato to enter hardware mode:

```
libusb USB scan
  → reads HKLM\SYSTEM\...\Enum\USB\VID_0582&PID_0208\512&256&1&0
  → checks /sys/bus/usb/devices/ to confirm device is physically present
  → fires "New USB Connection" in Serato

Serato aggregation loop
  → "New USB device plugged-in: Roland DJ-505"
  → queries MIDI devices for one with matching VID/PID
    → winealsa DRV_QUERYDEVICEINTERFACE returns interface path containing PID_0208
  → "Firmware supported, device: DJ-505"
  → CNativeMixer : kConnectedMode : hardware=DJ-505
  → Deck Manager : Dual Control enabled : 1

ASIO audio start
  → CoCreateInstance({8CEA6E64-A172-4bd4-8A9A-0204E73C4005}) → RDAS1197.DLL
  → createBuffers(nch=14)  [8 inputs + 6 outputs]
  → ASIOStart → callback thread begins calling bufferSwitch
  → "Audio Connection to Device: DJ-505 succeeded"
```

Key implementation notes:
- `createBuffers` is called with `nch=14` (8 inputs + 6 outputs). The ASIO stub
  must allocate at least 14 buffer slots (`MAX_CH ≥ 14`). If `MAX_CH=8`, output
  buffer pointers are left NULL and Serato crashes on the first `bufferSwitch`.
- Serato uses `direction=duplex` for the DJ-505 MIDI connection (single port,
  bidirectional), unlike some other devices that enumerate IN and OUT separately.
- The `NOTV` ("not verified") log message and the sysex handshake that follows
  are non-fatal — Serato enters `kConnectedMode` regardless and the handshake
  completes asynchronously with the real hardware.

---

## Contributing

If you get it working on another Serato version, controller, or distro — please
open a PR with the patch offsets and test results. The binary patch table in
`patch.sh` is designed to be extended with new version entries.

---

## License

MIT. The patched DLL sources (`libusb_stub.c`, `wine_open_hook.c`,
`rdas808_stub.c`, `rdas505_stub.c`) are original work. The binary patches are
offsets + byte sequences — no Serato code is included or redistributed.
