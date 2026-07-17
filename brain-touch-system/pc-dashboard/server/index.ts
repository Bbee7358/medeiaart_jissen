import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import Ajv2020Import, { type ErrorObject } from "ajv/dist/2020.js";
import { WebSocketServer, WebSocket } from "ws";

const PORT = 8787;
const PERFORMANCE_PORT = 8788;
const MAX_MESSAGE_BYTES = 256 * 1024;
const HEARTBEAT_INTERVAL_MS = 15_000;
const DIAGNOSTICS_INTERVAL_MS = 1_000;
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dashboardRoot = path.resolve(__dirname, "..");
const projectRoot = path.resolve(dashboardRoot, "..");
const logsDir = process.env.BRAIN_TOUCH_LOGS_DIR
  ? path.resolve(process.env.BRAIN_TOUCH_LOGS_DIR)
  : path.join(dashboardRoot, "logs");
const schemaPath = process.env.BRAIN_TOUCH_SCHEMA_PATH
  ? path.resolve(process.env.BRAIN_TOUCH_SCHEMA_PATH)
  : path.join(projectRoot, "shared/touch-event.schema.json");

type ClientRole = "unknown" | "iphone_sensor" | "dashboard";
type ClientState = {
  role: ClientRole;
  remote: string;
  alive: boolean;
  connectedAt: number;
};
type TouchEventMessage = {
  timestamp: number;
  isTouching: boolean;
  confidence: number;
  region?: unknown;
  regionLabel?: unknown;
  surface?: unknown;
  surfaceLabel?: unknown;
  durationSec?: unknown;
  [key: string]: unknown;
};
type SettingsUpdatePayload = {
  touchThresholdCm: number;
  strongTouchThresholdCm: number;
  dwellTimeSec: number;
  confidenceThreshold: number;
  smoothingFrames: number;
};
type PerformanceOutputSettings = {
  enabled: boolean;
  confirmedOnly: boolean;
  confidenceThreshold: number;
};
type DailyStats = {
  date: string;
  receivedCount: number;
  confirmedTouchCount: number;
};

const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8")) as object;
const Ajv2020 = Ajv2020Import as unknown as new (options?: object) => {
  compile<T>(schema: object): {
    (data: unknown): data is T;
    errors?: ErrorObject[] | null;
  };
};
const ajv = new Ajv2020({ allErrors: true, strict: false, allowUnionTypes: true });
const validateTouchEvent = ajv.compile<TouchEventMessage>(schema);
const httpServer = http.createServer(handleHttpRequest);
const performanceHttpServer = http.createServer(handlePerformanceHttpRequest);
const server = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });
const performanceServer = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });
const clients = new Map<WebSocket, ClientState>();
const performanceClients = new Map<WebSocket, { alive: boolean }>();

let stats: DailyStats = {
  date: formatLocalDate(new Date()),
  receivedCount: 0,
  confirmedTouchCount: 0
};
let latestSettings: SettingsUpdatePayload = {
  touchThresholdCm: 5,
  strongTouchThresholdCm: 3,
  dwellTimeSec: 0.5,
  confidenceThreshold: 0.55,
  smoothingFrames: 5
};
let performanceOutputSettings: PerformanceOutputSettings = {
  enabled: false,
  confirmedOnly: true,
  confidenceThreshold: 0.75
};
let logStream: fs.WriteStream | null = null;
let logStreamDate: string | null = null;
let lastEventAt: number | null = null;
let lastEventRemote: string | null = null;
let lastHttpRequestAt: number | null = null;
let lastHttpRequestRemote: string | null = null;
let lastSettingsAt: number | null = null;
let lastSettingsRemote: string | null = null;
let lastPerformanceEventAt: number | null = null;
let lastPerformanceEventRegion: string | null = null;
let lastWarning: string | null = null;
let shuttingDown = false;

fs.mkdirSync(logsDir, { recursive: true });
loadTodayStats();

