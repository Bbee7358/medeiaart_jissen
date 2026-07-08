import fs from "node:fs";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer, type WebSocket } from "ws";

const PORT = 8787;
const PERFORMANCE_PORT = 8788;
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dashboardRoot = path.resolve(__dirname, "..");
const projectRoot = path.resolve(dashboardRoot, "..");
const logsDir = path.join(dashboardRoot, "logs");
const schemaPath = path.join(projectRoot, "shared/touch-event.schema.json");
const httpServer = http.createServer(handleHttpRequest);
const performanceHttpServer = http.createServer(handlePerformanceHttpRequest);
const server = new WebSocketServer({ noServer: true });
const performanceServer = new WebSocketServer({ noServer: true });
const clients = new Set<WebSocket>();
const performanceClients = new Set<WebSocket>();
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8")) as { required?: string[] };
const requiredFields = schema.required ?? [];

process.on("uncaughtException", (error) => {
  console.error("[process] uncaught exception", error);
});

process.on("unhandledRejection", (reason) => {
  console.error("[process] unhandled rejection", reason);
});

type TouchEventMessage = {
  timestamp: number;
  isTouching: boolean;
  confidence: number;
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

type PerformanceEventMessage = {
  type: "brain_touch";
  region: unknown;
  regionLabel: unknown;
  surface: unknown;
  surfaceLabel: unknown;
  confidence: number;
  durationSec: unknown;
  timestamp: number;
};

type DailyStats = {
  date: string;
  receivedCount: number;
  confirmedTouchCount: number;
};

type ServerDiagnostics = {
  clientCount: number;
  localAddresses: string[];
  healthUrls: string[];
  websocketUrls: string[];
  lastEventAt: number | null;
  lastEventRemote: string | null;
  lastHttpRequestAt: number | null;
  lastHttpRequestRemote: string | null;
  lastSettingsAt: number | null;
  lastSettingsRemote: string | null;
  performanceClientCount: number;
  performanceWebSocketUrls: string[];
  performanceOutputEnabled: boolean;
  lastPerformanceEventAt: number | null;
  lastPerformanceEventRegion: string | null;
  lastWarning: string | null;
};

let stats: DailyStats = {
  date: formatLocalDate(new Date()),
  receivedCount: 0,
  confirmedTouchCount: 0
};

let diagnostics: ServerDiagnostics = {
  clientCount: 0,
  localAddresses: getLocalIPv4Addresses(),
  healthUrls: getLocalIPv4Addresses().map((address) => `http://${address}:${PORT}/health`),
  websocketUrls: getLocalIPv4Addresses().map((address) => `ws://${address}:${PORT}`),
  lastEventAt: null,
  lastEventRemote: null,
  lastHttpRequestAt: null,
  lastHttpRequestRemote: null,
  lastSettingsAt: null,
  lastSettingsRemote: null,
  performanceClientCount: 0,
  performanceWebSocketUrls: getLocalIPv4Addresses().map((address) => `ws://${address}:${PERFORMANCE_PORT}`),
  performanceOutputEnabled: false,
  lastPerformanceEventAt: null,
  lastPerformanceEventRegion: null,
  lastWarning: null
};

let latestSettings: SettingsUpdatePayload | null = null;
let performanceOutputSettings: PerformanceOutputSettings = {
  enabled: false,
  confirmedOnly: true,
  confidenceThreshold: 0.75
};

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
  return Object.values(os.networkInterfaces())
    .flatMap((networkInterface) => networkInterface ?? [])
    .filter((address) => address.family === "IPv4" && !address.internal)
    .map((address) => address.address);
}

function refreshNetworkDiagnostics() {
  const localAddresses = getLocalIPv4Addresses();
  diagnostics.localAddresses = localAddresses;
  diagnostics.healthUrls = localAddresses.map((address) => `http://${address}:${PORT}/health`);
  diagnostics.websocketUrls = localAddresses.map((address) => `ws://${address}:${PORT}`);
  diagnostics.performanceWebSocketUrls = localAddresses.map((address) => `ws://${address}:${PERFORMANCE_PORT}`);
  diagnostics.performanceOutputEnabled = performanceOutputSettings.enabled;
}

function resetStatsIfDateChanged() {
  const today = formatLocalDate(new Date());
  if (stats.date === today) return;

  stats = {
    date: today,
    receivedCount: 0,
    confirmedTouchCount: 0
  };
  loadTodayStats();
}

function isConfirmedTouch(event: TouchEventMessage) {
  return event.isTouching === true && typeof event.confidence === "number" && event.confidence >= 0.75;
}

