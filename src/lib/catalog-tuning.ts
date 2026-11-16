import type { CliDefaults } from "./types";

export function catalogTuning(model: string, effort: string, defaults: CliDefaults | null) {
  const models = defaults?.models ?? [];
  let row = models.find((m) => m.id === (model || defaults?.model));
  let level = effort;
  if (!row && model) {
    row = models.find((m) => model.startsWith(`${m.id}-`) &&
      m.efforts?.includes(model.slice(m.id.length + 1)));
    if (row && !level) level = model.slice(row.id.length + 1);
  }
  if (!row) row = models.find((m) => m.aliases?.includes(model));
  if (!row) return { model, effort };
  if (!row.efforts?.includes(level)) {
    level = row.defaultEffort && row.efforts?.includes(row.defaultEffort)
      ? row.defaultEffort : row.efforts?.[0] ?? "";
  }
  return { model: row.id, effort: level };
}
