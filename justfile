app := "build/Build/Products/Debug/gudmac.app"

# List available recipes
default:
    @just --list

# Regenerate the Xcode project from project.yml
gen:
    xcodegen generate

# Build the app (Debug)
build: gen
    xcodebuild -project gudmac.xcodeproj -scheme gudmac -configuration Debug -derivedDataPath build build

# Run the protocol/pipeline test suite
test: gen
    xcodebuild -project gudmac.xcodeproj -scheme gudmac -derivedDataPath build test

# Build and launch the menu-bar app
run: build
    open {{app}}

# Quit the running app
quit:
    -osascript -e 'quit app "gudmac"'

# Stream the app's logs
logs:
    log stream --predicate 'subsystem == "com.leftshift.gud"' --level info

# Re-render the app icon asset catalog
icon:
    swift scripts/make_icon.swift

# Notarized release build (see scripts/release.sh)
release version:
    ./scripts/release.sh {{version}}

# Remove generated project and build products
clean:
    rm -rf build gudmac.xcodeproj Support
