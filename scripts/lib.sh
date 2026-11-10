# Shared by the scripts (sourced), and the one place that names what Orbit installs and where.

readonly dest=~/Applications/Orbit
readonly app=$dest/Orbit.app
readonly command=~/.local/bin/orbit                       # the orbit command: a link to the app's executable
readonly config=~/.config/orbit/orbits.json
readonly logs=~/Library/Logs/Orbit
readonly stage=~/Library/Caches/Orbit/update
readonly signing=~/Library/"Application Support"/Orbit/signing
readonly keychain=$signing/orbit.keychain-db
readonly identifier=io.github.tbgihu.orbit
readonly runtime=${$(getconf DARWIN_USER_TEMP_DIR)%/}/$identifier     # Orbit's, whatever $TMPDIR says
readonly lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# What Orbit itself needs of the above, by its Info.plist key (Sources/Build.swift). build.sh writes them, so
# nothing is named twice. Paths in the home folder are written relative to it.
readonly shared=(OrbitIdentifier $identifier OrbitConfig $config OrbitLaunchers $dest OrbitStage $stage
                 OrbitLogs $logs OrbitLSRegister $lsregister)

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

# What tells the build at <Orbit.app> from another: its commit, without the "+" of local changes.
# Nothing when there is no app there.
identity() {
  local commit
  commit=$(plutil -extract OrbitCommit raw $1/Contents/Info.plist 2>/dev/null) || return 0
  print -r -- ${commit%+}
}

installed() { identity $app }

# The keychains macOS searches for you, one path per line.
keychains() { security list-keychains -d user | sed 's/^ *"//; s/"$//' }

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
  $lsregister -f -R $dest
  $app/Contents/MacOS/Orbit internal sync || true
  if linked || [[ ! -e $command && ! -L $command ]]; then
    mkdir -p $command:h
    ln -sfn $app/Contents/MacOS/Orbit $command
  fi
  rm -rf $stage/Orbit.app $stage/commit
  print "  installed Orbit $(plutil -extract CFBundleShortVersionString raw $app/Contents/Info.plist)"
}

