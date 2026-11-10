.PHONY: install update build identity clean

## make install    build, signed with Orbit's
##                 signing identity (created here), and install to ~/Applications/Orbit, with the orbit command.
install:
	@zsh -c 'source scripts/lib.sh && require_idle'
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

clean:
	@rm -rf build
