export type Point2D = {
  x: number;
  y: number;
};

export type Point3D = {
  x: number;
  y: number;
  z: number;
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
    fingerTips2D?: {
      thumbTip: Point2D | null;
      indexTip: Point2D | null;
      middleTip: Point2D | null;
      ringTip: Point2D | null;
      littleTip: Point2D | null;
    };
    depthMeters: number | null;
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
  lastEventAt: number | null;
  lastEventRemote: string | null;
  lastWarning: string | null;
};

export type ServerMessage =
  | TouchEventMessage
  | {
      type: "dailyStats";
      payload: DailyStats;
    }
  | {
      type: "serverDiagnostics";
      payload: ServerDiagnostics;
    };
