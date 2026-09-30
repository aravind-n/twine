libtwinecore @VERSION@ (macOS 26+, Apple Silicon and Intel)

libtwinecore.a is Twine's existing static C ABI library, containing both
the bridge and reusable Rust core. Native apps can include
include/twine_bridge.h and link libtwinecore.a. Rust is not required to
consume this binary. The exported API uses the twine_ prefix.

Configure your linker for macOS system libraries: -liconv and the
Foundation framework (-framework Foundation), in addition to this archive.
The app's TwineCorePackage/Package.swift shows its own integration.

Follow the ownership and call rules in the header. Serialize calls to a
client, release returned buffers with twine_buffer_release, and destroy
the client with twine_client_destroy after all calls finish. Use one
client per application data directory.

The JSON protocol is experimental. Its command and response definitions
are in twine-bridge/src/protocol in the matching source archive. Pin a
matching library/header release. External shells and agent harnesses are
installed separately by the consumer.

Source and license: https://github.com/aravind-n/twine
Release notes: https://github.com/aravind-n/twine/releases/tag/v@VERSION@