function formatLocalDate(date: Date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

function getLogPath(date = stats.date) {
  return path.join(logsDir, `touch-events-${date}.jsonl`);
}

function getLocalIPv4Addresses() {
  return [...new Set(
    Object.values(os.networkInterfaces())
      .flatMap((networkInterface) => networkInterface ?? [])
      .filter((address) => address.family === "IPv4" && !address.internal)
      .map((address) => address.address)
  )];
}

function getBonjourHostnames() {
  try {
    const localHostName = execFileSync("scutil", ["--get", "LocalHostName"], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    }).trim();
    return localHostName ? [`${localHostName}.local`] : [];
  } catch {
    return [];
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function isTypedMessage(value: unknown): value is { type: string; payload?: unknown } {
  return isRecord(value) && typeof value.type === "string";
}

function sendJson(socket: WebSocket, message: unknown) {
  if (socket.readyState !== WebSocket.OPEN) return;
  try {
    socket.send(JSON.stringify(message));
  } catch (error) {
    console.warn("[ws] send failed", error);
    socket.terminate();
  }
}

function sendToRole(role: ClientRole, message: unknown, except?: WebSocket) {
  for (const [socket, state] of clients) {
    if (socket !== except && state.role === role) sendJson(socket, message);
  }
}

function sendToDashboards(message: unknown) {
  sendToRole("dashboard", message);
}

function clientCounts() {
  let sensors = 0;
  let dashboards = 0;
  let unknown = 0;
  for (const state of clients.values()) {
    if (state.role === "iphone_sensor") sensors += 1;
    else if (state.role === "dashboard") dashboards += 1;
    else unknown += 1;
  }
  return { total: clients.size, sensors, dashboards, unknown };
}

function diagnosticsPayload() {
  const localAddresses = getLocalIPv4Addresses();
  const bonjourHostnames = getBonjourHostnames();
  const endpoints = [...bonjourHostnames, ...localAddresses];
  return {
    clientCount: clients.size,
    clientRoles: clientCounts(),
    localAddresses,
    bonjourHostnames,
    healthUrls: endpoints.map((host) => `http://${host}:${PORT}/health`),
    websocketUrls: endpoints.map((host) => `ws://${host}:${PORT}`),
    lastEventAt,
    lastEventRemote,
    lastHttpRequestAt,
    lastHttpRequestRemote,
    lastSettingsAt,
    lastSettingsRemote,
    performanceClientCount: performanceClients.size,
    performanceWebSocketUrls: endpoints.map((host) => `ws://${host}:${PERFORMANCE_PORT}`),
    performanceOutputEnabled: performanceOutputSettings.enabled,
    lastPerformanceEventAt,
    lastPerformanceEventRegion,
    lastWarning
  };
}

function broadcastDiagnostics() {
  sendToDashboards({ type: "serverDiagnostics", payload: diagnosticsPayload() });
}

function warn(message: string) {
  lastWarning = message;
  console.warn(message);
  broadcastDiagnostics();
}

function isConfirmedTouch(event: TouchEventMessage) {
  return event.isTouching && event.confidence >= 0.75;
}

function resetStatsIfDateChanged() {
  const today = formatLocalDate(new Date());
  if (stats.date === today) return;
  logStream?.end();
  logStream = null;
  logStreamDate = null;
  stats = { date: today, receivedCount: 0, confirmedTouchCount: 0 };
  loadTodayStats();
}

function loadTodayStats() {
  const logPath = getLogPath();
  if (!fs.existsSync(logPath)) return;
  for (const line of fs.readFileSync(logPath, "utf8").split("\n")) {
    if (!line) continue;
    try {
      const event = JSON.parse(line) as TouchEventMessage;
      stats.receivedCount += 1;
      if (isConfirmedTouch(event)) stats.confirmedTouchCount += 1;
    } catch {
      console.warn(`[log] malformed historical line in ${logPath}`);
    }
  }
}

function currentLogStream() {
  if (logStream && logStreamDate === stats.date) return logStream;
  logStream?.end();
  logStreamDate = stats.date;
  logStream = fs.createWriteStream(getLogPath(), { flags: "a", encoding: "utf8" });
  logStream.on("error", (error) => fatal("[log] write stream failed", error));
  return logStream;
}

function appendEvent(event: TouchEventMessage) {
  resetStatsIfDateChanged();
  const stream = currentLogStream();
  if (!stream.write(`${JSON.stringify(event)}\n`)) {
    for (const [socket, state] of clients) {
      if (state.role === "iphone_sensor") socket.pause();
    }
    stream.once("drain", () => {
      for (const [socket, state] of clients) {
        if (state.role === "iphone_sensor") socket.resume();
      }
    });
  }
  stats.receivedCount += 1;
  if (isConfirmedTouch(event)) stats.confirmedTouchCount += 1;
}

function formatAjvErrors(errors: ErrorObject[] | null | undefined) {
  return (errors ?? [])
    .slice(0, 6)
    .map((error) => `${error.instancePath || "/"} ${error.message ?? "invalid"}`)
    .join("; ");
}

function validateSettingsPayload(payload: unknown): SettingsUpdatePayload | null {
  if (!isRecord(payload)) return null;
  const settings = {
    touchThresholdCm: Number(payload.touchThresholdCm),
    strongTouchThresholdCm: Number(payload.strongTouchThresholdCm),
    dwellTimeSec: Number(payload.dwellTimeSec),
    confidenceThreshold: Number(payload.confidenceThreshold),
    smoothingFrames: Math.round(Number(payload.smoothingFrames))
  };
  if (Object.values(settings).some((value) => !Number.isFinite(value))) return null;
  if (
    settings.touchThresholdCm < 0.5 || settings.touchThresholdCm > 8 ||
    settings.strongTouchThresholdCm < 0.5 ||
    settings.strongTouchThresholdCm > settings.touchThresholdCm ||
    settings.dwellTimeSec < 0 || settings.dwellTimeSec > 3 ||
    settings.confidenceThreshold < 0 || settings.confidenceThreshold > 1 ||
    settings.smoothingFrames < 1 || settings.smoothingFrames > 30
  ) return null;
  return settings;
}

function validatePerformanceSettings(payload: unknown): PerformanceOutputSettings | null {
  if (!isRecord(payload)) return null;
  const confidenceThreshold = Number(payload.confidenceThreshold);
  if (!Number.isFinite(confidenceThreshold) || confidenceThreshold < 0 || confidenceThreshold > 1) return null;
  return {
    enabled: payload.enabled === true,
    confirmedOnly: payload.confirmedOnly !== false,
    confidenceThreshold
  };
}

function maybeBroadcastPerformanceEvent(event: TouchEventMessage) {
  if (!performanceOutputSettings.enabled) return;
  if (
    performanceOutputSettings.confirmedOnly &&
    (!event.isTouching || event.confidence < performanceOutputSettings.confidenceThreshold)
  ) return;
  const message = {
    type: "brain_touch",
    region: event.region,
    regionLabel: event.regionLabel,
    surface: event.surface,
    surfaceLabel: event.surfaceLabel,
    confidence: event.confidence,
    durationSec: event.durationSec,
    timestamp: event.timestamp
  };
  for (const socket of performanceClients.keys()) sendJson(socket, message);
  lastPerformanceEventAt = Date.now();
  lastPerformanceEventRegion = typeof event.region === "string" ? event.region : null;
}

function registerRole(socket: WebSocket, role: ClientRole) {
  const state = clients.get(socket);
  if (!state) return;
  state.role = role;
  sendJson(socket, { type: "hello_ack", payload: { role, serverTime: Date.now() } });
  if (role === "dashboard") {
    sendJson(socket, { type: "dailyStats", payload: stats });
    sendJson(socket, { type: "serverDiagnostics", payload: diagnosticsPayload() });
  } else if (role === "iphone_sensor") {
    sendJson(socket, { type: "settings_update", payload: latestSettings });
  }
  broadcastDiagnostics();
}

function handleMessage(socket: WebSocket, raw: Buffer, remote: string) {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw.toString("utf8")) as unknown;
  } catch {
    warn(`[ws] invalid JSON from ${remote}`);
    return;
  }
  const state = clients.get(socket);
  if (!state) return;

  if (isTypedMessage(parsed)) {
    if (parsed.type === "hello") {
      const requested = isRecord(parsed.payload) ? parsed.payload.role : undefined;
      if (requested === "iphone_sensor" || requested === "dashboard") {
        registerRole(socket, requested);
      } else {
        warn(`[ws] invalid role from ${remote}`);
      }
      return;
    }
    if (parsed.type === "ping") {
      sendJson(socket, { type: "pong", timestamp: Date.now() });
      return;
    }
    if (parsed.type === "pong") {
      state.alive = true;
      return;
    }
    if (parsed.type === "settings_update") {
      if (state.role !== "dashboard") {
        warn(`[ws] settings_update rejected from non-dashboard ${remote}`);
        return;
      }
      const settings = validateSettingsPayload(parsed.payload);
      if (!settings) {
        warn(`[ws] invalid settings_update from ${remote}`);
        return;
      }
      latestSettings = settings;
      lastSettingsAt = Date.now();
      lastSettingsRemote = remote;
      lastWarning = null;
      const recipientCount = clientCounts().sensors;
      sendToRole("iphone_sensor", { type: "settings_update", payload: settings });
      sendJson(socket, {
        type: "settings_forwarded",
        payload: { timestamp: Date.now(), recipientCount }
      });
      broadcastDiagnostics();
      return;
    }
    if (parsed.type === "settings_applied") {
      if (state.role === "iphone_sensor") {
        sendToDashboards({ type: "settings_applied", payload: parsed.payload });
      }
      return;
    }
    if (parsed.type === "performance_output_settings") {
      if (state.role !== "dashboard") return;
      const settings = validatePerformanceSettings(parsed.payload);
      if (!settings) {
        warn(`[ws] invalid performance settings from ${remote}`);
        return;
      }
      performanceOutputSettings = settings;
      broadcastDiagnostics();
      return;
    }
    if (parsed.type === "touch_event") parsed = parsed.payload;
    else if (parsed.type === "serverDiagnostics" || parsed.type === "dailyStats") return;
    else {
      warn(`[ws] unknown message type from ${remote}: ${parsed.type}`);
      return;
    }
  }

  // Legacy iPhone builds send a bare event before the role handshake.
  if (state.role === "unknown") state.role = "iphone_sensor";
  if (state.role !== "iphone_sensor") {
    warn(`[ws] touch event rejected from non-sensor ${remote}`);
    return;
  }
  if (!validateTouchEvent(parsed)) {
    warn(`[ws] schema validation failed from ${remote}: ${formatAjvErrors(validateTouchEvent.errors)}`);
    return;
  }

  const event = parsed as TouchEventMessage;
  appendEvent(event);
  lastEventAt = Date.now();
  lastEventRemote = remote;
  lastWarning = null;
  maybeBroadcastPerformanceEvent(event);
  sendToDashboards({ type: "touch_event", payload: event });
  sendToDashboards({ type: "dailyStats", payload: stats });
}

