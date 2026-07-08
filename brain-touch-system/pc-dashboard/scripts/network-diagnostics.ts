import os from "node:os";
import { execFileSync } from "node:child_process";

const PORT = 8787;

type Candidate = {
  name: string;
  address: string;
  likelyUse: string;
};

function getCandidates(): Candidate[] {
  return Object.entries(os.networkInterfaces()).flatMap(([name, addresses]) => {
    return (addresses ?? [])
      .filter((address) => address.family === "IPv4" && !address.internal)
      .map((address) => ({
        name,
        address: address.address,
        likelyUse: describeAddress(name, address.address)
      }));
  });
}

function describeAddress(name: string, address: string) {
  if (address.startsWith("172.20.10.")) {
    return "iPhone Personal Hotspot candidate";
  }

  if (address.startsWith("169.254.")) {
    return "link-local/USB candidate; try only if Wi-Fi candidates fail";
  }

  if (name === "en0") {
    return "Wi-Fi candidate";
  }

  return "network candidate";
}

const candidates = getCandidates();

console.log("Brain Touch network diagnostics");
console.log("");

try {
  const localHostName = execFileSync("scutil", ["--get", "LocalHostName"], { encoding: "utf8" }).trim();
  if (localHostName) {
    console.log(`Bonjour candidate: ${localHostName}.local`);
    console.log(`  Safari health check: http://${localHostName}.local:${PORT}/health`);
    console.log(`  iPhone WebSocket URL: ws://${localHostName}.local:${PORT}`);
    console.log("");
  }
} catch {
  // scutil may be unavailable in restricted shells; IP candidates are still useful.
}

if (candidates.length === 0) {
  console.log("No non-internal IPv4 addresses were found.");
  process.exit(0);
}

for (const candidate of candidates) {
  console.log(`${candidate.name}: ${candidate.address}`);
  console.log(`  use: ${candidate.likelyUse}`);
  console.log(`  Safari health check: http://${candidate.address}:${PORT}/health`);
  console.log(`  iPhone WebSocket URL: ws://${candidate.address}:${PORT}`);
  console.log("");
}

console.log("If Safari on iPhone cannot open any health check URL, the network is blocking device-to-device traffic.");
console.log("Recommended fallback: connect the Mac to the iPhone Personal Hotspot, then rerun this script and use the 172.20.10.x URL.");
