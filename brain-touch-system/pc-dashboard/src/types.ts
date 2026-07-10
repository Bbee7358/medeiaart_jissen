export type Point2D = {
  x: number;
  y: number;
};

export type Point3D = {
  x: number;
  y: number;
  z: number;
};

export type PixelPoint = {
  x: number;
  y: number;
};

export type PixelSize = {
  w: number;
  h: number;
};

export type BrainCalibration = {
  centerX: number;
  centerY: number;
  centerZ: number;
  widthMeters: number;
  depthMeters: number;
  heightMeters: number;
  touchThresholdCm: number;
  strongTouchThresholdCm?: number;
  dwellTimeSeconds: number;
  confidenceThreshold: number;
  smoothingFrames?: number;
};

export type SettingsUpdatePayload = {
  touchThresholdCm: number;
  strongTouchThresholdCm: number;
  dwellTimeSec: number;
  confidenceThreshold: number;
  smoothingFrames: number;
};

export type PerformanceOutputSettings = {
  enabled: boolean;
  confirmedOnly: boolean;
  confidenceThreshold: number;
};

export type TouchEventMessage = {
  version: "0.1.0";
  source: string;
  timestamp: number;
  handDetected: boolean;
  isTouching: boolean;
  region: string | null;
  regionLabel: string | null;
  surface: string | null;
  surfaceLabel: string | null;
  contactType: "index_fingertip" | "hand_palm" | "unknown";
  distanceCm: number | null;
  durationSec: number;
  confidence: number;
  debug: {
    indexTip2D: Point2D | null;
    indexTip3D: Point3D | null;
    indexTip3DSpace?: "arkit_world" | "camera";
    fingerTips2D?: {
      thumbTip: Point2D | null;
      indexTip: Point2D | null;
      middleTip: Point2D | null;
      ringTip: Point2D | null;
      littleTip: Point2D | null;
    };
    depthMeters: number | null;
    depthSample2D?: Point2D | null;
    rawImageNorm?: Point2D | null;
    depthPixel?: PixelPoint | null;
    depthMapSize?: PixelSize | null;
    capturedImageSize?: PixelSize | null;
    visionOrientation?: string | null;
    depthConfidenceRaw?: number | null;
    depthSource?: string | null;
    depthStrategy?: string | null;
    depthSampleCount?: number | null;
    touchCandidate?: boolean;
    strongTouchCandidate?: boolean;
    fingerSpeedMetersPerSec?: number | null;
    calibration?: BrainCalibration;
    fps: number;
  };
};

export type DashboardStatus = "connecting" | "connected" | "disconnected" | "error";

export type DailyStats = {
  date: string;
  receivedCount: number;
  confirmedTouchCount: number;
};

export type ServerDiagnostics = {
  clientCount: number;
  clientRoles?: {
    total: number;
    sensors: number;
    dashboards: number;
    unknown: number;
  };
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

export type ServerMessage =
  | TouchEventMessage
  | {
      type: "touch_event";
      payload: TouchEventMessage;
    }
  | {
      type: "settings_update";
      payload: SettingsUpdatePayload;
    }
  | {
      type: "performance_output_settings";
      payload: PerformanceOutputSettings;
    }
  | {
      type: "ping" | "pong";
      timestamp?: number;
    }
  | {
      type: "dailyStats";
      payload: DailyStats;
    }
  | {
      type: "serverDiagnostics";
      payload: ServerDiagnostics;
    }
  | {
      type: "hello_required" | "hello_ack" | "settings_forwarded" | "settings_applied";
      payload: unknown;
    };
