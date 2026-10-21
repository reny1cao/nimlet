# Nimlet — iPhone as trackpad + hold-to-talk for AI coding agents.
SIM ?= iPhone 17 Pro
DD  := build/dd
DIST := dist
HOST_APP := $(DD)/Build/Products/Debug/Mice.app
REMOTE_APP := $(DD)/Build/Products/Debug-iphonesimulator/MiceRemote.app
RELEASE_APP := $(DD)/Build/Products/Release/Mice.app
DEVICE_APP := $(DD)/Build/Products/Release-iphoneos/MiceRemote.app
CLI := build/nimlet
SIGN_IDENTITY ?= Developer ID Application
ENTITLEMENTS := Signing/NimletHost.entitlements

# The piped recipes below say `set -o pipefail` one by one rather than setting
# it once in .SHELLFLAGS, because macOS still ships GNU Make 3.81 and 3.81
# ignores .SHELLFLAGS entirely — the tidier version looks right and does
# nothing. Without pipefail, `xcodebuild ... | tail -3` reports the exit status
# of `tail`, which is always 0, so a failing build reported success and the
# dependent target ran anyway.
SHELL := /bin/bash

.PHONY: all help project host remote test relay-test run-host install-host sim install \
	device install-device logs bench watch listen tool release notarize clean

all: host remote

help:
	@echo "make host          build the menu bar app (Debug)"
	@echo "make remote        build the iOS app for the Simulator (Debug)"
	@echo "make test          run the unit tests"
	@echo "make run-host      build Debug and relaunch from the build directory"
	@echo "make install-host  build Release, install to /Applications, launch at login"
	@echo "make install       install on a booted Simulator — no dictation, see below"
	@echo "make device        install on a connected iPhone — the one that can dictate"
	@echo "make release       Release build, hardened runtime, signed, into $(DIST)/"
	@echo "make notarize      submit that build to Apple (needs MICE_NOTARY_PROFILE)"
	@echo "make tool          build the headless nimlet CLI into $(CLI)"
	@echo "make relay-test    check the push relay's JWT signing (needs node)"
	@echo "make bench         drive the host at 120 Hz and report send-side timing"
	@echo "make listen        attach as a listener and report the audio arriving"
	@echo "make logs          watch events arrive"
	@echo
	@echo "Dictation does not work in the Simulator: SpeechTranscriber.isAvailable"
	@echo "is false there and SFSpeechRecognizer fails to initialise. 'make install'"
	@echo "gets you a working trackpad with a dead microphone, which is fine for"
	@echo "pointer and delivery work and useless for voice. Use 'make device'."

project:
	xcodegen generate

host: project
	set -o pipefail; xcodebuild -project Nimlet.xcodeproj -scheme NimletHost -configuration Debug \
		-derivedDataPath $(DD) build | tail -3

remote: project
	set -o pipefail; xcodebuild -project Nimlet.xcodeproj -scheme NimletRemote -configuration Debug \
		-sdk iphonesimulator -destination 'platform=iOS Simulator,name=$(SIM)' \
		-derivedDataPath $(DD) build CODE_SIGNING_ALLOWED=NO | tail -3

# Unpiped on purpose: a failing assertion is the whole point of running these,
# and `tail` would cut it off above the summary.
test: project
	xcodebuild -project Nimlet.xcodeproj -scheme NimletTests -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DD) test

# Exercises the real iOS client over local TLS fixtures, without granting a
# test device access to the user's Mac. Use SIM=<name> to choose a simulator.
.PHONY: test-connections
test-connections:
	xcodegen generate --spec Tests/remote-tests.yml
	xcodebuild -project Tests/NimletConnectionTests.xcodeproj -scheme NimletConnectionTests \
		-destination 'platform=iOS Simulator,name=$(SIM)' \
		-derivedDataPath build/connection-tests test

