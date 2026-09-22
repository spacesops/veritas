#!/bin/bash
# Build Veritas-<version>.dmg from an exported app.
# Usage: ./scripts/create-dmg.sh [/path/to/export-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPORT_DIR="${1:-/tmp/veritas-export}"
VERSION="$(grep '^version' "$ROOT/Cargo.toml" | head -1 | sed 's/.*"\(.*\)".*/\1/')"
DMG="$ROOT/Veritas-${VERSION}.dmg"

if [[ ! -d "$EXPORT_DIR" ]]; then
  echo "Export dir not found: $EXPORT_DIR" >&2
  echo "Export the archive first, e.g.:" >&2
  echo "  xcodebuild -exportArchive -archivePath /tmp/Veritas.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath /tmp/veritas-export" >&2
  exit 1
fi

APP_SRC=""
for candidate in "$EXPORT_DIR/Veritas.app" "$EXPORT_DIR/veritas.app"; do
  if [[ -d "$candidate" ]]; then
    APP_SRC="$candidate"
    break
  fi
done
if [[ -z "$APP_SRC" ]]; then
  echo "No Veritas.app / veritas.app in $EXPORT_DIR" >&2
  ls -la "$EXPORT_DIR" >&2
  exit 1
fi

STAGE="$(mktemp -d /tmp/veritas-dmg.XXXXXX)"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT
cp -R "$APP_SRC" "$STAGE/Veritas.app"

command -v create-dmg >/dev/null || { echo "Install create-dmg: brew install create-dmg" >&2; exit 1; }

CMD=(
  create-dmg
  --volname "Veritas"
  --window-pos 200 120
  --window-size 600 330
  --icon-size 100
  --icon "Veritas.app" 170 125
  --app-drop-link 410 120
  --hide-extension "Veritas.app"
  --overwrite
)

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1 || true)"
if [[ -n "$IDENTITY" ]]; then
  echo "Signing DMG with: $IDENTITY"
  CMD+=(--codesign "$IDENTITY")
else
  echo "No Developer ID Application identity found; building an unsigned DMG."
  echo "Install a Developer ID Application certificate to sign for distribution."
fi

CMD+=("$DMG" "$STAGE")
"${CMD[@]}"

echo "Created $DMG"

if [[ -n "$IDENTITY" ]]; then
  if xcrun notarytool history --keychain-profile "veritas-notary" >/dev/null 2>&1; then
    echo "Submitting $DMG for notarization..."
    xcrun notarytool submit "$DMG" --keychain-profile "veritas-notary" --wait
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    echo "Notarized and stapled $DMG"
  else
    echo "Skipping notarization: no keychain profile named veritas-notary."
    echo "One-time setup (app-specific password from appleid.apple.com):"
    echo "  xcrun notarytool store-credentials veritas-notary --apple-id andrew@lunde.com --team-id YDF9P54VLB"
    echo "Then re-run: ./scripts/create-dmg.sh $EXPORT_DIR"
  fi
fi
