#!/bin/zsh
# Removes all of Orbit's code and data from this Mac: the app, its launchers and the orbit command, the staged
# update, the clone Orbit was installed from (Info.plist `OrbitSource`, else the clone this script is in), your
# orbits (orbits.json), settings, privacy permissions, Orbit's signing identity, caches and logs. Apple's
# intermediate certificate stays if Orbit added it (`development_identity` in lib.sh), since Xcode uses it too.
# Runs only when no orbit runs, and asks first.
#
#   uninstall.sh          `make uninstall`: lists what it deletes and asks to confirm. With no terminal on stdin
#                         the script refuses, since it can't ask.
#   uninstall.sh --yes    deletes without asking
#
# ORBIT_UNINSTALL_AFTER=<pid> makes it wait for <pid> to exit first: Uninstall Orbit in Settings sets this to the
# agent's pid. build.sh puts this script and lib.sh in Orbit.app, so Settings runs it without the clone.
#
# Deletes nothing when the clone's path looks wrong: not a git work tree with scripts/uninstall.sh at its top, or
# `/`, the home folder or a folder that holds the home folder. The clone goes last, after the final message.
set -euo pipefail
source "${0:A:h}/lib.sh"

yes=false
while (( $# )); do
  case $1 in
    --yes) yes=true; shift ;;
    *) print -u2 "usage: uninstall.sh [--yes]"; exit 64 ;;
  esac
done

[[ -n ${ORBIT_UNINSTALL_AFTER-} ]] && await_exit $ORBIT_UNINSTALL_AFTER
require_idle

# <path>, written from ~ when it is in the home folder.
tilde() { print -r -- "${1/#$HOME/~}" }

# Whether <folder> is an Orbit clone that is safe to delete as a whole.
orbit_clone() {
  local dir=${1:A} home=${HOME:A}
  [[ -n $1 && $dir != / && $dir != $home && $home != $dir/* && -f $dir/scripts/uninstall.sh ]] \
    && [[ $(git -C $dir rev-parse --show-toplevel 2>/dev/null) == $dir ]]
}

clone=$(plutil -extract OrbitSource raw $app/Contents/Info.plist 2>/dev/null) || clone=
[[ -z $clone ]] && orbit_clone ${0:A:h:h} && clone=${0:A:h:h}
if [[ -n $clone && ! -e $clone ]]; then
  print "  the clone Orbit was installed from, $(tilde $clone), is gone already"
  clone=
elif [[ -n $clone ]] && ! orbit_clone $clone; then
  print -u2 "  $clone, which Orbit was installed from, does not look like a clone of Orbit (nothing changed)"
  exit 1
fi
[[ -n $clone ]] && clone=${clone:A}

if ! $yes; then
  if [[ ! -t 0 ]]; then
    print -u2 "  uninstall.sh asks before deleting: run it at a terminal, or with --yes (nothing changed)"
    exit 1
  fi
  print "  This deletes, with no undo:"
  print "    Orbit's code: $(tilde $dest) (Orbit and its Spotlight launchers), the orbit command, the staged update"
  [[ -n $clone ]] && print "      and the clone Orbit was installed from, $(tilde $clone), with everything in it"
  print "    your orbits: $(tilde $config)"
  print "    Orbit's settings, privacy permissions, signing identity, caches and logs"
  print "  Apple's intermediate certificate stays, since Xcode uses it too."
  read -q "?  Delete all of this? [y/N] " && answer=0 || answer=$?
  print
  (( answer == 0 )) || { print "  nothing changed"; exit 1 }
fi

lock
stop_agent
for bundle in $dest/*.app(N); do $lsregister -u $bundle 2>/dev/null || true; done
repo=                                                             # the repository of the update worktree
[[ -e $stage/src ]] && repo=$(git -C $stage/src rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || true
if linked; then rm -f "${command:?}"; fi
rm -rf $dest $stage:h $logs $signing:h $runtime
[[ -n $repo ]] && { git --git-dir=$repo worktree prune 2>/dev/null || true }   # forget the update worktree
defaults delete $identifier 2>/dev/null || true
tccutil reset All $identifier >/dev/null 2>&1 || true              # the access granted in Privacy & Security
# Orbit writes only orbits.json in its folder, so the folder goes when nothing else of yours is in it.
rm -f $config $config:h/.DS_Store
rmdir $config:h 2>/dev/null || true
kept=
[[ -d $config:h ]] && kept=" (kept your other files in $(tilde $config:h))"

removed="Orbit, its launchers, settings, signing identity, caches, logs"
if [[ -n $clone ]]; then
  cd /                                                            # `make uninstall` runs in the clone
  print "  removed   $removed, your orbits$kept and $(tilde $clone)"
  rm -rf -- "${clone:?}"
else
  print "  removed   $removed and your orbits$kept"
fi
