# Homebrew cask for Limitbar. This file is the source of truth; copy it to `Casks/limitbar.rb` in the
# nicojan/homebrew-tap repo on each release (release/DISTRIBUTION.md, step 7). ./test.sh checks that its
# version matches the newest appcast item.
#
# `auto_updates true` tells Homebrew that Sparkle owns updates, so `brew upgrade` leaves an app that updated
# itself alone. Livecheck reads the same appcast the app does.
cask "limitbar" do
  version "1.1.0"
  sha256 "71b54d362432357d4a3c8414b8785827e403bbd79548295019705f0150fbbb1d"

  url "https://github.com/nicojan/limitbar/releases/download/v#{version}/Limitbar-#{version}.dmg"
  name "Limitbar"
  desc "Menu bar percentages for Claude's session and weekly limits"
  homepage "https://github.com/nicojan/limitbar"

  livecheck do
    url "https://nicojan.github.io/limitbar/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :ventura

  app "Limitbar.app"

  uninstall quit: "com.nicojan.limitbar"

  zap trash: [
    "~/Library/Application Support/Limitbar",
    "~/Library/Caches/com.nicojan.limitbar",
    "~/Library/HTTPStorages/com.nicojan.limitbar",
    "~/Library/Preferences/com.nicojan.limitbar.plist",
  ]
end
