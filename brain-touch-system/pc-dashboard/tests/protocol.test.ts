import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import Ajv2020Import from "ajv/dist/2020.js";

const Ajv2020 = Ajv2020Import as unknown as new (options?: object) => {
  compile(schema: object): (data: unknown) => boolean;
};
const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, "../..");
const schema = JSON.parse(
  fs.readFileSync(path.join(projectRoot, "shared/touch-event.schema.json"), "utf8")
) as object;
const validate = new Ajv2020({ strict: false, allowUnionTypes: true }).compile(schema);

test("all shared sample events satisfy the protocol schema", () => {
  const sampleDir = path.join(projectRoot, "shared/sample-events");
  const files = fs.readdirSync(sampleDir).filter((file) => file.endsWith(".json"));
  assert.ok(files.length >= 3);
  for (const file of files) {
    const event = JSON.parse(fs.readFileSync(path.join(sampleDir, file), "utf8")) as unknown;
    assert.equal(validate(event), true, file);
  }
});

test("invalid event types are rejected", () => {
  assert.equal(validate({
    version: "0.1.0",
    source: "iphone-12-pro",
    timestamp: "not-a-number"
  }), false);
});
