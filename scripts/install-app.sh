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
    "$HOME"/Library/Developer/Xcode/DerivedData/Shortcast-*/Build/Products/Release/"Short Generator.app" \
    "$HOME"/Library/Developer/Xcode/DerivedData/Shortcast-*/Build/Products/Debug/"Short Generator.app" \
    ".derivedData/Build/Products/Release/Short Generator.app" \
    ".derivedData/Build/Products/Debug/Short Generator.app" \
    "build/Build/Products/Release/Short Generator.app" \
    "build/Build/Products/Debug/Short Generator.app"
  do
    if [[ -d "$P" ]]; then
      POSSIBLE_CANDIDATES+=("$P")
    fi
  done

  if [[ ${#POSSIBLE_CANDIDATES[@]} -gt 0 ]]; then
    NEWEST=""
    NEWEST_TIME=0
    for CAND in "${POSSIBLE_CANDIDATES[@]}"; do
      MTIME=$(stat -f "%m" "$CAND" 2>/dev/null || echo 0)
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

APP_NAME="$(basename "$SRC")"
DEST_DIR="/Applications"
if [[ ! -w "$DEST_DIR" ]]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi

DEST="$DEST_DIR/$APP_NAME"
TMP="$DEST_DIR/.$APP_NAME.installing"

echo "==> Installing $APP_NAME -> $DEST"
rm -rf "$TMP"
/usr/bin/ditto "$SRC" "$TMP"
rm -rf "$DEST"
mv "$TMP" "$DEST"

# 3. Clean quarantine and ensure valid ad-hoc codesign for local launch
echo "==> Ensuring ad-hoc code signature and permissions..."
/usr/bin/xattr -cr "$DEST" || true
/usr/bin/codesign --force --deep --sign - "$DEST" || true

# Register with LaunchServices & unregister the DerivedData / intermediate copy to avoid duplicates in Launchpad
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  echo "==> Updating LaunchServices registration..."
  if [[ "$SRC" != "$DEST" ]]; then
    "$LSREGISTER" -u "$SRC" 2>/dev/null || true
  fi
  "$LSREGISTER" -f -trusted "$DEST" || true

  # Xcode invokes its built-in 'RegisterWithLaunchServices' on the intermediate
  # DerivedData product right as the target build completes.
  # To prevent a duplicate placeholder icon in the app hub / Launchpad, spawn
  # an asynchronous unregister watcher that runs after Xcode finishes.
  (
    sleep 2
    if [[ -n "${SRC:-}" && "$SRC" != "$DEST" ]]; then
      "$LSREGISTER" -u "$SRC" 2>/dev/null || true
    fi
    if [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
      find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 5 -name "$APP_NAME" -not -path "$DEST" -exec "$LSREGISTER" -u {} + 2>/dev/null || true
    fi
    "$LSREGISTER" -f -trusted "$DEST" 2>/dev/null || true
  ) >/dev/null 2>&1 &
fi
touch "$DEST"

# 4. Sync browser-publisher automation scripts to Application Support
PUBLISHER_SRC="${SRCROOT:-.}/scripts/browser-publisher"
if [[ -d "$PUBLISHER_SRC" ]]; then
  PUBLISHER_DEST="$HOME/Library/Application Support/Shortcast/browser-publisher"
  mkdir -p "$PUBLISHER_DEST"
  /usr/bin/rsync -a --exclude 'node_modules/.cache' "$PUBLISHER_SRC/" "$PUBLISHER_DEST/" || true
  echo "✓ Synced browser automation scripts to $PUBLISHER_DEST"
fi

# Touch to notify Finder of the updated app bundle
touch "$DEST"

echo "✓ Successfully installed and registered $APP_NAME in $DEST_DIR"

