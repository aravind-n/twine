const downloadButtons = document.querySelectorAll("[data-macos-download]");
let downloadPending = false;

for (const button of downloadButtons) {
  button.addEventListener("click", async (event) => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    if (downloadPending) return;

    downloadPending = true;
    for (const link of downloadButtons) {
      link.setAttribute("aria-disabled", "true");
      link.setAttribute("aria-busy", "true");
      document.getElementById(link.dataset.macosDownload).hidden = true;
    }
    const feedback = document.getElementById(button.dataset.macosDownload);
    const message = feedback.querySelector("span");
    const fallback = feedback.querySelector("a");
    feedback.hidden = false;
    message.textContent = "Finding the latest macOS download…";
    fallback.hidden = true;

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    try {
      const response = await fetch("https://api.github.com/repos/aravind-n/twine/releases/latest", {
        headers: { Accept: "application/vnd.github+json" },
        cache: "no-store",
        signal: controller.signal,
      });
      if (!response.ok) throw new Error("Release lookup failed");
      const release = await response.json();
      const asset = release.assets?.find((asset) =>
        asset.state === "uploaded" && /^Twine-.+-macos-universal\.zip$/.test(asset.name)
      );
      if (!asset?.browser_download_url) throw new Error("Universal ZIP is unavailable");

      for (const link of downloadButtons) link.href = asset.browser_download_url;
      message.textContent = "Your download is starting.";
      window.location.assign(asset.browser_download_url);
    } catch {
      message.textContent = "Couldn’t find the latest download. Please try again.";
      fallback.hidden = false;
    } finally {
      clearTimeout(timeout);
      downloadPending = false;
      for (const link of downloadButtons) {
        link.removeAttribute("aria-disabled");
        link.removeAttribute("aria-busy");
      }
    }
  });
}
