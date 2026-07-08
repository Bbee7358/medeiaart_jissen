import { useEffect, useMemo, useState } from "react";
import type { DailyStats, DashboardStatus, PixelPoint, PixelSize, Point2D, Point3D, ServerDiagnostics, ServerMessage, TouchEventMessage } from "./types";

const WS_URL = "ws://127.0.0.1:8787";
const MAX_LOGS = 10;

function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

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

function formatPixel(point: PixelPoint | null | undefined): string {
  if (!point) return "-";
  return `${point.x}, ${point.y}`;
}

function formatSize(size: PixelSize | null | undefined): string {
  if (!size) return "-";
  return `${size.w} x ${size.h}`;
}

function normalizedPercent(value: number | null | undefined): string {
  if (value === null || value === undefined || Number.isNaN(value)) return "50%";
  return `${clamp(value, 0, 1) * 100}%`;
}

function worldAxisPercent(value: number | null | undefined, rangeMeters = 1.5): string {
  if (value === null || value === undefined || Number.isNaN(value)) return "50%";
  return `${((clamp(value, -rangeMeters, rangeMeters) + rangeMeters) / (rangeMeters * 2)) * 100}%`;
}

function depthPercent(point: Point3D | null | undefined, maxDepthMeters = 2.5): string {
  if (!point || Number.isNaN(point.z)) return "0%";
  return `${(clamp(Math.abs(point.z), 0, maxDepthMeters) / maxDepthMeters) * 100}%`;
}

function pixelPercent(point: PixelPoint | null | undefined, size: PixelSize | null | undefined, axis: "x" | "y"): string {
  if (!point || !size) return "50%";
  const value = axis === "x" ? point.x : point.y;
  const max = axis === "x" ? size.w - 1 : size.h - 1;
  if (max <= 0) return "50%";
  return `${(clamp(value, 0, max) / max) * 100}%`;
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

      <section className="visual-grid">
        <article className="panel visual-panel">
          <h2>Index Tip 2D</h2>
          <div className="camera-plane">
            <span className="plane-label top">top</span>
            <span className="plane-label right">right</span>
            <span
              className={`finger-dot ${lastEvent?.debug.indexTip2D ? "visible" : ""}`}
              style={{
                left: normalizedPercent(lastEvent?.debug.indexTip2D?.x),
                top: normalizedPercent(lastEvent?.debug.indexTip2D?.y)
              }}
            />
            <span
              className={`finger-dot sample ${lastEvent?.debug.depthSample2D ? "visible" : ""}`}
              style={{
                left: normalizedPercent(lastEvent?.debug.depthSample2D?.x),
                top: normalizedPercent(lastEvent?.debug.depthSample2D?.y)
              }}
            />
          </div>
          <div className="visual-meta">
            <span>yellow: Vision tip</span>
            <strong>orange: depth sample</strong>
          </div>
        </article>

        <article className="panel visual-panel">
          <h2>Index Tip 3D</h2>
          <div className="world-view">
            <div className="world-plane">
              <span className="axis x-axis" />
              <span className="axis z-axis" />
              <span className="plane-label top">front</span>
              <span className="plane-label right">right</span>
              <span
                className={`finger-dot world ${lastEvent?.debug.indexTip3D ? "visible" : ""}`}
                style={{
                  left: worldAxisPercent(lastEvent?.debug.indexTip3D?.x),
                  top: worldAxisPercent(lastEvent?.debug.indexTip3D ? -lastEvent.debug.indexTip3D.z : undefined)
                }}
              />
            </div>
            <div className="depth-meter">
              <span style={{ width: depthPercent(lastEvent?.debug.indexTip3D) }} />
            </div>
            <div className="visual-meta">
              <span>{lastEvent?.debug.indexTip3DSpace ?? "-"}</span>
              <strong>{formatPoint3D(lastEvent?.debug.indexTip3D ?? null)}</strong>
            </div>
          </div>
        </article>

        <article className="panel visual-panel">
          <h2>Depth Map Sample</h2>
          <div className="depth-plane">
            <span className="plane-label top">depth map</span>
            <span
              className={`sample-window ${lastEvent?.debug.depthPixel ? "visible" : ""}`}
              style={{
                left: pixelPercent(lastEvent?.debug.depthPixel, lastEvent?.debug.depthMapSize, "x"),
                top: pixelPercent(lastEvent?.debug.depthPixel, lastEvent?.debug.depthMapSize, "y")
              }}
            />
          </div>
          <div className="visual-meta">
            <span>px {formatPixel(lastEvent?.debug.depthPixel)}</span>
            <strong>{formatSize(lastEvent?.debug.depthMapSize)}</strong>
          </div>
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
              <dt>touchCandidate</dt>
              <dd>{lastEvent ? String(lastEvent.debug.touchCandidate ?? false) : "-"}</dd>
            </div>
            <div>
              <dt>strongCandidate</dt>
              <dd>{lastEvent ? String(lastEvent.debug.strongTouchCandidate ?? false) : "-"}</dd>
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
              <dt>fingerSpeed</dt>
              <dd>{formatNumber(lastEvent?.debug.fingerSpeedMetersPerSec)} m/s</dd>
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
              <dt>depthSample2D</dt>
              <dd>{formatPoint2D(lastEvent?.debug.depthSample2D ?? null)}</dd>
            </div>
            <div>
              <dt>rawImageNorm</dt>
              <dd>{formatPoint2D(lastEvent?.debug.rawImageNorm ?? null)}</dd>
            </div>
            <div>
              <dt>depthPixel</dt>
              <dd>{formatPixel(lastEvent?.debug.depthPixel)}</dd>
            </div>
            <div>
              <dt>depth map</dt>
              <dd>{formatSize(lastEvent?.debug.depthMapSize)}</dd>
            </div>
            <div>
              <dt>captured image</dt>
              <dd>{formatSize(lastEvent?.debug.capturedImageSize)}</dd>
            </div>
            <div>
              <dt>depth confidence</dt>
              <dd>{lastEvent?.debug.depthConfidenceRaw ?? "-"}</dd>
            </div>
            <div>
              <dt>depth source</dt>
              <dd>{lastEvent?.debug.depthSource ?? "-"}</dd>
            </div>
            <div>
              <dt>depth strategy</dt>
              <dd>{lastEvent?.debug.depthStrategy ?? "-"}</dd>
            </div>
            <div>
              <dt>touch candidate</dt>
              <dd>{lastEvent ? String(lastEvent.debug.touchCandidate ?? false) : "-"}</dd>
            </div>
            <div>
              <dt>strong candidate</dt>
              <dd>{lastEvent ? String(lastEvent.debug.strongTouchCandidate ?? false) : "-"}</dd>
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
