import { useEffect, useMemo, useRef, useState } from "react";
import type { DailyStats, DashboardStatus, PerformanceOutputSettings, PixelPoint, PixelSize, Point2D, Point3D, ServerDiagnostics, ServerMessage, SettingsUpdatePayload, TouchEventMessage } from "./types";

const WS_URL = "ws://127.0.0.1:8787";
const MAX_LOGS = 10;
const THRESHOLDS_STORAGE_KEY = "brain-touch-dashboard.thresholds.v1";
const PERFORMANCE_OUTPUT_STORAGE_KEY = "brain-touch-dashboard.performance-output.v1";

type ThresholdSettings = {
  touchThresholdCm: number;
  strongTouchThresholdCm: number;
  dwellTimeSeconds: number;
  confidenceThreshold: number;
  smoothingFrames: number;
};

const DEFAULT_THRESHOLDS: ThresholdSettings = {
  touchThresholdCm: 5,
  strongTouchThresholdCm: 3,
  dwellTimeSeconds: 0.5,
  confidenceThreshold: 0.75,
  smoothingFrames: 5
};

const DEFAULT_PERFORMANCE_OUTPUT: PerformanceOutputSettings = {
  enabled: false,
  confirmedOnly: true,
  confidenceThreshold: 0.75
};

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

