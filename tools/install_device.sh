#!/bin/zsh
# Signs the iOS app with the development certificate and installs it on the connected iPhone over USB, then copies
# the extracted game into the app's Documents/game (once: it stays across reinstalls).
#
# usage: tools/install_device.sh <app> <provisioning profile> [game folder]
set -euo pipefail

APP=$1
PROFILE=$2
GAME=${3:-}
DEVICE=${RL_DEVICE:?set RL_DEVICE to the device identifier (xcrun devicectl list devices)}
BUNDLE_ID=com.E5N97.raymanlegends
IDENTITY=${RL_IDENTITY:-"Apple Development"}
WORK=$(mktemp -d)

security cms -D -i "$PROFILE" > "$WORK/profile.plist"
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$WORK/profile.plist" > "$WORK/entitlements.plist"

# A signed copy, so the build folder keeps its ad hoc signature.
SIGNED="$WORK/$(basename "$APP")"
cp -cR "$APP" "$SIGNED"
cp "$PROFILE" "$SIGNED/embedded.mobileprovision"
for lib in "$SIGNED"/Frameworks/*.dylib; do
    codesign --force --sign "$IDENTITY" --timestamp=none "$lib"
done
codesign --force --sign "$IDENTITY" --timestamp=none --entitlements "$WORK/entitlements.plist" "$SIGNED"

xcrun devicectl device install app --device "$DEVICE" "$SIGNED"

if [[ -n "$GAME" ]]; then
    if xcrun devicectl device info files --device "$DEVICE" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" 2>/dev/null | grep -q "Documents/game/default.xex"; then
        echo "game already on the device"
    else
        echo "copying the game ($(du -sh "$GAME" | cut -f1)) to Documents/game..."
        xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer \
            --domain-identifier "$BUNDLE_ID" --source "$GAME" --destination Documents/game
    fi
fi
rm -rf "$WORK"
