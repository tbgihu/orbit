# Shared by the scripts (sourced), and the one place that names what Orbit installs and where.

readonly dest=~/Applications/Orbit
readonly app=$dest/Orbit.app
readonly command=~/.local/bin/orbit                       # the orbit command: a link to the app's executable
readonly config=~/.config/orbit/orbits.json
readonly logs=~/Library/Logs/Orbit
readonly stage=~/Library/Caches/Orbit/update
readonly unsupported=$stage:h/unsupported                 # the version of Xcode that could not add Siri support
readonly offered=$stage:h/xcode-offered                   # make install has offered Xcode once, so it won't ask again
readonly verdict=$stage:h/xcode                           # what `xcode` last found, which Orbit reads
readonly signing=~/Library/"Application Support"/Orbit/signing
readonly keychain=$signing/orbit.keychain-db
readonly identifier=io.github.tbgihu.orbit
readonly runtime=${$(getconf DARWIN_USER_TEMP_DIR)%/}/$identifier     # Orbit's, whatever $TMPDIR says
readonly lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
readonly xcode_store=macappstores://apps.apple.com/app/id497799835
# Apple's Worldwide Developer Relations G3 certificate, which signs Apple Development certificates, from
# apple.com/certificateauthority. Public, valid until 2030; build.sh copies it next to this file in Orbit.app.
# SHA-256 DC:F2:18:78:C7:7F:41:98:E4:B4:61:4F:03:D6:96:D8:9C:66:C6:60:08:D4:24:4E:1B:99:16:1A:AC:91:60:1F.
readonly intermediate=${${(%):-%x}:A:h}/AppleWWDRCAG3.cer

# What Orbit itself needs of the above, by its Info.plist key (Sources/Build.swift). build.sh writes them, so
# nothing is named twice. Paths in the home folder are written relative to it.
readonly shared=(OrbitIdentifier $identifier OrbitConfig $config OrbitLaunchers $dest OrbitStage $stage
                 OrbitLogs $logs OrbitLSRegister $lsregister OrbitXcode $xcode_store OrbitXcodeVerdict $verdict)

# One installer or updater at a time (shlock removes a lock whose process is gone).
lock() {
  mkdir -p $stage:h
  local tries=0
  until shlock -f $stage.lock -p $$; do
    (( ++tries > 1200 )) && { print -u2 "  another install or update is running"; exit 1 }
    sleep 0.1
  done
}
# Releases the lock when the script ends, if it holds it. Set here, at the top level, since an EXIT trap set in a
# function fires as soon as that function returns.
trap '[[ -f $stage.lock && $(<$stage.lock) == $$ ]] && rm -f $stage.lock' EXIT

# What tells the build at <Orbit.app> from another: its commit, without the "+" of local changes, then " intents"
# when it has Siri support, that is the intents' metadata and a signature with a Team ID (`development_identity`).
# Nothing when there is no app there.
identity() {
  local commit siri=
  commit=$(plutil -extract OrbitCommit raw $1/Contents/Info.plist 2>/dev/null) || return 0
  [[ $(plutil -extract OrbitIntents raw $1/Contents/Info.plist 2>/dev/null) == true \
     && $(codesign -dv $1 2>&1) == *$'\n'TeamIdentifier=[A-Z0-9]* ]] && siri=" intents"   # else "not set"
  print -r -- ${commit%+}$siri
}

installed() { identity $app }

# The keychains macOS searches for you, one path per line.
keychains() { security list-keychains -d user | sed 's/^ *"//; s/"$//' }

# The identity build.sh signs Orbit with when there is one: an Apple Development certificate, which Xcode creates
# for any Apple Account. Its Team ID is what macOS requires of an app before it runs the app's intents for Siri,
# Shortcuts and Spotlight. Prints its SHA-1 hash, then its name, the lowest hash when there are several, so every
# build picks the same one. Returns 1 when there is none: build.sh then signs with Orbit Local Signing (identity.sh).
# A certificate macOS can't trace to Apple's root is no use, which happens when Xcode leaves out Apple's
# intermediate certificate that signed it: then this adds that certificate (`intermediate`) to the login keychain,
# unless one with its SHA-1 hash is in the keychains already, and looks again.
development_identity() {
  local found=$(apple_development -v)
  if [[ -z $found && -n $(apple_development) ]]; then
    local sha1=${(U)${=$(shasum -a 1 $intermediate)}[1]}           # the file is the certificate itself (DER)
    if [[ $(security find-certificate -a -Z 2>/dev/null) != *"SHA-1 hash: $sha1"* ]]; then
      security add-certificates $intermediate 2>/dev/null
      found=$(apple_development -v)
    fi
  fi
  [[ -n $found ]] && print -r -- $found
}
apple_development() {
  security find-identity $@ -p codesigning 2>/dev/null \
    | awk -F'"' '$2 ~ /^Apple Development: / { split($1, field, " "); print field[2], $2 }' | sort | head -n 1
}

