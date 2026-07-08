import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { WebSocketServer, type WebSocket } from "ws";

const PORT = 8787;
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const dashboardRoot = path.resolve(__dirname, "..");
const projectRoot = path.resolve(dashboardRoot, "..");
const logsDir = path.join(dashboardRoot, "logs");
const schemaPath = path.join(projectRoot, "shared/touch-event.schema.json");
const server = new WebSocketServer({ host: "0.0.0.0", port: PORT });
const clients = new Set<WebSocket>();
const schema = JSON.parse(fs.readFileSync(schemaPath, "utf8")) as { required?: string[] };
const requiredFields = schema.required ?? [];

type TouchEventMessage = {
  timestamp: number;
  isTouching: boolean;
  confidence: number;
  [key: string]: unknown;
};

type DailyStats = {
  date: string;
  receivedCount: number;
  confirmedTouchCount: number;
};

type ServerDiagnostics = {
  clientCount: number;
  lastEventAt: number | null;
  lastEventRemote: string | null;
  lastWarning: string | null;
};

let stats: DailyStats = {
  date: formatLocalDate(new Date()),
  receivedCount: 0,
  confirmedTouchCount: 0
};

let diagnostics: ServerDiagnostics = {
  clientCount: 0,
  lastEventAt: null,
  lastEventRemote: null,
  lastWarning: null
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
  diagnostics.clientCount = clients.size;
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

function appendEvent(event: TouchEventMessage) {
  resetStatsIfDateChanged();

  fs.appendFileSync(getLogPath(), `${JSON.stringify(event)}\n`, "utf8");
  stats.receivedCount += 1;
  if (isConfirmedTouch(event)) {
    stats.confirmedTouchCount += 1;
  }
}

server.on("connection", (socket, request) => {
  clients.add(socket);
  const remote = `${request.socket.remoteAddress ?? "unknown"}:${request.socket.remotePort ?? "unknown"}`;
  console.log(`[ws] connected ${remote}. clients=${clients.size}`);
  socket.send(JSON.stringify({ type: "dailyStats", payload: stats }));
  socket.send(JSON.stringify({ type: "serverDiagnostics", payload: { ...diagnostics, clientCount: clients.size } }));
  broadcastDiagnostics();

  socket.on("message", (data) => {
    const message = data.toString();
    let event: TouchEventMessage;

    try {
      event = JSON.parse(message) as TouchEventMessage;
    } catch {
      warnAndBroadcast(`[ws] ignored invalid JSON from ${remote}`);
      return;
    }

    const missingFields = validateRequiredFields(event);
    if (missingFields.length > 0) {
      warnAndBroadcast(`[ws] ignored event from ${remote}; missing required fields: ${missingFields.join(", ")}`);
      return;
    }

    appendEvent(event);
    diagnostics.lastEventAt = Date.now();
    diagnostics.lastEventRemote = remote;
    diagnostics.lastWarning = null;
    broadcast(message, socket);
    broadcastStats();
    broadcastDiagnostics();
  });

  socket.on("close", () => {
    clients.delete(socket);
    console.log(`[ws] disconnected ${remote}. clients=${clients.size}`);
    broadcastDiagnostics();
  });

  socket.on("error", (error) => {
    console.error(`[ws] error from ${remote}`, error);
  });
});

server.on("listening", () => {
  console.log(`[ws] brain touch server listening on ws://0.0.0.0:${PORT}`);
});

server.on("error", (error) => {
  console.error("[ws] server error", error);
  process.exitCode = 1;
});
