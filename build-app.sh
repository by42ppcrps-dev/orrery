#!/usr/bin/env bash
# Build, verify and safely install the Orrery app bundle.
#
#   ./build-app.sh              build a release bundle into build/Orrery.app
#   ./build-app.sh --install    build and install to /Applications (never over a running app)
#   ./build-app.sh --preview    debug bundle with its own identifier, for UI tests
#   ./build-app.sh --swap       install the bundle staged by the last plain build
#   ./build-app.sh --release    Developer ID build zipped for distribution (needs ORRERY_SIGN_IDENTITY;
#                               notarizes and staples when ORRERY_NOTARY_PROFILE is set)
#   ./build-app.sh --plan       print what the chosen mode would do, without building
#
# Signing: personal builds use an available Apple Development identity, falling back to ad-hoc
# (ORRERY_AUTO_SIGN=0 disables discovery). Set ORRERY_SIGN_IDENTITY to "Developer ID Application"
# identity for the hardened-runtime, timestamped signature a release needs. Notarization uses a
# notarytool keychain profile: `xcrun notarytool store-credentials <profile>` once, then
# ORRERY_NOTARY_PROFILE=<profile>.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME="Orrery"
IDENTIFIER="app.orrery.studio"
VERSION="1.10.0"
BUILD="38"
MODE="build"
PLAN=0
for argument in "$@"; do
  case "$argument" in
    --install) MODE="install" ;;
    --preview) MODE="preview" ;;
    --swap) MODE="swap" ;;
    --release) MODE="release" ;;
    --plan) PLAN=1 ;;
    *) echo "Unknown option: $argument" >&2; exit 2 ;;
  esac
done
CONFIGURATION="release"
if [ "$MODE" = "preview" ]; then
  IDENTIFIER="app.orrery.studio.preview"
  CONFIGURATION="debug"
fi
SIGN_IDENTITY="${ORRERY_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && [ "$MODE" != "release" ] && [ "${ORRERY_AUTO_SIGN:-1}" != "0" ]; then
  # Keep personal builds recognizable to Keychain across updates. Ad-hoc signatures change
  # their designated requirement with every binary. A local Apple identity keeps that stable.
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ {print $2; exit}')"
fi
NOTARY_PROFILE="${ORRERY_NOTARY_PROFILE:-}"
if [ "$MODE" = "release" ] && [ -z "$SIGN_IDENTITY" ]; then
  echo "A release needs ORRERY_SIGN_IDENTITY set to a \"Developer ID Application\" identity; an ad-hoc signed zip would be blocked by Gatekeeper on every other Mac." >&2
  exit 2
fi
if [ "$MODE" = "release" ] && [ -z "$NOTARY_PROFILE" ]; then
  echo "A public binary release needs ORRERY_NOTARY_PROFILE for notarization. Use the public source package until distribution signing and notarization are configured." >&2
  exit 2
fi
describe_signing() {
  if [ -n "$SIGN_IDENTITY" ]; then
    echo "signing: configured Apple identity, hardened runtime, secure timestamp"
  else
    echo "signing: ad-hoc (runs on this Mac; Gatekeeper blocks it elsewhere; set ORRERY_SIGN_IDENTITY for a distributable build)"
  fi
}
if [ "$PLAN" = "1" ]; then
  echo "plan for --$MODE: $NAME $VERSION ($BUILD), identifier $IDENTIFIER, $CONFIGURATION configuration"
  describe_signing
  case "$MODE" in
    install) echo "destination: /Applications/$NAME.app (refused while that app is running; the previous bundle is preserved under build/)" ;;
    preview) echo "destination: $ROOT/build/${NAME}Preview.app" ;;
    swap) echo "destination: /Applications/$NAME.app from the bundle staged by the last build" ;;
    release)
      echo "output: $ROOT/build/$NAME-$VERSION-$BUILD.zip"
      if [ -n "$NOTARY_PROFILE" ]; then echo "notarization: xcrun notarytool submit --wait with keychain profile \"$NOTARY_PROFILE\", then stapled"; else echo "notarization: skipped (set ORRERY_NOTARY_PROFILE to notarize and staple)"; fi ;;
    *) echo "destination: $ROOT/build/$NAME.app" ;;
  esac
  exit 0
