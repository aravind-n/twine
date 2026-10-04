"""Assemble the website, user guide, and generated Rust and Swift references."""

from pathlib import Path
from shutil import copyfile, copytree, rmtree
from string import Template
import sys

import markdown


def build(output: Path) -> None:
    root = Path(__file__).resolve().parent.parent
    source = root / "site"
    rust_docs = root / "target/api-docs-rust/doc"
    swift_docs = root / "target/api-docs-swift/Build/Products/Debug/Twine.doccarchive"
    for required in (
        rust_docs / "twine_core/index.html",
        rust_docs / "twine_bridge/index.html",
        swift_docs / "documentation/twine/index.html",
    ):
        if not required.is_file():
            raise FileNotFoundError(f"Missing API documentation: {required}. Run make build-site.")
    (output / "assets").mkdir(parents=True, exist_ok=True)
    (output / "docs/guide").mkdir(parents=True, exist_ok=True)

    for name in ("index.html", "styles.css"):
        copyfile(source / name, output / name)
    copyfile(source / "docs.html", output / "docs/index.html")
    copyfile(root / "docs/images/twine-workspace.png", output / "assets/workspace.png")
    icons = root / "macOS/Twine/Twine/Assets.xcassets/AppIcon.appiconset"
    copyfile(icons / "twine-256.png", output / "assets/icon.png")
    copyfile(icons / "twine-32.png", output / "assets/favicon.png")
    copyfile(source / "download.js", output / "assets/download.js")

    renderer = markdown.Markdown(
        extensions=["pymdownx.superfences", "tables", "toc", "sane_lists"],
        extension_configs={
            "toc": {"toc_depth": "2-3", "permalink": "#"},
            "pymdownx.highlight": {"use_pygments": False},
        },
    )
    content = renderer.convert((root / "docs/reference.md").read_text(encoding="utf-8"))
    content = content.replace(
        'href="../README.md"',
        'href="https://github.com/aravind-n/twine/blob/main/README.md"',
    )
    template = Template((source / "guide.html").read_text(encoding="utf-8"))
    (output / "docs/guide/index.html").write_text(
        template.substitute(content=content, toc=renderer.toc), encoding="utf-8"
    )
    for name, generated in (("rust", rust_docs), ("swift", swift_docs)):
        destination = output / "docs" / name
        if destination.exists():
            rmtree(destination)
        copytree(generated, destination)
    copyfile(source / "rust.html", output / "docs/rust/index.html")
    print(f"Built landing page, user guide, and Rust and Swift API docs in {output}")


if __name__ == "__main__":
    build(Path(sys.argv[1]))
