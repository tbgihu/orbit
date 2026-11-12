#!/bin/zsh
# Orbit's updates. The install is this git clone; an update brings it up to its upstream and rebuilds.
#
#   update.sh            `make update`: prepare, then install right away. Only when no orbit runs.
#   update.sh check      fetch and compare; exits 10 when a newer version than the installed Orbit exists, 3 offline
#   update.sh prepare
#                        fetch, and when the upstream (or this clone) is ahead of the installed Orbit, build that
#                        commit into the stage. Nothing installed changes. The agent runs this every 2 h. Exits 3
#                        when offline.
#   update.sh install [--after <pid>] [<url>…]
#                        wait for <pid> (the agent) to exit, prepare again unless the stage was readied in the last
#                        10 minutes, fast-forward the clone, put the
#                        new Orbit.app in place, then hand it each <url> (the requests the old one was started with,
#                        or its windows).
#
# Never moves the clone backwards or across local commits, and never prompts, since there is no terminal.
set -euo pipefail
cd "${0:A:h}/.."
source scripts/lib.sh
git rev-parse --git-dir >/dev/null 2>&1 || { print "  not a git clone, so there is nothing to update from"; exit 0 }
export GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=15"

# Sets `target` to the build to install and `current` when the installed Orbit (`have`) is that already. The
# commit is the upstream's after a fetch, or this clone's if it is ahead.
latest() {
  mkdir -p $stage
  have=$(installed)
  touch $stage/checked
  git fetch --quiet 2>/dev/null || { offline=1; print "  could not fetch, so using the commits already here" }
  local head=$(git rev-parse --short=12 HEAD)
  target=$(git rev-parse --short=12 '@{upstream}' 2>/dev/null) || target=$head
  git merge-base --is-ancestor $head $target 2>/dev/null || target=$head    # local commits: build those
  current=false
  [[ $have == $target ]] && current=true
  true
}

# Reports whether a newer version than the installed Orbit exists. Fetches and compares only.
check() {
  local target current have
  latest
  if [[ $target == $have ]]; then print "  up to date ($have)"; return 0; fi
  print "  available $target"
  return 10
}

prepare() {
  local target current have
  latest
  rm -rf $stage/src                                               # left by a build that failed or was interrupted

  if $current; then
    rm -rf $stage/Orbit.app $stage/commit
    print "  up to date ($(installed))"
    return
  fi
  if [[ -d $stage/Orbit.app && $(cat $stage/commit 2>/dev/null) == $target ]]; then
    touch $stage/commit                                           # confirmed the latest just now
    print "  ready     $target"
    return
  fi

  print "  building  $target"
  rm -rf $stage/Orbit.app $stage/commit
  git worktree prune                                              # forget one that was deleted, by an uninstall too
  git worktree add --quiet --detach $stage/src $target
  if ! (repo=$PWD; cd $stage/src && ORBIT_SOURCE=$repo scripts/build.sh >/dev/null); then
    git worktree remove --force $stage/src
    print "  could not build $target"
    return 1
  fi
  mv $stage/src/build/Orbit.app $stage/Orbit.app
  $lsregister -u $stage/Orbit.app 2>/dev/null || true             # not a candidate for orbit:// links
  git worktree remove --force $stage/src
  identity $stage/Orbit.app > $stage/commit
  print "  ready     $(<$stage/commit)"
}

install() {
  if [[ ${1-} == --after ]]; then
    await_exit $2
    shift 2
  fi
  # Install the latest commit, or what is staged when offline. A stage that a prepare built or confirmed in the
  # last 10 minutes counts as the latest, unlike one that a later `check` merely fetched past.
  offline=0
  local fresh=($stage/commit(Nmm-10))
  if [[ ! -d $stage/Orbit.app || -z $fresh ]]; then
    prepare || true
  fi
  if [[ -d $stage/Orbit.app ]]; then
    local target=$(<$stage/commit)
    if git merge --ff-only --quiet $target 2>/dev/null; then
      place $stage/Orbit.app
    else
      print "  could not fast-forward to $target, so kept $(installed)"
      rm -rf $stage/Orbit.app $stage/commit                       # else every launch would try it again
    fi
  fi
  for url in $@; do open -g -a $app $url; done
}

case ${1-} in
  prepare) lock; offline=0; prepare; exit $(( offline ? 3 : 0 )) ;;     # 3: could not reach the remote
  check) lock; offline=0; check && rc=0 || rc=$?; (( offline )) && exit 3; exit $rc ;;   # 10: one is available
  install) shift; lock; install $@ ;;
  "")
    require_idle
    lock
    prepare
    [[ -d $stage/Orbit.app ]] || exit 0
    stop_agent
    install
    ;;
  *) print -u2 "usage: update.sh [check | prepare | install [--after <pid>] [<url>…]]"
     exit 64 ;;
esac
