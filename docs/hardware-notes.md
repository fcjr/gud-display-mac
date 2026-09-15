# Hardware bring-up notes

Findings from running GUD Display against real GUD hardware. The reference device
was a **USB-to-VGA 16 kHz arcade display adapter** (`1d50:614d`), driving a
CRT in an arcade cabinet.

## Device profile

From `GET_DESCRIPTOR` / `GET_FORMATS` / `GET_CONNECTORS` / `GET_CONNECTOR_MODES`:

| Field | Value |
|---|---|
| Protocol version | 1 |
| Flags | 0 (no `STATUS_ON_SET`, no `FULL_UPDATE`) |
| Compression | none |
| `max_buffer_size` | 0 (unlimited) |
| Size | fixed 336×262, min == max |
| Formats | `0x50` RGB888 only |
| Connectors | one, flags 0 (no status polling) |
| Mode | clock 5670 kHz, 336/337/338/350 × 262/263/264/270, no `PREFERRED` flag |

5670 kHz over 350×270 works out to ~16.2 kHz horizontal / 60 Hz vertical —
genuine 240p-era arcade timing.

**Stalls** (`kIOUSBHostErrorPipeStall`) on: `GET_STATUS`, `GET_CONNECTOR_EDID`,
`SET_CONTROLLER_ENABLE`, `SET_STATE_COMMIT`, `SET_DISPLAY_ENABLE`. The panel is
fixed-function and always on, so it implements only what it needs. This is why
the enable sequence is best-effort — only the queries that define the pipeline
(descriptor, formats, connectors, modes) are treated as fatal.

## macOS platform behaviours worth remembering

These cost the most time to discover, and none are documented:

1. **macOS never configures vendor-class USB devices.** The gadget reports
   `bDeviceClass 0xFF`, so no Apple driver claims it and *no interface nodes
   exist in the IORegistry at all*. The host must call
   `configureWithValue:matchInterfaces:` itself, then wait for the interface to
   register asynchronously. On Linux, usbcore always does this — it is the one
   host duty macOS leaves to the application.

2. **macOS will not bring a display online below roughly 640×480.** A virtual
   display advertising only 336×262 is created successfully and then silently
   never activates. It needs at least one larger companion mode to exist; the
   native mode is then selected explicitly.

3. **`CGDisplayCopyAllDisplayModes` hides low-resolution modes by default.**
   A small panel's native mode counts as one, so it is invisible unless you
   pass `kCGDisplayShowDuplicateLowResolutionModes`.

4. **HiDPI on a small panel is a trap.** With `hiDPI = 1`, macOS synthesizes a
   family of larger scaled variants sharing the panel's aspect ratio and picks
   the biggest (1600×1248 was chosen for a 336×262 panel), so the desktop
   renders huge and gets downsampled. Keep it 0 for native rendering.

5. **Never set a display mode through a `CGBeginDisplayConfiguration`
   transaction unless you mean to touch the arrangement.** Completing with
   `.permanently` let macOS re-evaluate the whole layout and promote the tiny
   panel to *main display*, deactivating the laptop screen.
   `CGDisplaySetDisplayMode` affects only the one display.

6. **ScreenCaptureKit binds display geometry at stream creation.** Change the
   mode or origin afterwards and the stream keeps compositing the cursor
   against the old bounds — the pointer renders in the wrong place. Settle all
   geometry *before* starting capture.

7. **SCK recycles IOSurfaces from a small pool.** Reading a `CVPixelBuffer` on
   another queue after the callback returns races the compositor and ships
   stale or torn frames. Convert to the device format inside the callback.

8. **SCK can lose a virtual display permanently** (`-3815`, "Failed to find any
   displays or windows to capture") while CoreGraphics still lists it. Only
   recreating the display recovers it.

9. **Mirroring picks a resolution all displays share.** With only the panel's
   native mode advertised, "Entire Screen" mirroring drags every display down
   to it — a 168×132 desktop on the MacBook. Larger scaled modes exist behind
   the `ScaledModes` default for this reason.

## Firmware endurance limit (open issue)

The device wedges under sustained streaming: EP0 stops responding
(`kIOReturnNotResponding`) mid-transfer, the panel freezes on its last frame,
and only re-enumeration or a physical replug revives it.

Correlates with **throughput, not protocol usage**:

- Test pattern at one 264 KB frame every 2 seconds: never wedged.
- Desktop streaming at ~25 fps (~8 MB/s sustained): wedges after 600–3600
  frames, i.e. tens of seconds to a couple of minutes.

Full-frame-only mode and 4-pixel damage alignment did not prevent it, so it is
unlikely to be partial-rect handling or unaligned writes. The remaining
hypothesis is that the device cannot both absorb USB data and scan out the CRT
at that rate, and overruns.

The app used to detect this (idle EP0 ping, failed flushes), halve a
process-wide frame-rate ceiling on every occurrence and eventually reset the
device. That ceiling never recovered, so every reflash or replug of a healthy
device also cost half the frame rate until the app was relaunched. It now
follows the Linux driver instead: a failed flush is logged and abandoned, the
next damage tries again, and a device that disappears is torn down by the
IOKit termination notification. Pacing comes from USB flow control and damage
merging. `defaults write com.leftshift.gud MaxFrameRate N` remains as a hard
cap for firmware that needs one.

**Next step:** read the USB link speed logged at connect (`USB link: ...`). If
this is a full-speed (12 Mbps ≈ 1.2 MB/s) device, 264 KB frames cap out around
4 fps and the fix is a hard low default rather than adaptive backoff.

## Diagnostics

```sh
just logs                                          # live session logs
defaults write com.leftshift.gud TestPattern -bool YES   # synthetic pattern
defaults write com.leftshift.gud MaxFrameRate 5          # hard fps ceiling
defaults write com.leftshift.gud FullFrameOnly -bool YES # no partial rects
defaults write com.leftshift.gud ScaledModes -bool YES   # larger modes for mirroring
```

The test pattern is the fastest way to separate transfer bugs from capture
bugs: corner colors reveal orientation and channel order, the 32-pixel grid
reveals row pitch (a wrong stride shears the vertical bars into diagonals), and
the diagonal reveals combined width/pitch errors. If the pattern is correct,
the USB path is sound and the bug is upstream in capture.

## Touch screens

GUD carries pixels only; a panel's touch controller is exposed as a
separate USB HID touch screen interface (Digitizer page, Touch Screen
usage) on the same composite device, the way Linux's hid-multitouch expects.

macOS binds its own HID driver to any such interface and turns it into an
absolute pointer, but without a vendor driver it maps the digitizer's
coordinate space onto the **main display**, not onto the virtual display
this app created for the same device. Touching the little panel would move
the cursor around the primary monitor.

`TouchInputController` therefore opens the HID device with
`kIOHIDOptionsTypeSeizeDevice`. A seized device delivers reports only to the
seizing client; the system's event driver stops receiving them. Contacts are
read by usage from the device's parsed elements (Tip Switch, X, Y under each
Finger collection) rather than by report offset, so any descriptor layout
that follows the digitizer usage tables works. Each contact is scaled into
`CGDisplayBounds` of the virtual display and posted as `CGEvent` mouse
down/drag/up on the HID event tap.

Two TCC grants are involved, both requested only once a touch device is
actually matched: Input Monitoring (needed to open, and so to seize, a HID
device that produces system input) and Accessibility (needed to post
synthetic mouse events). Neither can be verified without the hardware: the
seize itself and whether the kernel's element values are current by the time
the raw report callback runs were designed from IOHIDFamily's behaviour, not
observed here.
