project := "GUDDisplay.xcodeproj"
scheme := "GUDDisplay"
app := "build/Build/Products/Debug/GUD Display.app"

# List available recipes
default:
    @just --list

# Regenerate the Xcode project from project.yml
gen:
    xcodegen generate

# Build the app (Debug)
build: gen
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Debug -derivedDataPath build build

# Run the protocol/pipeline test suite
test: gen
    xcodebuild -project {{project}} -scheme {{scheme}} -derivedDataPath build test

# Build the Release app (CI signs and notarizes this)
dist: gen
    xcodebuild -project {{project}} -scheme {{scheme}} -configuration Release -derivedDataPath build build

# Build and launch the menu-bar app
run: build
    open "{{app}}"

# Quit the running app
quit:
    -osascript -e 'quit app "GUD Display"'

# Stream the app's logs
logs:
    log stream --predicate 'subsystem == "com.leftshift.gud"' --level info

# Re-render the app icon asset catalog
icon:
    swift scripts/make_icon.swift

# Bump the version in project.yml (patch, minor, or major)
bump type="patch":
    scripts/bump-version.sh {{type}}

# Remove generated project and build products
clean:
    rm -rf build GUDDisplay.xcodeproj Support