function buildHealthPayload() {
  return {
    ok: true,
    service: "brain-touch-websocket",
    port: PORT,
    now: new Date().toISOString(),
    stats,
    diagnostics: diagnosticsPayload(),
    latestSettings,
    performanceOutputSettings,
    memory: process.memoryUsage()
  };
}

function handleHttpRequest(request: http.IncomingMessage, response: http.ServerResponse) {
  lastHttpRequestAt = Date.now();
  lastHttpRequestRemote = `${request.socket.remoteAddress ?? "unknown"}:${request.socket.remotePort ?? "unknown"}`;
  if (request.url === "/health" || request.url === "/health/") {
    response.writeHead(200, {
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8"
    });
    response.end(JSON.stringify(buildHealthPayload()));
    return;
  }
  const diagnostics = diagnosticsPayload();
  response.writeHead(200, {
    "Access-Control-Allow-Origin": "*",
    "Cache-Control": "no-store",
    "Content-Type": "text/plain; charset=utf-8"
  });
  response.end([
    "Brain Touch WebSocket server is running.",
    "",
    ...diagnostics.healthUrls.map((url) => `Health: ${url}`),
    ...diagnostics.websocketUrls.map((url) => `WebSocket: ${url}`)
  ].join("\n"));
}

function handlePerformanceHttpRequest(_request: http.IncomingMessage, response: http.ServerResponse) {
  response.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
  response.end(`Brain Touch performance relay: ws://<mac-host>:${PERFORMANCE_PORT}\n`);
}

