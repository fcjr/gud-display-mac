# Next steps

Status: streams a real desktop to real hardware at the panel's native
resolution. See [hardware-notes.md](hardware-notes.md) for device findings and
the platform quirks behind the current design.

## Blocking a v1

**1. Resolve the firmware endurance limit.**
The reference device wedges after tens of seconds of sustained streaming.
Start by reading the `USB link:` line logged at connect — if the device
enumerates at full speed (12 Mbps), 264 KB frames cap out near 4 fps and the
answer is a low fixed default, not adaptive backoff. If it is high speed, the
bottleneck is the device's own scan-out and the next experiment is a bandwidth
sweep: fix the frame rate at 1, 2, 5, 10, 20 fps and record time-to-wedge.
That curve determines whether to ship a per-device rate table or keep the
adaptive halving.

**2. Recover without a replug.**
`resetWithError:` re-enumerates but the device usually does not come back, so
recovery currently ends in a physical replug. Try releasing and re-claiming the
interface (destroy the transport, re-open the `io_service_t`) before falling
back to a device reset.

**3. Verify against a second device.**
Everything so far is one device's behaviour. gud-gadget on a Pi or phone would
separate "GUD on macOS" bugs from "this adapter" bugs — particularly the
endurance limit, `STATUS_ON_SET` (this device never exercises it), LZ4
compression (never exercised), and EDID mode parsing (this device stalls EDID).

## Correctness and polish

- **Damage-rect regression.** With partial updates the panel showed stale
  content; that traced to the buffer-lifetime bug, now fixed. Re-verify that
  partial rects render correctly now, since testing moved to full-frame mode
  while chasing it.
- **Drain the last damage.** If a frame arrives mid-flush and no further frames
  follow (screen goes static), its accumulated damage is never sent. Add a
  short drain timer, or re-pack from a retained copy.
- **Idle heartbeat vs. sleep.** The 3 s EP0 ping keeps the USB link busy
  forever; skip it while the display is asleep or the stream is paused.
- **Cursor.** Composited by SCK (`showsCursor`). On a 336×262 panel the arrow
  is large; consider an option to hide it or scale it down.
- **Multiple devices.** Untested with two GUD devices attached. Each session
  assigns `serialNumber: 1`, which likely confuses macOS — derive it from the
  USB device.
- **`vImage`/SIMD conversion.** The pixel loops are scalar. Irrelevant at
  336×262; will matter on a 1080p device.

## Protocol coverage not yet exercised

- LZ4 block compression (no test device advertises it)
- `STATUS_ON_SET` error reporting (Linux kernel gadgets need it)
- `FULL_UPDATE` devices (gud-pico)
- EDID-only devices (mode list parsed from EDID)
- Backlight brightness (`GUD_PROPERTY_BACKLIGHT_BRIGHTNESS`) and device-side
  rotation — both P2 in the PRD, neither implemented
- Connector hotplug: polling and the `CHANGED` bit are implemented but the
  reference device sets no `POLL_STATUS` flag, so the path is untested

## Shipping

- Point `SUFeedURL` at a real appcast and host it; the Sparkle key pair is
  already generated (public key in `project.yml`, private key gitignored under
  `keys/`).
- Add the Apple signing/notarization secrets to the repo so
  the release workflow works end to end.
- Request Apple's **Persistent Content Capture** entitlement to suppress
  macOS 15's monthly screen-recording re-approval prompt.
- CI: `just test` in GitHub Actions would cover the protocol, pixel, EDID, and
  LZ4 suites without hardware.
