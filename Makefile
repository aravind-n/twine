.DEFAULT_GOAL := help

PROJECT := macOS/Twine/Twine.xcodeproj
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme Twine -skipPackagePluginValidation
XCODEBUILD_DEBUG := $(XCODEBUILD) -destination 'platform=macOS,arch=$(shell uname -m)'
FRAMEWORK_BUILD := macOS/TwineCorePackage/build.sh
DERIVED_DATA ?= $(CURDIR)/target/release-app
BUILD_DIR ?= $(DERIVED_DATA)/Build/Products/Release
BUNDLE_DIR ?= $(CURDIR)/target/release-bundle
OUTPUT_DIR ?= $(CURDIR)/dist
XCODE_BUILD_ARGS ?=
RELEASE_SCRIPT := bash .github/release/release.sh
BUILD_NUMBER_FILE ?= $(CURDIR)/.build-number

# Allocate at recipe execution time so help, linting, and dry runs do not increment.
define BUILD_DEBUG_APP
	@set -eu; \
	build_number=1; \
	if [ -f "$(BUILD_NUMBER_FILE)" ]; then \
		read -r build_number < "$(BUILD_NUMBER_FILE)"; \
	fi; \
	case "$$build_number" in \
		''|*[!0-9]*|0*) echo 'error: $(BUILD_NUMBER_FILE) must contain a positive integer without leading zeros' >&2; exit 1 ;; \
	esac; \
	build_number=$$((build_number + 1)); \
	printf '%s\n' "$$build_number" > "$(BUILD_NUMBER_FILE)"; \
	echo "Building Twine (build $$build_number)"; \
	$(XCODEBUILD_DEBUG) CURRENT_PROJECT_VERSION="$$build_number" $(1)
endef

UI_TEST_DERIVED_DATA ?= /tmp/twine-uitests
# Tests outside this list are retired from default runs, but remain available with ONLY or ALL=1.
# Add a test here to re-enable it in local and CI default runs.
UI_DEFAULT_TESTS := testFirstLaunchShowsStartPage \
	testZoomIsSharedByNewWindowsAndRememberedAfterRelaunch \
	testZoomReflowsTerminalAndScalesEditorPopoverAndSheet \
	testZoomBoundsKeepSplitDraggingAndSmallWindowsUsable \
	testZoomedWebPreviewsKeepLocalLinksInteractive \
	testRelaunchOpensLastFolderAndReturnsToStartPage \
	testFolderWindowsKeepShellsAndCommandsIndependent \
	testOpeningAnOpenFolderFocusesItsWindowIncludingSymlinks \
	testRelaunchRestoresAllFolderWindowsAndLeavesClosedFoldersClosed \
	testClosingAnUnavailableRestoredFolderKeepsItClosedOnRelaunch \
	testSessionsOwnTabsAndRestoreFreshShellsAfterRelaunch \
	testQuitStopsShellAndDescendant \
	testSingleAgentStartsInteractivelyTakesInputAndCancels \
	testClaudeMinimapDotsSelectTheirTraceAndScrollToThePrompt \
	testAgentReceivesTerminalColorsBeforeItsStartupProbeTimesOut \
	testForceQuitPreservesAgentOutputAndCanResumeItsSession \
	testAdversarialHarnessSelectionUserCompletionReviewLoopAndTraces \
	testWorkflowDesignerKeyboardEntryValidationAndBuiltinCopy \
	testBentoPanesKeepEachShellAndMoveTheKeyboardBetweenThem \
	testTerminalSplitsResizeKeepTheirNeighborAndRestoreOutput \
	testFileEditingUndoSaveAndConflictChoices \
	testMarkdownPreviewSourceSaveReloadAndLocalLinks \
	testClearedTraceOpensSavedInputAndOutputWithoutAScrollbackWarning
UI_VISUAL_TESTS := testFolderWindowInDarkAppearance \
	testDraftAndFooterAtMinimumWindowSizeInDarkAppearance \
	testTracesInDarkAppearance testCoordinatorGraphInDarkAppearance \
	testShortOutputMinimapInBothAppearances
UI_TEST_ARGS := $(if $(strip $(ONLY)),\
	$(addprefix -only-testing:TwineUITests/TwineUITests/,$(ONLY)),\
	$(if $(filter 1,$(ALL)),-only-testing:TwineUITests,\
		$(addprefix -only-testing:TwineUITests/TwineUITests/,$(UI_DEFAULT_TESTS))))

.PHONY: help fmt-rust lint-rust test-rust check-rust clean-rust \
	framework framework-release build-macos build-macos-release fmt-macos lint-macos \
	test-macos ui-test-macos ui-test-macos-built ui-test-macos-all ui-test-macos-visual check-macos clean-macos \
	fmt lint test check clean release-build-app release-bundle release-package check-release check-release-scripts

