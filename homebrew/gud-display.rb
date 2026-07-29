cask "gud-display" do
  version "VERSION_PLACEHOLDER"
  sha256 "SHA256_PLACEHOLDER"

  url "https://github.com/fcjr/gud-display-mac/releases/download/v#{version}/GUD-Display-#{version}.zip"
  name "GUD Display"
  desc "Driver for GUD (Generic USB Display) devices"
  homepage "https://github.com/fcjr/gud-display-mac"

  depends_on macos: ">= :sonoma"

  app "GUD Display.app"

  zap trash: [
    "~/Library/Preferences/com.leftshift.gud.plist",
    "~/Library/Caches/com.leftshift.gud",
  ]
end
