#!/bin/zsh
# Builds build/Orbit.app from this checkout. Launchers are not built here; the installed agent creates them from
# ~/.config/orbit/orbits.json (Sources/Launchers.swift).
#   SIGN_ID       codesign identity. Default: an Apple Development certificate if there is one, else Orbit's own
#                 (scripts/identity.sh) if it exists, else ad hoc.
#   ORBIT_SOURCE  the clone updates come from. Default: this checkout (update.sh sets it when building in a worktree).
#
# With Xcode and an Apple Development certificate (`xcode` in lib.sh) the build also gets Siri support: the
# compiler writes down what it knows of the intents, and Xcode's appintentsmetadataprocessor turns that into
# Metadata.appintents in the bundle, called as Xcode's own build calls it (ExtractAppIntentsMetadata;
# AppIntentsMetadata.xcspec in swiftlang/swift-build). Without them nothing differs except that this is left out,
# and when Xcode's compiler or that tool fails, the Command Line Tools build Orbit as they do without Xcode.
# Info.plist's OrbitIntents says which it is.
set -euo pipefail
cd "${0:A:h}/.."

source scripts/lib.sh

readonly built=build/Orbit.app
readonly plist=$built/Contents/Info.plist
# Use the Apple Development certificate if there is one (`development_identity`), by its hash, which Siri support
# needs. Else Orbit's own identity (identity.sh) if it exists: its keychain is unlocked with the password file, so
# codesign never prompts. Otherwise sign ad hoc.
sign_args=() sign_name=
if [[ -z ${SIGN_ID-} ]] && development=$(development_identity); then
  SIGN_ID=${development%% *} sign_name=${development#* }
elif [[ -z ${SIGN_ID-} && -f $signing/password ]] \
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

readonly target=$(uname -m)-apple-macos15.0 work=$PWD/build/intents
# The protocols whose conformances the compiler describes, as Xcode lists them (SWIFT_EMIT_CONST_VALUE_PROTOCOLS).
readonly protocols='["AppIntent","EntityQuery","AppEntity","TransientEntity","AppEnum","AppShortcutProviding",'\
'"AppShortcutsProvider","AnyResolverProviding","AppIntentsPackage","DynamicOptionsProvider",'\
'"_IntentValueRepresentable","_AssistantIntentsProvider","_GenerativeFunctionExtractable","IntentValueQuery","Resolver"]'
extract=()
intents=false

print "  building  Orbit $(plutil -extract CFBundleShortVersionString raw Support/Info.plist)"
rm -rf build
mkdir -p $built/Contents/{MacOS,Resources}
if developer=$(xcode); then
  export DEVELOPER_DIR=$developer                                 # Xcode's compiler and SDK, whatever is selected
  mkdir $work
  print -r -- $protocols > $work/protocols.json
  extract=(-emit-const-values-path $work/Orbit.swiftconstvalues
           -Xfrontend -const-gather-protocols-file -Xfrontend $work/protocols.json
           -Xlinker -dependency_info -Xlinker $work/Orbit_dependency_info.dat)
fi
compile() {
  swiftc Sources/*.swift -o $built/Contents/MacOS/Orbit -module-name Orbit \
    -Osize -wmo -swift-version 6 -target $target -framework AppKit $@
}
# This Xcode failed at Siri support. Orbit is built without it, and this Xcode isn't asked again.
without_intents() {
  extract=()
  rm -rf $built/Contents/Resources/Metadata.appintents
  mkdir -p $unsupported:h
  xcodebuild -version > $unsupported
  xcode >/dev/null || true                                        # so Orbit sees it at once
  print -u2 "  this Xcode could not add Siri support, so Orbit is built without it"
}
if (( $#extract )) && ! compile $extract; then                    # the Command Line Tools still build Orbit
  without_intents
  if [[ -d /Library/Developer/CommandLineTools ]]; then
    export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  else
    unset DEVELOPER_DIR                                           # none: the selected developer folder then
  fi
fi
(( $#extract )) || compile
if (( $#extract )); then
  print -l $PWD/Sources/*.swift > $work/Orbit.SwiftFileList
  print -r -- $work/Orbit.swiftconstvalues > $work/Orbit.SwiftConstValuesFileList
  : > $work/Orbit.DependencyMetadataFileList
  : > $work/Orbit.DependencyStaticMetadataFileList
  if xcrun appintentsmetadataprocessor \
       --toolchain-dir $DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain --module-name Orbit \
       --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" --xcode-version ${$(xcodebuild -version)[-1]} \
       --platform-family macOS --deployment-target ${target##*macos} --bundle-identifier $identifier \
       --output $PWD/$built/Contents/Resources --target-triple $target \
       --binary-file $PWD/$built/Contents/MacOS/Orbit \
       --dependency-file $work/Orbit_dependency_info.dat --source-file-list $work/Orbit.SwiftFileList \
       --metadata-file-list $work/Orbit.DependencyMetadataFileList \
       --static-metadata-file-list $work/Orbit.DependencyStaticMetadataFileList \
       --swift-const-vals-list $work/Orbit.SwiftConstValuesFileList \
       --compile-time-extraction --deployment-aware-processing --no-app-shortcuts-localization \
       2> $work/metadata.log \
     && [[ -d $built/Contents/Resources/Metadata.appintents ]]; then
    intents=true
  else
    cat $work/metadata.log >&2                                    # what the tool said, which it otherwise logs every time
    without_intents
  fi
fi
rm -rf $work
strip -x $built/Contents/MacOS/Orbit                              # local symbols aren't needed at run time

cp Support/Info.plist $plist
plutil -insert CFBundleIdentifier -string $identifier $plist
plutil -insert CFBundleURLTypes.0.CFBundleURLName -string $identifier $plist
for key value in $shared; do plutil -insert $key -string ${value#$HOME/} $plist; done
$intents && plutil -insert OrbitIntents -bool true $plist
plutil -replace CFBundleVersion -string "$version" $plist
plutil -insert OrbitCommit -string "$commit" $plist
[[ -n $origin ]] && plutil -insert OrbitSource -string "$origin" $plist
$built/Contents/MacOS/Orbit internal icon "" $built/Contents/Resources/AppIcon.icns
cp scripts/lib.sh scripts/uninstall.sh scripts/AppleWWDRCAG3.cer $built/Contents/Resources   # used without the clone

codesign --force --sign "$sign_id" $sign_args --timestamp=none $built 2>/dev/null \
  || { print -u2 "  signing with \"$sign_name\" failed${sign_args:+: \`make identity\` recreates Orbit's identity}"
       exit 1 }
$lsregister -u $built 2>/dev/null || true                         # only the installed Orbit handles orbit:// links