function formatPercent(value: number | null | undefined): string {
  if (value === null || value === undefined || Number.isNaN(value)) return "-";
  return `${Math.round(value * 100)}%`;
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

function loadThresholdSettings(): ThresholdSettings {
  try {
    const raw = window.localStorage.getItem(THRESHOLDS_STORAGE_KEY);
    if (!raw) return DEFAULT_THRESHOLDS;

    const parsed = JSON.parse(raw) as Partial<ThresholdSettings>;
    return {
      touchThresholdCm: clamp(Number(parsed.touchThresholdCm ?? DEFAULT_THRESHOLDS.touchThresholdCm), 0.5, 20),
      strongTouchThresholdCm: clamp(Number(parsed.strongTouchThresholdCm ?? DEFAULT_THRESHOLDS.strongTouchThresholdCm), 0.5, 20),
      dwellTimeSeconds: clamp(Number(parsed.dwellTimeSeconds ?? DEFAULT_THRESHOLDS.dwellTimeSeconds), 0, 3),
      confidenceThreshold: clamp(Number(parsed.confidenceThreshold ?? DEFAULT_THRESHOLDS.confidenceThreshold), 0, 1),
      smoothingFrames: Math.round(clamp(Number(parsed.smoothingFrames ?? DEFAULT_THRESHOLDS.smoothingFrames), 1, 30))
    };
  } catch {
    return DEFAULT_THRESHOLDS;
  }
}

function loadPerformanceOutputSettings(): PerformanceOutputSettings {
  try {
    const raw = window.localStorage.getItem(PERFORMANCE_OUTPUT_STORAGE_KEY);
    if (!raw) return DEFAULT_PERFORMANCE_OUTPUT;

    const parsed = JSON.parse(raw) as Partial<PerformanceOutputSettings>;
    return {
      enabled: Boolean(parsed.enabled ?? DEFAULT_PERFORMANCE_OUTPUT.enabled),
      confirmedOnly: parsed.confirmedOnly === undefined ? DEFAULT_PERFORMANCE_OUTPUT.confirmedOnly : Boolean(parsed.confirmedOnly),
      confidenceThreshold: clamp(Number(parsed.confidenceThreshold ?? DEFAULT_PERFORMANCE_OUTPUT.confidenceThreshold), 0, 1)
    };
  } catch {
    return DEFAULT_PERFORMANCE_OUTPUT;
  }
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

function isTouchEventEnvelope(message: ServerMessage): message is { type: "touch_event"; payload: TouchEventMessage } {
  return "type" in message && message.type === "touch_event";
}

function isSettingsUpdateMessage(message: ServerMessage): message is { type: "settings_update"; payload: SettingsUpdatePayload } {
  return "type" in message && message.type === "settings_update";
}

function isPerformanceOutputSettingsMessage(message: ServerMessage): message is { type: "performance_output_settings"; payload: PerformanceOutputSettings } {
  return "type" in message && message.type === "performance_output_settings";
}

function isPingPongMessage(message: ServerMessage): message is { type: "ping" | "pong"; timestamp?: number } {
  return "type" in message && (message.type === "ping" || message.type === "pong");
}

function buildSettingsPayload(thresholds: ThresholdSettings): SettingsUpdatePayload {
  return {
    touchThresholdCm: thresholds.touchThresholdCm,
    strongTouchThresholdCm: thresholds.strongTouchThresholdCm,
    dwellTimeSec: thresholds.dwellTimeSeconds,
    confidenceThreshold: thresholds.confidenceThreshold,
    smoothingFrames: thresholds.smoothingFrames
  };
}

function App() {
  const [status, setStatus] = useState<DashboardStatus>("connecting");
  const [lastEvent, setLastEvent] = useState<TouchEventMessage | null>(null);
  const [logs, setLogs] = useState<TouchEventMessage[]>([]);
  const [lastReceivedAt, setLastReceivedAt] = useState<number | null>(null);
  const [dailyStats, setDailyStats] = useState<DailyStats | null>(null);
  const [serverDiagnostics, setServerDiagnostics] = useState<ServerDiagnostics | null>(null);
  const [thresholds, setThresholds] = useState<ThresholdSettings>(() => loadThresholdSettings());
  const [performanceOutput, setPerformanceOutput] = useState<PerformanceOutputSettings>(() => loadPerformanceOutputSettings());
  const [lastSettingsSentAt, setLastSettingsSentAt] = useState<number | null>(null);
  const [settingsSendStatus, setSettingsSendStatus] = useState("not sent");
  const [lastPerformanceSettingsSentAt, setLastPerformanceSettingsSentAt] = useState<number | null>(null);
  const [performanceSettingsStatus, setPerformanceSettingsStatus] = useState("not sent");
  const socketRef = useRef<WebSocket | null>(null);
  const thresholdsRef = useRef(thresholds);
  const performanceOutputRef = useRef(performanceOutput);

  useEffect(() => {
    window.localStorage.setItem(THRESHOLDS_STORAGE_KEY, JSON.stringify(thresholds));
    thresholdsRef.current = thresholds;
  }, [thresholds]);

  useEffect(() => {
    window.localStorage.setItem(PERFORMANCE_OUTPUT_STORAGE_KEY, JSON.stringify(performanceOutput));
    performanceOutputRef.current = performanceOutput;
  }, [performanceOutput]);

  const settingsPayload = useMemo(() => buildSettingsPayload(thresholds), [thresholds]);

  const sendSettingsUpdate = (payload: SettingsUpdatePayload) => {
    const socket = socketRef.current;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      setSettingsSendStatus("waiting for WebSocket");
      return;
    }

    socket.send(JSON.stringify({ type: "settings_update", payload }));
    setLastSettingsSentAt(Date.now());
    setSettingsSendStatus("sent to server");
  };

  const sendPerformanceOutputSettings = (payload: PerformanceOutputSettings) => {
    const socket = socketRef.current;
    if (!socket || socket.readyState !== WebSocket.OPEN) {
      setPerformanceSettingsStatus("waiting for WebSocket");
      return;
    }

    socket.send(JSON.stringify({ type: "performance_output_settings", payload }));
    setLastPerformanceSettingsSentAt(Date.now());
    setPerformanceSettingsStatus("sent to server");
  };

  useEffect(() => {
    sendSettingsUpdate(settingsPayload);
  }, [settingsPayload]);

  useEffect(() => {
    sendPerformanceOutputSettings(performanceOutput);
  }, [performanceOutput]);

  useEffect(() => {
    let reconnectTimer: number | undefined;
    let socket: WebSocket | undefined;
    let closedByEffect = false;

    const connect = () => {
      setStatus("connecting");
      socket = new WebSocket(WS_URL);
      socketRef.current = socket;

      socket.addEventListener("open", () => {
        setStatus("connected");
        socket?.send(JSON.stringify({ type: "hello", payload: { role: "dashboard" } }));
        sendSettingsUpdate(buildSettingsPayload(thresholdsRef.current));
        sendPerformanceOutputSettings(performanceOutputRef.current);
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

          if (isSettingsUpdateMessage(parsed)) {
            setSettingsSendStatus("server has latest settings");
            return;
          }

          if (isPerformanceOutputSettingsMessage(parsed)) {
            setPerformanceSettingsStatus("server has latest output settings");
            return;
          }

          if (isPingPongMessage(parsed)) {
            return;
          }

          if ("type" in parsed && parsed.type === "settings_forwarded") {
            setSettingsSendStatus("forwarded to iPhone");
            return;
          }

          if ("type" in parsed && parsed.type === "settings_applied") {
            setSettingsSendStatus("applied on iPhone");
            return;
          }

          if ("type" in parsed && (parsed.type === "hello_required" || parsed.type === "hello_ack")) {
            return;
          }

          const touchEvent: TouchEventMessage = isTouchEventEnvelope(parsed)
            ? parsed.payload
            : parsed as TouchEventMessage;

          setLastEvent(touchEvent);
          setLastReceivedAt(Date.now());
          setLogs((current) => [touchEvent, ...current].slice(0, MAX_LOGS));
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
      if (socketRef.current === socket) {
        socketRef.current = null;
      }
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

  const thresholdChecks = useMemo(() => {
    const distanceOk = lastEvent?.distanceCm !== null && lastEvent?.distanceCm !== undefined
      ? lastEvent.distanceCm <= thresholds.touchThresholdCm
      : false;
    const strongDistanceOk = lastEvent?.distanceCm !== null && lastEvent?.distanceCm !== undefined
      ? lastEvent.distanceCm <= thresholds.strongTouchThresholdCm
      : false;
    const durationOk = lastEvent?.durationSec !== null && lastEvent?.durationSec !== undefined
      ? lastEvent.durationSec >= thresholds.dwellTimeSeconds
      : false;
    const confidenceOk = lastEvent ? lastEvent.confidence >= thresholds.confidenceThreshold : false;

    return {
      distanceOk,
      strongDistanceOk,
      durationOk,
      confidenceOk,
      allOk: distanceOk && durationOk && confidenceOk
    };
  }, [lastEvent, thresholds]);

  const updateThreshold = (key: keyof ThresholdSettings, value: number) => {
    setThresholds((current) => ({
      ...current,
      [key]: key === "smoothingFrames" ? Math.round(value) : value
    }));
  };

  const updatePerformanceOutput = <Key extends keyof PerformanceOutputSettings>(
    key: Key,
    value: PerformanceOutputSettings[Key]
  ) => {
    setPerformanceOutput((current) => ({
      ...current,
      [key]: value
    }));
  };

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

      <section className="panel threshold-panel">
        <div className="panel-heading">
          <h2>Threshold Controls</h2>
          <span className={`condition-pill ${thresholdChecks.allOk ? "ok" : "ng"}`}>
            {thresholdChecks.allOk ? "接触確定条件を満たしている" : "接触確定条件を満たしていない"}
          </span>
        </div>

        <div className="threshold-layout">
          <div className="threshold-controls">
            <ThresholdControl
              label="touch threshold cm"
              value={thresholds.touchThresholdCm}
              min={0.5}
              max={30}
              step={0.5}
              unit="cm"
              onChange={(value) => updateThreshold("touchThresholdCm", value)}
            />
            <ThresholdControl
              label="strong touch threshold cm"
              value={thresholds.strongTouchThresholdCm}
              min={0.5}
              max={30}
              step={0.5}
              unit="cm"
              onChange={(value) => updateThreshold("strongTouchThresholdCm", value)}
            />
            <ThresholdControl
              label="dwell time seconds"
              value={thresholds.dwellTimeSeconds}
              min={0}
              max={5}
              step={0.1}
              unit="s"
              onChange={(value) => updateThreshold("dwellTimeSeconds", value)}
            />
            <ThresholdControl
              label="confidence threshold"
              value={thresholds.confidenceThreshold}
              min={0}
              max={1}
              step={0.05}
              unit=""
              onChange={(value) => updateThreshold("confidenceThreshold", value)}
            />
            <ThresholdControl
              label="smoothing frames"
              value={thresholds.smoothingFrames}
              min={1}
              max={30}
              step={1}
              unit="frames"
              onChange={(value) => updateThreshold("smoothingFrames", value)}
            />
          </div>

          <div className="threshold-checks">
            <ThresholdCheck
              label="distanceCm"
              current={`${formatNumber(lastEvent?.distanceCm)} cm`}
              target={`<= ${thresholds.touchThresholdCm.toFixed(1)} cm`}
              ok={thresholdChecks.distanceOk}
            />
            <ThresholdCheck
              label="strong distance"
              current={`${formatNumber(lastEvent?.distanceCm)} cm`}
              target={`<= ${thresholds.strongTouchThresholdCm.toFixed(1)} cm`}
              ok={thresholdChecks.strongDistanceOk}
            />
            <ThresholdCheck
              label="durationSec"
              current={`${formatNumber(lastEvent?.durationSec)} s`}
              target={`>= ${thresholds.dwellTimeSeconds.toFixed(1)} s`}
              ok={thresholdChecks.durationOk}
            />
            <ThresholdCheck
              label="confidence"
              current={formatPercent(lastEvent?.confidence)}
              target={`>= ${formatPercent(thresholds.confidenceThreshold)}`}
              ok={thresholdChecks.confidenceOk}
            />
            <ThresholdCheck
              label="settings_update"
              current={settingsSendStatus}
              target={lastSettingsSentAt ? formatTime(lastSettingsSentAt) : "not sent yet"}
              ok={settingsSendStatus.includes("sent") || settingsSendStatus.includes("latest")}
            />
          </div>
        </div>
      </section>

      <section className="panel performance-panel">
        <div className="panel-heading">
          <h2>Performance Output</h2>
          <span className={`condition-pill ${performanceOutput.enabled ? "ok" : "ng"}`}>
            {performanceOutput.enabled ? "演出出力ON" : "演出出力OFF"}
          </span>
        </div>

        <div className="performance-layout">
          <div className="toggle-stack">
            <label className="toggle-row">
              <span>演出出力ON/OFF</span>
              <input
                type="checkbox"
                checked={performanceOutput.enabled}
                onChange={(event) => updatePerformanceOutput("enabled", event.currentTarget.checked)}
              />
            </label>
            <label className="toggle-row">
              <span>確定イベントだけ送る</span>
              <input
                type="checkbox"
                checked={performanceOutput.confirmedOnly}
                onChange={(event) => updatePerformanceOutput("confirmedOnly", event.currentTarget.checked)}
              />
            </label>
            <ThresholdControl
              label="performance confidence"
              value={performanceOutput.confidenceThreshold}
              min={0}
              max={1}
              step={0.05}
              unit=""
              onChange={(value) => updatePerformanceOutput("confidenceThreshold", value)}
            />
          </div>

          <div className="threshold-checks">
            <ThresholdCheck
              label="relay port"
              current="8788"
              target="ws://<PC>:8788"
              ok={performanceOutput.enabled}
            />
            <ThresholdCheck
              label="relay clients"
              current={String(serverDiagnostics?.performanceClientCount ?? 0)}
              target={serverDiagnostics?.performanceWebSocketUrls?.join(" / ") || "ws://127.0.0.1:8788"}
              ok={(serverDiagnostics?.performanceClientCount ?? 0) > 0}
            />
            <ThresholdCheck
              label="last output"
              current={serverDiagnostics?.lastPerformanceEventAt ? formatTime(serverDiagnostics.lastPerformanceEventAt) : "-"}
              target={serverDiagnostics?.lastPerformanceEventRegion ?? "waiting"}
              ok={!!serverDiagnostics?.lastPerformanceEventAt}
            />
            <ThresholdCheck
              label="output settings"
              current={performanceSettingsStatus}
              target={lastPerformanceSettingsSentAt ? formatTime(lastPerformanceSettingsSentAt) : "not sent yet"}
              ok={performanceSettingsStatus.includes("sent") || performanceSettingsStatus.includes("latest")}
            />
          </div>
        </div>
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
            <dt>last settings update</dt>
            <dd>{serverDiagnostics?.lastSettingsAt ? formatTime(serverDiagnostics.lastSettingsAt) : "-"}</dd>
          </div>
          <div>
            <dt>last settings sender</dt>
            <dd>{serverDiagnostics?.lastSettingsRemote ?? "-"}</dd>
          </div>
          <div>
            <dt>performance output</dt>
            <dd>{serverDiagnostics ? (serverDiagnostics.performanceOutputEnabled ? "on" : "off") : "-"}</dd>
          </div>
          <div>
            <dt>performance clients</dt>
            <dd>{serverDiagnostics?.performanceClientCount ?? "-"}</dd>
          </div>
          <div>
            <dt>performance WebSocket URL</dt>
            <dd>{serverDiagnostics?.performanceWebSocketUrls?.join(" / ") || "-"}</dd>
          </div>
          <div>
            <dt>last performance event</dt>
            <dd>{serverDiagnostics?.lastPerformanceEventAt ? formatTime(serverDiagnostics.lastPerformanceEventAt) : "-"}</dd>
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

type ThresholdControlProps = {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  unit: string;
  onChange: (value: number) => void;
};

function ThresholdControl({ label, value, min, max, step, unit, onChange }: ThresholdControlProps) {
  const displayValue = unit === ""
    ? value.toFixed(2)
    : `${value.toFixed(step >= 1 ? 0 : 1)} ${unit}`;

  return (
    <label className="threshold-control">
      <span>{label}</span>
      <strong>{displayValue}</strong>
      <input
        type="range"
        min={min}
        max={max}
        step={step}
        value={value}
        onChange={(event) => onChange(Number(event.currentTarget.value))}
      />
    </label>
  );
}

type ThresholdCheckProps = {
  label: string;
  current: string;
  target: string;
  ok: boolean;
};

function ThresholdCheck({ label, current, target, ok }: ThresholdCheckProps) {
  return (
    <div className={`threshold-check ${ok ? "ok" : "ng"}`}>
      <span>{label}</span>
      <strong>{current}</strong>
      <em>{target}</em>
    </div>
  );
}