help:
	@echo 'usage: make <target> [ONLY="testA testB"]'
	@echo ''
	@echo 'Whole repository:'
	@echo '  fmt                   Format Rust and Swift code'
	@echo '  lint                  Run lint-rust and lint-macos'
	@echo '  test                  Run test-rust and test-macos'
	@echo '  check                 Run check-rust and check-macos'
	@echo '  clean                 Run clean-rust and clean-macos'
	@echo ''
	@echo 'Rust workspace (twine-core, twine-bridge):'
	@echo '  fmt-rust              Format Rust code'
	@echo '  lint-rust             Check Rust formatting and run Clippy with warnings denied'
	@echo '  test-rust             Run the Rust workspace tests (optional RUST_TEST_ARGS)'
	@echo '  check-rust            Run lint-rust and test-rust'
	@echo '  clean-rust            Remove Cargo build output'
	@echo ''
	@echo 'macOS app:'
	@echo '  framework             Build the Debug TwineCore XCFramework'
	@echo '  framework-release     Build the Release TwineCore XCFramework'
	@echo '  build-macos           Increment the local build number and build the Debug app'
	@echo '  build-macos-release   Build the universal Release app, after the Release framework'
	@echo '  fmt-macos             Format Swift code'
	@echo '  lint-macos            Prepare the framework, then run swift-format lint and SwiftLint'
	@echo '  test-macos            Run the Swift unit tests, after the Debug framework'
	@echo '  ui-test-macos         Run the default UI tests, or select with ONLY="testA testB"; takes over the desktop'
	@echo '  ui-test-macos-built   Run UI tests using existing build-for-testing products (ALL=1 includes retired tests)'
	@echo '  ui-test-macos-all     Run all UI tests, including retired tests and the launch benchmark; takes over the desktop'
	@echo '  ui-test-macos-visual  Run optional appearance and screenshot checks; takes over the desktop'
	@echo '  check-macos           Run lint-macos and test-macos'
	@echo '  clean-macos           Remove the framework, package caches, and Xcode build output'
	@echo ''
	@echo 'Release packaging:'
	@echo '  release-build-app     Build Release app using an existing Release framework'
	@echo '  release-bundle        Save app, static C ABI library, header, symbols, commit'
	@echo '  release-package       Package and verify archives for VERSION (BUNDLE_DIR, OUTPUT_DIR)'
	@echo '  check-release         Test changelog extraction and lint release tooling'
	@echo ''
	@echo '  help                  Show this message (default)'

fmt-rust:
	cargo fmt --all

lint-rust:
	cargo fmt --all --check
	cargo clippy --workspace --all-targets --locked -- -D warnings

test-rust:
	cargo test --workspace --locked $(RUST_TEST_ARGS)

check-rust: lint-rust test-rust

clean-rust:
	cargo clean

framework:
	$(FRAMEWORK_BUILD) debug

framework-release:
	$(FRAMEWORK_BUILD) release

build-macos: framework
	$(call BUILD_DEBUG_APP,build)

build-macos-release: framework-release
	$(MAKE) release-build-app

release-build-app:
	$(XCODEBUILD) -configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath "$(DERIVED_DATA)" -onlyUsePackageVersionsFromResolvedFile build $(XCODE_BUILD_ARGS)

release-bundle:
	$(RELEASE_SCRIPT) bundle "$(BUILD_DIR)" "$(BUNDLE_DIR)"

release-package:
	$(RELEASE_SCRIPT) package "$(VERSION)" "$(BUNDLE_DIR)" "$(OUTPUT_DIR)"

check-release-scripts:
	bash .github/release/test-notes.sh
	shellcheck .github/release/*.sh

check-release: check-release-scripts
	actionlint -ignore 'label "xcode-27" is unknown'

fmt-macos:
	swift format --in-place --recursive macOS/

lint-macos: framework
	swift format lint --strict --recursive macOS/
	macOS/Twine/Scripts/swiftlint.sh

test-macos: framework
	$(call BUILD_DEBUG_APP,test -only-testing:TwineTests)

ui-test-macos: framework
	$(call BUILD_DEBUG_APP,-derivedDataPath "$(UI_TEST_DERIVED_DATA)" test $(UI_TEST_ARGS))

ui-test-macos-built:
	$(XCODEBUILD_DEBUG) -derivedDataPath "$(UI_TEST_DERIVED_DATA)" test-without-building $(UI_TEST_ARGS)

ui-test-macos-all:
	$(MAKE) ui-test-macos ALL=1

ui-test-macos-visual:
	$(MAKE) ui-test-macos ONLY="$(UI_VISUAL_TESTS)"

check-macos: lint-macos test-macos

# Package resolution needs the framework, so clean Xcode's output before removing it.
clean-macos:
	if [ -d macOS/TwineCorePackage/TwineCore.xcframework ]; then $(XCODEBUILD_DEBUG) clean; fi
	rm -rf macOS/TwineCorePackage/TwineCore.xcframework macOS/TwineCorePackage/.build \
		macOS/TwineCorePackage/.swiftpm macOS/TwineCorePackage/.build-core.* /tmp/twine-uitests

fmt: fmt-rust fmt-macos

lint: lint-rust lint-macos

test: test-rust test-macos

check: check-rust check-macos

clean: clean-rust clean-macos
