import assert from "node:assert/strict";
import test from "node:test";
import {
  PERFORMANCE_EFFECT_KEYS,
  PerformanceTouchStateMachine,
  resolvePerformanceEffect
} from "../server/performance-events.js";

test("all twelve physical regions map to MediaArtG1 effects", () => {
  const mappings = {
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
    side_lower_back_right: "visual"
  } as const;

  for (const [region, effect] of Object.entries(mappings)) {
    assert.equal(resolvePerformanceEffect(region), effect);
  }
  assert.deepEqual([...PERFORMANCE_EFFECT_KEYS].sort(), [
    "amygdala",
    "auditory",
    "gustatory",
    "hippocampus",
    "visual"
  ]);
});

test("continuous sensor frames create one start, updates, and one end", () => {
  const machine = new PerformanceTouchStateMachine();
  const base = {
    region: "side_lower_middle_left",
    regionLabel: "側面下段・中央左",
    surface: "left",
    surfaceLabel: "左側面",
    confidence: 0.9,
    durationSec: 0.5
  };

  assert.equal(machine.update({ ...base, timestamp: 1, isTouching: true }, 0.75)[0]?.phase, "start");
  assert.equal(machine.update({ ...base, timestamp: 2, isTouching: true }, 0.75)[0]?.phase, "update");
  assert.equal(machine.update({ ...base, timestamp: 3, isTouching: false }, 0.75)[0]?.phase, "end");
  assert.deepEqual(machine.update({ ...base, timestamp: 4, isTouching: false }, 0.75), []);
});

test("changing regions ends the old effect before starting the new one", () => {
  const machine = new PerformanceTouchStateMachine();
  machine.update({
    timestamp: 1,
    isTouching: true,
    confidence: 0.9,
    region: "top_back_left"
  }, 0.75);

  const messages = machine.update({
    timestamp: 2,
    isTouching: true,
    confidence: 0.9,
    region: "top_front_left"
  }, 0.75);

  assert.deepEqual(messages.map(({ phase, effectKey }) => ({ phase, effectKey })), [
    { phase: "end", effectKey: "visual" },
    { phase: "start", effectKey: "amygdala" }
  ]);
});
