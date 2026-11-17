# nvoffload

A userspace render-offload tool for macOS, in the spirit of Linux `prime-run`, for muxless NVIDIA Optimus
laptops running the [NullMoth NVIDIA driver](https://github.com/nullmoth/nvidia-macos-driver).

**Status: scaffold, not yet compiled.** Written on Linux against the macOS 15 SDK API surface; the first build
happens on the Mac. Expect compiler nits on first `cmake --build`.

## What is in the tree

| Target | Path | Purpose |
|---|---|---|
| `nvprime-run` | `src/launcher/` | CLI launcher. `--info` prints every Metal device with identity flags, every IOAccelerator / IOFramebuffer / PCI display device, CoreGraphics displays, and NullMoth state (bundles, kexts, sysctls, boot-args, SIP). Otherwise injects the dylib and execs the target. |
| `libnvoffload.dylib` | `src/interposer/` | `DYLD_INSERT_LIBRARIES` payload. Interposes `MTLCreateSystemDefaultDevice`, `MTLCopyAllDevices`, `MTLCopyAllDevicesWithObserver`; sets MoltenVK env; swizzles `CAMetalLayer` for the cross-GPU present bridge. |
| `nvoffload-presenter` | `src/presenter/` | Smallest possible experiment: render (CPU or a chosen `MTLDevice`) into an `IOSurface` and show it through `CALayer.contents`. Separates "does IOSurface→screen work on this desktop" from "does NullMoth write frames back where WindowServer can read them". |
| `nvo_diag` | `src/diag/` | The enumeration code, shared by `--info` and the dylib. |

## The machine this was scoped on

Surface Laptop Studio (gen 1), i7-11370H, read from Linux on 2026-11-14:

- Intel Iris Xe `8086:9a49`, PCI class 0300. Owns **every** connector: eDP panel, HDMI, DP-1..3 (USB-C). No MUX in firmware.
- GeForce RTX 3050 Ti Laptop (GA107M) `10de:25a0`, PCI class **0302** (3D controller): no display outputs at all.

So the NVIDIA GPU can never scan out. Frames must cross to the Intel side. There are three ways that can happen, and
the tool behaves differently in each. `nvprime-run --info` tells you which one you are in.

### Mode A: two Metal devices (WhateverXe + NullMoth) — the design target

[WhateverXe](https://github.com/b00t0x/WhateverXe) (BSD-3, b00t0x) loads Apple's own Tiger Lake driver
(`AppleIntelTGLCompat`) on Xe-LP iGPUs; `9A49` is in its implemented list, Tiger Lake-U 48/80 EU tested, the
96 EU H35 part is "expected, untested". With it the iGPU is a real `MTLDevice` (`isLowPower = true`) that owns the
panel, and NullMoth's RTX is a second, headless device. That is exactly Apple's dual-GPU MacBook Pro shape, which
WindowServer already understands. NullMoth issue 494 shows both stacks coexisting (UHD 770 + RTX 3080 Ti, Tahoe).

What nvoffload does here:
1. `MTLCreateSystemDefaultDevice()` → NVIDIA device; `MTLCopyAllDevices()` reordered NVIDIA-first (covers MoltenVK, which puts the default device at `physicalDevices[0]` when `MVK_CONFIG_FORCE_LOW_POWER_GPU=0`).
2. `CAMetalLayer.device = <nvidia>` is intercepted: the layer really sits on the Intel device (so WindowServer composites natively), `framebufferOnly` is forced off, and `nextDrawable` returns a proxy whose `texture` is an NVIDIA texture bound to an `IOSurface`.
3. `[commandBuffer presentDrawable:proxy]` on the NVIDIA command-buffer class adds a completed handler → `synchronizeResource` on the managed texture (render device) → blit `IOSurface` texture into the real drawable on the Intel device → present. Three-deep ring of shared targets per layer.

Open question for the Mac: whether WindowServer can import NullMoth's IOSurfaces directly for a layer whose device is
the NVIDIA GPU (as it does for eGPU-rendered windows on a built-in display). If it can, the bridge is unnecessary and
`--no-bridge` is the right default; the `--trace` log shows it.

### Mode B: single Metal device, panel on the firmware framebuffer (stock NullMoth on 11th gen Intel)

Without WhateverXe, macOS has no Iris Xe driver. The panel is `IONDRVFramebuffer` over the UEFI GOP buffer, one
resolution, CPU-drawn desktop. NullMoth's plugin (`plugin/NVMTLDevice.m` near line 744) withholds the Metal device
from WindowServer when `debug.nvaccel_headless = 1`, so the RTX is an app-only device. Device selection is moot and
there is no presenting GPU to bridge to. nvoffload passes layers through and only traces; `nvoffload-presenter` is the
useful tool here. This is the state in NullMoth issues 119, 135, 219 (all Tiger Lake-H + 30-series/16-series mobile).

### Mode C: NullMoth's kernel hybrid path (`nmhybrid=1..4`)

NullMoth ships `NMIntelFB.kext` (`docs/HYBRID-LAPTOPS.md`): WindowServer composites on the NVIDIA GPU and the kext
drives the Intel display engine (display version 12 = Tiger Lake; `9a49` is in its tables) as "head 4" of the NVIDIA
accelerator, copying or zero-copy-importing each composited frame. It is "built offline, has not run on a hybrid
laptop" except one Alder Lake tester (issue 555). In this mode there is one Metal device and it already owns the
desktop; nvoffload is just diagnostics. `docs/HYBRID-TESTER-PLAN.md` upstream is the test script if you go this way.

## Build (on the Mac)

```
brew install cmake ninja
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build build
./build/nvprime-run --info
```

## Test plan, in order

1. `nvprime-run --info` on the stock machine. Record the whole output. Key lines: device count, `headless=`,
   `lowPower=`, which `IOFramebuffer` class sits under the Intel PCI device, `debug.nvaccel_headless`.
2. `nvoffload-presenter --cpu`. A moving white bar on a gradient means IOSurface→CALayer works on this desktop.
3. `nvoffload-presenter` (no args; picks the NVIDIA device). Colour cycling means NullMoth's managed-texture
   `synchronizeResource` lands pixels in the IOSurface pages that WindowServer reads. Black or stale = the gap is in the
   plugin's host copy path, and that is the first real code problem.
4. `nvprime-run --trace --log=2 /Applications/<some Metal app>.app`. Read what the app got from
   `MTLCreateSystemDefaultDevice` and what each `CAMetalLayer` was handed.
5. With WhateverXe installed (mode A): repeat 1 and 4; then `nvprime-run --log=2 <app>` with the bridge on and
   `--no-bridge` to compare. Metal apps to start with: a `MTKView` sample, then Blender, then a MoltenVK game.

## Running NullMoth and WhateverXe together: config reconciliation

Settings each project asks for, and what to use for both (precedent: NullMoth issue 494, done by hand):

| Setting | NullMoth | WhateverXe | Use |
|---|---|---|---|
| `csr-active-config` | `430A0000` (0x0A43) | `03080000` (0x803) | 0x0A43 (superset of 0x803) |
| `boot-args` | `nvfb=1 nvaccel=1 nvfbheads=4 -nvkmsnosmooth amfi_get_out_of_my_way=0x1 amfi=0x80 ipc_control_port_options=0` | `-allow3d -disablegfxfirmware` | union of both |
| AMFIPass | `AMFIPass.kext` | "AMFIPass 1.4.1 Mod", not both | the Mod only |
| WhateverGreen | may be present (`gfxrst=4` then) | must be **off** | off; drop `gfxrst=4` |
| `Kernel > Block` | `com.apple.iokit.IONDRVSupport` Exclude | — | keep (needed for NVRMFB index 0) |
| DVMT | — | 96 MB, or `-igfxdvmt` + `framebuffer-stolenmem 0000C003` | Surface firmware has no DVMT setting: use the patch |
| SMBIOS | `iMacPro1,1` / `MacPro7,1` | laptop SMBIOS for PNLF | needs a decision; a MacBookPro16,x SMBIOS is what NullMoth laptop reports use |
| `SecureBootModel` | `Disabled` | — | Disabled |

WhateverXe's own caveats: sleep/wake experimental and untested on Tiger Lake, USB-C DP reconnection unreliable,
no Thunderbolt/MST output. Surface Laptop Studio has only USB-C/Thunderbolt outputs, so external displays are a
risk area regardless of the NVIDIA side.

## NVOffload.app (menu bar agent)

`NVOffload.app` bundles `libnvoffload.dylib` and `nvprime-run` and makes the redirect automatic:

- **Offload mode**: Off / Listed apps only / All third-party apps. The choice is written to
  `~/Library/Application Support/nvoffload/policy.json` and applied to the login session with `launchctl setenv`
  (`DYLD_INSERT_LIBRARIES`, `NVOFFLOAD_POLICY`, `NVOFFLOAD_DEVICE=nvidia`, `MVK_CONFIG_FORCE_LOW_POWER_GPU=0`), so apps
  launched afterwards from Finder or the Dock load the dylib. The dylib reads the policy once at load and stays inert in
  processes it does not match (Apple bundle ids, nvoffload's own tools, anything excluded).
- **Heavy-app suggestions**: every 2 s the agent reads each IOAccelerator's `PerformanceStatistics`. When a non-Apple
  frontmost app keeps the Intel GPU at 60 % or more for 8 s while the NVIDIA GPU idles, a notification offers to add it
  to the list for its next launch. Nothing changes without that click.
- **Launch an App on the NVIDIA GPU…** runs one app once through `nvprime-run`, regardless of the policy.
- **Start at Login** writes `~/Library/LaunchAgents/org.nvoffload.agent.plist`; the agent re-applies the session
  environment at every start because `launchctl setenv` does not persist across logins.

Policy file schema: `{"mode": "off|allowlist|all", "apps": ["bundle.id" | "ExecutableName"], "exclude": [...]}`.
Children inherit the environment, so a game started by a launcher such as Steam is evaluated on its own bundle id.

## Vulkan

MoltenVK follows the interposed default device via `MVK_CONFIG_FORCE_LOW_POWER_GPU=0`. Apps that enumerate and filter
physical devices themselves (by `deviceType == INTEGRATED` or by rejecting a headless device) need a Vulkan implicit
layer that hides or reorders devices; that is the next piece if a target app needs it. NullMoth also exposes a native
Vulkan ICD (NVK) on recent versions; check `/Library/GPUBundles/nvmtl` and `vulkaninfo` before assuming MoltenVK.

## Injection caveats

`DYLD_INSERT_LIBRARIES` is honoured only when library validation is off for the target. NullMoth's required
`amfi_get_out_of_my_way=0x1 amfi=0x80` plus SIP 0x0A43 turn it off system-wide, which is why this approach is viable on
a NullMoth machine and not on a stock Mac. Apple-signed system apps still strip the variable.

## Known gaps / TODO

- Not compiled yet. Expect: `NS_RETURNS_RETAINED` placement on the C replacements, `MTLDeviceLocation` enum warnings, `setContentsChanged` selector warning.
- Bridge: only BGRA8 / BGRA8_sRGB / RGBA16Float / RGB10A2 layers are bridged; others pass through with a warning.
- Bridge: the proxy's direct `-present` path is unsynchronized (apps should present via the command buffer; most do).
- Bridge: `presentDrawable:` is hooked on the command-buffer class discovered from one NVIDIA queue; if NullMoth uses several concrete classes, add per-class hooking in `nvo_bridge_install_if_needed`.
- No handling of `CAMetalLayer` moving between displays (per-window device choice).
- `--info` does not yet print per-display → IOFramebuffer mapping (needs `CGDisplayIOServicePort` or the newer `kIODisplayConnect` walk).

## Licence

nvoffload is MIT. It links only Apple frameworks. NullMoth is PolyForm Noncommercial 1.0.0 and is not redistributed
here; WhateverXe is BSD-3-Clause. This tool is a client of both, not a derivative.
