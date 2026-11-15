// Unsent composer drafts, keyed by a stable string (e.g. `chat:<convId>` or
// `chat:new`). The Composer reads/writes this so an in-progress message survives
// a view switch (chat ↔ board ↔ automations, which unmounts the composer) and a
// conversation switch (which keeps the composer mounted but changes its key).
//
// Backed by an in-memory cache (survives unmounts within a session) plus
// localStorage write-through, so text also survives a ⌘R reload. Attachment
// bytes are cached in memory and written through to IndexedDB so a renderer
// recovery/reload cannot discard an unsent attachment.

import { createStore, del, get, set } from "idb-keyval";
import { invoke } from "@/lib/host/core";
import { listen } from "@/lib/host/event";

const PREFIX = "cetus:draft:";
/** When each draft was last edited (ms), so the newer of the desktop's and
 *  the phone's copy wins. */
const AT_PREFIX = "cetus:draftAt:";

const cache = new Map<string, string>();
const editedAt = new Map<string, number>();
export type DraftAttachment =
  | { type: "image"; data: string; mimeType: string; name: string }
  | { type: "file"; data: string; mimeType: string; name: string; sizeBytes: number };
const attachmentCache = new Map<string, DraftAttachment[]>();
const attachmentRevision = new Map<string, number>();
const attachmentStore = createStore("cetus-drafts", "attachments");
const attachmentWrites = new Map<string, Promise<void>>();
let hydrated = false;

/** Pull any persisted drafts into the in-memory cache once, lazily. */
function hydrate() {
  if (hydrated) return;
  hydrated = true;
  if (typeof window === "undefined") return;
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (k && k.startsWith(PREFIX)) {
        cache.set(k.slice(PREFIX.length), localStorage.getItem(k) ?? "");
      } else if (k && k.startsWith(AT_PREFIX)) {
        editedAt.set(k.slice(AT_PREFIX.length), Number(localStorage.getItem(k)) || 0);
      }
    }
  } catch {}
}

export function readDraft(key: string): string {
  hydrate();
  return cache.get(key) ?? "";
}

// localStorage is synchronous, and the composer saves on every keystroke, so
// writes are batched: the cache is current immediately and the disk catches up
// once typing pauses (or the page hides, so a reload still finds the text).
const PERSIST_DELAY_MS = 400;
const pendingWrites = new Set<string>();
let persistTimer: ReturnType<typeof setTimeout> | undefined;

function flushDrafts() {
  clearTimeout(persistTimer);
  persistTimer = undefined;
  for (const key of pendingWrites) {
    const text = cache.get(key);
    try {
      if (text) localStorage.setItem(PREFIX + key, text);
      else localStorage.removeItem(PREFIX + key);
      const at = editedAt.get(key);
      if (at && shared(key)) localStorage.setItem(AT_PREFIX + key, String(at));
    } catch {}
  }
  pendingWrites.clear();
}

if (typeof window !== "undefined") {
  window.addEventListener("pagehide", flushDrafts);
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") flushDrafts();
  });
}

export function writeDraft(key: string, text: string): void {
  storeDraft(key, text, Date.now());
  if (shared(key)) schedulePush(key);
}

function storeDraft(key: string, text: string, at: number) {
  hydrate();
  if (text) {
    cache.set(key, text);
  } else {
    cache.delete(key);
  }
  editedAt.set(key, at);
  pendingWrites.add(key);
  clearTimeout(persistTimer);
  persistTimer = setTimeout(flushDrafts, PERSIST_DELAY_MS);
}

// ---- Sync with the phone -------------------------------------------------
// The typed text of a chat's draft (not quotes, mentions or attachments) is
// shared with Cetus on the phone through the backend's `remote.drafts`
// setting. The newest edit wins; edits from the phone arrive as
// `remote-draft` events and reach a mounted composer via subscribeDraft.

/** `chat:<id>` and `chat:new`; derived keys (`#quote`, `#mentions`) stay local. */
function shared(key: string): boolean {
  return key.startsWith("chat:") && !key.includes("#");
}

const PUSH_DELAY_MS = 600;
const pushTimers = new Map<string, ReturnType<typeof setTimeout>>();

