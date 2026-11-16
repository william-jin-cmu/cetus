import { describe, expect, test } from "bun:test";
import { catalogTuning } from "../src/lib/catalog-tuning";
const defaults = { model: "carbon", effort: "medium", models: [
  { id: "carbon", label: "Carbon", efforts: ["low", "medium", "high"], defaultEffort: "medium" },
  { id: "hydrogen", label: "Hydrogen", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "high" },
  { id: "fixed", label: "Fixed", efforts: [], defaultEffort: null, aliases: ["legacy-low"] },
] };
describe("Antigravity independent tuning", () => {
  test("migrates a combined selection without losing its effort", () => {
    expect(catalogTuning("carbon-high", "", defaults)).toEqual({model: "carbon", effort: "high"});
    expect(catalogTuning("carbon-high", "low", defaults)).toEqual({model: "carbon", effort: "low"});
  });
  test("switching models clears unsupported effort using the new model default", () => {
    expect(catalogTuning("carbon", "xhigh", defaults)).toEqual({model: "carbon", effort: "medium"});
    expect(catalogTuning("hydrogen", "xhigh", defaults)).toEqual({model: "hydrogen", effort: "xhigh"});
    expect(catalogTuning("fixed", "high", defaults)).toEqual({model: "fixed", effort: ""});
  });
  test("migrates fixed legacy model aliases using the advertised mapping", () => {
    expect(catalogTuning("legacy-low", "", defaults)).toEqual({model: "fixed", effort: ""});
  });
  test("does not rewrite before the catalog loads or guess unknown model ids", () => {
    expect(catalogTuning("carbon-high", "", null)).toEqual({model: "carbon-high", effort: ""});
    expect(catalogTuning("unknown-high", "", defaults)).toEqual({model: "unknown-high", effort: ""});
  });
});

 test("OpenCode provider/model IDs preserve their separate effort", () => {
   const catalog = {model: "gcp-gemini/gemini-4-carbon", effort: "low", models: [
     {id: "gcp-gemini/gemini-4-carbon", label: "Carbon", efforts: ["low", "medium", "high"], defaultEffort: "low"},
     {id: "opencode/big-pickle", label: "Big Pickle", efforts: []},
   ]};
   expect(catalogTuning("", "", catalog)).toEqual({model: "gcp-gemini/gemini-4-carbon", effort: "low"});
   expect(catalogTuning("gcp-gemini/gemini-4-carbon", "high", catalog)).toEqual({model: "gcp-gemini/gemini-4-carbon", effort: "high"});
   expect(catalogTuning("opencode/big-pickle", "high", catalog)).toEqual({model: "opencode/big-pickle", effort: ""});
 });
