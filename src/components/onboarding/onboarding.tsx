"use client";
// First-run setup. Shown once (gated by a localStorage flag, mirroring
// cetus:notificationPrefs / cetus:lastModelChoice). One quiet card on the
// app's own surface; its look and motion are bespoke and live in
// `styles/onboarding.css` rather than the stock settings controls, with the
// tiles that lift when switched on in `styles/lift-tile.css`.
//
// Step 1 picks runtimes: cetus probes which agent CLIs are installed and
// pre-selects the ones that work right now, so a user with Claude Code or
// Codex signed in starts chatting without pasting any API key. The built-in
// Cetus agent is just another tile — on by default only when it has a model
// to run on (or nothing else is installed), with an optional DeepSeek key
// field. Continue writes the selection to Settings › Runtimes.
//
// Step 2 grants OS permissions through the same `lib/permissions` calls and
// copy as Settings → Permissions. Everything here is optional and can be
// changed later in Settings.

import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import { ArrowRight, Check } from "lucide-react";
import { Spinner } from "@/components/ui/spinner";
import { useTranslation } from "@/lib/i18n";
import { api } from "@/lib/api";
import { CetusIcon } from "@/components/brand-icons";
import { BACKENDS } from "@/components/chat/backend-picker";
import {
  DEFAULT_CLI_AGENT_SETTINGS,
  isBackendEnabled,
  runtimeEnabledPatch,
} from "@/lib/runtime-settings";
import {
  openPermissionSettings,
  requestPermission,
  type PermStatus,
  type PermissionId,
  type PermissionMeta,
} from "@/lib/permissions";
import type { BackendId, CliAgentSettings } from "@/lib/types";
import { cn } from "@/lib/utils";
import {
  APPLICABLE_PERMISSIONS,
  usePermissionStatuses,
} from "@/components/settings/permission-row";

const ONBOARDING_KEY = "cetus:onboardingDone";

type CliRuntimeStatus = Awaited<ReturnType<typeof api.getCliRuntimeStatus>>;
type CliBackendId = Exclude<BackendId, "pi">;

function cliInstalled(status: CliRuntimeStatus, id: CliBackendId): boolean {
  return id === "claude-code" ? status.claudeCode : status[id];
}

/** What the first-run probe learned. `cli` is null when the probe itself
 *  failed — then nothing is known and nothing gets switched off. */
interface Detection {
  saved: CliAgentSettings;
  cli: CliRuntimeStatus | null;
  /** Cetus has a model to run on: a DeepSeek key or a custom provider. */
  cetusReady: boolean;
}

type RowState = "ready" | "notInstalled" | "notSignedIn" | "needsKey" | "unknown";

function rowState(id: BackendId, d: Detection, cetusReady: boolean): RowState {
  if (id === "pi") return cetusReady ? "ready" : "needsKey";
  if (!d.cli) return "unknown";
  if (!cliInstalled(d.cli, id)) return "notInstalled";
  if (id === "codex" && d.cli.codexLoggedIn === false) return "notSignedIn";
  return "ready";
}

/** The pre-selection: every runtime that works right now. Cetus without a
 *  model stays off unless it's the only option, so the default runtime of a
 *  fresh install is one that can actually answer. A runtime the user already
 *  switched off in Settings stays off. */
function initialSelection(d: Detection): Record<BackendId, boolean> {
  const anyCli =
    d.cli !== null &&
    BACKENDS.some((b) => b.id !== "pi" && cliInstalled(d.cli!, b.id));
  const selection = {} as Record<BackendId, boolean>;
  for (const { id } of BACKENDS) {
    const detected =
      id === "pi"
        ? d.cetusReady || !anyCli
        : d.cli === null || cliInstalled(d.cli, id);
    selection[id] = detected && isBackendEnabled(id, d.saved);
  }
  if (!Object.values(selection).some(Boolean)) selection.pi = true;
  return selection;
}

function markDone() {
  try {
    localStorage.setItem(ONBOARDING_KEY, "1");
  } catch {
    /* best-effort */
  }
}

type Step = 0 | 1;
/** How long the leave transition in onboarding.css runs before unmounting. */
const LEAVE_MS = 280;

/** Stagger slot for `.onb-item`. */
function slot(i: number): CSSProperties {
  return { "--i": i } as CSSProperties;
}

/** Tracks an element's natural height so its wrapper can ease between step
 *  heights (CSS can't transition to `auto`). Undefined until first measured,
 *  so the first paint is never animated. */
