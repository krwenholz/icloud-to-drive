SWIFT_SOURCES := App Packages/MirrorCore/Sources Packages/MirrorCore/Tests Packages/MirrorCore/Package.swift

.PHONY: check test lint format setup

# Everything CI runs.
check: lint test

test:
	scripts/test.sh

lint:
	scripts/lint.sh

format:
	swift format format --in-place --recursive --parallel $(SWIFT_SOURCES)

setup:
	mise install
