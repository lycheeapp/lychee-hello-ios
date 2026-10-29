# Lychee Hello (iOS) — common commands.
#
# IMPORTANT: XcodeGen enumerates source files at *generation* time. Any time files are added,
# removed or moved you must regenerate, or the new files simply are not in the target. The classic
# symptom of a missing entry point is:
#
#     Undefined symbol: _main
#
# `make build` and `make test` regenerate first so this cannot happen by accident.

SCHEME  := LycheeHello
PROJECT := LycheeHello.xcodeproj
DEST    := platform=iOS Simulator,name=iPhone 15

.DEFAULT_GOAL := help
.PHONY: help generate build test clean open

help: ## List available commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

generate: ## Regenerate the Xcode project from project.yml
	xcodegen generate

build: generate ## Regenerate, then build
	xcodebuild build -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)'

test: generate ## Regenerate, then run the test suite
	xcodebuild test -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)'

open: generate ## Regenerate and open in Xcode
	open $(PROJECT)

clean: ## Remove build output and the generated project
	rm -rf build DerivedData $(PROJECT)