function useMeasuredHeight(active: boolean) {
  const ref = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState<number>();
  useEffect(() => {
    const node = ref.current;
    if (!active || !node) return;
    const observer = new ResizeObserver(() => setHeight(node.offsetHeight));
    observer.observe(node);
    return () => observer.disconnect();
  }, [active]);
  return { ref, height };
}

export function Onboarding() {
  const { t } = useTranslation("settings");
  // Undecided (null) until we read localStorage client-side, so we never flash
  // the overlay before knowing whether it's already been seen.
  const [show, setShow] = useState<boolean | null>(null);
  const [step, setStep] = useState<Step>(0);
  const [direction, setDirection] = useState<"forward" | "back">("forward");
  const [leaving, setLeaving] = useState(false);
  const [detection, setDetection] = useState<Detection | null>(null);
  const [selection, setSelection] = useState<Record<BackendId, boolean> | null>(
    null,
  );
  const [keySaved, setKeySaved] = useState(false);
  const [deepseekKey, setDeepseekKey] = useState("");
  const [savingKey, setSavingKey] = useState(false);
  const [keyError, setKeyError] = useState<string | null>(null);
  const { ref: contentRef, height } = useMeasuredHeight(show === true);

  useEffect(() => {
    let seen = false;
    try {
      seen = localStorage.getItem(ONBOARDING_KEY) === "1";
    } catch {
      seen = false;
    }
    setShow(!seen);
  }, []);

  useEffect(() => {
    if (show !== true) return;
    let cancelled = false;
    Promise.all([
      api.getCliAgentSettings().catch(() => null),
      api.getCliRuntimeStatus().catch(() => null),
      api.listApiKeys().catch(() => [] as string[]),
      api.listCustomProviders().catch(() => []),
    ]).then(([saved, cli, keys, custom]) => {
      if (cancelled) return;
      const next: Detection = {
        saved: { ...DEFAULT_CLI_AGENT_SETTINGS, ...saved },
        cli,
        cetusReady:
          keys.includes("deepseek") ||
          custom.some((provider) => provider.models.length > 0),
      };
      setDetection(next);
      setSelection(initialSelection(next));
    });
    return () => {
      cancelled = true;
    };
  }, [show]);

  // Probe statuses only once the permissions step is on screen.
  const { statuses, onChanged, allGranted } = usePermissionStatuses(
    show === true && step === 1,
  );

  const cetusReady = keySaved || detection?.cetusReady === true;
  // Working runtimes first, so the rows that matter lead the list.
  const rows = useMemo(() => {
    if (!detection) return [];
    return BACKENDS.map((backend) => ({
      backend,
      state: rowState(backend.id, detection, cetusReady),
    })).sort(
      (a, b) => Number(b.state === "ready") - Number(a.state === "ready"),
    );
  }, [detection, cetusReady]);
  const selectedCount = selection
    ? Object.values(selection).filter(Boolean).length
    : 0;

  function go(next: Step) {
    setDirection(next > step ? "forward" : "back");
    setStep(next);
  }

  function finish() {
    if (leaving) return;
    markDone();
    setLeaving(true);
    window.setTimeout(() => setShow(false), LEAVE_MS);
  }

  /** Persist the picked runtimes, then move on. Re-reads the settings so the
   *  write only touches the enable flags. A failed save is not worth blocking
   *  first run on — Settings › Runtimes offers the same switches. */
  async function saveRuntimesAndContinue() {
    go(1);
    if (!selection) return;
    try {
      const current = {
        ...DEFAULT_CLI_AGENT_SETTINGS,
        ...(await api.getCliAgentSettings()),
      };
      const next = BACKENDS.reduce<CliAgentSettings>(
        (acc, { id }) => ({ ...acc, ...runtimeEnabledPatch(id, selection[id]) }),
        current,
      );
      await api.setCliAgentSettings(next);
    } catch {
      /* best-effort */
    }
  }

  async function saveDeepseekKey() {
    const key = deepseekKey.trim();
    if (!key) return;
    setSavingKey(true);
    setKeyError(null);
    try {
      await api.setApiKey("deepseek", key);
      setKeySaved(true);
      setDeepseekKey("");
    } catch (error) {
      setKeyError(String(error));
    } finally {
      setSavingKey(false);
    }
  }

  if (show !== true) return null;

  const keyOpen = selection?.pi === true && !!detection && !cetusReady;

  return (
    <div
      className="onb-root fixed inset-0 z-[60] flex items-center justify-center p-4"
      data-leaving={leaving}
    >
      <div className="onb-card w-full max-w-[40rem]">
        <div className="onb-resize" style={{ height }}>
          <div ref={contentRef} className="px-9 pt-8 pb-7">
            <header className="flex items-center justify-between">
              <span className="flex items-center gap-2">
                <CetusIcon className="size-6" />
                <span className="font-serif text-[1.375rem] leading-none font-semibold italic">
                  cetus
                </span>
              </span>
              <span className="text-xs tabular-nums text-muted-foreground/70">
                {step + 1} / 2
              </span>
            </header>

            {/* Keyed by step: each one remounts and settles in. */}
            <div key={step} className="onb-step mt-9" data-dir={direction}>
              {step === 0 ? (
                <>
                  <h1 className="onb-title">{t("onboarding.welcome.title")}</h1>
                  <p className="mt-2.5 max-w-md text-sm leading-relaxed text-muted-foreground">
                    {t("onboarding.welcome.subtitle")}
                  </p>

                  {!detection || !selection ? (
                    <div className="mt-7 flex h-[13.5rem] items-center justify-center">
                      <Spinner className="size-4 text-muted-foreground" />
                    </div>
                  ) : (
                    <div className="mt-7 grid grid-cols-2 gap-2.5 sm:grid-cols-4">
                      {rows.map(({ backend, state }, i) => {
                        const checked = selection[backend.id];
                        const locked = checked && selectedCount <= 1;
                        return (
                          <button
                            key={backend.id}
                            type="button"
                            role="switch"
                            aria-checked={checked}
                            aria-label={t("runtimes.enabled", {
                              runtime: backend.label,
                            })}
                            data-testid={`onboarding-runtime-${backend.id}`}
                            data-on={checked}
                            title={
                              locked ? t("runtimes.lastEnabled") : undefined
                            }
                            className="lift-tile onb-item flex flex-col px-3.5 pt-3.5 pb-3"
                            style={slot(i)}
                            onClick={() => {
                              if (locked) return;
                              setSelection({
                                ...selection,
                                [backend.id]: !checked,
                              });
                            }}
                          >
                            <span className="flex items-start justify-between">
                              <span className="lift-mark flex size-6 items-center justify-center">
                                <backend.icon className="size-6" />
                              </span>
                              <span className="onb-tick">
                                <Check className="size-2.5" strokeWidth={3.5} />
                              </span>
                            </span>
                            <span className="mt-5 block text-[0.8125rem] leading-snug font-medium">
                              {backend.label}
                            </span>
                            <RuntimeStatus state={state} />
                          </button>
                        );
                      })}
                    </div>
                  )}

                  <div
                    className="onb-reveal"
                    data-open={keyOpen}
                    inert={!keyOpen}
                  >
                    <div>
                      <div className="pt-3">
                        <div className="onb-field">
                          <input
                            id="onboarding-deepseek-key"
                            type="password"
                            value={deepseekKey}
                            onChange={(event) =>
                              setDeepseekKey(event.target.value)
                            }
                            onKeyDown={(event) => {
                              if (event.key === "Enter") saveDeepseekKey();
                            }}
                            placeholder={t("onboarding.runtime.deepseekKey")}
                            aria-label={t("onboarding.runtime.deepseekKey")}
                          />
                          <button
                            type="button"
                            className="onb-ink onb-ink-quiet h-6 px-2.5 text-[0.6875rem]"
                            onClick={saveDeepseekKey}
                            disabled={!deepseekKey.trim() || savingKey}
                          >
                            {savingKey && <Spinner className="size-3" />}
                            {t("onboarding.runtime.save")}
                          </button>
                        </div>
                        {keyError && (
                          <p className="mt-2 px-3.5 text-xs text-destructive">
                            {keyError}
                          </p>
                        )}
                        <p className="mt-2 px-3.5 text-xs leading-relaxed text-muted-foreground">
                          {t("onboarding.runtime.keyNote")}
                        </p>
                      </div>
                    </div>
                  </div>
                </>
              ) : (
                <>
                  <h1 className="onb-title">
                    {t("onboarding.permissions.title")}
                  </h1>
                  <p className="mt-2.5 max-w-md text-sm leading-relaxed text-muted-foreground">
                    {t("onboarding.permissions.subtitle")}
                  </p>

                  <div className="mt-7 flex flex-col gap-2">
                    {APPLICABLE_PERMISSIONS.map((p, i) => (
                      <PermissionTile
                        key={p.id}
                        meta={p}
                        status={statuses[p.id]}
                        onChanged={onChanged}
                        style={slot(i)}
                      />
                    ))}
                  </div>
                </>
              )}
            </div>

            <footer className="mt-8 flex items-center justify-between gap-6">
              <p className="max-w-[19rem] text-xs leading-relaxed text-muted-foreground/80">
                {step === 0
                  ? t("onboarding.runtime.note")
                  : t("onboarding.permissions.note")}
              </p>
              <div className="flex shrink-0 items-center gap-1">
                <button
                  type="button"
                  className="onb-link h-9 px-3 text-sm"
                  onClick={step === 0 ? finish : () => go(0)}
                >
                  {step === 0 ? t("onboarding.skip") : t("onboarding.back")}
                </button>
                {step === 0 ? (
                  <button
                    type="button"
                    className="onb-ink h-9 pr-3.5 pl-4 text-sm"
                    onClick={saveRuntimesAndContinue}
                    disabled={!selection}
                  >
                    {t("onboarding.welcome.start")}
                    <ArrowRight className="onb-arrow size-3.5" />
                  </button>
                ) : (
                  <button
                    type="button"
                    className="onb-ink h-9 px-4 text-sm"
                    onClick={finish}
                  >
                    {allGranted && <Check className="size-3.5" />}
                    {t("onboarding.done")}
                  </button>
                )}
              </div>
            </footer>
          </div>
        </div>
      </div>
    </div>
  );
}

