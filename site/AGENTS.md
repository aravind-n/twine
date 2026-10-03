# Twine website

This directory contains the static GitHub Pages landing page and docs template.
Keep it in plain HTML and CSS, with relative asset URLs so it works under `/twine/` and in local
previews. No JavaScript runtime is required. `make build-site` creates an isolated
Python environment under `target/site-venv` with the pinned Markdown renderer.

Use the terminology in `../CONTEXT.md`. Keep feature descriptions and installation
requirements consistent with `../README.md` and `../docs/reference.md`. Link to
GitHub Releases for downloads and to `docs/` for detailed usage. The docs page is
generated from `../docs/reference.md`; edit that source instead of generated HTML.

Run `make build-site`, `make serve-site`, and `make check-site` from the repository
root. The build copies the app icon and README screenshot into `dist/site/assets`;
update their original files instead of adding duplicate images here. Generated
files in `dist` are ignored by Git.

Check the page in a browser at desktop and mobile widths after visual changes.
The Pages workflow builds pull requests and deploys only from `main`.