# Siri support (Sources/Intents.swift) needs metadata that only Xcode's tools extract; the Command Line Tools
# can't. It also needs an Apple Development certificate (`development_identity`). This finds an Xcode that can: the
# selected developer folder, else Xcode in /Applications. Returns 0 when there is the certificate too, 1 without
# Xcode, 2 while its licence is not accepted, which makes its tools refuse to run, 3 when this version of Xcode has
# already failed at it (build.sh), and 4 without the certificate. Prints the folder of the Xcode it found.
# It also writes the answer to $verdict: the status and the folder, then the files whose change can change the
# answer, the keychains among them, so Orbit knows when to ask again without running Xcode's tools.
xcode() {
  local dir found= rc=1 inputs=(/var/db/xcode_select_link /Library/Preferences/com.apple.dt.Xcode.plist)
  for dir in "${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null)}" /Applications/Xcode.app/Contents/Developer; do
    [[ -n $dir ]] && inputs+=($dir:h/Info.plist)                 # replaced when Xcode is installed or updated
    [[ -n $dir && -x $dir/usr/bin/xcodebuild ]] || continue       # the Command Line Tools have none
    if ! $dir/usr/bin/xcodebuild -license check >/dev/null 2>&1; then rc=2
    elif ! DEVELOPER_DIR=$dir xcrun --find appintentsmetadataprocessor >/dev/null 2>&1; then continue
    elif [[ -f $unsupported && $(<$unsupported) == $($dir/usr/bin/xcodebuild -version 2>/dev/null) ]]; then rc=3
    else
      inputs+=(${(f)"$(keychains)"})                             # where Xcode puts a new certificate
      development_identity >/dev/null && rc=0 || rc=4
    fi
    found=$dir
    break
  done
  mkdir -p $verdict:h
  print -rl -- "$rc $found" $inputs > $verdict.$$ && mv -f $verdict.$$ $verdict
  [[ -n $found ]] && print -r -- $found
  return $rc
}

# `make install` at a terminal on a Mac without Xcode: says what Xcode would add and offers its App Store page,
# once. Siri support is not a setting: Orbit adds it like an update once Xcode is ready, and macOS turns an app's
# access off, in System Settings.
offer_xcode() {
  [[ -t 0 && -t 1 ]] || return 0
  local state=0
  xcode >/dev/null || state=$?
  if (( state == 2 )) && [[ $(installed) != *" intents" ]]; then
    print "  Siri & Shortcuts support waits for Xcode's licence: open Xcode once and accept the licence, then Orbit adds this support."
  elif (( state == 4 )) && [[ $(installed) != *" intents" ]]; then
    print "  Siri & Shortcuts support needs an Apple Development certificate: Orbit's Settings shows how to create one for free."
  elif (( state == 1 )) && [[ ! -f $offered ]]; then
    print "  Siri & Shortcuts support lets Siri, Apple Intelligence, Shortcuts and Spotlight start, stop and check your orbits."
    print "  Orbit adds this support once Xcode is installed (free, about 10 GB from the App Store)."
    mkdir -p $offered:h
    : > $offered
    read -q "?  Open Xcode in the App Store now? [y/N] "
    local answer=$?
    print
    (( answer )) || open $xcode_store
  fi
}

# Exits unless no orbit runs, like the app, which never interrupts an orbit for an update.
require_idle() {
  local record pid running=()
  for record in $runtime/*.pid(N); do
    read -r pid _ < $record                     # a record is "<pid> <start time>"
    kill -0 $pid 2>/dev/null && running+=(${record:t:r})
  done
  (( $#running )) || return 0
  print -u2 "  ${(j:, :)running} still running: stop every orbit, then run this again (nothing changed)"
  exit 1
}

# Waits up to 5 s for process <pid> (the agent) to exit.
await_exit() {
  zmodload zsh/zselect                                            # a 50 ms wait without starting a process
  for _ in {1..100}; do kill -0 $1 2>/dev/null || break; zselect -t 5 || true; done
}

# Quits a running agent. Call require_idle first, so it has no orbits to stop.
stop_agent() {
  if pkill -TERM -x -U $UID Orbit 2>/dev/null; then
    for _ in {1..50}; do pgrep -x -U $UID Orbit >/dev/null || break; sleep 0.1; done
  fi
}

# Whether the orbit command is Orbit's link, wherever it points now.
linked() { [[ -L $command && $(readlink $command) == $dest/* ]] }

# Puts <Orbit.app> in place of the installed one (two renames) and registers it, then has it sync the launchers
# and links the orbit command to it, unless something else has that name.
place() {
  [[ -x $1/Contents/MacOS/Orbit ]] || { print -u2 "  no complete Orbit.app at $1: nothing installed"; exit 1 }
  mkdir -p $dest
  rm -rf $app.old
  [[ -d $app ]] && mv $app $app.old
  mv $1 $app
  rm -rf $app.old
  $lsregister -f -R $dest                                 # before the sync, which tells Siri of the orbits
  $app/Contents/MacOS/Orbit internal sync || true
  if linked || [[ ! -e $command && ! -L $command ]]; then
    mkdir -p $command:h
    ln -sfn $app/Contents/MacOS/Orbit $command
  fi
  rm -rf $stage/Orbit.app $stage/commit
  print "  installed Orbit $(plutil -extract CFBundleShortVersionString raw $app/Contents/Info.plist)"
}

