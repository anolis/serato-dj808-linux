# serato-dj808-linux

Makes the **Roland DJ-808** (and likely other Roland/BOSS USB MIDI controllers)
work with **Serato DJ Pro** running under **Wine** on Linux.

No Windows. No dual-boot. No VM.

---

## Background

Serato DJ Pro uses `libusb` to identify connected hardware controllers.
Under Wine on Linux, the libusb→kernel USB path relies on `CM_Get_Parent`,
which Wine stubs out. As a result, Serato finds the DJ-808's USB device but
can never read its VID/PID, so the device aggregation loop retries forever
(tens of thousands of times per session) and the controller never connects.

This patcher fixes that with four changes:

1. **Custom `libusb-1.0.dll`** — reads VID/PID directly from Wine's device
   registry (`SYSTEM\CurrentControlSet\Enum\USB`) instead of using kernel
   USB ioctls. Serato gets the correct `0x0582 / 0x01C9` identifiers and
   recognises the DJ-808.

2. **LD_PRELOAD hook** — intercepts `open()`/`openat()` in the Wine loader
   and redirects specific DLL paths to our patched copies, without touching
   your system Wine installation.

3. **Binary patches to `Serato DJ Pro.exe`** *(version-specific)* — five
   NOP patches that bypass vtable gate-checks in the USB aggregation
   function. These checks return 0 when no MIDI connection is established
   yet, causing the aggregation to skip its search entirely. The patches
   make the searches run unconditionally on the first attempt.

4. **OAuth URI handler** — registers `seratodjpro://` as a Linux xdg scheme
   so that the login flow (Firefox → `id.serato.com` → redirect back to app)
   completes instead of silently failing.

## Requirements

| Package | Purpose |
|---|---|
| `wine` (WineHQ stable ≥ 10) | Runs Serato |
| `gcc` | Builds the LD_PRELOAD hook |
| `mingw-w64` | Cross-compiles the libusb stub (Windows DLL) |
| `python3` | Applies binary patches |
| `xdg-utils` | Registers the OAuth URI handler |

On Debian/Ubuntu:
```bash
sudo apt install wine-stable gcc mingw-w64 python3 xdg-utils
```

## Usage

1. Install Serato DJ Pro for Windows into your Wine prefix as normal.
2. Run the patcher:

```bash
chmod +x patch.sh
./patch.sh
```

By default it targets `~/.wine` and uses `wine` from `$PATH`.
Override with flags:

```bash
./patch.sh --wineprefix ~/.wine-serato --wine-bin /opt/wine-stable/bin/wine
```

Preview what it will do without changing anything:

```bash
./patch.sh --dry-run
```

3. Launch Serato:

```bash
~/.local/bin/serato-dj-pro
```

Or use the **Serato DJ Pro** shortcut in your application menu.

## Supported Serato versions

| Version | Status |
|---|---|
| 2.5.12 | Fully patched — binary patches + all hooks |
| Others | Hooks and libusb stub applied; binary patches skipped @todo |

> **Note on 4.0.x subscriptions:** Serato DJ Pro 4.0 requires an active
> subscription even if your controller shipped with a perpetual license.
> Version 2.x / 3.x supports perpetual hardware-unlock licenses.
> If you have a perpetual license, install one of those versions instead.

## What gets changed

| File | Change |
|---|---|
| `<serato-dir>/libusb-1.0.dll` | Replaced with our stub (original saved as `.orig`) |
| `<serato-dir>/Serato DJ Pro.exe` | Binary-patched (original saved as `.bak_dj808_<ver>`) |
| `~/.local/share/serato-dj808-linux/wine_open_hook.so` | Built and installed |
| `~/.local/share/serato-dj808-linux/x86_64-windows/` | Patched DLLs cache |
| `~/.local/bin/serato-dj-pro` | Launch wrapper script |
| `~/.local/share/applications/serato-dj-pro.desktop` | Desktop shortcut |
| `~/.local/share/applications/seratodjpro-handler.desktop` | OAuth URI handler |
| Wine registry `HKCR\seratodjpro` | OAuth callback scheme |

## Tested on

- Debian 13 (bookworm) / Wine 11.0 (WineHQ stable)
- Roland DJ-808 (VID `0x0582`, PID `0x01C9`)
- Serato DJ Pro 2.5.12

## Contributing

If you get it working on another Serato version, controller, or distro — please
open a PR with the patch offsets and test results. The binary patch table in
`patch.sh` is designed to be extended with new version entries.

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

## License

MIT. The patched DLL sources (`libusb_stub.c`, `wine_open_hook.c`) are
original work. The binary patches are offsets + byte sequences — no Serato
code is included or redistributed.
