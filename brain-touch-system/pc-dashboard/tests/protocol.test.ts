import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import Ajv2020Import from "ajv/dist/2020.js";

const Ajv2020 = Ajv2020Import as unknown as new (options?: object) => {
  compile(schema: object): (data: unknown) => boolean;
};
const here = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(here, "../..");
const schema = JSON.parse(
  fs.readFileSync(path.join(projectRoot, "shared/touch-event.schema.json"), "utf8")
) as object;
const validate = new Ajv2020({ strict: false, allowUnionTypes: true }).compile(schema);

test("all shared sample events satisfy the protocol schema", () => {
  const sampleDir = path.join(projectRoot, "shared/sample-events");
  const files = fs.readdirSync(sampleDir).filter((file) => file.endsWith(".json"));
  assert.ok(files.length >= 3);
  for (const file of files) {
    const event = JSON.parse(fs.readFileSync(path.join(sampleDir, file), "utf8")) as unknown;
    assert.equal(validate(event), true, file);
  }
});

test("invalid event types are rejected", () => {
  assert.equal(validate({
    version: "0.1.0",
    source: "iphone-12-pro",
    timestamp: "not-a-number"
  }), false);
});

test("current iPhone debug payload satisfies the schema", () => {
  const event = {
    version: "0.1.0",
    source: "iphone-12-pro",
    timestamp: Date.now(),
    handDetected: true,
    isTouching: true,
    region: "side_lower_middle_right",
    regionLabel: "側面下段・中央右",
    surface: "right",
    surfaceLabel: "右側面",
    contactType: "middle_fingertip",
    distanceCm: 1.2,
    durationSec: 0.6,
    confidence: 0.86,
    debug: {
      indexTip2D: { x: 0.5, y: 0.5 },
      indexTip3D: { x: 0.1, y: -0.2, z: -0.6 },
      indexTip3DSpace: "arkit_world",
      selectedFinger: "middle",
      selectedFingerTip3D: { x: 0.1, y: -0.2, z: -0.6 },
      selectedFingerDIP3D: { x: 0.12, y: -0.18, z: -0.55 },
      surfaceApproachAlignment: 0.8,
      reprojectionErrorPixels: 0.4,
      eventFps: 10,
      calibrationValid: true,
      handDetectorSource: "mediapipe",
      handDetectorStatus: "detected",
      handDetectorInferenceMs: 21,
      handLandmarks2D: Array.from({ length: 21 }, () => ({ x: 0.5, y: 0.5 })),
      detectedJointCount: 21,
      fingerTips2D: {
        thumbTip: null,
        indexTip: { x: 0.5, y: 0.5 },
        middleTip: { x: 0.55, y: 0.5 },
        ringTip: null,
        littleTip: null
      },
      depthMeters: 0.61,
      depthSample2D: { x: 0.55, y: 0.5 },
      rawImageNorm: { x: 0.5, y: 0.45 },
      depthPixel: { x: 120, y: 90 },
      depthMapSize: { w: 256, h: 192 },
      capturedImageSize: { w: 1920, h: 1440 },
      visionOrientation: "right",
      depthConfidenceRaw: 2,
      depthSource: "smoothedSceneDepth",
      depthStrategy: "middle_tip_high_confidence_median",
      depthSampleCount: 12,
      touchCandidate: true,
      strongTouchCandidate: true,
      fingerSpeedMetersPerSec: 0.03,
      surfaceContactProfile: null,
      calibration: {
        centerX: 0,
        centerY: -0.6,
        centerZ: 0,
        widthMeters: 0.15,
        depthMeters: 0.13,
        heightMeters: 0.1,
        meshRealWidthMeters: 0.15,
        meshYawDegrees: 0,
        touchThresholdCm: 5,
        strongTouchThresholdCm: 3,
        dwellTimeSeconds: 0.5,
        confidenceThreshold: 0.75,
        smoothingFrames: 5
      },
      fps: 30
    }
  };
  assert.equal(validate(event), true);
});
