cask "arbor" do
  version "1.6.0"

  on_arm do
    sha256 "5375d098e07f8cc2d4dc21f2783d59d61eaa5df2d3ada2ea1b18c9f2f2c8df73"

    url "https://github.com/cacuscacus/arbor/releases/download/v#{version}/Arbor-#{version}-macos-arm64.zip"
  end

  name "Arbor"
  desc "Native open-source file manager for developers and power users"
  homepage "https://github.com/cacuscacus/arbor"

  depends_on macos: :tahoe

  app "Arbor.app"

  zap trash: [
    "~/Library/Preferences/cacus.Arbor.plist",
    "~/Library/Saved Application State/cacus.Arbor.savedState",
  ]

  caveats <<~EOS
    Arbor is distributed without Apple notarization. On first launch macOS may
    block the app. Use Finder → right-click Arbor → Open, then confirm.

    Prefer upgrading with:
      brew upgrade --cask arbor
  EOS
end
