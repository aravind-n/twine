import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { readFile, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { basename, extname, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

export const repositoryRoot = fileURLToPath(new URL("../../", import.meta.url));
const docs = resolve(repositoryRoot, "docs");
const dmgPath = process.env.TWINE_TEST_DMG && resolve(repositoryRoot, process.env.TWINE_TEST_DMG);
const fixture = Buffer.from("Twine DMG browser download fixture\n");
export const dmgName = dmgPath ? basename(dmgPath) : "Twine-1.2.3-macos-universal.dmg";
const types = { ".html": "text/html", ".js": "text/javascript", ".css": "text/css", ".png": "image/png" };

export async function sha256(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

export async function serveSite() {
  const dmgSize = dmgPath ? (await stat(dmgPath)).size : fixture.length;
  const expectedHash = dmgPath ? await sha256(dmgPath) : createHash("sha256").update(fixture).digest("hex");
  const server = createServer(async (request, response) => {
    const pathname = new URL(request.url, "http://localhost").pathname;
    if (pathname === `/downloads/${dmgName}`) {
      response.writeHead(200, {
        "Content-Type": "application/x-apple-diskimage",
        "Content-Length": dmgSize,
        "Content-Disposition": `attachment; filename="${dmgName}"`,
      });
      if (dmgPath) createReadStream(dmgPath).pipe(response);
      else response.end(fixture);
      return;
    }

    const path = resolve(docs, `.${decodeURIComponent(pathname.endsWith("/") ? `${pathname}index.html` : pathname)}`);
    if (!path.startsWith(`${docs}${sep}`)) {
      response.writeHead(403).end();
      return;
    }
    try {
      const content = await readFile(path);
      response.writeHead(200, { "Content-Type": types[extname(path)] ?? "application/octet-stream" });
      response.end(content);
    } catch {
      response.writeHead(404).end();
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    expectedHash,
    close: () => new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve())),
  };
}