function loadTodayStats() {
  const logPath = getLogPath(stats.date);
  if (!fs.existsSync(logPath)) return;

  const lines = fs.readFileSync(logPath, "utf8").split("\n").filter(Boolean);
  stats.receivedCount = 0;
  stats.confirmedTouchCount = 0;

  for (const line of lines) {
    try {
      const event = JSON.parse(line) as TouchEventMessage;
      stats.receivedCount += 1;
      if (isConfirmedTouch(event)) {
        stats.confirmedTouchCount += 1;
      }
    } catch {
      console.warn(`[log] ignored malformed line while loading ${logPath}`);
    }
  }
}

function broadcast(message: string, sender: WebSocket) {
  for (const client of clients) {
    if (client === sender) continue;
    if (client.readyState === client.OPEN) {
      client.send(message);
    }
  }
}

function sendJson(socket: WebSocket, message: unknown) {
  if (socket.readyState === socket.OPEN) {
    socket.send(JSON.stringify(message));
  }
}

function sendPerformanceJson(message: unknown) {
  const json = JSON.stringify(message);
  for (const client of performanceClients) {
    if (client.readyState === client.OPEN) {
      client.send(json);
    }
  }
}

function broadcastStats() {
  const message = JSON.stringify({
    type: "dailyStats",
    payload: stats
  });

  for (const client of clients) {
    if (client.readyState === client.OPEN) {
      client.send(message);
    }
  }
}

function broadcastDiagnostics() {
  refreshNetworkDiagnostics();
  diagnostics.clientCount = clients.size;
  diagnostics.performanceClientCount = performanceClients.size;
  const message = JSON.stringify({
    type: "serverDiagnostics",
    payload: diagnostics
  });

  for (const client of clients) {
    if (client.readyState === client.OPEN) {
      client.send(message);
    }
  }
}

function warnAndBroadcast(message: string) {
  diagnostics.lastWarning = message;
  console.warn(message);
  broadcastDiagnostics();
}