# Restarts the menu bar app from the build directory.
# The relay is JavaScript and runs on somebody else's edge, so it is not part of
# `make test`. What this checks is the piece that fails silently: a JWT APNs
# refuses looks exactly like a wrong key id, a wrong team id or a skewed clock.
relay-test:
	cd Relay && node --test worker.test.js connect/relay.test.mjs

run-host: host
	-pkill -x Mice
	open $(HOST_APP)

# Release build into /Applications, so it survives `make clean` and can
# launch at login.
install-host: project
	@DD=$(DD) Scripts/install-host.sh

sim:
	-xcrun simctl boot "$(SIM)"
	open -a Simulator

# Trackpad, pairing, clicks, scroll and text delivery all work here. Dictation
# does not, and cannot: SpeechTranscriber.isAvailable is false in the Simulator
# and SFSpeechRecognizer fails to initialise, so the hold-to-talk path is dead
# on the build the quickstart reaches for first. `make device` is the one that
# can dictate.
#
# The bundle id is read from the build, so a fork's own prefix launches too.
install: remote sim
	xcrun simctl install booted $(REMOTE_APP)
	xcrun simctl launch booted $$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' $(REMOTE_APP)/Info.plist)
	@echo "Installed on the Simulator. Dictation will not work here — use 'make device'."

# The build that can actually dictate. Needs a real signing identity and a
# connected, trusted iPhone. Pass DEVICE=<udid> to install it as well;
# `xcrun devicectl list devices` prints the ids.
device: project
	set -o pipefail; xcodebuild -project Nimlet.xcodeproj -scheme NimletRemote -configuration Release \
		-destination 'generic/platform=iOS' -derivedDataPath $(DD) build | tail -3
	@if [ -n "$(DEVICE)" ]; then \
		xcrun devicectl device install app --device "$(DEVICE)" $(DEVICE_APP); \
	else \
		echo "Built $(DEVICE_APP)."; \
		echo "To install: make device DEVICE=<udid>   (xcrun devicectl list devices)"; \
	fi

