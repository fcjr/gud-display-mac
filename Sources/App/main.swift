import AppKit

let app = NSApplication.shared
// Hosted unit tests need AppKit, but must not start USB sessions, Sparkle,
// or permission prompts under the test runner's separate app identity.
let delegate = NSClassFromString("XCTestCase") == nil ? AppDelegate() : nil
app.delegate = delegate
app.run()
