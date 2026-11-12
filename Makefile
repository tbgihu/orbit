.PHONY: install update build identity uninstall clean

## make install    build, signed with your Apple Development certificate if there is one, else with Orbit's
##                 signing identity (created here), and install to ~/Applications/Orbit, with the orbit command.
##                 Without Xcode it offers once to open its App Store page, for Siri and Shortcuts
install:
	@zsh -c 'source scripts/lib.sh && require_idle && offer_xcode'
	@scripts/identity.sh
	@scripts/build.sh
	@scripts/install.sh

## make update     pull (fast-forward only) and install when the installed Orbit is behind
update:
	@scripts/update.sh

## make build      build build/Orbit.app only
build:
	@scripts/build.sh

## make identity   create the local signing certificate
identity:
	@scripts/identity.sh

## make uninstall  ask, then delete Orbit, the clone it was installed from, your orbits and all of Orbit's data
uninstall:
	@scripts/uninstall.sh

clean:
	@rm -rf build