fi
mkdir -p "$ROOT/build"
STAGED_RECORD="$ROOT/build/next-app-path"
is_running() {
  pgrep -f "^$1/Contents/MacOS/$NAME([[:space:]]|$)" >/dev/null 2>&1
}
sign_bundle() {
  if [ -n "$SIGN_IDENTITY" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$1"
  else
    codesign --force --sign - --timestamp=none "$1"
  fi
  codesign --verify --deep --strict "$1"
}
if [ "$MODE" = "swap" ]; then
  [ -f "$STAGED_RECORD" ] || { echo "No staged build; run ./build-app.sh first." >&2; exit 1; }
  STAGE="$(cat "$STAGED_RECORD")"
  case "$STAGE" in "$ROOT"/build/staging.*/$NAME.app) ;; *) echo "Invalid staged path" >&2; exit 1 ;; esac
  STAGING_ROOT="$(dirname "$STAGE")"
else
  echo "Building $CONFIGURATION app…"
  swift build -c "$CONFIGURATION" --package-path "$ROOT"
  BIN="$(swift build -c "$CONFIGURATION" --package-path "$ROOT" --show-bin-path)/$NAME"
  [ -x "$BIN" ] || { echo "Binary not found: $BIN" >&2; exit 1; }
  STAGING_ROOT="$(mktemp -d "$ROOT/build/staging.XXXXXX")"
  STAGE="$STAGING_ROOT/$NAME.app"
  mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources"
  cp "$BIN" "$STAGE/Contents/MacOS/$NAME"
  cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleDisplayName</key><string>$NAME</string>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>$IDENTIFIER</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSSupportsAutomaticTermination</key><false/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST
  if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$STAGE/Contents/Resources/AppIcon.icns"
  fi
  sign_bundle "$STAGE"
  describe_signing
  if [ "$MODE" != "preview" ] && [ "$MODE" != "release" ]; then printf '%s\n' "$STAGE" > "$STAGED_RECORD"; fi
fi
codesign --verify --deep --strict "$STAGE"
if [ "$MODE" = "release" ]; then
  ZIP="$ROOT/build/$NAME-$VERSION-$BUILD.zip"
  rm -f "$ZIP"
  if [ -n "$NOTARY_PROFILE" ]; then
    ditto -c -k --keepParent "$STAGE" "$ZIP"
    echo "Submitting for notarization (profile $NOTARY_PROFILE)…"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$STAGE"
    xcrun stapler validate "$STAGE"
    spctl --assess --type execute "$STAGE"
    rm -f "$ZIP"
  else
    echo "Not notarized: set ORRERY_NOTARY_PROFILE to submit and staple. Gatekeeper will warn until it is."
  fi
  ditto -c -k --keepParent "$STAGE" "$ZIP"
  shasum -a 256 "$ZIP"
  echo "Release ready: $ZIP"
  exit 0
fi
if [ "$MODE" = "install" ] || [ "$MODE" = "swap" ]; then
  DESTINATION="/Applications/$NAME.app"
elif [ "$MODE" = "preview" ]; then
  DESTINATION="$ROOT/build/${NAME}Preview.app"
else
  DESTINATION="$ROOT/build/$NAME.app"
fi
if is_running "$DESTINATION"; then
  echo "The destination app is running; it has not been modified."
  echo "Verified new build: $STAGE"
  echo "Quit that app before installing or swapping the new build."
  exit 2
fi
# Copy and verify completely before touching a previous installation.
NEXT="$DESTINATION.next-$$"
ditto "$STAGE" "$NEXT"
codesign --verify --deep --strict "$NEXT"
if is_running "$DESTINATION"; then
  echo "The destination started while copying. Kept new build at $NEXT; existing app is untouched."
  exit 2
fi
if [ -e "$DESTINATION" ]; then
  BACKUP_DIR="$(mktemp -d "$ROOT/build/previous.XXXXXX")"
  mv "$DESTINATION" "$BACKUP_DIR/$(basename "$DESTINATION")"
  echo "Previous app preserved at $BACKUP_DIR"
fi
mv "$NEXT" "$DESTINATION"
# Keep one previous copy for rollback. Older copies piled up (110 of them once) and Launch
# Services happily launched one of them for `open -a Orrery`, so two builds ran at once.
ls -dt "$ROOT"/build/previous.* 2>/dev/null | tail -n +2 | while IFS= read -r old; do rm -rf "$old"; done
for leftover in "$ROOT"/build/staging.*; do [ -e "$leftover" ] || continue; [ "$leftover" = "$STAGING_ROOT" ] || rm -rf "$leftover"; done
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DESTINATION" >/dev/null 2>&1 || true
echo "Ready: $DESTINATION"
