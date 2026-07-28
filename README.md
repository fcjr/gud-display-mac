# gudmac

A DisplayLink-style macOS driver for [GUD (Generic USB Display)](https://github.com/notro/gud/wiki) devices. Plug in any GUD device — a Raspberry Pi Zero, Pi Pico, ESP32 monitor, or a Linux phone running [gud-gadget](https://github.com/samcday/gud-gadget) — and it appears as a real macOS display.

See [PRD.md](PRD.md) for the full product requirements and architecture.

## How it works

A user-space menu-bar app (no kernel extensions):

1. **USB** — claims the GUD vendor interface (VID `0x1d50` / PID `0x614d`) via IOUSBHost
2. **Virtual display** — creates a display with the private `CGVirtualDisplay` CoreGraphics SPI, registering every mode the device offers
3. **Capture** — streams that display's pixels with ScreenCaptureKit (dirty rects only; idle screen ≈ zero USB traffic)
4. **Pipeline** — converts to the device's pixel format (XRGB8888/ARGB8888/RGB888/RGB565/RGB332/XRGB1111/R8/R1), LZ4-block-compresses when the device supports it, and sends damage rects over the bulk endpoint

Also handled: EDID-only devices (DTD parsing), `FULL_UPDATE` devices (Pi Pico class), `STATUS_ON_SET` error reporting (Linux kernel gadgets), resolution switching from System Settings or the menu, connector hotplug polling, sleep/wake DPMS, and dropped-frame damage merging under USB backpressure.

## Permissions

gudmac needs **Screen Recording** permission (Privacy & Security › Screen Recording) — the pixel path is a screen capture, same as DisplayLink Manager. The app prompts on first launch; grant and relaunch. On macOS 15, expect a monthly re-approval prompt.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`):

```sh
xcodegen generate
xcodebuild -project gudmac.xcodeproj -scheme gudmac build   # build
xcodebuild -project gudmac.xcodeproj -scheme gudmac test    # protocol/pipeline tests
```

The test suite exercises the protocol client against mock device profiles (Linux kernel gadget, gud-gadget, gud-pico), the pixel converters, the EDID parser, and the LZ4 block framing.

## Releasing

```sh
./scripts/release.sh <version>
```

Builds Release, notarizes via `notarytool` (keychain profile `gudmac-notary`), staples, and produces `build/gudmac-<version>.zip`. Updates ship via Sparkle; sign the zip with `sign_update` and publish it with the appcast. Update `SUFeedURL`/`SUPublicEDKey` in `project.yml` before the first real release.

## Status

Feature-complete against the PRD's M1–M3 scope, **not yet validated against hardware**. The remaining milestone is the M0 spike: run against a real GUD device to confirm entitlement-free IOUSBHost interface claiming and SCK capture of a CGVirtualDisplay.

## License

Vendored third-party code: [lz4](https://github.com/lz4/lz4) (BSD-2-Clause), `CGVirtualDisplayPrivate.h` adapted from [DeskPad](https://github.com/Stengo/DeskPad) (MIT).