function validateRequiredFields(event: unknown) {
  if (!event || typeof event !== "object" || Array.isArray(event)) {
    return ["<root must be object>"];
  }

  const record = event as Record<string, unknown>;
  return requiredFields.filter((field) => !(field in record));
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

function isTypedMessage(value: unknown): value is { type: string; payload?: unknown } {
  return isRecord(value) && typeof value.type === "string";
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

  const values = Object.values(settings);
  if (values.some((value) => !Number.isFinite(value))) {
    return null;
  }

  if (
    settings.touchThresholdCm < 0.5 ||
    settings.touchThresholdCm > 30 ||
    settings.strongTouchThresholdCm < 0.5 ||
    settings.strongTouchThresholdCm > 30 ||
    settings.dwellTimeSec < 0 ||
    settings.dwellTimeSec > 5 ||
    settings.confidenceThreshold < 0 ||
    settings.confidenceThreshold > 1 ||
    settings.smoothingFrames < 1 ||
    settings.smoothingFrames > 30
  ) {
    return null;
  }

  return settings;
}

function validatePerformanceOutputSettings(payload: unknown): PerformanceOutputSettings | null {
  if (!isRecord(payload)) return null;

  const settings = {
    enabled: Boolean(payload.enabled),
    confirmedOnly: payload.confirmedOnly === undefined ? true : Boolean(payload.confirmedOnly),
    confidenceThreshold: Number(payload.confidenceThreshold)
  };

  if (!Number.isFinite(settings.confidenceThreshold)) return null;
  if (settings.confidenceThreshold < 0 || settings.confidenceThreshold > 1) return null;

  return settings;
}

function shouldSendPerformanceEvent(event: TouchEventMessage) {
  if (!performanceOutputSettings.enabled) return false;
  if (!performanceOutputSettings.confirmedOnly) return true;
  return event.isTouching === true
    && typeof event.confidence === "number"
    && event.confidence >= performanceOutputSettings.confidenceThreshold;
}

function toPerformanceEvent(event: TouchEventMessage): PerformanceEventMessage {
  return {
    type: "brain_touch",
    region: event.region,
    regionLabel: event.regionLabel,
    surface: event.surface,
    surfaceLabel: event.surfaceLabel,
    confidence: event.confidence,
    durationSec: event.durationSec,
    timestamp: event.timestamp
  };
}

function maybeBroadcastPerformanceEvent(event: TouchEventMessage) {
  if (!shouldSendPerformanceEvent(event)) return;

  sendPerformanceJson(toPerformanceEvent(event));
  diagnostics.lastPerformanceEventAt = Date.now();
  diagnostics.lastPerformanceEventRegion = typeof event.region === "string" ? event.region : null;
}

function appendEvent(event: TouchEventMessage) {
  resetStatsIfDateChanged();

  fs.appendFileSync(getLogPath(), `${JSON.stringify(event)}\n`, "utf8");
  stats.receivedCount += 1;
  if (isConfirmedTouch(event)) {
    stats.confirmedTouchCount += 1;
  }
}

function buildHealthPayload() {
  refreshNetworkDiagnostics();

  return {
    ok: true,
    service: "brain-touch-websocket",
    port: PORT,
    now: new Date().toISOString(),
    stats,
    diagnostics: {
      ...diagnostics,
      clientCount: clients.size,
      performanceClientCount: performanceClients.size
    },
    latestSettings,
    performanceOutputSettings
  };
}

function handleHttpRequest(request: http.IncomingMessage, response: http.ServerResponse) {
  const remote = `${request.socket.remoteAddress ?? "unknown"}:${request.socket.remotePort ?? "unknown"}`;
  diagnostics.lastHttpRequestAt = Date.now();
  diagnostics.lastHttpRequestRemote = remote;
  console.log(`[http] ${remote} ${request.method ?? "UNKNOWN"} ${request.url ?? "/"}`);

  if (request.url === "/health" || request.url === "/health/") {
    const body = JSON.stringify(buildHealthPayload(), null, 2);
    response.writeHead(200, {
      "Access-Control-Allow-Origin": "*",
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8"
    });
    response.end(body);
    broadcastDiagnostics();
    return;
  }

  const healthUrls = buildHealthPayload().diagnostics.healthUrls;
  const websocketUrls = buildHealthPayload().diagnostics.websocketUrls;
  const body = [
    "Brain Touch WebSocket server is running.",
    "",
    "Health check URLs:",
    ...healthUrls.map((url) => `- ${url}`),
    "",
    "iPhone WebSocket URLs:",
    ...websocketUrls.map((url) => `- ${url}`)
  ].join("\n");

  response.writeHead(200, {
    "Access-Control-Allow-Origin": "*",
    "Cache-Control": "no-store",
    "Content-Type": "text/plain; charset=utf-8"
  });
  response.end(body);
  broadcastDiagnostics();
}

function handlePerformanceHttpRequest(request: http.IncomingMessage, response: http.ServerResponse) {
  const body = [
    "Brain Touch performance WebSocket relay is running.",
    "",
    `WebSocket port: ${PERFORMANCE_PORT}`,
    "Connect TouchDesigner / p5.js / Processing / Unity clients here.",
    "",
    ...getLocalIPv4Addresses().map((address) => `- ws://${address}:${PERFORMANCE_PORT}`)
  ].join("\n");

  response.writeHead(200, {
    "Access-Control-Allow-Origin": "*",
    "Cache-Control": "no-store",
    "Content-Type": "text/plain; charset=utf-8"
  });
  response.end(body);
}

server.on("connection", (socket, request) => {
  clients.add(socket);
  const remote = `${request.socket.remoteAddress ?? "unknown"}:${request.socket.remotePort ?? "unknown"}`;
  console.log(`[ws] connected ${remote}. clients=${clients.size}`);
  socket.send(JSON.stringify({ type: "dailyStats", payload: stats }));
  socket.send(JSON.stringify({ type: "serverDiagnostics", payload: { ...diagnostics, clientCount: clients.size } }));
  if (latestSettings) {
    sendJson(socket, { type: "settings_update", payload: latestSettings });
  }
  broadcastDiagnostics();

  socket.on("message", (data) => {
    const message = data.toString();
    console.log(`[ws] message from ${remote}: ${message.slice(0, 200)}`);
    let parsed: unknown;

    try {
      parsed = JSON.parse(message) as unknown;
    } catch {
      warnAndBroadcast(`[ws] ignored invalid JSON from ${remote}`);
      return;
    }

    if (isTypedMessage(parsed)) {
      if (parsed.type === "ping") {
        sendJson(socket, { type: "pong", timestamp: Date.now() });
        return;
      }

      if (parsed.type === "pong") {
        return;
      }

      if (parsed.type === "settings_update") {
        const settings = validateSettingsPayload(parsed.payload);
        if (!settings) {
          warnAndBroadcast(`[ws] ignored invalid settings_update from ${remote}`);
          return;
        }

        latestSettings = settings;
        diagnostics.lastSettingsAt = Date.now();
        diagnostics.lastSettingsRemote = remote;
        diagnostics.lastWarning = null;
        broadcast(JSON.stringify({ type: "settings_update", payload: settings }), socket);
        broadcastDiagnostics();
        return;
      }

      if (parsed.type === "performance_output_settings") {
        const settings = validatePerformanceOutputSettings(parsed.payload);
        if (!settings) {
          warnAndBroadcast(`[ws] ignored invalid performance_output_settings from ${remote}`);
          return;
        }

        performanceOutputSettings = settings;
        diagnostics.performanceOutputEnabled = settings.enabled;
        diagnostics.lastWarning = null;
        broadcastDiagnostics();
        return;
      }

      if (parsed.type === "touch_event") {
        parsed = parsed.payload;
      } else {
        warnAndBroadcast(`[ws] ignored unknown message type from ${remote}: ${parsed.type}`);
        return;
      }
    }

    const event = parsed as TouchEventMessage;

    const missingFields = validateRequiredFields(event);
    if (missingFields.length > 0) {
      warnAndBroadcast(`[ws] ignored event from ${remote}; missing required fields: ${missingFields.join(", ")}`);
      return;
    }

    appendEvent(event);
    diagnostics.lastEventAt = Date.now();
    diagnostics.lastEventRemote = remote;
    diagnostics.lastWarning = null;
    maybeBroadcastPerformanceEvent(event);
    broadcast(JSON.stringify({ type: "touch_event", payload: event }), socket);
    broadcastStats();
    broadcastDiagnostics();
  });

  socket.on("close", (code, reason) => {
    clients.delete(socket);
    console.log(`[ws] disconnected ${remote}. code=${code} reason=${reason.toString()} clients=${clients.size}`);
    broadcastDiagnostics();
  });

  socket.on("error", (error) => {
    console.error(`[ws] error from ${remote}`, error);
  });
});

performanceServer.on("connection", (socket, request) => {
  performanceClients.add(socket);
  const remote = `${request.socket.remoteAddress ?? "unknown"}:${request.socket.remotePort ?? "unknown"}`;
  console.log(`[performance-ws] connected ${remote}. clients=${performanceClients.size}`);
  sendJson(socket, {
    type: "performance_status",
    enabled: performanceOutputSettings.enabled,
    confirmedOnly: performanceOutputSettings.confirmedOnly,
    confidenceThreshold: performanceOutputSettings.confidenceThreshold
  });
  broadcastDiagnostics();

  socket.on("message", (data) => {
    const message = data.toString();
    if (message === "ping") {
      sendJson(socket, { type: "pong", timestamp: Date.now() });
      return;
    }

    try {
      const parsed = JSON.parse(message) as unknown;
      if (isTypedMessage(parsed) && parsed.type === "ping") {
        sendJson(socket, { type: "pong", timestamp: Date.now() });
      }
    } catch {
      // Performance clients may be receive-only. Ignore non-JSON messages.
    }
  });

  socket.on("close", (code, reason) => {
    performanceClients.delete(socket);
    console.log(`[performance-ws] disconnected ${remote}. code=${code} reason=${reason.toString()} clients=${performanceClients.size}`);
    broadcastDiagnostics();
  });

  socket.on("error", (error) => {
    console.error(`[performance-ws] error from ${remote}`, error);
  });
});

httpServer.on("upgrade", (request, socket, head) => {
  const remote = `${request.socket.remoteAddress ?? "unknown"}:${request.socket.remotePort ?? "unknown"}`;
  console.log(`[ws] upgrade request from ${remote} ${request.url ?? "/"}`);

  server.handleUpgrade(request, socket, head, (webSocket) => {
    server.emit("connection", webSocket, request);
  });
});

performanceHttpServer.on("upgrade", (request, socket, head) => {
  const remote = `${request.socket.remoteAddress ?? "unknown"}:${request.socket.remotePort ?? "unknown"}`;
  console.log(`[performance-ws] upgrade request from ${remote} ${request.url ?? "/"}`);

  performanceServer.handleUpgrade(request, socket, head, (webSocket) => {
    performanceServer.emit("connection", webSocket, request);
  });
});

httpServer.on("listening", () => {
  refreshNetworkDiagnostics();
  console.log(`[ws] brain touch server listening on ws://0.0.0.0:${PORT}`);
  for (const url of diagnostics.healthUrls) {
    console.log(`[http] health check available at ${url}`);
  }
});

performanceHttpServer.on("listening", () => {
  console.log(`[performance-ws] relay listening on ws://0.0.0.0:${PERFORMANCE_PORT}`);
  for (const address of getLocalIPv4Addresses()) {
    console.log(`[performance-ws] external clients can connect to ws://${address}:${PERFORMANCE_PORT}`);
  }
});

httpServer.on("error", (error) => {
  console.error("[ws] server error", error);
  process.exitCode = 1;
});

performanceHttpServer.on("error", (error) => {
  console.error("[performance-ws] server error", error);
  process.exitCode = 1;
});

httpServer.listen(PORT, "0.0.0.0");
performanceHttpServer.listen(PERFORMANCE_PORT, "0.0.0.0");
