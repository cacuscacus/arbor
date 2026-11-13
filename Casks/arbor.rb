cask "arbor" do
  version "1.6.1"

  on_arm do
    sha256 "6def6ada68012570695923f6b1a61161486d45de21d2dbf42b0901ab8f9f4eef"

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
