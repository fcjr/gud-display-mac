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

For a small panel, choose **Open Display Window** under that device in the
menu. This opens a live view on your main screen. Resizing keeps the display's
aspect ratio, with the image filling the window. A recent frame from the USB
capture appears immediately while the sharper desktop preview starts. The
window stays visible while you use other apps. Click the preview to move your
pointer onto the GUD desktop, then click, scroll, drag, and type normally
while watching the window. The first click only moves the pointer. Move back
across the display edge to return to your main screen. No additional
permissions are needed beyond Screen Recording.

Each device has its own preview window. Closing or minimizing it stops the
preview capture; the USB display keeps working.

## Performance

Frames go out as damage rectangles, not whole frames. ScreenCaptureKit
reports no dirty rects on a scaled stream, so each captured frame is diffed
against the previous one in 16-pixel tiles and the changed tiles are grouped
into a few rectangles (`DamageTracker`). A moving cursor or a line of typing
costs a couple of kilobytes; on a full-speed USB device that is the
difference between 4 fps and the capture rate. Rectangles are converted and
LZ4-compressed on the capture queue while the previous frame is still on the
bus, so the link never waits on the CPU.

Compression uses LZ4 HC level 6 by default (`defaults write com.leftshift.gud
LZ4Level N`; 0 is plain LZ4, up to 12), about 20% fewer bytes than plain LZ4
on text. All of this is within the GUD wire protocol as the Linux driver
defines it: partial rectangles, `max_buffer_size` bands, standard LZ4 blocks.

## Status

Tested against the RCade adapter driving a CRT at its native 336×262. Other GUD devices (gud-gadget on a Pi or phone, Pico and ESP32 boards) should work but have not been verified; if you have one, please open an issue with what you see. See [docs/hardware-notes.md](docs/hardware-notes.md) for device findings.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). With [just](https://github.com/casey/just):

```sh
just build   # Debug build
just run     # build and launch
just test    # protocol and pipeline tests
just logs    # stream the app's logs
```

Or directly: `xcodegen generate && xcodebuild -project GUDDisplay.xcodeproj -scheme GUDDisplay build`.

Keep local app builds signed with the configured Developer ID. Unsigned or
ad-hoc builds can lose Screen Recording access after a rebuild even when the
Settings toggle remains enabled. `just test` uses a separate build directory
and runs without starting USB sessions or requesting permissions.

Releases are cut from the Actions tab with the **bump-release** workflow, which bumps the version, tags it, and triggers the signed and notarized build, GitHub release, appcast update, and Homebrew cask.

## License

[MIT](LICENSE). Vendored third-party code: [lz4](https://github.com/lz4/lz4) (BSD-2-Clause), `CGVirtualDisplayPrivate.h` adapted from [DeskPad](https://github.com/Stengo/DeskPad) (MIT).