server.on("connection", (socket, request) => {
  const remote = `${request.socket.remoteAddress ?? "unknown"}:${request.socket.remotePort ?? "unknown"}`;
  clients.set(socket, { role: "unknown", remote, alive: true, connectedAt: Date.now() });
  sendJson(socket, { type: "hello_required", payload: { roles: ["iphone_sensor", "dashboard"] } });
  socket.on("pong", () => {
    const state = clients.get(socket);
    if (state) state.alive = true;
  });
  socket.on("message", (data, isBinary) => {
    if (isBinary) {
      warn(`[ws] binary message rejected from ${remote}`);
      return;
    }
    const raw = Buffer.isBuffer(data)
      ? data
      : Array.isArray(data)
        ? Buffer.concat(data)
        : Buffer.from(data as ArrayBuffer);
    handleMessage(socket, raw, remote);
  });
  socket.on("close", () => {
    clients.delete(socket);
    broadcastDiagnostics();
  });
  socket.on("error", (error) => console.warn(`[ws] ${remote}`, error.message));
  broadcastDiagnostics();
});

performanceServer.on("connection", (socket) => {
  performanceClients.set(socket, { alive: true });
  socket.on("pong", () => {
    const state = performanceClients.get(socket);
    if (state) state.alive = true;
  });
  socket.on("close", () => performanceClients.delete(socket));
  socket.on("error", (error) => console.warn("[performance-ws]", error.message));
  sendJson(socket, { type: "performance_status", payload: performanceOutputSettings });
});

