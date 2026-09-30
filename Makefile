.DEFAULT_GOAL := help

PROJECT := macOS/Twine/Twine.xcodeproj
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme Twine -skipPackagePluginValidation
XCODEBUILD_DEBUG := $(XCODEBUILD) -destination 'platform=macOS,arch=$(shell uname -m)'
FRAMEWORK_BUILD := macOS/TwineCorePackage/build.sh
UI_TEST_TARGETS := $(if $(strip $(ONLY)),$(addprefix TwineUITests/TwineUITests/,$(ONLY)),TwineUITests)

.PHONY: help fmt-rust lint-rust test-rust check-rust clean-rust \
	framework framework-release build-macos build-macos-release fmt-macos lint-macos \
	test-macos ui-test-macos check-macos clean-macos \
	fmt lint test check clean

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
	@echo '  test-rust             Run the Rust workspace tests'
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
	@echo '  ui-test-macos         Run UI tests, or select tests with ONLY="testA testB"; takes over the desktop'
	@echo '  check-macos           Run lint-macos and test-macos'
	@echo '  clean-macos           Remove the framework, package caches, and Xcode build output'
	@echo ''
	@echo '  help                  Show this message (default)'

fmt-rust:
	cargo fmt --all

lint-rust:
	cargo fmt --all --check
	cargo clippy --workspace --all-targets --locked -- -D warnings

test-rust:
	cargo test --workspace --locked

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
	$(XCODEBUILD) -configuration Release -destination 'generic/platform=macOS' build

fmt-macos:
	swift format --in-place --recursive macOS/

lint-macos: framework
	swift format lint --strict --recursive macOS/
	macOS/Twine/Scripts/swiftlint.sh

test-macos: framework
	$(XCODEBUILD_DEBUG) test -only-testing:TwineTests

ui-test-macos: framework
	$(XCODEBUILD_DEBUG) -derivedDataPath /tmp/twine-uitests test $(addprefix -only-testing:,$(UI_TEST_TARGETS))

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