# Headless client, also used for timing measurements. Built with swiftc rather
# than as an Xcode target because it is a plain command-line binary and does not
# need a bundle, a platform or a signing identity.
tool:
	@mkdir -p build
	swiftc -O Shared/*.swift Tools/nimlet/*.swift -o $(CLI)

# The older single-file client, kept for `make watch`: it is the only thing
# that counts frames on the panel channel, which `nimlet` cannot do.
send-tool:
	@mkdir -p build
	swiftc -O Shared/*.swift NimletRemote/AudioDecoder.swift Tools/nimlet-send/main.swift -o build/nimlet-send

# Drives the host at 120 Hz and reports send-side timing. Needs `nimlet pair`
# once for the code. Enable host-side percentiles first:
#   defaults write com.renyicao.mice.host mice.instrument -bool YES
bench: tool
	$(CLI) bench --hz 120 --seconds 5

# Attaches as a panel viewer and reports what the host is actually sending.
# "Is the mirror blank, or is nothing being sent?"
watch: send-tool
	./build/nimlet-send --code $$(defaults read com.renyicao.mice.host mice.pairingCode.v1) \
		--watch 5

# The same question for audio, and it has an extra half: this decodes what
# arrives, so "nothing is being sent" and "silence is being sent" are told apart.
# Play something on the Mac first, or the honest answer is that it is quiet.
listen: send-tool
	./build/nimlet-send --code $$(defaults read com.renyicao.mice.host mice.pairingCode.v1) \
		--listen 5

# "Is it the network, or is it the Accessibility grant?"
logs:
	log stream --predicate 'subsystem == "com.renyicao.mice"' --style compact

# A signed, hardened-runtime Release build in $(DIST). This is a complete,
# working step; only `notarize` below is unfinished.
#
# The copy in $(DIST) is re-signed rather than trusted from the build settings,
# because it is the one that ships and --options runtime is the exact flag
# notarization checks for.
release: project
	set -o pipefail; xcodebuild -project Nimlet.xcodeproj -scheme NimletHost -configuration Release \
		-derivedDataPath $(DD) build | tail -3
	rm -rf $(DIST)
	mkdir -p $(DIST)
	cp -R $(RELEASE_APP) $(DIST)/Mice.app
	mkdir -p $(DIST)/Mice.app/Contents/Resources
	cp LICENSE $(DIST)/Mice.app/Contents/Resources/LICENSE.txt
	cp THIRD-PARTY-NOTICES.txt $(DIST)/Mice.app/Contents/Resources/THIRD-PARTY-NOTICES.txt
	codesign --force --options runtime --timestamp \
		--sign "$(SIGN_IDENTITY)" $(DIST)/Mice.app/Contents/Helpers/nimlet
	codesign --force --options runtime --timestamp \
		--entitlements $(ENTITLEMENTS) --sign "$(SIGN_IDENTITY)" $(DIST)/Mice.app
	codesign --verify --strict --verbose=2 $(DIST)/Mice.app
	ditto -c -k --keepParent $(DIST)/Mice.app $(DIST)/Mice.zip
	@echo "$(DIST)/Mice.zip is signed but NOT notarized. Gatekeeper will still"
	@echo "refuse it on a machine that has not seen it before. Run 'make notarize'."

# UNVERIFIED: this has never been run. Nobody has an App Store Connect
# credential for Nimlet yet, so the submission below has not once round-tripped
# against Apple, and the first person to try it should expect to fix it.
#
# It is written out rather than stubbed because the commands are not the hard
# part — and it exits non-zero when the credential is missing rather than
# printing a reassuring message, so `make release notarize` can never leave
# behind a build that only looks distributable.
#
# stapler writes the ticket into the .app, so the zip is rebuilt from it
# afterwards rather than kept from `release`.
notarize:
	@test -f $(DIST)/Mice.zip || { \
		echo "No $(DIST)/Mice.zip. Run 'make release' first."; exit 1; }
	@test -n "$$MICE_NOTARY_PROFILE" || { \
		echo "NOT NOTARIZED: MICE_NOTARY_PROFILE is unset, so nothing was submitted."; \
		echo; \
		echo "Store the credential once — in the login keychain, never in this repo:"; \
		echo "  xcrun notarytool store-credentials mice-notary \\"; \
		echo "      --apple-id <apple-id> --team-id HG29U745Q5 --password <app-specific>"; \
		echo; \
		echo "then: MICE_NOTARY_PROFILE=mice-notary make notarize"; \
		exit 1; }
	xcrun notarytool submit $(DIST)/Mice.zip \
		--keychain-profile "$$MICE_NOTARY_PROFILE" --wait
	xcrun stapler staple $(DIST)/Mice.app
	xcrun stapler validate $(DIST)/Mice.app
	rm -f $(DIST)/Mice.zip
	ditto -c -k --keepParent $(DIST)/Mice.app $(DIST)/Mice.zip
	@echo "Notarized and stapled: $(DIST)/Mice.zip"

# Installs on your actual iPhone. Unlock it and connect it first — over USB, or
# over Wi-Fi if you have paired it for that. `xcrun devicectl list devices` says
# "connected" when it is ready; anything else and this will not find it.
DEVICE_APP := $(DD)/Build/Products/Release-iphoneos/MiceRemote.app

install-device: device
	@UDID=$$(xcrun devicectl list devices 2>/dev/null \
		| awk '$$0 ~ /physical/ && $$0 ~ /connected/ {for (i=1;i<=NF;i++) if ($$i ~ /^[0-9A-Fa-f-]{25,}$$/) {print $$i; exit}}'); \
	if [ -z "$$UDID" ]; then \
		echo "error: no connected iPhone. Unlock it, plug it in, and check 'xcrun devicectl list devices'." >&2; \
		exit 1; \
	fi; \
	echo "==> Installing to $$UDID"; \
	xcrun devicectl device install app --device "$$UDID" $(DEVICE_APP)

clean:
	rm -rf build dist Nimlet.xcodeproj
