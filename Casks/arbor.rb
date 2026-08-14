cask "arbor" do
  version "1.4.8"

  on_arm do
    sha256 "66cf844013f8363c9ef2f28b1dbe88b7ca84532472eb6320094a7b6e689bb8d9"

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
