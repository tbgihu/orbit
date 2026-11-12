#!/bin/zsh
# Builds build/Orbit.app from this checkout. Launchers are not built here; the installed agent creates them from
# ~/.config/orbit/orbits.json (Sources/Launchers.swift).
#   SIGN_ID       codesign identity. Default: Orbit's own
#                 (scripts/identity.sh) if it exists, else ad hoc.
#   ORBIT_SOURCE  the clone updates come from. Default: this checkout (update.sh sets it when building in a worktree).
set -euo pipefail
cd "${0:A:h}/.."

source scripts/lib.sh

readonly built=build/Orbit.app
readonly plist=$built/Contents/Info.plist
# Use Orbit's own identity (identity.sh) if it exists: its keychain is unlocked with the password file, so
# codesign never prompts. Otherwise sign ad hoc.
sign_args=() sign_name=
if [[ -z ${SIGN_ID-} && -f $signing/password ]] \
   && security unlock-keychain -p "$(<$signing/password)" $keychain 2>/dev/null; then
  SIGN_ID="Orbit Local Signing"
  sign_args=(--keychain $keychain)
fi
readonly sign_id=${SIGN_ID:--} sign_name=${sign_name:-${SIGN_ID:--}}
# Updates compare against the commit, with "+" for local changes. A folder that isn't a git clone (a downloaded
# ZIP) still builds, just without updates, even inside another repository, whose commits are not Orbit's.
if [[ $(git rev-parse --show-toplevel 2>/dev/null) == $PWD ]]; then
  readonly commit=$(git rev-parse --short=12 HEAD)$(git diff --quiet HEAD || print +)
  readonly version=$(git rev-list --count HEAD)
  readonly origin=${ORBIT_SOURCE:-$PWD}
else
  readonly commit=source version=1 origin=
fi

readonly target=$(uname -m)-apple-macos15.0

print "  building  Orbit $(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
rm -rf build
mkdir -p $built/Contents/{MacOS,Resources}
swiftc Sources/*.swift -o $built/Contents/MacOS/Orbit -module-name Orbit \
  -Osize -wmo -swift-version 6 -target $target -framework AppKit
strip -x $built/Contents/MacOS/Orbit                              # local symbols aren't needed at run time

cp Support/Info.plist $plist
plutil -insert CFBundleIdentifier -string $identifier $plist
plutil -insert CFBundleURLTypes.0.CFBundleURLName -string $identifier $plist
for key value in $shared; do plutil -insert $key -string ${value#$HOME/} $plist; done
plutil -replace CFBundleVersion -string "$version" $plist
plutil -insert OrbitCommit -string "$commit" $plist
[[ -n $origin ]] && plutil -insert OrbitSource -string "$origin" $plist
$built/Contents/MacOS/Orbit internal icon "" $built/Contents/Resources/AppIcon.icns
cp scripts/lib.sh scripts/uninstall.sh $built/Contents/Resources   # used without the clone

codesign --force --sign "$sign_id" $sign_args --timestamp=none $built 2>/dev/null \
  || { print -u2 "  signing with \"$sign_name\" failed${sign_args:+: \`make identity\` recreates Orbit's identity}"
       exit 1 }
$lsregister -u $built 2>/dev/null || true                         # only the installed Orbit handles orbit:// links