function schedulePush(key: string) {
  clearTimeout(pushTimers.get(key));
  pushTimers.set(
    key,
    setTimeout(() => {
      pushTimers.delete(key);
      pushDraft(key);
    }, PUSH_DELAY_MS),
  );
}

function pushDraft(key: string) {
  invoke("set_remote_draft", {
    key,
    text: cache.get(key) ?? "",
    updatedAt: editedAt.get(key) ?? Date.now(),
  }).catch(() => {});
}

const listeners = new Map<string, Set<(text: string) => void>>();

/** Hear about edits made on the phone to this draft. */
export function subscribeDraft(key: string, fn: (text: string) => void): () => void {
  let set = listeners.get(key);
  if (!set) listeners.set(key, (set = new Set()));
  set.add(fn);
  return () => {
    set.delete(fn);
    if (!set.size) listeners.delete(key);
  };
}

function applyRemote(key: string, text: string, at: number) {
  hydrate();
  if (!shared(key) || at <= (editedAt.get(key) ?? 0)) return;
  // An edit typed here but not pushed yet is newer than anything incoming.
  if (pushTimers.has(key)) return;
  storeDraft(key, text, at);
  listeners.get(key)?.forEach((fn) => fn(text));
}

let syncing = false;

/** Merge the phone's drafts once, then follow its edits. Call at startup. */
export function startDraftSync(): void {
  if (syncing || typeof window === "undefined") return;
  syncing = true;
  hydrate();
  void listen<{ key: string; text: string; updatedAt: number }>("remote-draft", (e) => {
    applyRemote(e.payload.key, e.payload.text ?? "", e.payload.updatedAt ?? 0);
  });
  invoke<Record<string, { text?: string; updatedAt?: number }>>("get_remote_drafts")
    .then((remote) => {
      for (const [key, entry] of Object.entries(remote ?? {})) {
        applyRemote(key, entry.text ?? "", entry.updatedAt ?? 0);
      }
      // Edits made here while the backend didn't have them yet.
      for (const [key, at] of editedAt) {
        if (shared(key) && at > (remote?.[key]?.updatedAt ?? 0)) pushDraft(key);
      }
    })
    .catch(() => {});
}

export function readDraftAttachments(key: string): DraftAttachment[] {
  return attachmentCache.get(key)?.map((attachment) => ({ ...attachment })) ?? [];
}

/** Hydrate attachment bytes after a renderer reload. A revision guard prevents
 * a slow IndexedDB read from resurrecting attachments the user just removed. */
export async function readPersistedDraftAttachments(key: string): Promise<DraftAttachment[]> {
  const cached = attachmentCache.get(key);
  if (cached) return cached.map((attachment) => ({ ...attachment }));
  const revision = attachmentRevision.get(key) ?? 0;
  try {
    const stored = (await get<DraftAttachment[]>(key, attachmentStore)) ?? [];
    if ((attachmentRevision.get(key) ?? 0) !== revision) {
      return readDraftAttachments(key);
    }
    if (stored.length) {
      attachmentCache.set(
        key,
        stored.map((attachment) => ({ ...attachment })),
      );
    }
    return stored.map((attachment) => ({ ...attachment }));
  } catch {
    return [];
  }
}

export function writeDraftAttachments(key: string, attachments: DraftAttachment[]): void {
  attachmentRevision.set(key, (attachmentRevision.get(key) ?? 0) + 1);
  let stored: DraftAttachment[] = [];
  if (attachments.length) {
    stored = attachments.map((attachment) =>
      attachment.type === "image"
        ? {
            type: attachment.type,
            data: attachment.data,
            mimeType: attachment.mimeType,
            name: attachment.name,
          }
        : { ...attachment },
    );
    attachmentCache.set(key, stored);
  } else {
    attachmentCache.delete(key);
  }
  // Serialize writes per draft. Without this, a large `set` followed quickly
  // by remove-all could finish after the `del` and resurrect stale bytes on the
  // next renderer load.
  const previous = attachmentWrites.get(key) ?? Promise.resolve();
  const next = previous
    .catch(() => {})
    .then(() =>
      stored.length ? set(key, stored, attachmentStore) : del(key, attachmentStore),
    );
  attachmentWrites.set(key, next);
  void next
    .finally(() => {
      if (attachmentWrites.get(key) === next) attachmentWrites.delete(key);
    })
    .catch(() => {});
}
