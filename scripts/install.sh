#!/bin/zsh
# Installs build/Orbit.app as ~/Applications/Orbit/Orbit.app, has it create the Spotlight launchers for your orbits
# and links the orbit command into ~/.local/bin. A first install also creates ~/.config/orbit/orbits.json from the
# example. Runs only when no orbit runs.
set -euo pipefail
cd "${0:A:h}/.."
source scripts/lib.sh

require_idle

first=false
if [[ ! -f $config ]]; then
  first=true
  mkdir -p $config:h
  sed "s|\"\\./orbits.schema.json\"|\"file://$PWD/orbits.schema.json\"|" orbits.example.json > $config
  print "  created   $config from the examples"
fi

lock
stop_agent
place build/Orbit.app
if ! linked; then
  print "  $command is not Orbit's, so the orbit command was not installed"
elif [[ :$PATH: != *:$command:h:* ]]; then
  print "  to use the orbit command, add its folder to your PATH: echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zprofile"
fi
$first && open $app                                       # show the window after a first install
true
