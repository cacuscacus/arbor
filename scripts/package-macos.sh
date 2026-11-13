#!/usr/bin/env bash
# Build a Release Arbor.app and zip it for GitHub Releases / Homebrew.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/apps/macos/Arbor.xcodeproj"
SCHEME="Arbor"
CONFIGURATION="Release"
DIST="$ROOT/dist"
ARCH="$(uname -m)"

case "$ARCH" in
  arm64) ARCH_LABEL="arm64" ;;
  x86_64) ARCH_LABEL="x86_64" ;;
  *)
    echo "Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

VERSION="$(
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings \
    | awk -F' = ' '/MARKETING_VERSION/ { print $2; exit }'
)"
if [[ -z "$VERSION" ]]; then
  echo "Could not read MARKETING_VERSION from Xcode project" >&2
  exit 1
fi

DERIVED="$DIST/DerivedData"
APP_SRC="$DERIVED/Build/Products/$CONFIGURATION/Arbor.app"
ZIP_NAME="Arbor-${VERSION}-macos-${ARCH_LABEL}.zip"
ZIP_PATH="$DIST/$ZIP_NAME"

echo "==> Packaging Arbor ${VERSION} (${ARCH_LABEL})"
rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Building SFTP helper"
cargo build --manifest-path "$ROOT/Cargo.toml" --release -p arbor-sftp-helper

# Ad-hoc sign for distribution without an Apple Developer Program membership.
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED" \
  -destination "platform=macOS,arch=${ARCH}" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=YES \
  CODE_SIGNING_ALLOWED=YES \
  build

if [[ ! -d "$APP_SRC" ]]; then
  echo "Build succeeded but Arbor.app not found at $APP_SRC" >&2
  exit 1
fi

mkdir -p "$APP_SRC/Contents/Helpers"
cp "$ROOT/target/release/arbor-sftp-helper" "$APP_SRC/Contents/Helpers/arbor-sftp-helper"
chmod 755 "$APP_SRC/Contents/Helpers/arbor-sftp-helper"

# Re-sign ad-hoc after copy into a clean staging tree (strip extended attrs that confuse Gatekeeper/zip).
STAGE="$DIST/stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP_SRC" "$STAGE/Arbor.app"
xattr -cr "$STAGE/Arbor.app" || true
codesign --force --deep --sign - "$STAGE/Arbor.app"

(
  cd "$STAGE"
  ditto -c -k --sequesterRsrc --keepParent "Arbor.app" "$ZIP_PATH"
)

SHA="$(shasum -a 256 "$ZIP_PATH" | awk '{ print $1 }')"
echo "$SHA  $ZIP_NAME" >"$ZIP_PATH.sha256"

cat <<EOF

Packaged:
  $ZIP_PATH
  sha256: $SHA

Next:
  1. Put that sha256 into Casks/arbor.rb
  2. Commit, tag v${VERSION}, push
  3. gh release create v${VERSION} --title "v${VERSION}" --generate-notes "$ZIP_PATH"
  4. brew tap cacuscacus/arbor https://github.com/cacuscacus/arbor
     brew install --cask arbor
EOF
