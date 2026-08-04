cask "arbor" do
  version "1.2.0"

  on_arm do
    sha256 "bac4aa96bcf525a6192e3808dd8ccbe6d3f1b9ec73aaa164c3818767ada49ab9"

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
