# GUD Display

A DisplayLink-style macOS driver for [GUD (Generic USB Display)](https://github.com/notro/gud/wiki) devices.

Installs as a menubar application & does userspace screen capture -> usb.

Built for use with the [RCade](https://github.com/fcjr/rcade) driver by [scd31](https://www.scd31.com/posts/building-an-arcade-display-adapter), and a few other boards she is cooking up.

## Install (soon, not yet released)

```sh
brew install --cask fcjr/fcjr/gud-display
```

## Status

This is a WIP, I still need to get my hands on more hardware to test.

## License

Vendored third-party code: [lz4](https://github.com/lz4/lz4) (BSD-2-Clause), `CGVirtualDisplayPrivate.h` adapted from [DeskPad](https://github.com/Stengo/DeskPad) (MIT).
