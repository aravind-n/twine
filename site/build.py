"""Assemble the landing page and render the existing Markdown reference."""

from pathlib import Path
from shutil import copyfile
from string import Template
import sys

import markdown


def build(output: Path) -> None:
    root = Path(__file__).resolve().parent.parent
    source = root / "site"
    (output / "assets").mkdir(parents=True, exist_ok=True)
    (output / "docs").mkdir(exist_ok=True)

    for name in ("index.html", "styles.css"):
        copyfile(source / name, output / name)
    copyfile(root / "docs/images/twine-workspace.png", output / "assets/workspace.png")
    icons = root / "macOS/Twine/Twine/Assets.xcassets/AppIcon.appiconset"
    copyfile(icons / "twine-256.png", output / "assets/icon.png")
    copyfile(icons / "twine-32.png", output / "assets/favicon.png")

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
    template = Template((source / "docs.html").read_text(encoding="utf-8"))
    (output / "docs/index.html").write_text(
        template.substitute(content=content, toc=renderer.toc), encoding="utf-8"
    )
    print(f"Built landing page and documentation in {output}")


if __name__ == "__main__":
    build(Path(sys.argv[1]))
