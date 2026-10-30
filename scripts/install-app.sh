#!/bin/bash
# Installs the freshly built app into /Applications (fallback: ~/Applications)
# and registers it with LaunchServices so it appears in Launchpad / Spotlight /
# Dock like any other app. Invoked as an Xcode post-build phase (see project.yml)
# and also usable standalone:  ./scripts/install-app.sh
set -euo pipefail

# Skip on CI and for non-build actions (archive/install/analyze).
if [[ -n "${CI:-}" ]]; then exit 0; fi
if [[ -n "${ACTION:-}" && "${ACTION}" != "build" ]]; then exit 0; fi
if [[ "${SHORTCAST_SKIP_INSTALL:-0}" == "1" ]]; then exit 0; fi

PROJECT_ROOT="${SRCROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SRC="${1:-}"

# 1. Check if argument or environment passed a valid bundle
if [[ -z "$SRC" && -n "${TARGET_BUILD_DIR:-}" && -n "${FULL_PRODUCT_NAME:-}" ]]; then
  CANDIDATE="${TARGET_BUILD_DIR}/${FULL_PRODUCT_NAME}"
  if [[ -d "$CANDIDATE" ]]; then
    SRC="$CANDIDATE"
  fi
fi

# 2. Fallback discovery in Xcode DerivedData and project build directories (pick newest)
if [[ -z "$SRC" || ! -d "$SRC" ]]; then
  POSSIBLE_CANDIDATES=()
  for P in \
    "$HOME"/Library/Developer/Xcode/DerivedData/Shortcast-*/Build/Products/Release/"КАДР & СЕНС.app" \
    "$HOME"/Library/Developer/Xcode/DerivedData/Shortcast-*/Build/Products/Debug/"КАДР & СЕНС.app" \
    "$PROJECT_ROOT/.derivedData/Build/Products/Release/КАДР & СЕНС.app" \
    "$PROJECT_ROOT/.derivedData/Build/Products/Debug/КАДР & СЕНС.app" \
    "$PROJECT_ROOT/build/Build/Products/Release/КАДР & СЕНС.app" \
    "$PROJECT_ROOT/build/Build/Products/Debug/КАДР & СЕНС.app" \
    "$PROJECT_ROOT/.build/Build/Products/Release/КАДР & СЕНС.app" \
    "$PROJECT_ROOT/.build/Build/Products/Debug/КАДР & СЕНС.app" \
    "$PROJECT_ROOT/build/Release/КАДР & СЕНС.app" \
    "$PROJECT_ROOT/build/Debug/КАДР & СЕНС.app"
  do
    if [[ -f "$P/Contents/Info.plist" && -x "$P/Contents/MacOS/КАДР & СЕНС" ]]; then
      POSSIBLE_CANDIDATES+=("$P")
    fi
  done

  if [[ ${#POSSIBLE_CANDIDATES[@]} -gt 0 ]]; then
    NEWEST=""
    NEWEST_TIME=0
    for CAND in "${POSSIBLE_CANDIDATES[@]}"; do
      BIN="$(find "$CAND/Contents/MacOS" -type f 2>/dev/null | head -n 1)"
      if [[ -n "$BIN" && -f "$BIN" ]]; then
        MTIME=$(stat -f "%m" "$BIN" 2>/dev/null || echo 0)
      else
        MTIME=$(stat -f "%m" "$CAND" 2>/dev/null || echo 0)
      fi
      if [[ "$MTIME" -gt "$NEWEST_TIME" ]]; then
        NEWEST_TIME="$MTIME"
        NEWEST="$CAND"
      fi
    done
    SRC="$NEWEST"
  fi
fi

if [[ -z "$SRC" || ! -d "$SRC" ]]; then
  echo "warning: install-app: built app bundle not found. Run a build first or pass path as arg 1."
  exit 0
fi

# Never replace the installed app with an incomplete or unrelated bundle.
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SRC/Contents/Info.plist")
if [[ "$BUNDLE_ID" != "app.shortcast.Shortcast" ]]; then
  echo "error: install-app: unexpected bundle identifier: $BUNDLE_ID" >&2
  exit 1
fi
APP_NAME="КАДР & СЕНС.app"
DEST_DIR="/Applications"
if [[ ! -d "$DEST_DIR/$APP_NAME" && ! -w "$DEST_DIR" ]]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi

DEST="$DEST_DIR/$APP_NAME"
TMP="$DEST_DIR/.$APP_NAME.installing"

# Remove the prior display-name bundle only after verifying it belongs to this app.
for OLD in "/Applications/Short Generator.app" "$HOME/Applications/Short Generator.app"; do
  [[ -d "$OLD" && "$OLD" != "$DEST" ]] || continue
  OLD_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$OLD_ID" == "app.shortcast.Shortcast" ]]; then
    echo "==> Removing previous branded bundle $OLD"
    rm -rf "$OLD"
  fi
done

echo "==> Installing $APP_NAME -> $DEST"
rm -rf "$TMP"
/usr/bin/ditto "$SRC" "$TMP"
# Unit-test hosts are build artifacts, never part of the installed application.
rm -rf "$TMP/Contents/PlugIns/ShortcastTests.xctest"
rm -rf "$DEST"
mv "$TMP" "$DEST"

# 3. Clean quarantine and ensure valid ad-hoc codesign for local launch
echo "==> Ensuring ad-hoc code signature and permissions..."
/usr/bin/xattr -cr "$DEST" || true
/usr/bin/codesign --force --deep --sign - "$DEST" || true

# Clean all registrations belonging to this app, including deleted temporary
# builds and malformed legacy products. The scheme repeats this synchronously
# after Xcode's final RegisterWithLaunchServices task; no timing-based watcher.
/usr/bin/python3 "$PROJECT_ROOT/scripts/register-installed-app.py" --installed "$DEST"

# 4. Sync browser-publisher automation scripts to Application Support
PUBLISHER_SRC="$PROJECT_ROOT/scripts/browser-publisher"
if [[ -d "$PUBLISHER_SRC" ]]; then
  PUBLISHER_DEST="$HOME/Library/Application Support/Shortcast/browser-publisher"
  mkdir -p "$PUBLISHER_DEST"
  /usr/bin/rsync -a --delete --delete-excluded --exclude '/test/' --exclude 'node_modules/.cache' "$PUBLISHER_SRC/" "$PUBLISHER_DEST/" || true
  echo "✓ Synced browser automation scripts to $PUBLISHER_DEST"
fi

# Touch to notify Finder of the updated app bundle
touch "$DEST"

# Xcode's product bundles are needed for incremental builds. Keep them in place,
# but hide them from normal Finder searches after installation so only the
# installed copy is presented as the application.
for STALE in \
  "$PROJECT_ROOT"/.build/Build/Products/Debug/"$APP_NAME" \
  "$PROJECT_ROOT"/.build/Build/Products/Release/"$APP_NAME" \
  "$PROJECT_ROOT"/.derivedData/Build/Products/Debug/"$APP_NAME" \
  "$PROJECT_ROOT"/.derivedData/Build/Products/Release/"$APP_NAME" \
  "$PROJECT_ROOT"/build/Build/Products/Debug/"$APP_NAME" \
  "$PROJECT_ROOT"/build/Build/Products/Release/"$APP_NAME" \
  "$HOME"/Library/Developer/Xcode/DerivedData/Shortcast-*/Build/Products/Debug/"$APP_NAME" \
  "$HOME"/Library/Developer/Xcode/DerivedData/Shortcast-*/Build/Products/Release/"$APP_NAME"
do
  [[ -d "$STALE" && "$STALE" != "$DEST" ]] || continue
  STALE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STALE/Contents/Info.plist" 2>/dev/null || true)
  if [[ "$STALE_ID" == "app.shortcast.Shortcast" ]]; then
    /usr/bin/chflags hidden "$STALE"
    echo "✓ Hid Xcode build product $STALE"
  fi
done

echo "✓ Successfully installed and registered $APP_NAME in $DEST_DIR"

