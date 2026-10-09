.DEFAULT_GOAL := help
# Xcode consumes one selected local binary package. Serialize stages that select its profile.
.NOTPARALLEL:

OUT := $(CURDIR)/out
PROJECT := macOS/Twine/Twine.xcodeproj
LIB_TARGET := aarch64-apple-darwin
export CARGO_TARGET_DIR := $(CURDIR)/target
export MACOSX_DEPLOYMENT_TARGET := 26.0
export SWIFT_PACKAGES_DIR := $(OUT)/dependencies/SourcePackages
XCODEBUILD := TMPDIR="$(OUT)/dependencies/tmp" xcodebuild -project $(PROJECT) -scheme Twine -skipPackagePluginValidation \
	-clonedSourcePackagesDirPath "$(SWIFT_PACKAGES_DIR)" \
	-packageCachePath "$(OUT)/dependencies/cache" -onlyUsePackageVersionsFromResolvedFile
XCODEBUILD_DEBUG := $(XCODEBUILD) -configuration Debug -destination 'platform=macOS,arch=arm64'
XCODEBUILD_RELEASE := $(XCODEBUILD) -configuration Release -destination 'generic/platform=macOS'
RELEASE_SETTINGS := ARCHS=arm64 GCC_GENERATE_DEBUGGING_SYMBOLS=NO DEBUG_INFORMATION_FORMAT= \
	ENABLE_CODE_COVERAGE=NO CLANG_ENABLE_CODE_COVERAGE=NO SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule
XCODE_BUILD_ARGS ?=
FRAMEWORK_BUILD := sh macOS/TwineCorePackage/build.sh
FRAMEWORK_SELECT := sh macOS/TwineCorePackage/select.sh
TESTS_DIR := $(OUT)/tests/build
# Tests run from these build products without the project, so CI can build once and test on other machines.
TEST_PRODUCTS := $(TESTS_DIR)/Build/Products
TEST_ARCHIVE := $(OUT)/tests/products.tar.gz
TEST_RUN = xcodebuild test-without-building -xctestrun "$(TEST_PRODUCTS)"/*.xctestrun \
	-destination 'platform=macOS,arch=arm64' -derivedDataPath "$(TESTS_DIR)"
SITE_DIR := $(OUT)/docs/site
LIB_DOC_DIR := $(OUT)/docs/rust
APP_DOC_DIR := $(OUT)/docs/swift
DMG_TOOLS_DIR := $(OUT)/packaging/tools
ACTIONLINT ?= actionlint
# The test host uses fresh temporary data; Xcode products and results stay in out/tests.
TEST_ENV := TEST_RUNNER_TWINE_PREFERENCES_SUITE=com.twineproject.Twine.tests.unit-host

# PREBUILT=1 runs a target without its prerequisites. CI uses it to run tests from unpacked test products.
needs = $(if $(PREBUILT),,$(1))

# Tests outside this list are retired from default runs, but remain available with ONLY or ALL=1.
# Add a test here to re-enable it in local and CI default runs.
UI_DEFAULT_TESTS := testFirstLaunchShowsStartPage \
	testFileMenuCanOpenWindowsAndFoldersAfterClosingLastWindow \
	testSettingsPopupLoadsSavesAndProtectsUnsavedChanges \
	testSavingSettingsReflowsExistingTerminalsInAllFolderWindows \
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
	testTerminalRunsLibraryInjectionAndDebugger \
	testSingleAgentStartsInteractivelyTakesInputAndCancels \
	testClaudeMinimapDotsSelectTheirTraceAndScrollToThePrompt \
	testTimelineInspectorShowsNestedCallsFiltersAndSurvivesRelaunch \
	testNativeHistoryShowsModelSummaryFullDetailsAndStoragePinAfterRelaunch \
	testTraceViewModesPreserveSelectionAndCollapsedState \
	testLegacyTraceEventsKeepLoadedPagesWhenThePanelRefreshes \
	testAgentReceivesTerminalColors \
	testForceQuitPreservesAgentOutputAndCanResumeItsSession \
	testAdversarialHarnessSelectionUserCompletionReviewLoopAndTraces \
	testWorkflowDesignerKeyboardEntryValidationAndBuiltinCopy \
	testBentoPanesKeepEachShellAndMoveTheKeyboardBetweenThem \
	testTerminalSplitsResizeKeepTheirNeighborAndRestoreOutput \
	testFileEditingUndoSaveAndConflictChoices \
	testAutosaveSettingsApplyToOpenTabsAndCommandSSavesExplicitly \
	testFileTreeContextMenusTargetClickedRowsAndPreserveEdits \
	testSwiftSyntaxHighlightingPreservesUnicodeCRLFEditingAndUndo \
	testSyntaxLanguageOverridesStayWithTheirFileTabs \
	testHTMLSyntaxHighlightingPreservesSourceEditingAndCSSDetection \
	testMarkdownPreviewSourceSaveReloadAndLocalLinks \
	testClearedTraceOpensSavedInputAndOutputWithoutAScrollbackWarning
UI_VISUAL_TESTS := testFolderWindowInDarkAppearance \
	testDraftAndFooterAtMinimumWindowSizeInDarkAppearance \
	testTracesInDarkAppearance testCoordinatorGraphInDarkAppearance \
	testShortOutputMinimapInBothAppearances
# SHARD=n/N runs every Nth default test, starting at the nth, so CI can split the list across machines.
UI_SHARD_TESTS = $(shell printf '%s\n' $(UI_DEFAULT_TESTS) | \
	awk -v shard='$(SHARD)' 'BEGIN { split(shard, part, "/") } part[2] > 0 && NR % part[2] == part[1] % part[2]')
UI_TEST_ARGS := $(if $(strip $(ONLY)),\
	$(addprefix -only-testing:TwineUITests/TwineUITests/,$(ONLY)),\
	$(if $(filter 1,$(ALL)),-only-testing:TwineUITests,\
		$(addprefix -only-testing:TwineUITests/TwineUITests/,\
			$(if $(strip $(SHARD)),$(UI_SHARD_TESTS),$(UI_DEFAULT_TESTS)))))

.PHONY: help
help: ## Show this help
	@echo 'usage: make <target> [VARIABLE=value ...]'
	@awk -F ':.*## ' '/^##@ /{printf "\n%s\n", substr($$0, 5)} /^[a-z-]+:.*## /{printf "  %-24s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

##@ Build
.PHONY: debug
debug: $(call needs,deps-debug) ## Build the debug app
	$(XCODEBUILD_DEBUG) -derivedDataPath "$(OUT)/debug" build $(XCODE_BUILD_ARGS)

.PHONY: release
release: $(call needs,deps-release) ## Build the release app
	$(XCODEBUILD_RELEASE) -derivedDataPath "$(OUT)/release" build $(RELEASE_SETTINGS) $(XCODE_BUILD_ARGS)

.PHONY: clean
clean: clean-dev-state ## Remove all build output and development data
	cargo clean
	rm -rf "$(OUT)"

.PHONY: clean-dev-state
clean-dev-state: ## Remove development data only
	sh scripts/clean-dev-state.sh

##@ Format, lint and test
.PHONY: fmt
fmt: fmt-lib fmt-app ## Format the library and the app

.PHONY: lint
lint: lint-lib lint-app ## Lint the library and the app

.PHONY: test
test: test-lib test-app ## Test the library and the app

.PHONY: check
check: check-lib check-app ## Lint and test the library and the app

.PHONY: fmt-lib
fmt-lib: ## Format the library
	cargo fmt --all

.PHONY: lint-lib
lint-lib: ## Lint the library
	cargo fmt --all --check
	cargo clippy --workspace --all-targets --locked -- -D warnings

.PHONY: test-lib
test-lib: ## Test the library (LIB_TEST_ARGS='filter -- flags')
	cargo test --workspace --locked $(LIB_TEST_ARGS)

.PHONY: check-lib
check-lib: lint-lib test-lib ## Lint and test the library

.PHONY: fmt-app
fmt-app: ## Format the app
	swift format --in-place --recursive macOS/

.PHONY: lint-app
lint-app: $(call needs,deps-debug) ## Lint the app
	swift format lint --strict --recursive macOS/
	macOS/Twine/Scripts/swiftlint.sh

.PHONY: test-app
test-app: $(call needs,build-tests) ## Run the app's unit tests
	@set -eu; \
	twine_test_data=$$(mktemp -d "$${TMPDIR:-/tmp}/twine-unit-tests.XXXXXX"); \
	trap 'rm -rf "$$twine_test_data"' EXIT; \
	TEST_RUNNER_TWINE_DATA_DIRECTORY="$$twine_test_data" \
	TEST_RUNNER_XDG_CONFIG_HOME="$$twine_test_data/config" $(TEST_ENV) \
		$(TEST_RUN) -only-testing:TwineTests

.PHONY: check-app
check-app: lint-app test-app ## Lint and unit-test the app

.PHONY: ui-test
ui-test: $(call needs,build-tests) ## Run UI tests (ONLY="testA testB", ALL=1 or SHARD=n/N)
	@test -n "$(strip $(UI_TEST_ARGS))" || { echo 'usage: make ui-test [ONLY="testA testB" | ALL=1 | SHARD=n/N]' >&2; exit 2; }
	$(TEST_ENV) $(TEST_RUN) $(UI_TEST_ARGS)

.PHONY: ui-test-visual
ui-test-visual: ## Run the visual UI tests
	$(MAKE) ui-test ONLY="$(UI_VISUAL_TESTS)"

.PHONY: lint-ci
lint-ci: ## Lint CI workflows and build scripts
	$(ACTIONLINT) -ignore 'label "xcode-27" is unknown'
	shellcheck scripts/*.sh macOS/TwineCorePackage/*.sh macOS/Twine/Scripts/swiftlint.sh

.PHONY: check-bundle
check-bundle: ## Test and lint the release scripts
	bash .github/release/test-notes.sh
	bash .github/release/test-signing.sh
	shellcheck .github/release/*.sh

# Build stages. debug, release and the app targets run these first.
.PHONY: framework-debug
framework-debug:
	cargo build --package twine-bridge --profile debug --locked --target $(LIB_TARGET)
	$(FRAMEWORK_BUILD) debug

.PHONY: framework-release
framework-release:
	cargo build --package twine-bridge --profile release --locked --target $(LIB_TARGET)
	$(FRAMEWORK_BUILD) release

.PHONY: deps-debug
deps-debug: $(call needs,framework-debug)
	mkdir -p "$(OUT)/dependencies/tmp"
	$(FRAMEWORK_SELECT) debug
	$(XCODEBUILD_DEBUG) -derivedDataPath "$(OUT)/debug" -resolvePackageDependencies

.PHONY: deps-release
deps-release: $(call needs,framework-release)
	mkdir -p "$(OUT)/dependencies/tmp"
	$(FRAMEWORK_SELECT) release
	$(XCODEBUILD_RELEASE) -derivedDataPath "$(OUT)/release" -resolvePackageDependencies

.PHONY: build-tests
build-tests: $(call needs,deps-debug)
	rm -f "$(TEST_PRODUCTS)"/*.xctestrun
	$(XCODEBUILD_DEBUG) build-for-testing -derivedDataPath "$(TESTS_DIR)" $(XCODE_BUILD_ARGS)

# CI archives the test products in the build job and unpacks them in each test job.
.PHONY: pack-tests
pack-tests: $(call needs,build-tests)
	cd "$(TEST_PRODUCTS)" && tar -czf "$(TEST_ARCHIVE)" Debug/Twine.app Debug/TwineUITests-Runner.app *.xctestrun

.PHONY: unpack-tests
unpack-tests:
	mkdir -p "$(TEST_PRODUCTS)"
	tar -xzf "$(TEST_ARCHIVE)" -C "$(TEST_PRODUCTS)"

##@ DMG packaging
.PHONY: build-dmg
build-dmg: dmg-tools ## Create a DMG from a signed app (APP=path DMG=path)
	@test -n "$(APP)" && test -n "$(DMG)" || { echo 'usage: make build-dmg APP=path DMG=path' >&2; exit 2; }
	bash .github/release/build-dmg.sh "$(APP)" "$(DMG)"

.PHONY: validate-dmg
validate-dmg: dmg-tools ## Validate an existing DMG (DMG=path [VERSION=x.y.z])
	@test -n "$(DMG)" || { echo 'usage: make validate-dmg DMG=path [VERSION=x.y.z]' >&2; exit 2; }
	bash .github/release/validate-dmg.sh "$(DMG)" "$(VERSION)"

.PHONY: dmg-tools
dmg-tools: $(DMG_TOOLS_DIR)/.installed ## Install the DMG tools

$(DMG_TOOLS_DIR)/.installed: .github/release/dmg-requirements.txt
	python3 -m venv "$(DMG_TOOLS_DIR)"
	"$(DMG_TOOLS_DIR)/bin/python3" -m pip install --disable-pip-version-check --cache-dir "$(OUT)/dependencies/pip" -r $<
	touch "$@"

.PHONY: regenerate-dmg-artwork
regenerate-dmg-artwork: ## Regenerate the DMG background
	swift format --in-place .github/release/render-background.swift
	swift .github/release/render-background.swift

##@ Documentation
.PHONY: build-site
build-site: $(call needs,docs-lib docs-app) ## Build the documentation website
	rm -rf "$(SITE_DIR)"
	mkdir -p "$(SITE_DIR)"
	cp docs/index.html "$(SITE_DIR)/"
	cp -R docs/assets docs/documentation "$(SITE_DIR)/"
	cp macOS/Twine/Twine/Assets.xcassets/AppIcon.appiconset/twine-256.png "$(SITE_DIR)/assets/icon.png"
	cp macOS/Twine/Twine/Assets.xcassets/AppIcon.appiconset/twine-32.png "$(SITE_DIR)/assets/favicon.png"
	cp -R "$(LIB_DOC_DIR)/doc/." "$(SITE_DIR)/documentation/rust/"
	cp -R "$(APP_DOC_DIR)/Build/Products/Debug/Twine.doccarchive" "$(SITE_DIR)/documentation/swift"

.PHONY: docs-lib
docs-lib: ## Build the library API reference
	RUSTDOCFLAGS='-D warnings' cargo doc --workspace --no-deps --locked
	mkdir -p "$(LIB_DOC_DIR)"
	rm -rf "$(LIB_DOC_DIR)/doc"
	cp -R "$(CURDIR)/target/doc" "$(LIB_DOC_DIR)/doc"

.PHONY: docs-app
docs-app: $(call needs,deps-debug) ## Build the app API reference
	$(XCODEBUILD_DEBUG) docbuild -derivedDataPath "$(APP_DOC_DIR)" \
		OTHER_SWIFT_FLAGS='-symbol-graph-skip-synthesized-members' \
		DOCC_HOSTING_BASE_PATH=twine/documentation/swift DOCC_TRANSFORM_FOR_STATIC_HOSTING=YES $(XCODE_BUILD_ARGS)
	# Validate Twine's catalog strictly without treating dependency documentation warnings as errors.
	mkdir -p "$(APP_DOC_DIR)/Build/Products/Debug"
	xcrun docc convert macOS/Twine/Twine/Documentation.docc \
		--additional-symbol-graph-dir "$(APP_DOC_DIR)/Build/Intermediates.noindex/Twine.build/Debug/Twine.build/symbol-graph" \
		--output-dir "$(APP_DOC_DIR)/Build/Products/Debug/Twine.doccarchive" \
		--fallback-display-name Twine --fallback-bundle-identifier com.twineproject.Twine \
		--fallback-default-module-kind Application --hosting-base-path twine/documentation/swift \
		--transform-for-static-hosting --warnings-as-errors \
		--source-service github --source-service-base-url https://github.com/aravind-n/twine/blob/main \
		--checkout-path "$(CURDIR)"
