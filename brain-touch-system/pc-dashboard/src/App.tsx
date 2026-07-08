import { useEffect, useMemo, useState } from "react";
import type { DailyStats, DashboardStatus, Point2D, Point3D, ServerDiagnostics, ServerMessage, TouchEventMessage } from "./types";

const WS_URL = "ws://127.0.0.1:8787";
const MAX_LOGS = 10;

function formatTime(timestamp?: number): string {
  if (!timestamp) return "-";
  return new Intl.DateTimeFormat("ja-JP", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    fractionalSecondDigits: 3
  }).format(new Date(timestamp));
}

function formatNumber(value: number | null | undefined, digits = 2): string {
  if (value === null || value === undefined || Number.isNaN(value)) return "-";
  return value.toFixed(digits);
}

function formatPoint2D(point: Point2D | null): string {
  if (!point) return "-";
  return `x ${point.x.toFixed(3)}, y ${point.y.toFixed(3)}`;
}

function formatPoint3D(point: Point3D | null): string {
  if (!point) return "-";
  return `x ${point.x.toFixed(3)}, y ${point.y.toFixed(3)}, z ${point.z.toFixed(3)}`;
}

function statusLabel(status: DashboardStatus): string {
  switch (status) {
    case "connecting":
      return "connecting";
    case "connected":
      return "connected";
    case "disconnected":
      return "disconnected";
    case "error":
      return "error";
  }
}

function isDailyStatsMessage(message: ServerMessage): message is { type: "dailyStats"; payload: DailyStats } {
  return "type" in message && message.type === "dailyStats";
}

function isServerDiagnosticsMessage(message: ServerMessage): message is { type: "serverDiagnostics"; payload: ServerDiagnostics } {
  return "type" in message && message.type === "serverDiagnostics";
}

