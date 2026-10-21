// Hold the package to twig's one version: `[workspace.package] version` in the
// root Cargo.toml, which every crate inherits and every release tags.
//
//   node bindings/typescript/scripts/version-sync.mjs          write it into
//       package.json and package-lock.json (ship's `post_bump`)
//   node bindings/typescript/scripts/version-sync.mjs --check  fail on any
//       that disagrees (the `version` CI job)
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pkgDir = dirname(dirname(fileURLToPath(import.meta.url)));
const cargo = readFileSync(join(pkgDir, "..", "..", "Cargo.toml"), "utf8");
const section = cargo.slice(cargo.indexOf("[workspace.package]"));
const version = /^version = "([^"]+)"$/m.exec(section)?.[1];
if (!version) throw new Error("version-sync: no [workspace.package] version in Cargo.toml");

const check = process.argv.includes("--check");
let stale = 0;

/** Set each of `paths` (key paths into the JSON at `file`) to the version. */
function sync(file, paths) {
  const path = join(pkgDir, file);
  const json = JSON.parse(readFileSync(path, "utf8"));
  for (const keys of paths) {
    let at = json;
    for (const key of keys.slice(0, -1)) at = at?.[key];
    const last = keys.at(-1);
    if (at?.[last] === version) continue;
    if (check) {
      console.error(`version-sync: ${file} ${keys.join(".")} is ${at?.[last]}, Cargo.toml says ${version}`);
      stale++;
    } else {
      at[last] = version;
    }
  }
  if (!check) writeFileSync(path, JSON.stringify(json, null, 2) + "\n");
}

sync("package.json", [["version"]]);
sync("package-lock.json", [["version"], ["packages", "", "version"]]);

if (stale > 0) process.exit(1);
console.error(check ? `version-sync: every file says ${version}` : `version-sync: wrote ${version}`);
