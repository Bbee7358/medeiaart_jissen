export const PERFORMANCE_EFFECT_KEYS = [
  "visual",
  "auditory",
  "gustatory",
  "hippocampus",
  "amygdala"
] as const;

export type PerformanceEffectKey = typeof PERFORMANCE_EFFECT_KEYS[number];
export type PerformanceTouchPhase = "start" | "update" | "end";

export type PerformanceTouchInput = {
  timestamp: number;
  isTouching: boolean;
  confidence: number;
  region?: unknown;
  regionLabel?: unknown;
  surface?: unknown;
  surfaceLabel?: unknown;
  durationSec?: unknown;
};

export type PerformanceTouchStateMessage = {
  type: "brain_touch_state";
  phase: PerformanceTouchPhase;
  effectKey: PerformanceEffectKey;
  region: string;
  regionLabel: string | null;
  surface: string | null;
  surfaceLabel: string | null;
  confidence: number;
  durationSec: number;
  timestamp: number;
};

// Physical 12-zone layout -> MediaArtG1's five existing effect categories.
// This is an exhibition mapping, not a claim of anatomical equivalence.
const REGION_EFFECT_MAP: Record<string, PerformanceEffectKey> = {
  top_front_left: "amygdala",
  top_front_right: "amygdala",
  top_middle_left: "hippocampus",
  top_middle_right: "hippocampus",
  top_back_left: "visual",
  top_back_right: "visual",
  side_lower_front_left: "gustatory",
  side_lower_front_right: "gustatory",
  side_lower_middle_left: "auditory",
  side_lower_middle_right: "auditory",
  side_lower_back_left: "visual",
  side_lower_back_right: "visual",

  left_occipital_lobe: "visual",
  right_occipital_lobe: "visual",
  occipital_lobe: "visual",
  left_temporal_lobe: "auditory",
  right_temporal_lobe: "auditory",
  left_parietal_lobe: "hippocampus",
  right_parietal_lobe: "hippocampus",
  left_frontal_lobe: "amygdala",
  right_frontal_lobe: "amygdala",
  cerebellum: "gustatory",
  brainstem: "gustatory",

  front: "gustatory",
  back: "visual",
  left_side: "auditory",
  right_side: "auditory",
  top: "hippocampus",
  center: "amygdala"
};

export function resolvePerformanceEffect(region: unknown): PerformanceEffectKey | null {
  if (typeof region !== "string") return null;
  return REGION_EFFECT_MAP[region] ?? null;
}

function textOrNull(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

function finiteNumber(value: unknown, fallback = 0): number {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function makeMessage(
  phase: PerformanceTouchPhase,
  input: PerformanceTouchInput,
  effectKey: PerformanceEffectKey,
  region: string,
  regionLabel: string | null
): PerformanceTouchStateMessage {
  return {
    type: "brain_touch_state",
    phase,
    effectKey,
    region,
    regionLabel,
    surface: textOrNull(input.surface),
    surfaceLabel: textOrNull(input.surfaceLabel),
    confidence: finiteNumber(input.confidence),
    durationSec: finiteNumber(input.durationSec),
    timestamp: finiteNumber(input.timestamp, Date.now())
  };
}

export class PerformanceTouchStateMachine {
  private active: {
    effectKey: PerformanceEffectKey;
    region: string;
    regionLabel: string | null;
  } | null = null;

  update(input: PerformanceTouchInput, confidenceThreshold: number): PerformanceTouchStateMessage[] {
    const region = typeof input.region === "string" ? input.region : "unknown";
    const effectKey = resolvePerformanceEffect(region);
    const qualifies = input.isTouching && input.confidence >= confidenceThreshold && effectKey !== null;

    if (!qualifies || !effectKey) {
      return this.end(input);
    }

    const regionLabel = textOrNull(input.regionLabel);
    if (!this.active) {
      this.active = { effectKey, region, regionLabel };
      return [makeMessage("start", input, effectKey, region, regionLabel)];
    }

    if (this.active.effectKey === effectKey && this.active.region === region) {
      this.active.regionLabel = regionLabel;
      return [makeMessage("update", input, effectKey, region, regionLabel)];
    }

    const ended = makeMessage(
      "end",
      input,
      this.active.effectKey,
      this.active.region,
      this.active.regionLabel
    );
    this.active = { effectKey, region, regionLabel };
    return [ended, makeMessage("start", input, effectKey, region, regionLabel)];
  }

  reset(timestamp = Date.now()): PerformanceTouchStateMessage[] {
    return this.end({ timestamp, isTouching: false, confidence: 0 });
  }

  private end(input: PerformanceTouchInput): PerformanceTouchStateMessage[] {
    if (!this.active) return [];
    const message = makeMessage(
      "end",
      input,
      this.active.effectKey,
      this.active.region,
      this.active.regionLabel
    );
    this.active = null;
    return [message];
  }
}
