# GUD Display

A DisplayLink-style macOS driver for [GUD (Generic USB Display)](https://github.com/notro/gud/wiki) devices. Plug in any GUD device — a Raspberry Pi Zero, Pi Pico, ESP32 monitor, an arcade CRT adapter, or a Linux phone running [gud-gadget](https://github.com/samcday/gud-gadget) — and it appears as a real macOS display.

See [PRD.md](PRD.md) for product requirements and architecture, and [docs/](docs/) for hardware findings and next steps.

## Install

```sh
brew install --cask fcjr/fcjr/gud-display
```

## How it works

A user-space menu-bar app (no kernel extensions):

1. **USB** — configures and claims the GUD vendor interface (VID `0x1d50` / PID `0x614d`) via IOUSBHost
2. **Virtual display** — creates a display with the private `CGVirtualDisplay` CoreGraphics SPI at the panel's native resolution
3. **Capture** — streams that display's pixels with ScreenCaptureKit (dirty rects only; idle screen ≈ zero USB traffic)
4. **Pipeline** — converts to the device's pixel format (XRGB8888/ARGB8888/RGB888/RGB565/RGB332/XRGB1111/R8/R1), LZ4-block-compresses when the device supports it, and sends damage rects over the bulk endpoint

Also handled: EDID-only devices (DTD parsing), `FULL_UPDATE` devices (Pi Pico class), `STATUS_ON_SET` error reporting (Linux kernel gadgets), resolution switching, connector hotplug polling, sleep/wake DPMS, and recovery from device wedges and lost capture streams.

## Permissions

GUD Display needs **Screen Recording** permission (Privacy & Security › Screen Recording) — the pixel path is a screen capture, same as DisplayLink Manager. The app prompts on first launch; grant and relaunch. On macOS 15, expect a monthly re-approval prompt.

## Building

Requires Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and [just](https://github.com/casey/just):

```sh
brew install xcodegen just
just run     # build and launch
just test    # protocol/pipeline tests
just logs    # stream the app's logs
```

The test suite exercises the protocol client against mock device profiles (Linux kernel gadget, gud-gadget, gud-pico), the pixel converters, the EDID parser, and the LZ4 block framing.

## Releasing

Run the **bump-release** workflow from the Actions tab and pick patch, minor, or major. It bumps `MARKETING_VERSION` in `project.yml`, commits, and pushes a `vX.Y.Z` tag. The tag triggers `release.yml`, which builds, signs, notarizes, staples, publishes the GitHub release, appends the Sparkle appcast entry on `main`, and updates the Homebrew cask in `fcjr/homebrew-fcjr`.

Required repository secrets:

| Secret | Purpose |
|---|---|
| `APPLE_CERTIFICATE` | Developer ID .p12, base64 |
| `APPLE_CERTIFICATE_PASSWORD` | password for that .p12 |
| `APPLE_API_KEY_P8_BASE64` | App Store Connect API key, base64 |
| `APPLE_API_KEY` | API key ID |
| `APPLE_API_ISSUER` | API issuer ID |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key |
| `RELEASE_APP_ID` | GitHub App ID (tagging + tap push) |
| `RELEASE_APP_PRIVATE_KEY` | that App's private key |

## Debugging

```sh
defaults write com.leftshift.gud TestPattern -bool YES     # synthetic pattern instead of the desktop
defaults write com.leftshift.gud MaxFrameRate 5            # hard fps ceiling
defaults write com.leftshift.gud FullFrameOnly -bool YES   # disable partial-rect updates
defaults write com.leftshift.gud ScaledModes -bool YES     # larger modes, for mirroring
```

The test pattern is the fastest way to separate transfer bugs from capture bugs — see [docs/hardware-notes.md](docs/hardware-notes.md).

## Status

Streams a real desktop to real hardware at the panel's native resolution. The open issue is a firmware endurance limit on the reference device under sustained throughput; see [docs/next-steps.md](docs/next-steps.md).

## License

Vendored third-party code: [lz4](https://github.com/lz4/lz4) (BSD-2-Clause), `CGVirtualDisplayPrivate.h` adapted from [DeskPad](https://github.com/Stengo/DeskPad) (MIT).
