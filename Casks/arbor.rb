cask "arbor" do
  version "1.13.0"

  on_arm do
    sha256 "bdefe810916860161fbb7d8f433e3e0803f5777350d9a1d61d03935c8e59c30a"

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
