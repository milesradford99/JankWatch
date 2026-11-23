#!/usr/bin/env bash
# Build JankWatch.app (+ jankprobe) for one architecture.
#   scripts/build-app.sh            # host architecture
#   scripts/build-app.sh arm64      # Apple Silicon
#   scripts/build-app.sh x86_64     # Intel (works on Apple Silicon too: cross-compiles)
# Signing: set JANKWATCH_SIGN_IDENTITY to a code-signing certificate name (see README "签名").
# Without it the app is ad-hoc signed and macOS forgets its permissions after every rebuild.
set -euo pipefail

ARCH="${1:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "unknown arch: $ARCH (use arm64 or x86_64)"; exit 64;; esac

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(cat "$ROOT/VERSION")"
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
IDENTITY="${JANKWATCH_SIGN_IDENTITY:--}"
OUT="$ROOT/dist/$ARCH"

echo "==> building $ARCH (version $VERSION build $BUILD)"
swift build -c release --arch "$ARCH" --package-path "$ROOT"
BIN="$(swift build -c release --arch "$ARCH" --package-path "$ROOT" --show-bin-path)"

APP="$OUT/JankWatch.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/JankWatch" "$APP/Contents/MacOS/JankWatch"
cp "$BIN/jankctl" "$APP/Contents/MacOS/jankctl"
cp "$BIN/jankprobe" "$OUT/jankprobe"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"

echo "==> signing with identity: $IDENTITY"
if [ "$IDENTITY" = "-" ]; then
  echo "    (ad-hoc: permissions will need re-granting after each rebuild; see README)"
fi
codesign --force --sign "$IDENTITY" --identifier io.jankwatch.jankctl "$APP/Contents/MacOS/jankctl"
codesign --force --sign "$IDENTITY" --identifier io.jankwatch.JankWatch "$APP"
codesign --force --sign "$IDENTITY" --identifier io.jankwatch.jankprobe "$OUT/jankprobe"
codesign --verify --verbose=1 "$APP"

(cd "$OUT" && ditto -c -k --keepParent JankWatch.app "JankWatch-$VERSION-$ARCH.zip")
echo "==> done: $APP"
echo "    jankprobe: $OUT/jankprobe"
echo "    zip: $OUT/JankWatch-$VERSION-$ARCH.zip"