httpServer.on("upgrade", (request, socket, head) => {
  server.handleUpgrade(request, socket, head, (webSocket) => {
    server.emit("connection", webSocket, request);
  });
});
performanceHttpServer.on("upgrade", (request, socket, head) => {
  performanceServer.handleUpgrade(request, socket, head, (webSocket) => {
    performanceServer.emit("connection", webSocket, request);
  });
});

const heartbeat = setInterval(() => {
  for (const [socket, state] of clients) {
    if (!state.alive) {
      socket.terminate();
      clients.delete(socket);
      continue;
    }
    state.alive = false;
    socket.ping();
  }
  for (const [socket, state] of performanceClients) {
    if (!state.alive) {
      socket.terminate();
      performanceClients.delete(socket);
      continue;
    }
    state.alive = false;
    socket.ping();
  }
}, HEARTBEAT_INTERVAL_MS);
heartbeat.unref();

const diagnosticsTimer = setInterval(broadcastDiagnostics, DIAGNOSTICS_INTERVAL_MS);
diagnosticsTimer.unref();

function shutdown(exitCode = 0) {
  if (shuttingDown) return;
  shuttingDown = true;
  clearInterval(heartbeat);
  clearInterval(diagnosticsTimer);
  for (const socket of clients.keys()) socket.close(1001, "server shutdown");
  for (const socket of performanceClients.keys()) socket.close(1001, "server shutdown");
  server.close();
  performanceServer.close();
  logStream?.end();
  let pending = 2;
  const done = () => {
    pending -= 1;
    if (pending === 0) process.exit(exitCode);
  };
  httpServer.close(done);
  performanceHttpServer.close(done);
  setTimeout(() => process.exit(exitCode), 2_000).unref();
}

function fatal(message: string, error: unknown) {
  console.error(message, error);
  shutdown(1);
}

process.once("SIGINT", () => shutdown(0));
process.once("SIGTERM", () => shutdown(0));
process.once("uncaughtException", (error) => fatal("[process] uncaught exception", error));
process.once("unhandledRejection", (reason) => fatal("[process] unhandled rejection", reason));

httpServer.listen(PORT, "0.0.0.0", () => {
  console.log(`Brain Touch WebSocket server listening on 0.0.0.0:${PORT}`);
});
performanceHttpServer.listen(PERFORMANCE_PORT, "0.0.0.0", () => {
  console.log(`Performance relay listening on 0.0.0.0:${PERFORMANCE_PORT}`);
});
