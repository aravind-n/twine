# Twine website

This directory contains the static GitHub Pages landing page, documentation index,
user guide template, and combined Rust workspace reference entry page.
Keep it in plain HTML and CSS, with relative asset URLs so it works under `/twine/` and in local
previews. No JavaScript runtime is required. `make build-site` creates an isolated
Python environment under `target/site-venv` with the pinned Markdown renderer.

Use the terminology in `../CONTEXT.md`. Keep feature descriptions and installation
requirements consistent with `../README.md` and `../docs/reference.md`. Link to
GitHub Releases for downloads and to `docs/` for detailed usage. The user guide is
generated from `../docs/reference.md`; edit that source instead of generated HTML.
Rust APIs come from `cargo doc --workspace --no-deps`; `rust.html` provides one
entry page and shared search for the core and C ABI bridge. Swift APIs come from Xcode
DocC, including internal app symbols. The Swift overview lives in
`../macOS/Twine/Twine/Documentation.docc/Twine.md`.

Run `make build-site`, `make serve-site`, and `make check-site` from the repository
root. `make docs-rust` and `make docs-swift` build the API references separately.
The full website build needs the macOS app toolchain described in the root README.
The build copies the app icon and README screenshot into `dist/twine/assets`;
update their original files instead of adding duplicate images here. Generated
files in `dist` are ignored by Git.

Check the page in a browser at desktop and mobile widths after visual changes.
DocC is configured for `/twine/docs/swift/`. Local previews serve at `/twine/` so
its scripts, search, and direct symbol links use the same paths as GitHub Pages.
The Pages workflow builds on the existing `xcode-27` runner and deploys only from
`main`. Keep its path filters in sync with all API documentation inputs.