function App() {
  const [status, setStatus] = useState<DashboardStatus>("connecting");
  const [lastEvent, setLastEvent] = useState<TouchEventMessage | null>(null);
  const [logs, setLogs] = useState<TouchEventMessage[]>([]);
  const [lastReceivedAt, setLastReceivedAt] = useState<number | null>(null);
  const [dailyStats, setDailyStats] = useState<DailyStats | null>(null);
  const [serverDiagnostics, setServerDiagnostics] = useState<ServerDiagnostics | null>(null);

  useEffect(() => {
    let reconnectTimer: number | undefined;
    let socket: WebSocket | undefined;
    let closedByEffect = false;

    const connect = () => {
      setStatus("connecting");
      socket = new WebSocket(WS_URL);

      socket.addEventListener("open", () => {
        setStatus("connected");
      });

      socket.addEventListener("message", (event) => {
        try {
          const parsed = JSON.parse(event.data) as ServerMessage;

          if (isDailyStatsMessage(parsed)) {
            setDailyStats(parsed.payload);
            return;
          }

          if (isServerDiagnosticsMessage(parsed)) {
            setServerDiagnostics(parsed.payload);
            return;
          }

          setLastEvent(parsed);
          setLastReceivedAt(Date.now());
          setLogs((current) => [parsed, ...current].slice(0, MAX_LOGS));
        } catch (error) {
          console.error("Invalid JSON event", error);
        }
      });

      socket.addEventListener("close", () => {
        if (closedByEffect) return;
        setStatus("disconnected");
        reconnectTimer = window.setTimeout(connect, 1000);
      });

      socket.addEventListener("error", () => {
        setStatus("error");
      });
    };

    connect();

    return () => {
      closedByEffect = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      socket?.close();
    };
  }, []);

  const confidencePercent = useMemo(() => {
    if (!lastEvent) return "-";
    return `${Math.round(lastEvent.confidence * 100)}%`;
  }, [lastEvent]);

  const headline = useMemo(() => {
    if (!lastEvent) return "waiting for iPhone...";
    if (!lastEvent.isTouching) return "接触候補なし";

    const region = lastEvent.regionLabel ?? "不明部位";
    const surface = lastEvent.surfaceLabel ?? "不明面";
    return `${region}の${surface}を触っています`;
  }, [lastEvent]);

  return (
    <main className="dashboard">
      <section className={`hero ${lastEvent?.isTouching ? "is-touching" : ""}`}>
        <div className="hero-topline">
          <span className={`status-dot ${status}`} />
          <span>{statusLabel(status)}</span>
        </div>
        <h1>{headline}</h1>
        <div className="hero-meta">
          <span>Last received: {lastReceivedAt ? formatTime(lastReceivedAt) : "-"}</span>
          <span>Event time: {formatTime(lastEvent?.timestamp)}</span>
          <span>Today: {dailyStats?.date ?? "-"}</span>
        </div>
      </section>

      <section className="summary-grid">
        <article className="panel counter-panel">
          <span>今日の受信件数</span>
          <strong>{dailyStats?.receivedCount ?? 0}</strong>
        </article>
        <article className="panel counter-panel confirmed">
          <span>今日の接触確定件数</span>
          <strong>{dailyStats?.confirmedTouchCount ?? 0}</strong>
        </article>
      </section>

      <section className="panel diagnostics-panel">
        <h2>Connection Diagnostics</h2>
        <dl>
          <div>
            <dt>server clients</dt>
            <dd>{serverDiagnostics?.clientCount ?? "-"}</dd>
          </div>
          <div>
            <dt>last iPhone event</dt>
            <dd>{serverDiagnostics?.lastEventAt ? formatTime(serverDiagnostics.lastEventAt) : "-"}</dd>
          </div>
          <div>
            <dt>last sender</dt>
            <dd>{serverDiagnostics?.lastEventRemote ?? "-"}</dd>
          </div>
          <div>
            <dt>last HTTP check</dt>
            <dd>{serverDiagnostics?.lastHttpRequestAt ? formatTime(serverDiagnostics.lastHttpRequestAt) : "-"}</dd>
          </div>
          <div>
            <dt>last HTTP sender</dt>
            <dd>{serverDiagnostics?.lastHttpRequestRemote ?? "-"}</dd>
          </div>
          <div>
            <dt>Mac IP candidates</dt>
            <dd>{serverDiagnostics?.localAddresses?.join(", ") || "-"}</dd>
          </div>
          <div>
            <dt>Safari health check</dt>
            <dd>{serverDiagnostics?.healthUrls?.join(" / ") || "-"}</dd>
          </div>
          <div>
            <dt>iPhone WebSocket URL</dt>
            <dd>{serverDiagnostics?.websocketUrls?.join(" / ") || "-"}</dd>
          </div>
          <div>
            <dt>server warning</dt>
            <dd>{serverDiagnostics?.lastWarning ?? "-"}</dd>
          </div>
        </dl>
      </section>

      <section className="grid">
        <article className="panel state-panel">
          <h2>State</h2>
          <dl>
            <div>
              <dt>handDetected</dt>
              <dd>{lastEvent ? String(lastEvent.handDetected) : "-"}</dd>
            </div>
            <div>
              <dt>isTouching</dt>
              <dd>{lastEvent ? String(lastEvent.isTouching) : "-"}</dd>
            </div>
            <div>
              <dt>regionLabel</dt>
              <dd>{lastEvent?.regionLabel ?? "-"}</dd>
            </div>
            <div>
              <dt>surfaceLabel</dt>
              <dd>{lastEvent?.surfaceLabel ?? "-"}</dd>
            </div>
            <div>
              <dt>contactType</dt>
              <dd>{lastEvent?.contactType ?? "-"}</dd>
            </div>
          </dl>
        </article>

        <article className="panel metrics-panel">
          <h2>Metrics</h2>
          <dl>
            <div>
              <dt>distanceCm</dt>
              <dd>{formatNumber(lastEvent?.distanceCm)} cm</dd>
            </div>
            <div>
              <dt>durationSec</dt>
              <dd>{formatNumber(lastEvent?.durationSec)} s</dd>
            </div>
            <div>
              <dt>confidence</dt>
              <dd>{confidencePercent}</dd>
            </div>
            <div>
              <dt>depthMeters</dt>
              <dd>{formatNumber(lastEvent?.debug.depthMeters)} m</dd>
            </div>
            <div>
              <dt>fps</dt>
              <dd>{formatNumber(lastEvent?.debug.fps, 0)}</dd>
            </div>
          </dl>
        </article>

        <article className="panel debug-panel">
          <h2>Debug</h2>
          <dl>
            <div>
              <dt>indexTip2D</dt>
              <dd>{formatPoint2D(lastEvent?.debug.indexTip2D ?? null)}</dd>
            </div>
            <div>
              <dt>indexTip3D</dt>
              <dd>{formatPoint3D(lastEvent?.debug.indexTip3D ?? null)}</dd>
            </div>
            <div>
              <dt>indexTip3DSpace</dt>
              <dd>{lastEvent?.debug.indexTip3DSpace ?? "-"}</dd>
            </div>
            <div>
              <dt>source</dt>
              <dd>{lastEvent?.source ?? "-"}</dd>
            </div>
          </dl>
          <details>
            <summary>JSON全文</summary>
            <pre>{lastEvent ? JSON.stringify(lastEvent, null, 2) : "waiting for iPhone..."}</pre>
          </details>
        </article>
      </section>

      <section className="panel log-panel">
        <h2>Recent Events</h2>
        {logs.length === 0 ? (
          <p className="muted">waiting for iPhone...</p>
        ) : (
          <ol>
            {logs.map((event, index) => (
              <li key={`${event.timestamp}-${index}`}>
                <span>{formatTime(event.timestamp)}</span>
                <strong>{event.isTouching ? `${event.regionLabel ?? "不明部位"} / ${event.surfaceLabel ?? "不明面"}` : "接触候補なし"}</strong>
                <span>{Math.round(event.confidence * 100)}%</span>
              </li>
            ))}
          </ol>
        )}
      </section>
    </main>
  );
}

export default App;
