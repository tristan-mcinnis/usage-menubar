# One entry point for agents and humans. Warnings are errors in build and test.
# Targets wrap scripts/; the scripts stay the source of truth.

SWIFT_FLAGS := -Xswiftc -warnings-as-errors

.PHONY: build test check app install

build:
	swift build $(SWIFT_FLAGS)

test:
	swift test $(SWIFT_FLAGS)

# Strict build and test, then an ad-hoc release bundle in dist/Usage.app. Never launches.
check: build test app

# Build dist/Usage.app. Does not install or launch.
app:
	./scripts/build-app.sh

# Verify, install to /Applications and launch in the background. Pass flags with ARGS, e.g. ARGS=--no-launch.
install:
	./scripts/install.sh $(ARGS)
