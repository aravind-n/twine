.DEFAULT_GOAL := help

PROJECT := macOS/Twine/Twine.xcodeproj
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme Twine -skipPackagePluginValidation
XCODEBUILD_DEBUG := $(XCODEBUILD) -destination 'platform=macOS,arch=$(shell uname -m)'
FRAMEWORK_BUILD := macOS/TwineCorePackage/build.sh
DERIVED_DATA ?= $(CURDIR)/target/release-app
BUILD_DIR ?= $(DERIVED_DATA)/Build/Products/Release
BUNDLE_DIR ?= $(CURDIR)/target/release-bundle
OUTPUT_DIR ?= $(CURDIR)/dist
SITE_DIR := $(CURDIR)/dist/twine
RUST_DOC_DIR := $(CURDIR)/target/api-docs-rust
SWIFT_DOC_DIR := $(CURDIR)/target/api-docs-swift
XCODE_BUILD_ARGS ?=
RELEASE_SCRIPT := bash .github/release/release.sh

UI_TEST_DERIVED_DATA ?= /tmp/twine-uitests
# Tests outside this list are retired from default runs, but remain available with ONLY or ALL=1.
# Add a test here to re-enable it in local and CI default runs.
UI_DEFAULT_TESTS := testFirstLaunchShowsStartPage \
	testSidebarToolbarInFullScreenInDarkAppearance \
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
	testTimelineInspectorShowsNestedCallsFiltersAndSurvivesRelaunch \
	testAgentReceivesTerminalColorsBeforeItsStartupProbeTimesOut \
	testForceQuitPreservesAgentOutputAndCanResumeItsSession \
	testAdversarialHarnessSelectionUserCompletionReviewLoopAndTraces \
	testWorkflowDesignerKeyboardEntryValidationAndBuiltinCopy \
	testBentoPanesKeepEachShellAndMoveTheKeyboardBetweenThem \
	testTerminalSplitsResizeKeepTheirNeighborAndRestoreOutput \
	testFileEditingUndoSaveAndConflictChoices \
	testSwiftSyntaxHighlightingPreservesUnicodeCRLFEditingAndUndo \
	testSyntaxLanguageOverridesStayWithTheirFileTabs \
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
	fmt lint test check clean release-build-app release-bundle release-package nightly-package \
	check-release check-release-scripts check-release-package \
	build-site docs-rust docs-swift

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
	@echo 'GitHub Pages website:'
	@echo '  build-site            Copy static pages and generate API docs in dist/twine'
	@echo '  docs-rust             Generate Rust workspace API docs with cargo doc'
	@echo '  docs-swift            Generate Swift app API docs with Xcode DocC'
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
	@echo '  build-macos           Build the Debug app, after the Debug framework'
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
	@echo '  nightly-package       Package and verify archives for NIGHTLY_ID (BUNDLE_DIR, OUTPUT_DIR)'
	@echo '  check-release         Test release scripts and macOS packaging, and lint workflows'
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
	$(XCODEBUILD_DEBUG) build

build-macos-release: framework-release
	$(MAKE) release-build-app

release-build-app:
	$(XCODEBUILD) -configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath "$(DERIVED_DATA)" -onlyUsePackageVersionsFromResolvedFile build $(XCODE_BUILD_ARGS)

release-bundle:
	$(RELEASE_SCRIPT) bundle "$(BUILD_DIR)" "$(BUNDLE_DIR)"

release-package:
	$(RELEASE_SCRIPT) package "$(VERSION)" "$(BUNDLE_DIR)" "$(OUTPUT_DIR)"

nightly-package:
	$(RELEASE_SCRIPT) nightly-package "$(NIGHTLY_ID)" "$(BUNDLE_DIR)" "$(OUTPUT_DIR)"

check-release-scripts:
	bash .github/release/test-notes.sh
	bash .github/release/test-nightly.sh
	shellcheck .github/release/*.sh

check-release-package:
	bash .github/release/test-package.sh

check-release: check-release-scripts check-release-package
	actionlint -ignore 'label "xcode-27" is unknown'

docs-rust:
	RUSTDOCFLAGS='-D warnings' cargo doc --workspace --no-deps --locked --target-dir "$(RUST_DOC_DIR)"

docs-swift: framework
	$(XCODEBUILD_DEBUG) docbuild -derivedDataPath "$(SWIFT_DOC_DIR)" \
		-onlyUsePackageVersionsFromResolvedFile \
		OTHER_SWIFT_FLAGS='-symbol-graph-skip-synthesized-members' \
		DOCC_HOSTING_BASE_PATH=twine/documentation/swift DOCC_TRANSFORM_FOR_STATIC_HOSTING=YES
	# Validate Twine's catalog strictly without treating dependency documentation warnings as errors.
	xcrun docc convert macOS/Twine/Twine/Documentation.docc \
		--additional-symbol-graph-dir "$(SWIFT_DOC_DIR)/Build/Intermediates.noindex/Twine.build/Debug/Twine.build/symbol-graph" \
		--output-dir "$(SWIFT_DOC_DIR)/Build/Products/Debug/Twine.doccarchive" \
		--fallback-display-name Twine --fallback-bundle-identifier com.twineproject.Twine \
		--fallback-default-module-kind Application --hosting-base-path twine/documentation/swift \
		--transform-for-static-hosting --warnings-as-errors \
		--source-service github --source-service-base-url https://github.com/aravind-n/twine/blob/main \
		--checkout-path "$(CURDIR)"

build-site: docs-rust docs-swift
	rm -rf "$(SITE_DIR)"
	mkdir -p "$(SITE_DIR)"
	cp docs/index.html "$(SITE_DIR)/"
	cp -R docs/assets docs/documentation "$(SITE_DIR)/"
	cp macOS/Twine/Twine/Assets.xcassets/AppIcon.appiconset/twine-256.png "$(SITE_DIR)/assets/icon.png"
	cp macOS/Twine/Twine/Assets.xcassets/AppIcon.appiconset/twine-32.png "$(SITE_DIR)/assets/favicon.png"
	cp -R "$(RUST_DOC_DIR)/doc/." "$(SITE_DIR)/documentation/rust/"
	cp -R "$(SWIFT_DOC_DIR)/Build/Products/Debug/Twine.doccarchive" "$(SITE_DIR)/documentation/swift"

fmt-macos:
	swift format --in-place --recursive macOS/

lint-macos: framework
	swift format lint --strict --recursive macOS/
	macOS/Twine/Scripts/swiftlint.sh

test-macos: framework
	@set -eu; \
	twine_test_data=$$(mktemp -d /tmp/twine-unit-tests.XXXXXX); \
	trap 'rm -rf "$$twine_test_data"' EXIT; \
	TEST_RUNNER_TWINE_DATA_DIRECTORY="$$twine_test_data" \
		$(XCODEBUILD_DEBUG) test -only-testing:TwineTests

ui-test-macos: framework
	$(XCODEBUILD_DEBUG) -derivedDataPath "$(UI_TEST_DERIVED_DATA)" test $(UI_TEST_ARGS)

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
