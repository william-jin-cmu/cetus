import { describe, expect, test } from "bun:test";
import { antigravityTuning } from "../src/lib/antigravity-tuning";
const defaults = { model: "carbon", effort: "medium", models: [
  { id: "carbon", label: "Carbon", efforts: ["low", "medium", "high"], defaultEffort: "medium" },
  { id: "hydrogen", label: "Hydrogen", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "high" },
  { id: "fixed", label: "Fixed", efforts: [], defaultEffort: null, aliases: ["legacy-low"] },
] };
describe("Antigravity independent tuning", () => {
  test("migrates a combined selection without losing its effort", () => {
    expect(antigravityTuning("carbon-high", "", defaults)).toEqual({model: "carbon", effort: "high"});
    expect(antigravityTuning("carbon-high", "low", defaults)).toEqual({model: "carbon", effort: "low"});
  });
  test("switching models clears unsupported effort using the new model default", () => {
    expect(antigravityTuning("carbon", "xhigh", defaults)).toEqual({model: "carbon", effort: "medium"});
    expect(antigravityTuning("hydrogen", "xhigh", defaults)).toEqual({model: "hydrogen", effort: "xhigh"});
    expect(antigravityTuning("fixed", "high", defaults)).toEqual({model: "fixed", effort: ""});
  });
  test("migrates fixed legacy model aliases using the advertised mapping", () => {
    expect(antigravityTuning("legacy-low", "", defaults)).toEqual({model: "fixed", effort: ""});
  });
  test("does not rewrite before the catalog loads or guess unknown model ids", () => {
    expect(antigravityTuning("carbon-high", "", null)).toEqual({model: "carbon-high", effort: ""});
    expect(antigravityTuning("unknown-high", "", defaults)).toEqual({model: "unknown-high", effort: ""});
  });
});
