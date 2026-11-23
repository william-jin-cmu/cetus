import { describe, expect, test } from "bun:test";
import {
  INITIAL_PROMPT_HISTORY_NAV,
  appendPromptHistory,
  isOnFirstLine,
  isOnLastLine,
  stepPromptHistory,
} from "./prompt-history.ts";

describe("appendPromptHistory", () => {
  test("prepends trimmed prompts, deduplicates existing entries, and caps size", () => {
    let entries = appendPromptHistory([], "  first prompt  ", 3);
    entries = appendPromptHistory(entries, "second prompt", 3);
    entries = appendPromptHistory(entries, "   ", 3);
    expect(entries).toEqual(["second prompt", "first prompt"]);

    // Re-sending an older prompt moves it to the top instead of duplicating it.
    entries = appendPromptHistory(entries, "first prompt", 3);
    expect(entries).toEqual(["first prompt", "second prompt"]);

    entries = appendPromptHistory(entries, "third", 3);
    entries = appendPromptHistory(entries, "fourth", 3);
    expect(entries).toEqual(["fourth", "third", "first prompt"]);
  });
});

describe("line boundary helpers", () => {
  test("detects first and last lines in single-line and multi-line text", () => {
    expect(isOnFirstLine("", 0)).toBe(true);
    expect(isOnLastLine("", 0)).toBe(true);
    expect(isOnFirstLine("hello", 3)).toBe(true);
    expect(isOnLastLine("hello", 3)).toBe(true);

    const multi = "line 1\nline 2\nline 3";
    expect(isOnFirstLine(multi, 0)).toBe(true);
    expect(isOnFirstLine(multi, 6)).toBe(true);
    expect(isOnFirstLine(multi, 7)).toBe(false);
    expect(isOnLastLine(multi, 13)).toBe(false);
    expect(isOnLastLine(multi, 14)).toBe(true);
    expect(isOnLastLine(multi, multi.length)).toBe(true);
  });
});

describe("stepPromptHistory", () => {
  const entries = ["latest", "line A\nline B", "oldest"];

  test("walks up through history and restores the saved draft on ArrowDown", () => {
    const step1 = stepPromptHistory({
      direction: "up",
      state: INITIAL_PROMPT_HISTORY_NAV,
      entries,
      text: "in-progress draft",
      selectionStart: 5,
      selectionEnd: 5,
    });
    expect(step1).toEqual({
      nextState: { index: 0, savedDraft: "in-progress draft" },
      nextText: "latest",
      caret: "latest".length,
    });

    // Stepping up into a multi-line prompt places caret at 0 so another ↑ skips past it.
    const step2 = stepPromptHistory({
      direction: "up",
      state: step1.nextState,
      entries,
      text: step1.nextText,
      selectionStart: step1.caret,
      selectionEnd: step1.caret,
    });
    expect(step2).toEqual({
      nextState: { index: 1, savedDraft: "in-progress draft" },
      nextText: "line A\nline B",
      caret: 0,
    });

    const step3 = stepPromptHistory({
      direction: "up",
      state: step2.nextState,
      entries,
      text: step2.nextText,
      selectionStart: step2.caret,
      selectionEnd: step2.caret,
    });
    expect(step3).toEqual({
      nextState: { index: 2, savedDraft: "in-progress draft" },
      nextText: "oldest",
      caret: "oldest".length,
    });

    // At the oldest entry, ArrowUp is a no-op.
    expect(
      stepPromptHistory({
        direction: "up",
        state: step3.nextState,
        entries,
        text: step3.nextText,
        selectionStart: step3.caret,
        selectionEnd: step3.caret,
      }),
    ).toBeNull();

    // Stepping down into a multi-line prompt places caret at end so another ↓ keeps moving down.
    const down1 = stepPromptHistory({
      direction: "down",
      state: step3.nextState,
      entries,
      text: step3.nextText,
      selectionStart: step3.caret,
      selectionEnd: step3.caret,
    });
    expect(down1).toEqual({
      nextState: { index: 1, savedDraft: "in-progress draft" },
      nextText: "line A\nline B",
      caret: "line A\nline B".length,
    });

    const down2 = stepPromptHistory({
      direction: "down",
      state: down1.nextState,
      entries,
      text: down1.nextText,
      selectionStart: down1.caret,
      selectionEnd: down1.caret,
    });
    expect(down2).toEqual({
      nextState: { index: 0, savedDraft: "in-progress draft" },
      nextText: "latest",
      caret: "latest".length,
    });

    const restored = stepPromptHistory({
      direction: "down",
      state: down2.nextState,
      entries,
      text: down2.nextText,
      selectionStart: down2.caret,
      selectionEnd: down2.caret,
    });
    expect(restored).toEqual({
      nextState: INITIAL_PROMPT_HISTORY_NAV,
      nextText: "in-progress draft",
      caret: "in-progress draft".length,
    });
  });

  test("does not hijack ArrowUp/ArrowDown inside multi-line text or active selections", () => {
    // Caret on second line: ArrowUp should move within the textarea instead.
    expect(
      stepPromptHistory({
        direction: "up",
        state: INITIAL_PROMPT_HISTORY_NAV,
        entries,
        text: "first line\nsecond line",
        selectionStart: 15,
        selectionEnd: 15,
      }),
    ).toBeNull();

    // Caret on first line of multi-line entry while browsing: ArrowDown should move to line 2 first.
    expect(
      stepPromptHistory({
        direction: "down",
        state: { index: 1, savedDraft: "" },
        entries,
        text: "line A\nline B",
        selectionStart: 2,
        selectionEnd: 2,
      }),
    ).toBeNull();

    // Active selection: never hijack.
    expect(
      stepPromptHistory({
        direction: "up",
        state: INITIAL_PROMPT_HISTORY_NAV,
        entries,
        text: "selected",
        selectionStart: 0,
        selectionEnd: 4,
      }),
    ).toBeNull();

    // ArrowDown when not browsing history: never hijack.
    expect(
      stepPromptHistory({
        direction: "down",
        state: INITIAL_PROMPT_HISTORY_NAV,
        entries,
        text: "",
        selectionStart: 0,
        selectionEnd: 0,
      }),
    ).toBeNull();
  });
});
