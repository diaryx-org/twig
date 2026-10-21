// Its own file, so its own process: the module must not be loaded before
// the test starts.
import { test } from "node:test";
import assert from "node:assert/strict";
import { Document, init, isReady } from "@diaryx/twig";

test("a synchronous call while init() is pending keeps one instance", async () => {
  assert.equal(isReady(), false);
  const pending = init();
  using doc = Document.parse("# Heading\n", "md");
  assert.equal(doc.query("heading").length, 1);
  await pending;
  // The handle still belongs to the live instance's memory.
  assert.equal(doc.query("heading").length, 1);
  using again = Document.parse("# Again\n", "md");
  assert.equal(again.query("heading").length, 1);
});