function RuntimeStatus({ state }: { state: RowState }) {
  const { t } = useTranslation("settings");
  if (state === "unknown") return <span className="mt-auto block h-4 pt-0.5" />;
  const label = {
    ready: t("onboarding.runtime.ready"),
    notInstalled: t("onboarding.runtime.notInstalled"),
    notSignedIn: t("runtimes.codexNotSignedIn"),
    needsKey: t("onboarding.runtime.keyOptional"),
  }[state];
  return (
    <span
      title={
        state === "notSignedIn" ? t("runtimes.codexNotSignedIn.hint") : undefined
      }
      className={cn(
        "mt-auto flex items-center gap-1.5 pt-0.5 text-[0.6875rem]",
        state === "notSignedIn"
          ? "text-amber-600 dark:text-amber-400"
          : "text-muted-foreground",
      )}
    >
      {state === "ready" && <span className="onb-ready-dot" />}
      <span className="truncate">{label}</span>
    </span>
  );
}

/** One OS permission in the onboarding's own dress: a well that lifts into a
 *  key once granted. Same calls and copy as the Settings → Permissions row. */
function PermissionTile({
  meta,
  status,
  onChanged,
  style,
}: {
  meta: PermissionMeta;
  status: PermStatus | undefined;
  onChanged: (id: PermissionId, status: PermStatus) => void;
  style: CSSProperties;
}) {
  const { t } = useTranslation("settings");
  const [busy, setBusy] = useState(false);
  const granted = status === "granted";

  async function grant() {
    setBusy(true);
    try {
      onChanged(meta.id, await requestPermission(meta.id));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div
      className="lift-tile onb-item flex items-center gap-3.5 py-3 pr-3.5 pl-4"
      data-on={granted}
      data-granted={granted}
      style={style}
    >
      <meta.icon className="size-[1.125rem] shrink-0" />
      <div className="min-w-0 flex-1">
        <p className="text-[0.8125rem] font-medium text-foreground">
          {t(meta.labelKey)}
        </p>
        <p className="mt-0.5 text-xs leading-snug text-muted-foreground">
          {t(meta.descKey)}
        </p>
      </div>
      {granted ? (
        <span className="flex shrink-0 items-center gap-1.5 text-xs text-muted-foreground">
          {t("permissions.status.granted")}
          <span className="onb-tick">
            <Check className="size-2.5" strokeWidth={3.5} />
          </span>
        </span>
      ) : (
        <span className="flex shrink-0 items-center gap-1">
          {meta.canOpenSettings && (
            <button
              type="button"
              className="onb-link h-7 px-2 text-xs"
              onClick={() => openPermissionSettings(meta.id)}
            >
              {t("permissions.openSettings")}
            </button>
          )}
          <button
            type="button"
            className="onb-ink h-7 px-3 text-xs"
            onClick={grant}
            disabled={busy}
          >
            {t("permissions.grant")}
          </button>
        </span>
      )}
    </div>
  );
}
