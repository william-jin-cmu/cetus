// Global local prompt history for the chat composer (↑ / ↓ recall).
//
// Stored newest-first in localStorage so sent prompts can be recalled across
// conversations and reloads, matching Claude Code / shell history semantics.

const STORAGE_KEY = "cetus:prompt-history:v1";
export const MAX_PROMPT_HISTORY = 100;

let cache: string[] | null = null;

function hydrate(): string[] {
  if (cache) return cache;
  if (typeof window === "undefined") {
    cache = [];
    return cache;
  }
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) {
      cache = [];
      return cache;
    }
    const parsed: unknown = JSON.parse(raw);
    if (Array.isArray(parsed)) {
      cache = parsed
        .filter((item): item is string => typeof item === "string" && item.trim().length > 0)
        .slice(0, MAX_PROMPT_HISTORY);
      return cache;
    }
  } catch {
    // Corrupt or unavailable storage — start fresh.
  }
  cache = [];
  return cache;
}

function persist(entries: string[]) {
  if (typeof window === "undefined") return;
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(entries));
  } catch {
    // Quota or private mode — keep the in-memory cache usable.
  }
}

/** Pure helper: insert a prompt at the head of history, deduplicating and capping length. */
export function appendPromptHistory(
  entries: readonly string[],
  prompt: string,
  maxEntries = MAX_PROMPT_HISTORY,
): string[] {
  const trimmed = prompt.trim();
  if (!trimmed) return entries.slice(0, maxEntries);
  const next = [trimmed, ...entries.filter((item) => item !== trimmed)];
  return next.slice(0, maxEntries);
}

/** Read the cached global prompt history (newest first). */
export function readPromptHistory(): readonly string[] {
  return hydrate();
}

/** Record a newly sent prompt into the global local history. */
export function recordPromptHistory(prompt: string): void {
  const next = appendPromptHistory(hydrate(), prompt);
  cache = next;
  persist(next);
}

export interface PromptHistoryNavState {
  /** -1 when not browsing history; 0 is the most recent sent prompt. */
  index: number;
  /** Unsent draft captured when entering history browsing from index -1. */
  savedDraft: string;
}

export const INITIAL_PROMPT_HISTORY_NAV: PromptHistoryNavState = {
  index: -1,
  savedDraft: "",
};

export interface StepPromptHistoryInput {
  direction: "up" | "down";
  state: PromptHistoryNavState;
  entries: readonly string[];
  text: string;
  selectionStart: number;
  selectionEnd: number;
}

export interface StepPromptHistoryResult {
  nextState: PromptHistoryNavState;
  nextText: string;
  caret: number;
}

export function isOnFirstLine(text: string, caret: number): boolean {
  return !text.slice(0, caret).includes("\n");
}

export function isOnLastLine(text: string, caret: number): boolean {
  return !text.slice(caret).includes("\n");
}

function caretForRecall(text: string, direction: "up" | "down"): number {
  // Single-line prompts put the caret at the end (ready to edit, and still on
  // both first and last line so repeated ↑/↓ keeps stepping). Multi-line
  // prompts land on the boundary matching travel direction so rapid ↑↑ or ↓↓
  // never gets stuck inside a multi-line entry.
  if (!text.includes("\n")) return text.length;
  return direction === "up" ? 0 : text.length;
}

/** Compute the next composer text + cursor state for an ArrowUp / ArrowDown press.
 *  Returns null when the keystroke should fall through to native textarea navigation. */
export function stepPromptHistory({
  direction,
  state,
  entries,
  text,
  selectionStart,
  selectionEnd,
}: StepPromptHistoryInput): StepPromptHistoryResult | null {
  if (selectionStart !== selectionEnd) return null;

  if (direction === "up") {
    if (entries.length === 0) return null;
    if (!isOnFirstLine(text, selectionStart)) return null;

    if (state.index === -1) {
      const nextText = entries[0];
      return {
        nextState: { index: 0, savedDraft: text },
        nextText,
        caret: caretForRecall(nextText, "up"),
      };
    }

    const nextIndex = state.index + 1;
    if (nextIndex >= entries.length) return null;
    const nextText = entries[nextIndex];
    return {
      nextState: { index: nextIndex, savedDraft: state.savedDraft },
      nextText,
      caret: caretForRecall(nextText, "up"),
    };
  }

  // direction === "down"
  if (state.index < 0) return null;
  if (!isOnLastLine(text, selectionStart)) return null;

  if (state.index > 0) {
    const nextIndex = state.index - 1;
    const nextText = entries[nextIndex];
    return {
      nextState: { index: nextIndex, savedDraft: state.savedDraft },
      nextText,
      caret: caretForRecall(nextText, "down"),
    };
  }

  const nextText = state.savedDraft;
  return {
    nextState: INITIAL_PROMPT_HISTORY_NAV,
    nextText,
    caret: nextText.length,
  };
}
