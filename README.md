# GUD Display

A DisplayLink-style macOS driver for [GUD (Generic USB Display)](https://github.com/notro/gud/wiki) devices.

Plug in a GUD device and it shows up as a real display in macOS. GUD Display runs as a menu bar app: it creates a virtual display, captures it with ScreenCaptureKit, and streams the frames to the device over USB. If the device has a touch screen, touching it moves the pointer on that display. No kernel extension, no root.

Built for the [RCade](https://github.com/fcjr/rcade) USB-to-VGA arcade adapter by [scd31](https://www.scd31.com/posts/building-an-arcade-display-adapter), and for [gudlet](https://github.com/fcjr/gudlet), which turns Waveshare's 1.69" touch boards into tiny USB monitors.

## Install

```sh
brew install --cask fcjr/fcjr/gud-display
```

Or download `GUD-Display-<version>.zip` from the [latest release](https://github.com/fcjr/gud-display-mac/releases/latest) and drop `GUD Display.app` into `/Applications`.

Requires macOS 14 (Sonoma) or later. Builds are signed and notarized, and the app updates itself via Sparkle.

## Getting started

1. Launch GUD Display. It lives in the menu bar and has no Dock icon.
2. Grant **Screen Recording** when prompted, then relaunch. macOS treats mirroring the virtual display as screen recording, so without it the device shows a black screen.
3. Plug in your GUD device. A new display appears in System Settings › Displays, and you can arrange it like any other monitor.

## Permissions

| Permission | Needed for | When it is asked |
|---|---|---|
| Screen Recording | Sending the display's pixels to the device | At first launch |
| Input Monitoring | Reading a device's touch screen instead of letting macOS map it onto your main display | When a touch-capable device is plugged in |
| Accessibility | Turning touches into clicks on the virtual display | When a touch-capable device is plugged in |

The menu's **Permissions** section checks all three every time it opens. A missing one is a button that opens the System Settings pane where it is granted, and touch starts working as soon as its two are granted, with no relaunch.

## The menu

Each connected device gets its own section showing its name, panel size and rotation, plus the transfer rate since the menu was last opened.

- **Resolution** lists the modes the device advertises. Small panels are also given a larger desktop mode that macOS will actually select; the desktop is scaled into the panel.
- **Rotation** appears for devices that support the GUD rotation property, with 0°, 90°, 180° and 270°. The device turns the picture in hardware, and touch turns with it. macOS shows no Rotation control for a virtual display, but because both shapes are listed, choosing the landscape resolution for the display in System Settings › Displays rotates it too. The choice is remembered per device.
- **Touch** switches a touch screen off and on. Off keeps the panel's touches from doing anything at all. Remembered per device.
- **Brightness** appears for devices with a backlight.
- **Open Display Window** opens a live view of the display on your main screen, handy for a small panel. Resizing keeps the aspect ratio. Click the preview to move your pointer onto the GUD desktop, then click, scroll, drag and type normally while watching the window; move back across the display edge to return. Closing the window stops the preview capture; the USB display keeps working.
- **Launch at Login** and **Check for Updates…** do what they say.

## Touch

A device with a touch screen exposes it as a standard USB HID touch screen next to its display interface. On its own, macOS would treat that digitizer as a pointer over your main display. GUD Display takes the device over exclusively, which is why it needs Input Monitoring, and posts taps and drags itself at the matching spot on the virtual display, which is why it needs Accessibility. Single touch is supported: tap, double tap and drag.

## Performance

Frames go out as damage rectangles, not whole frames. ScreenCaptureKit reports no dirty rects on a scaled stream, so each captured frame is diffed against the previous one in 16-pixel tiles and the changed tiles are grouped into a few rectangles. A moving cursor or a line of typing costs a couple of kilobytes; on a full-speed USB device that is the difference between 4 fps and the capture rate. Rectangles are converted and LZ4-compressed while the previous frame is still on the bus, so the link never waits on the CPU.

Compression uses LZ4 HC level 6 by default, about 20% fewer bytes than plain LZ4 on text. Everything stays within the GUD wire protocol as the Linux driver defines it: partial rectangles, `max_buffer_size` bands, standard LZ4 blocks, the rotation property.

Advanced settings, all via `defaults write com.leftshift.gud`:

| Key | Effect |
|---|---|
| `LZ4Level N` | Compression level; 0 is plain LZ4, up to 12 |
| `MaxFrameRate N` | Cap the capture rate (5 to 60) |
| `NativeResolution -bool YES` | Run a small panel pixel for pixel instead of scaling a larger desktop into it |
| `ScaledModes -bool YES` | Offer larger modes so mirroring has a shared resolution |
| `FullFrameOnly -bool YES` | Send whole frames instead of damage rectangles (debugging) |
| `TestPattern -bool YES` | Send a test pattern instead of the desktop (debugging) |

## Tested devices

- The RCade USB-to-VGA adapter driving an arcade CRT at 336×262.
- gudlet on the Waveshare ESP32-S3-Touch-LCD-1.69, including touch and rotation.

Other GUD devices, such as gud-gadget on a Raspberry Pi or a phone and other Pico and ESP32 boards, should work but have not been verified. If you have one, please open an issue with what you see. See [docs/hardware-notes.md](docs/hardware-notes.md) for findings from real hardware.

## Building

Requires Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`). With [just](https://github.com/casey/just):

```sh
just build   # Debug build
just run     # build and launch
just test    # protocol, pipeline and touch tests
just logs    # stream the app's logs
```

Or directly: `xcodegen generate && xcodebuild -project GUDDisplay.xcodeproj -scheme GUDDisplay build`.

Keep local builds signed with the configured Developer ID. Unsigned or ad-hoc builds can lose their permissions after a rebuild even when the Settings toggles remain enabled. `just test` uses a separate build directory and runs without starting USB sessions or requesting permissions.

Releases are cut from the Actions tab with the **bump-release** workflow, which bumps the version, tags it, and triggers the signed and notarized build, GitHub release, appcast update and Homebrew cask.

## License

[MIT](LICENSE). Vendored third-party code: [lz4](https://github.com/lz4/lz4) (BSD-2-Clause), `CGVirtualDisplayPrivate.h` adapted from [DeskPad](https://github.com/Stengo/DeskPad) (MIT).
