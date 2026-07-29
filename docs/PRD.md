# gudmac — PRD

**A DisplayLink-style macOS driver for GUD (Generic USB Display) devices.**

Status: Draft v0.1 · 2026-07-28

---

## 1. Summary

gudmac is a user-space macOS app that acts as the *host side* of the [GUD protocol](https://github.com/notro/gud/wiki), the open USB display protocol implemented by the Linux `drivers/gpu/drm/gud` driver. Plug in any GUD device — a Raspberry Pi Zero running the reference gadget, a Pi Pico, an ESP32 monitor, a phone running [gud-gadget](https://github.com/samcday/gud-gadget) — and it appears in macOS as a real display: it shows up in System Settings, windows can be dragged to it, and pixels stream to the device over USB.

Today GUD devices only work with Linux hosts. macOS has no driver, and no public API for third-party display drivers — which is why DisplayLink ships a user-space "virtual graphics card" app rather than a kernel driver. gudmac takes the same proven architecture and points it at an open protocol instead of proprietary silicon.

**Architecture in one sentence:** create a virtual display with the `CGVirtualDisplay` CoreGraphics SPI → capture its pixels with ScreenCaptureKit → convert/compress damage rects (LZ4) → send them to the device via IOUSBHost per the GUD wire protocol.

## 2. Goals and non-goals

### Goals

- **G1 — Any compliant GUD device works.** Interop with every known implementation: Linux kernel gadget (`f_gud`), samcday/gud-gadget (Rust/FunctionFS), gud-pico (USB 1.1 full speed), ESP32 monitors. The protocol has no formal spec — the Linux host driver *is* the spec — so compatibility means faithfully replicating `gud_drv.c` / `gud_pipe.c` / `gud_connector.c` behavior.
- **G2 — Real display semantics.** The GUD device is a first-class macOS display: extend or mirror, arrangement in System Settings, HiDPI modes where the device resolution warrants it, correct size-in-millimeters from EDID when available.
- **G3 — Zero-config.** Plug in → display appears (after one-time permission grants). Unplug → display disappears cleanly, windows migrate back.
- **G4 — Usable performance on USB 2.0.** Smooth desktop/productivity use at the device's native resolution; graceful degradation (frame dropping, never corruption) under full-motion video.
- **G5 — Survivable distribution.** Developer ID signed + notarized menu-bar app, auto-start login item, no kernel extensions, no root requirement in the common case.

### Non-goals (v1)

- **Not a DisplayLink replacement.** DisplayLink chips speak a proprietary protocol; this driver speaks GUD only.
- **No pre-login display.** TCC screen capture requires a user session; no image at the login window or FileVault preboot (same limitation DisplayLink has, minus their login-screen extension).
- **No HDCP/DRM content.** The pixel path is screen capture; protected playback (Netflix in Safari, etc.) will blank or be refused by the OS. Document, don't fight.
- **No audio, no touch/HID backchannel.** GUD is display-only; composite gadgets may expose HID on other interfaces, which macOS handles natively anyway.
- **No App Store distribution.** `CGVirtualDisplay` is private API; App Review rejects it. Notarization does not (it's a malware scan, not an API scan) — this is the same path BetterDisplay and DisplayLink Manager ship through.
- **v1 protocol subset:** no TV-connector properties (margins/hue/etc.), no device-side rotation. Backlight is a stretch goal.

## 3. Users

1. **Tinkerers/makers** with a Pi Zero/Pico/ESP32 "$5 USB monitor" who want it to work on their Mac like it does on Linux.
2. **Linux-phone users** (postmarketOS + gud-gadget) using their phone as a portable second display for a MacBook.
3. **Hardware builders** prototyping USB display products who want a cross-platform open protocol instead of licensing DisplayLink.

## 4. Background: the GUD protocol (what we must implement)

Reference: `include/drm/gud.h` (Linux ≥5.13; three pixel formats added in 5.16, no wire changes since). Protocol version is **1** and has never been bumped; extensibility is via new pixel-format bytes and property IDs that hosts must skip when unknown.

### 4.1 Device identification

- Match **VID `0x1d50` / PID `0x614d`** (Openmoko-registered) **and `bInterfaceClass = 0xFF`** (vendor specific). Matching is per-interface — GUD may be one function of a composite device.
- Confirm by reading the display descriptor and checking **magic `0x1d50614d`**; if absent, release the interface (it's some other vendor function).
- Required endpoints: **EP0 + one bulk OUT**. Nothing else. No interrupt endpoint — hotplug/status is polled.

### 4.2 Control plane

All requests are vendor+interface control transfers (`bmRequestType` 0xC1 IN / 0x41 OUT), `wValue` = connector index for connector requests, `wIndex` = interface number, little-endian packed structs, serialized (one at a time), 5 s timeout.

| Req | Dir | Purpose |
|---|---|---|
| `0x00 GET_STATUS` | IN | 1-byte status: OK / BUSY / REQUEST_NOT_SUPPORTED / PROTOCOL_ERROR / INVALID_PARAMETER / ERROR |
| `0x01 GET_DESCRIPTOR` | IN | magic, version, flags (`STATUS_ON_SET`, `FULL_UPDATE`), compression bitmask (LZ4), `max_buffer_size`, min/max width/height |
| `0x40 GET_FORMATS` | IN | byte array of pixel formats (max 32) |
| `0x41 GET_PROPERTIES` | IN | plane properties (rotation), max 32 |
| `0x50 GET_CONNECTORS` | IN | array of {type, flags} (max 32); flags: POLL_STATUS, INTERLACE, DOUBLESCAN |
| `0x51 GET_CONNECTOR_PROPERTIES` | IN | per-connector properties (TV props, backlight) |
| `0x53 SET_CONNECTOR_FORCE_DETECT` | OUT | zero-length, before a forced status probe |
| `0x54 GET_CONNECTOR_STATUS` | IN | bits 0–1 connected/disconnected/unknown; bit 7 CHANGED → re-enumerate modes |
| `0x55 GET_CONNECTOR_MODES` | IN | array of 24-byte mode structs (max 128), DRM-style timings + PREFERRED flag |
| `0x56 GET_CONNECTOR_EDID` | IN | EDID blob, multiple of 128 B, max 2048 |
| `0x60 SET_BUFFER` | OUT | damage rect header: x, y, w, h, length, compression, compressed_length |
| `0x61 SET_STATE_CHECK` | OUT | full state: mode timings + format + connector + **complete property array, every time** |
| `0x62 SET_STATE_COMMIT` | OUT | zero-length; applies last CHECK |
| `0x63 SET_CONTROLLER_ENABLE` | OUT | u8 0/1 |
| `0x64 SET_DISPLAY_ENABLE` | OUT | u8 0/1 (DPMS) |

Error protocol: on a **STALL**, issue `GET_STATUS` to learn why. If the descriptor sets **`STATUS_ON_SET`**, issue `GET_STATUS` after *every successful SET* as well — the Linux composite gadget framework can't fail a control-OUT status stage, so all Linux-kernel-based gadgets need this. **Mandatory for interop.** `INVALID_PARAMETER` in response to `SET_STATE_CHECK` means "device can't do this state" — pick a different mode, don't treat it as fatal.

### 4.3 Initialization & modeset sequence

1. `GET_DESCRIPTOR` → validate magic, `version == 1`, sane min/max dims; reject `FULL_UPDATE`+compression combo.
2. `GET_FORMATS`, `GET_PROPERTIES`, `GET_CONNECTORS`, per-connector properties. Skip unknown properties (forward compat — samcday's gadget replies with zeroed property structs and the Linux host just logs and continues; we must too).
3. Modes: `GET_CONNECTOR_EDID`, then `GET_CONNECTOR_MODES`. If MODES is non-empty it *is* the mode list (EDID is informational — monitor name, physical size); if empty, parse modes from EDID.
4. Enable: `SET_STATE_CHECK` → `SET_CONTROLLER_ENABLE 1` → `SET_STATE_COMMIT` → `SET_DISPLAY_ENABLE 1` → first full-frame flush. Disable in reverse.
5. Poll `GET_CONNECTOR_STATUS` every **10 s** for connectors flagged POLL_STATUS; honor the CHANGED bit by re-fetching EDID/modes.
6. **Only one connector may be active at a time** (single pipe in the protocol).

### 4.4 Pixel data plane

Per damage flush:

1. Extract the damage rect from the framebuffer, **tightly packed to rect width** (no stride), rows top-to-bottom.
2. Convert to the negotiated device format if needed.
3. Optionally LZ4-compress — **raw LZ4 block, no frame header**; `length` = uncompressed size, `compressed_length` = wire size. If compression doesn't shrink, send uncompressed (per-transfer fallback; device must accept both).
4. `SET_BUFFER` control request, then **one bulk OUT transfer** of the payload.

Constraints:

- If the rect exceeds `min(host buffer, device max_buffer_size)`, split **horizontally into whole-line bands**, each with its own SET_BUFFER + bulk pair. (Splits can tear; unavoidable at protocol level.)
- **`FULL_UPDATE` devices:** always send the whole frame and *omit* SET_BUFFER entirely — except once after a failed bulk transfer, as a device resync. Incompatible with compression.
- Retry a failed flush **once**; then drop until new damage arrives.
- Coalesce pending damage into a bounding rect between flushes (v1; per-rect batching is a later optimization).

Pixel formats (1 byte each): `R1 0x01`, `R8 0x08` (5.16+), `XRGB1111 0x20`, `RGB332 0x30` (5.16+), `RGB565 0x40`, `RGB888 0x50` (5.16+), `XRGB8888 0x80`, `ARGB8888 0x81`. Host renders XRGB8888 internally and converts down. **v1 must support conversion to: RGB565, XRGB8888, RGB888, R1, R8** (R1 monochrome via grayscale threshold, byte-aligned rect x, matching the Linux host). `XRGB1111`/`RGB332` are stretch.

## 5. Product requirements

### 5.1 Functional

| ID | Requirement | Priority |
|---|---|---|
| F1 | Detect GUD device attach/detach (VID/PID/class match + magic verification) and create/destroy the virtual display automatically | P0 |
| F2 | Full protocol init, mode enumeration (mode-list *and* EDID-only devices), check/commit/enable sequencing per §4.3 | P0 |
| F3 | Virtual display registered with macOS: appears in System Settings › Displays, participates in arrangement, extend + mirror | P0 |
| F4 | Mode list mapped from device modes; expose HiDPI (2×) variants when device resolution ≥ ~1920 wide; user-selectable mode switches re-negotiate via STATE_CHECK/COMMIT | P0 |
| F5 | Damage-driven streaming: only changed regions transferred, using ScreenCaptureKit dirty rects; idle screen ≈ zero USB traffic | P0 |
| F6 | LZ4 block compression when device advertises it, with per-flush uncompressed fallback | P0 |
| F7 | Format conversion per §4.4 format list | P0 (R1/R8: P1) |
| F8 | STATUS_ON_SET and STALL→GET_STATUS error protocol | P0 |
| F9 | FULL_UPDATE device support (Pi Pico class) | P1 |
| F10 | Connector status polling, CHANGED-bit re-enumeration, multi-connector devices (activate first connected) | P1 |
| F11 | Menu-bar UI: per-device status, resolution picker, fps/bandwidth stats, pause streaming, launch-at-login toggle | P1 |
| F12 | Sleep/wake: DPMS off (`SET_DISPLAY_ENABLE 0`) on sleep, full re-init on wake; clean teardown on unplug (controller disable is moot — device is gone — but virtual display must be destroyed promptly so windows migrate) | P0 |
| F13 | Multiple simultaneous GUD devices (macOS caps virtual displays at ~4 system-wide) | P1 |
| F14 | Backlight brightness slider (GUD_PROPERTY_BACKLIGHT_BRIGHTNESS via state resend) | P2 |
| F15 | Device-side rotation property | P2 |

### 5.2 Performance targets

USB 2.0 real-world bulk throughput is ~29 MB/s to a Pi 4-class gadget (~21 MB/s Pi Zero); Linux-host reference numbers at 1080p RGB565 are 7–22 fps on USB 2.0 depending on content compressibility, 19–41 fps on USB 3.x. Targets (RGB565, USB 2.0 high-speed device, typical desktop content):

| Scenario | Target |
|---|---|
| Idle desktop | ~0 MB/s USB, <1% CPU |
| Typing/scrolling (small damage) | 30+ fps perceived, no visible lag |
| 1080p full-screen video | ≥ 10 fps sustained, no corruption, no unbounded queueing (drop frames instead) |
| 800×600-class device (Pi Zero) | 25+ fps mixed content — parity with the Linux host |
| End-to-end latency (damage → on wire) | < 50 ms typical |
| Host CPU while streaming actively | < 1 P-core equivalent at 1080p (conversion+LZ4 are memory-bandwidth-cheap on Apple Silicon) |

These are engineering estimates pending M1 measurement (see Risks R6).

### 5.3 Compatibility matrix (release gate)

| Device | Transport | Exercises |
|---|---|---|
| samcday/gud-gadget on a Linux phone/SBC | USB 2.0 | RGB565, LZ4, permissive state handling, sloppy responses (zero-byte-padded EDID/properties) |
| Linux kernel gadget (`f_gud`) on Pi 4 / Pi Zero | USB 2.0 | STATUS_ON_SET path, XRGB8888, backlight property |
| notro/gud-pico (Pi Pico) | USB 1.1 FS | FULL_UPDATE, RGB565/R1, 64-byte bulk packets, tiny max_buffer_size |
| Linux host driver as behavioral oracle | — | Any divergence in request ordering/contents observed via USB capture is a bug |

macOS support: **macOS 14 (Sonoma) and 15 (Sequoia)**, Apple Silicon primary, Intel best-effort.

## 6. Architecture

Single user-space process (menu-bar app), no kexts, no DriverKit (DriverKit has no display family — this is *why* the whole product category is user-space).

```
┌───────────────────────────────── gudmac.app ─────────────────────────────────┐
│                                                                              │
│  USB Monitor ──▶ Device Session (one per GUD device)                         │
│  (IOUSBHost        │                                                         │
│   matching)        ├── Protocol Client ── control requests, state machine    │
│                    │      (IOUSBHostPipe: EP0 + bulk OUT)                    │
│                    ├── Virtual Display ── CGVirtualDisplay (private SPI)     │
│                    │      descriptor from EDID/modes; HiDPI mode pairs       │
│                    ├── Capture ── ScreenCaptureKit SCStream on that display  │
│                    │      IOSurface frames + dirtyRects + idle-skip          │
│                    └── Pipeline ── damage merge → format convert → LZ4 →     │
│                           SET_BUFFER + bulk write (dedicated serial queue)   │
│                                                                              │
│  Menu-bar UI · settings · stats · launch-at-login (SMAppService)             │
└──────────────────────────────────────────────────────────────────────────────┘
```

Key decisions:

1. **USB via IOUSBHost, no entitlement, no root.** GUD interfaces are vendor-class (0xFF) so no Apple class driver claims them; an unclaimed interface can be opened exclusively by a non-sandboxed Developer ID app. No device capture, no `com.apple.vm.device-access`. (Validated in M0 — this rule is assembled from Apple forum/DTS guidance, not a single doc.) libusb is a fallback, not an advantage.
2. **Virtual display via `CGVirtualDisplay`** (`CGVirtualDisplayDescriptor` / `Settings` / `Mode`): the only mechanism on modern macOS, used by DisplayLink Manager, BetterDisplay, Sidecar itself. Set vendor/product/serial from the USB device, physical size from EDID, provide 1× and 2× mode variants. Refresh is effectively capped at 60 Hz — fine, USB is the bottleneck anyway. DeskPad ships a complete reverse-engineered header (`CGVirtualDisplayPrivate.h`, MIT) that is directly reusable: modes are plain `{width, height, refreshRate}` objects, `CGVirtualDisplaySettings.hiDPI = 1` makes macOS synthesize the scaled "looks like" variants, and color primaries/white point are optional (DeskPad omits them entirely). The created display exposes `displayID` (`CGDirectDisplayID`) — the handle for scoping capture and for `NSScreen` lookup. **User-initiated mode switches** (System Settings, RDM, etc.) are observed via `NSApplication.didChangeScreenParametersNotification` → find our `NSScreen` by `displayID` → read new `frame.size`/`backingScaleFactor` → renegotiate with the device (STATE_CHECK/COMMIT) — DeskPad demonstrates exactly this loop.
3. **Capture via ScreenCaptureKit only.** `CGDisplayStream` is obsoleted in the macOS 15 SDK — DeskPad still uses it (BGRA, IOSurface handler), which confirms capture *works* against a CGVirtualDisplay but disqualifies that API going forward. Concrete SCK design, verified against the SDK headers (everything below is available since SCK's introduction in macOS 12.3 unless noted):
   - **Discovery/filter:** `SCShareableContent.getShareableContent…` → match `SCDisplay.displayID` against our `CGVirtualDisplay.displayID` → `SCContentFilter(display:excludingWindows: [])`.
   - **Configuration:** `width`/`height` in *pixels* at the device's native resolution; `pixelFormat = 'BGRA'`; `queueDepth` default 8 (hard max 8 — return buffers promptly or the stream stalls); `showsCursor = true` (GUD has no cursor plane, so the cursor must be composited into the frame); `minimumFrameInterval` default 1/60, raised adaptively under USB backpressure via `updateConfiguration(_:)` — config and filter updates are live, no stream restart.
   - **Frame handling:** `SCStreamOutput` delivers IOSurface-backed `CMSampleBuffer`s with per-frame attachments. `SCStreamFrameInfoStatus`: process `.complete` (and `.started` = first frame → full-frame damage), skip `.idle` (unchanged) — this is the zero-traffic-when-idle mechanism; `.blank`/`.suspended` are candidates for driving `SET_DISPLAY_ENABLE 0` on the device. `SCStreamFrameInfoDirtyRects`: "union of rectangles that were redrawn and rectangles that were moved," CGRects **in pixels** — available since 12.3 (previously-flagged uncertainty: resolved). `SCStreamFrameInfoDisplayTime` (mach time) feeds latency stats.
   - **Failure handling:** `SCStreamDelegate.didStopWithError` — notably `SCStreamErrorUserDeclined` (-3801) when Screen Recording permission is revoked (incl. macOS 15 monthly re-approval lapses) → surface in menu-bar UI, auto-restart on regrant. `SCContentFilter` scoped to our virtual display; BGRA IOSurface output; `minimumFrameInterval` adaptively raised under USB backpressure; `SCStreamFrameInfo` `.status == .idle` → skip, `.dirtyRects` → damage list. Buffers returned to the pool promptly (copy-out happens in the conversion step anyway, since GUD needs tightly-packed re-layout).
4. **Backpressure = frame dropping.** One flush in flight per device; if a new frame arrives while busy, merge its damage into the pending rect and drop the older pixels. Never queue frames.
5. **Threading:** SCK delivers on its own queue → hand IOSurface to a per-device serial pipeline queue → convert+compress (Accelerate/`vImage` for swizzles, `liblz4`-compatible block API — note Apple's `Compression` framework LZ4 uses a framed variant with block headers; we need **raw block** format, so vendor upstream lz4) → synchronous bulk write. Control requests serialized on the same queue as required by the protocol.

### Permissions & first-run UX

- **Screen Recording (TCC)**: required; one-time System Settings toggle + app relaunch. On macOS 15, monthly re-approval prompts apply; request Apple's restricted **Persistent Content Capture** entitlement (granted case-by-case to remote-desktop-class apps; we're a strong candidate) — until granted, the monthly nag is documented behavior.
- Onboarding flow: detect missing permission → explainer window with deep-link to the Settings pane → auto-relaunch.

## 7. Milestones

- **M0 — Spike (de-risk everything private/uncertain):** open a gud-gadget device via IOUSBHost without entitlements; run the full init sequence from a CLI tool; push a static test pattern. Separately: create a CGVirtualDisplay (bootstrap from DeskPad's `CGVirtualDisplayPrivate.h`) + SCK capture loop with dirty rects — the open verification is SCK-on-virtual-display, since DeskPad only proves the CGDisplayStream pairing. *Exit: pixels from macOS visible on a GUD panel; both SPI paths confirmed on macOS 14 + 15.*
- **M1 — Vertical slice:** end-to-end live desktop on one device — RGB565 + XRGB8888, LZ4, damage streaming, STATUS_ON_SET, clean plug/unplug. *Exit: daily-drivable second display from a Pi 4 gadget.*
- **M2 — Any-device compliance:** format conversions (R1/R8/RGB888), FULL_UPDATE (Pi Pico), EDID-only devices, transfer splitting, status polling + CHANGED, error/retry policy, USB capture diffing against the Linux host oracle. *Exit: compatibility matrix green.*
- **M3 — Product:** menu-bar UI, onboarding/permissions flow, sleep/wake, multi-device, stats, signing + notarization + Sparkle updates, docs. *Exit: public beta.*
- **M4 — Polish (post-v1):** backlight, rotation, adaptive quality for video regions, performance tuning, Persistent Content Capture entitlement pursuit.

## 8. Risks

| # | Risk | Sev | Mitigation |
|---|---|---|---|
| R1 | **`CGVirtualDisplay` is private SPI** — Apple could break it in any release | High | It has been stable macOS 11→15 and load-bearing for DisplayLink/BetterDisplay/Sidecar-adjacent code; pin known-good behavior per OS in CI; abstract behind one module; accept as existential platform risk (there is no alternative) |
| R2 | IOUSBHost exclusive-open rules differ from forum-derived understanding (some config needs root/capture) | Med | M0 spike on both macOS versions; fallback: privileged helper via SMJobBless-style install (avoid if possible) |
| R3 | macOS 15 monthly screen-capture re-prompt degrades "it just works" | Med | Persistent Content Capture entitlement request; clear UX when capture silently stops |
| R4 | SCK dirty rects unreliable with multiple virtual displays (frames misattributed — reported in Apple forums) | Med | Multi-display test in M2; fallback to per-frame full-damage diffing (CPU tile-hash) if rects prove wrong |
| R5 | Device ecosystem is permissive/sloppy (zero-padded EDID, junk properties) and the kernel GUD driver is now orphaned upstream — real devices are the compat target, not the letter of gud.h | Med | Tolerance rules from §4 (skip unknowns, accept short/odd responses like the Linux host does); compat matrix as release gate |
| R6 | USB 2.0 bandwidth makes video content disappointing (10–20 fps at 1080p) | Low | Expectation-setting in docs; adaptive frame interval; post-v1 lossy fallback for high-motion regions |
| R7 | GUD protocol is Linux-host-defined with no conformance suite | Low | Treat Linux host as oracle (USB captures); contribute findings back to the GUD wiki |

## 9. Open questions

1. **Mirroring semantics:** when the user mirrors a physical display to the GUD display, does SCK capture of the virtual display behave identically? (Test in M1.)
2. **HiDPI heuristics:** offer 2× modes for small panels (e.g. 800×480) where "looks like 400×240" may be more useful than native? User-configurable?
3. **Persistent Content Capture:** will Apple grant it to a display driver (vs. remote desktop)? Apply early with DisplayLink precedent as the argument.
4. **Update cadence for new pixel formats/properties** landing in future Linux versions — track `include/drm/gud.h` even though the in-kernel driver is orphaned?
5. **Monetization/licensing:** open source (fits the GUD ecosystem ethos and this repo) vs. freemium à la BetterDisplay — out of scope for this PRD but affects Sparkle/notarization infra choices.

## 10. References

- GUD protocol wiki (Noralf Trønnes): https://github.com/notro/gud/wiki — protocol, performance data, gadget docs
- Linux host driver (the de facto spec): https://github.com/torvalds/linux/tree/v5.13/drivers/gpu/drm/gud + `include/drm/gud.h`
- Device implementations: https://github.com/samcday/gud-gadget · https://github.com/notro/gud-pico · esp32-usb-monitor
- CGVirtualDisplay usage examples: https://github.com/Stengo/DeskPad (MIT; reusable `CGVirtualDisplayPrivate.h`, mode-change observation pattern; capture is legacy CGDisplayStream) · https://github.com/tml1024/FluffyDisplay
- ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit
- IOUSBHost: https://developer.apple.com/documentation/iousbhost
- DisplayLink Manager architecture & limitations: https://support.displaylink.com/knowledgebase/articles/1932214
