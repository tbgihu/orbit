# Shared by the scripts (sourced), and the one place that names what Orbit installs and where.

readonly dest=~/Applications/Orbit
readonly app=$dest/Orbit.app
readonly command=~/.local/bin/orbit                       # the orbit command: a link to the app's executable
readonly config=~/.config/orbit/orbits.json
readonly logs=~/Library/Logs/Orbit
readonly signing=~/Library/"Application Support"/Orbit/signing
readonly keychain=$signing/orbit.keychain-db
readonly identifier=io.github.tbgihu.orbit
readonly runtime=${$(getconf DARWIN_USER_TEMP_DIR)%/}/$identifier     # Orbit's, whatever $TMPDIR says
readonly lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# What Orbit itself needs of the above, by its Info.plist key (Sources/Build.swift). build.sh writes them, so
# nothing is named twice. Paths in the home folder are written relative to it.
readonly shared=(OrbitIdentifier $identifier OrbitConfig $config OrbitLaunchers $dest
                 OrbitLogs $logs OrbitLSRegister $lsregister)

# The keychains macOS searches for you, one path per line.
keychains() { security list-keychains -d user | sed 's/^ *"//; s/"$//' }

# Exits unless no orbit runs: an install never interrupts an orbit.
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
  $lsregister -f -R $dest
  $app/Contents/MacOS/Orbit internal sync || true
  if linked || [[ ! -e $command && ! -L $command ]]; then
    mkdir -p $command:h
    ln -sfn $app/Contents/MacOS/Orbit $command
  fi
  print "  installed Orbit $(plutil -extract CFBundleShortVersionString raw $app/Contents/Info.plist)"
}

