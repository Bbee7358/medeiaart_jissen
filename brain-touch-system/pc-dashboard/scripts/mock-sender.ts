import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import WebSocket from "ws";

const WS_URL = "ws://127.0.0.1:8787";
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const samplesDir = path.resolve(__dirname, "../../shared/sample-events");

const sampleFiles = fs
  .readdirSync(samplesDir)
  .filter((file) => file.endsWith(".json"))
  .sort()
  .map((file) => path.join(samplesDir, file));

if (sampleFiles.length === 0) {
  console.error(`[mock] no sample JSON files found in ${samplesDir}`);
  process.exit(1);
}

const samples = sampleFiles.map((file) => JSON.parse(fs.readFileSync(file, "utf8")));
const socket = new WebSocket(WS_URL);
let index = 0;

socket.on("open", () => {
  console.log(`[mock] connected to ${WS_URL}`);

  setInterval(() => {
    const sample = samples[index % samples.length];
    const event = {
      ...sample,
      timestamp: Date.now(),
      durationSec: sample.isTouching ? Number((0.2 + (index % 8) * 0.13).toFixed(2)) : 0
    };

    socket.send(JSON.stringify(event));
    console.log(`[mock] sent ${event.isTouching ? event.regionLabel : "no touch"}`);
    index += 1;
  }, 1000);
});

socket.on("error", (error) => {
  console.error(`[mock] websocket error: ${error.message}`);
  process.exitCode = 1;
});

socket.on("close", () => {
  console.log("[mock] disconnected");
});

