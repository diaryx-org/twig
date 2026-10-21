// Vendor twig's license text and the TypeScript guide into the npm package so
// the published tarball is self-contained.
//
// These files live once outside the package dir (docs/LICENSE-MIT,
// docs/LICENSE-APACHE and the guide at docs/typescript.md). An npm package can
// only ship files inside its own dir, and a symlink would resolve to nothing
// once installed from the registry — so before packing, real content is
// copied in. The README is the guide with its prov frontmatter stripped, so
// the npm page opens on prose. The copies are git-ignored; package.json's
// `files` allowlist adds them to the tarball. Runs from `prepack`, covering
// `npm pack` and `npm publish`.
import { copyFileSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pkgDir = dirname(dirname(fileURLToPath(import.meta.url))); // bindings/typescript
const docs = join(pkgDir, "..", "..", "docs");

for (const name of ["LICENSE-MIT", "LICENSE-APACHE"]) copyFileSync(join(docs, name), join(pkgDir, name));

const guide = readFileSync(join(docs, "typescript.md"), "utf8");
writeFileSync(join(pkgDir, "README.md"), guide.replace(/^---\n[\s\S]*?\n---\n+/, ""));

console.error(`vendor-publish-files: wrote 3 files -> ${pkgDir}`);
