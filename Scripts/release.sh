#!/bin/bash
#
# Builds a signed, notarized Epochary release and gathers everything to attach to its
# GitHub release.
#
#   Scripts/release.sh             the real thing: needs a clean, committed tree
#   Scripts/release.sh --dry-run   reuses the built tools, allows uncommitted changes and
#                                  stops before notarization, to check the build
#
# Output in build/release/<version>/assets:
#   Epochary-<version>.dmg   the notarized app, with the approval stapled to both the app and the DMG
#   the source archives of the bundled tools and build-tools.sh   (GPL corresponding source)
#   SHA256SUMS               checksums of all of the above
#
# Notarization uses credentials saved once in the keychain:
#   xcrun notarytool store-credentials epochary-notary --apple-id <apple-id> --team-id 849VGKLAH8
# Set NOTARY_PROFILE to use a different profile name.

set -euo pipefail

DRY_RUN=false
[ "${1:-}" = --dry-run ] && DRY_RUN=true
NOTARY_PROFILE=${NOTARY_PROFILE:-epochary-notary}
TEAM_ID=849VGKLAH8
IDENTITY=$(security find-identity -v -p codesigning \
    | sed -n "s/.*\"\(Developer ID Application: .*($TEAM_ID)\)\"/\1/p" | head -1)

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(sed -n 's/^ *MARKETING_VERSION: *//p' project.yml)
OUT=$ROOT/build/release/$VERSION
APP_NAME=Epochary
DMG_NAME=$APP_NAME-$VERSION.dmg

step() { echo "==> $*"; }
fail() { echo "error: $*" >&2; exit 1; }

[ -n "$IDENTITY" ] || fail "no Developer ID Application certificate for team $TEAM_ID in the keychain."

# A release is built from exactly what's committed, so the tag holds its source.
if ! $DRY_RUN; then
    [ -z "$(git status --porcelain)" ] || fail "commit or stash your changes first; a release is built from the committed tree."
    xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
        || fail "no notarization credentials named \"$NOTARY_PROFILE\" (see the top of this script)."
fi
[ ! -e "$OUT" ] || fail "$OUT already exists; remove it to build $VERSION again."
mkdir -p "$OUT/assets"

if $DRY_RUN && [ -d build/vendor/bin ]; then
    step "Reusing the tools in build/vendor (dry run)"
else
    step "Building the bundled tools"
    Vendor/build-tools.sh > "$OUT/build-tools.log" 2>&1 || fail "the tools build failed; see $OUT/build-tools.log"
fi

step "Building $APP_NAME $VERSION (Release)"
xcodebuild -project Epochary.xcodeproj -scheme Epochary -configuration Release \
    -derivedDataPath "$OUT/DerivedData" clean build > "$OUT/xcodebuild.log" 2>&1 \
    || fail "the build failed; see $OUT/xcodebuild.log"
APP=$OUT/$APP_NAME.app
ditto "$OUT/DerivedData/Build/Products/Release/$APP_NAME.app" "$APP"

step "Checking signatures"
codesign --verify --deep --strict "$APP" || fail "the app's signature doesn't verify"
for code in "$APP" "$APP"/Contents/Helpers/*; do
    details=$(codesign -dvv "$code" 2>&1)
    grep -q "^Authority=Developer ID Application: .*($TEAM_ID)" <<<"$details" || fail "$code isn't signed with the Developer ID"
    grep -q '^Timestamp=' <<<"$details" || fail "$code has no secure timestamp"
    grep -q 'flags=.*runtime' <<<"$details" || fail "$code doesn't use the hardened runtime"
done
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q get-task-allow; then
    fail "the app has the debugging entitlement, which notarization rejects"
fi
[ "$(ls "$APP/Contents/Helpers" | wc -l | tr -d ' ')" = 6 ] || fail "expected six bundled tools in Contents/Helpers"

notarize() {  # file → waits for Apple's verdict; prints the log if it's rejected
    local result id
    result=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
    echo "$result" | sed 's/^/    /'
    if ! grep -q 'status: Accepted' <<<"$result"; then
        id=$(sed -n 's/^ *id: //p' <<<"$result" | head -1)
        [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
        fail "notarization of $(basename "$1") wasn't accepted"
    fi
}

if ! $DRY_RUN; then
    step "Notarizing the app"
    ditto -c -k --keepParent "$APP" "$OUT/$APP_NAME.zip"
    notarize "$OUT/$APP_NAME.zip"
    xcrun stapler staple "$APP"
    rm "$OUT/$APP_NAME.zip"
fi

step "Making $DMG_NAME"
STAGING=$OUT/dmg
mkdir "$STAGING"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -fs HFS+ -format UDZO \
    "$OUT/assets/$DMG_NAME"
codesign --sign "$IDENTITY" --timestamp "$OUT/assets/$DMG_NAME"

if ! $DRY_RUN; then
    step "Notarizing the disk image"
    notarize "$OUT/assets/$DMG_NAME"
    xcrun stapler staple "$OUT/assets/$DMG_NAME"
    step "Checking with Gatekeeper"
    spctl --assess --type open --context context:primary-signature -v "$OUT/assets/$DMG_NAME"
    spctl --assess --type execute -v "$APP"
fi

step "Gathering the release files"
for file in build/vendor/sources/*; do
    [ "$(basename "$file")" = SHA256SUMS ] || cp "$file" "$OUT/assets/"
done
(cd "$OUT/assets" && shasum -a 256 * > SHA256SUMS)

step "Done: $OUT/assets"
ls -l "$OUT/assets"
if $DRY_RUN; then
    echo "Dry run: nothing was notarized. Run without --dry-run for a release."
else
    echo "Next: tag v$VERSION, push the tag, and create the GitHub release with these files."
fi
