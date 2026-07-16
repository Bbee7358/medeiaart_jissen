import WebSocket from "ws";

const SENSOR_URL = process.env.WS_URL ?? "ws://127.0.0.1:8787";
const PERFORMANCE_URL = process.env.PERFORMANCE_WS_URL ?? "ws://127.0.0.1:8788";
const requestedEffect = process.argv[2];
const HOLD_MS = Math.max(200, Number(process.argv[3] ?? 1_200));
const GAP_MS = 350;
const regions = [
  ["top_back_left", "上段・後左", "visual"],
  ["side_lower_middle_left", "側面下段・中央左", "auditory"],
  ["side_lower_front_left", "側面下段・前左", "gustatory"],
  ["top_middle_left", "上段・中央左", "hippocampus"],
  ["top_front_left", "上段・前左", "amygdala"]
] as const;
const demoRegions = requestedEffect
  ? regions.filter(([, , effect]) => effect === requestedEffect)
  : regions;

if (demoRegions.length === 0) {
  throw new Error(`Unknown effect: ${requestedEffect}`);
}

function wait(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function connect(role: "dashboard" | "iphone_sensor") {
  return new Promise<WebSocket>((resolve, reject) => {
    const socket = new WebSocket(SENSOR_URL);
    socket.once("open", () => {
      socket.send(JSON.stringify({ type: "hello", payload: { role } }));
      resolve(socket);
    });
    socket.once("error", reject);
  });
}

function connectPerformanceOutput() {
  return new Promise<WebSocket>((resolve, reject) => {
    const socket = new WebSocket(PERFORMANCE_URL);
    socket.once("open", () => resolve(socket));
    socket.once("error", reject);
  });
}

function event(region: string, regionLabel: string, isTouching: boolean) {
  return {
    type: "touch_event",
    payload: {
      version: "0.1.0",
      source: "performance-demo",
      timestamp: Date.now(),
      handDetected: true,
      isTouching,
      region,
      regionLabel,
      surface: "top",
      surfaceLabel: "上面",
      contactType: "index_fingertip",
      distanceCm: isTouching ? 1.5 : 8,
      durationSec: isTouching ? 0.6 : 0,
      confidence: isTouching ? 0.95 : 0,
      debug: {
        indexTip2D: { x: 0.5, y: 0.5 },
        indexTip3D: { x: 0, y: -0.5, z: 0 },
        depthMeters: 0.5,
        fps: 30
      }
    }
  };
}

const performance = await connectPerformanceOutput();
const observedEffects = new Set<string>();
performance.on("message", (data) => {
  try {
    const message = JSON.parse(data.toString()) as { type?: string; phase?: string; effectKey?: string };
    if (message.type === "brain_touch_state" && message.phase === "start" && message.effectKey) {
      observedEffects.add(message.effectKey);
    }
  } catch {
    // The demo only asserts known JSON state messages.
  }
});

const dashboard = await connect("dashboard");
dashboard.send(JSON.stringify({
  type: "performance_output_settings",
  payload: { enabled: true, confirmedOnly: true, confidenceThreshold: 0.75 }
}));
const sensor = await connect("iphone_sensor");

console.log("MediaArtG1 performance demo started");
for (const [region, label, effect] of demoRegions) {
  console.log(`${effect}: ${label}`);
  sensor.send(JSON.stringify(event(region, label, true)));
  await wait(HOLD_MS);
  sensor.send(JSON.stringify(event(region, label, false)));
  await wait(GAP_MS);
}

sensor.close();
dashboard.close();
await wait(100);
performance.close();

const missingEffects = demoRegions
  .map(([, , effect]) => effect)
  .filter((effect) => !observedEffects.has(effect));
if (missingEffects.length > 0) {
  throw new Error(`Performance relay did not emit: ${missingEffects.join(", ")}`);
}
console.log(`MediaArtG1 performance demo complete: ${[...observedEffects].join(", ")}`);
