/// App-injected JavaScript runs even when scripts supplied by a Markdown document are disabled.
nonisolated enum MarkdownPreviewScript {
    static let headings = #"""
        const used = new Set(Array.from(document.querySelectorAll('[id]'), element => element.id));
        for (const heading of document.querySelectorAll('h1, h2, h3, h4, h5, h6')) {
            if (heading.id) continue;
            const slug = heading.textContent.toLowerCase().trim()
                .replace(/[^\p{L}\p{N}\p{M}\s_-]/gu, '').replace(/\s/g, '-');
            let id = slug;
            let suffix = 0;
            while (used.has(id)) id = `${slug}-${++suffix}`;
            used.add(id);
            heading.id = id;
        }
        """#

    static let scroll = #"""
        const target = document.getElementById(fragment) || document.getElementsByName(fragment)[0];
        if (target) target.scrollIntoView();
        else if (!fragment) window.scrollTo(0, 0);
        """#
}
