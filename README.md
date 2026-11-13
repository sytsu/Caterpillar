# Caterpillar

Windows 11 on ARM, running on an iPhone or iPad.

Caterpillar is a fork of [WindowsiOS](https://github.com/ammaarreshi/WindowsiOS) by Ammaar Reshi. The
engine is the same: its own ARM64-to-ARM64 JIT with a software MMU and a virtual board that Windows
boots on (UEFI, ACPI, NVMe, xHCI, VirtIO network, HD Audio). No QEMU, no hypervisor. What Caterpillar
changes is everything around it: the picture fills the phone's screen, the app is built for touch, and
you can install it from an `.ipa`.

> Caterpillar does not include Windows. You bring a Windows 11 ARM64 disk image that you made from
> your own copy. Windows is a trademark of Microsoft; this project is not affiliated with or endorsed
> by Microsoft.

## What is different from WindowsiOS

**The picture fits the screen.** Stock UEFI firmware only offers 640×480, 800×600 and 1024×768, and
Windows keeps whatever the firmware hands over, which is why it used to sit in a small 4:3 box.
Caterpillar works out the shape of your screen and makes the firmware boot at a matching size
(1344×720 on an iPhone 16, for example), so Windows fills the display in landscape with no bars.
See [How the resolution is set](#how-the-resolution-is-set).

**An interface made for a phone.**

- Landscape: Windows takes the whole screen, or the whole screen clear of the camera housing and
  rounded corners. The controls sit in the margin beside the picture, so they never cover Windows.
- Portrait: Windows on top, a trackpad and the keyboard underneath.
- Two ways to use the screen, switched with one tap: **Touch** (the pointer goes where your finger
  is) and **Trackpad** (the finger moves the pointer, like a laptop).
- Controls use Liquid Glass on iOS 26 and later.

**Touch gestures**

| Gesture | Touch | Trackpad |
|---|---|---|
| Tap | Click | Click |
| Drag | Drag | Move the pointer |
| Touch and hold | Right-click | Grab (then drag) |
| Double-tap and drag | | Grab and drag |
| Two-finger drag | Scroll | Scroll |
| Two-finger tap | Right-click | Right-click |
| Three-finger tap | Show or hide the keyboard | Show or hide the keyboard |

**Keyboard.** The iOS keyboard gets an extra row with Esc, Tab, Ctrl, Alt, Win, Shift, the arrows,
Del, Home, End, Page Up, Page Down and F1–F12. Ctrl, Alt, Win and Shift stay armed for the next key,
so Ctrl then C is Ctrl+C. A hardware keyboard and mouse are passed straight through. (The hardware
keyboard and mouse paths have not been tried on a device yet.)

**Less to set up.** The UEFI firmware ships inside the app and the variable store is created for you;
the only file you need is the disk image, and there is an Import button for it.

**Settings.** Resolution (Fast, Balanced, Sharp, Native, Classic 4:3), memory, processor cores, crisp
pixels, a 30 fps limit, pointer speed, scroll direction, start on launch.

**Smaller things.** A menu that sends Ctrl+Alt+Del, Task Manager, Switch App, Close Window and other
key combinations; type the iOS clipboard into Windows; save a screenshot to Files; lock the
orientation; shut down or force stop; the frame rate drops to 30 by itself when the device runs hot;
and the screen no longer misses small changes such as the pointer moving over a still desktop.

## Install

1. Download `Caterpillar.ipa` from [Releases](../../releases).
2. Install it with a sideloading tool: Sideloadly, AltStore, SideStore, or TrollStore.
   For AltStore and SideStore you can add this source instead, and get updates in the app:

   ```
   https://github.com/sytsu/Caterpillar/releases/latest/download/repo.json
   ```
3. Enable JIT (below), import a disk image, and tap **Start Windows**.

Needs iOS or iPadOS 17 or later on an arm64 device. An iPhone with 8 GB of memory (iPhone 15 Pro,
iPhone 16 and later) is the comfortable minimum; Windows gets up to 4.5 GB.

### JIT

Caterpillar translates Windows' code as it runs, and iOS only allows that with JIT enabled.

- **StikDebug** (on the device): install [StikDebug](https://github.com/StikDebug/StikDebug) and pair
  it once. After that, tapping **Start Windows** opens StikDebug, which attaches, grants JIT and
  returns you to Caterpillar. This covers iOS 26 and 27 devices, where JIT needs a debugger to
  answer requests (the script it uses is `ios/Sources/Resources/henge-jit.js`).
- **A Mac and a cable**: `scripts/launch_with_lldb.sh <device-udid>` launches the app, grants JIT
  through LLDB and detaches.

### The disk image

Caterpillar boots a raw disk image named `windows11.img` (or `windows11.hvsparse`, a packed form it
unpacks on first start). Make it on a Mac:

```bash
# Windows 11 ARM64 from Microsoft, as an ESD, in work/downloads/; NetKVM driver from virtio-win
python3 scripts/provision_windows_arm64.py     # installs Windows into work/windows11.img
python3 scripts/optimize_windows_lite.py       # optional: fewer background services, less idle memory
build/hvsparse pack work/windows11_lite.img work/windows11.hvsparse   # optional: skip the empty space
```

Then copy the image to the device (AirDrop, or Finder/Files with a cable) and either tap **Import**
on Caterpillar's first screen, or put it at `Files › Caterpillar › Machines › Win11`.

A Windows 11 ARM64 image installed elsewhere, for example in a virtual machine on a Mac, also boots
as long as Windows is on a GPT disk and was not encrypted with BitLocker.

### Sharing files

`Files › Caterpillar › Shared` on the device is a folder Windows can reach over its virtual network at
`http://10.0.2.4/` (WebDAV). Open that address in a browser inside Windows to download files, or map it
as a network drive: `net use Z: \\10.0.2.4\DavWWWRoot`. Mapping needs Windows' WebClient service,
which a trimmed-down image may have turned off.

### The display driver

Caterpillar's machine has a display adapter (virtio-gpu) whose monitor is exactly the size chosen in
Settings. With its driver, **viogpudo** from the [virtio-win](https://github.com/virtio-win/virtio-win-pkg-scripts)
drivers, Windows treats the phone as a real display of that size: it always starts at that
resolution, with no manual step, and the pointer is drawn by the app instead of by Windows. An image
that has run under QEMU, UTM or another virtio hypervisor usually has the driver already; otherwise
install the virtio-win guest tools inside Windows once.

Without the driver Windows draws into the firmware's boot framebuffer with its basic display driver.
That works, but Windows then reuses the desktop size it last had (often 800×600 or 1024×768) and
scales it into the middle of the screen. Caterpillar notices, keeps touch lined up, and shows a hint;
the manual fix is **Settings › System › Display › Display resolution** in Windows, picking the size
Caterpillar booted at.

### Filling the whole screen

**Settings › Display › Picture › Fill the whole screen** makes the display the full size of the phone's
screen, corner to corner, with nothing stretched: Windows gets a wider monitor (1560×720 on an
iPhone 16 instead of 1344×720). The camera housing and the rounded corners cover a little of the
picture, and the controls fold away to a tab at the edge. It applies the next time Windows starts.

## How the resolution is set

Until Windows' own display driver takes over (and always, if it is not installed), Windows draws
into the framebuffer the firmware set up (GOP) and never changes its size. EDK2's `QemuRamfbDxe` driver keeps its list of sizes in a plain
table: 640×480, 800×600, 1024×768. When that driver first talks to the virtual machine's
configuration device, which is before it has sized its framebuffer, Caterpillar finds the table in
guest memory next to the driver's code and rewrites its entries to the size it wants
(`devices/fw_cfg.c`, `hv_fw_cfg_set_gop_mode`). The firmware file itself is untouched, so a stock
build works, and a firmware reboot is patched again.

The size comes from the screen: the landscape area Windows will fill, at a height picked by the
resolution setting (720, 900, 1080 or every pixel), with the width following the screen's shape.
Because the size is fixed at boot, changing it takes a restart of Windows. Windows draws everything
on the processor, so **Fast** really is faster; raise the scale in Windows' display settings if text
looks small.

## Build

Needs a Mac with Xcode and `brew install xcodegen meson ninja pkgconf`.

```bash
scripts/build_ipa.sh              # dist/Caterpillar.ipa (unsigned)
scripts/build_ipa.sh simulator    # build/sim/Caterpillar.app
```

The first run downloads and cross-compiles libffi, glib and libslirp, and fetches the EDK2 firmware
that QEMU distributes (pinned by checksum). `BUNDLE_ID=com.example.caterpillar scripts/build_ipa.sh`
builds under another bundle identifier (the default is `com.sytsu.caterpillar`). Caterpillar installs
next to WindowsiOS, not over it; move `windows11.img` across in Files if you are switching.

The Simulator build runs the whole machine, JIT included, because a Simulator app is a Mac process.
That makes it a real test bed: put a `windows11.img` (or a symbolic link to one) in the app's
`Documents/Machines/Win11` folder. An empty 80 MB file is enough to reach the UEFI shell.

```bash
scripts/ui_test.sh <simulator-udid>                       # UI tests; screenshots in build/ui-shots
scripts/ui_drive.sh <simulator-udid> "tap 0.5 0.5; shot a" # touch a running session without restarting it
```

The engine also runs as a Mac program, which is how the core is tested:

```bash
make -j8 all test-core
build/winvm --code code.fd --vars vars.fd --disk windows11.img --cpus 4 --ram 4096 --res 1344x720
```

## Layout

| Path | What is there |
|---|---|
| `core/` | The JIT: decoder, translator, dispatcher, software MMU, exceptions, system registers |
| `devices/` | The virtual board: GIC, timers, UEFI flash, fw_cfg, ramfb, ACPI, PCIe, NVMe, xHCI, VirtIO, HD Audio |
| `host/` | Glue to the host: JIT memory, disks, networking (libslirp), audio, the Mac runner |
| `ios/Sources/Native/` | The iOS side of the engine: JIT setup, and the bridge the app talks to |
| `ios/Sources/App/` | The app (SwiftUI) |
| `scripts/` | Building the app, its dependencies, and Windows disk images |
| `tests/` | Engine tests |

## Credits and licence

Caterpillar is free software under the GNU General Public License, version 2 or later; see
[LICENSE](LICENSE). It stands on:

- [WindowsiOS](https://github.com/ammaarreshi/WindowsiOS) by Ammaar Reshi, which this is a fork of.
- [Henge](https://github.com/Leviidev/Henge) and [Husk](https://github.com/Leviidev/Husk) by Leviidev,
  where the JIT engine, the JIT setup for iOS and the file-sharing server come from.
- [TianoCore EDK2](https://github.com/tianocore/edk2), [libslirp](https://gitlab.freedesktop.org/slirp/libslirp),
  [GLib](https://gitlab.gnome.org/GNOME/glib), [libffi](https://github.com/libffi/libffi) and
  [StikDebug](https://github.com/StikDebug/StikDebug).

Full notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
