# GUD Display

A DisplayLink-style macOS driver for [GUD (Generic USB Display)](https://github.com/notro/gud/wiki) devices.

Plug in a GUD device and it shows up as a real display in macOS. GUD Display runs as a menu bar app: it creates a virtual display, captures it with ScreenCaptureKit, and streams the frames to the device over USB. No kernel extension, no root.

Built for the [RCade](https://github.com/fcjr/rcade) USB-to-VGA arcade adapter by [scd31](https://www.scd31.com/posts/building-an-arcade-display-adapter), and a few other boards she is cooking up.

## Install

```sh
brew install --cask fcjr/fcjr/gud-display
```

Or download `GUD-Display-<version>.zip` from the [latest release](https://github.com/fcjr/gud-display-mac/releases/latest) and drop `GUD Display.app` into `/Applications`.

Requires macOS 14 (Sonoma) or later. Builds are signed and notarized, and the app updates itself via Sparkle.

## Usage

1. Launch GUD Display. It lives in the menu bar and has no Dock icon.
2. Grant **Screen Recording** permission when prompted (System Settings › Privacy & Security › Screen Recording), then relaunch. macOS treats mirroring the virtual display as screen recording, so without it the device shows a black screen.
3. Plug in your GUD device. A new display appears in System Settings › Displays and you can arrange it like any other monitor.

The menu bar item shows the connected device, lets you pick a resolution from the modes the device advertises, and toggles Launch at Login.

## Status

Tested against the RCade adapter driving a CRT at its native 336×262. Other GUD devices (gud-gadget on a Pi or phone, Pico and ESP32 boards) should work but have not been verified; if you have one, please open an issue with what you see. See [docs/hardware-notes.md](docs/hardware-notes.md) for device findings and [docs/next-steps.md](docs/next-steps.md) for known gaps.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). With [just](https://github.com/casey/just):

```sh
just build   # Debug build
just run     # build and launch
just test    # protocol and pipeline tests
just logs    # stream the app's logs
```

Or directly: `xcodegen generate && xcodebuild -project GUDDisplay.xcodeproj -scheme GUDDisplay build`.

Releases are cut from the Actions tab with the **bump-release** workflow, which bumps the version, tags it, and triggers the signed and notarized build, GitHub release, appcast update, and Homebrew cask.

## License

[MIT](LICENSE). Vendored third-party code: [lz4](https://github.com/lz4/lz4) (BSD-2-Clause), `CGVirtualDisplayPrivate.h` adapted from [DeskPad](https://github.com/Stengo/DeskPad) (MIT).
