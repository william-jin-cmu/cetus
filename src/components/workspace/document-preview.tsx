"use client";

import { useEffect, useRef, useState } from "react";
import { Spinner } from "@/components/ui/spinner";
import { useTranslation } from "@/lib/i18n";

export function isWordExt(ext: string): boolean {
  return ext.toLowerCase() === "docx";
}

export function isPresentationExt(ext: string): boolean {
  return ext.toLowerCase() === "pptx";
}

function extOf(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot >= 0 ? name.slice(dot + 1).toLowerCase() : "";
}

export function isWordName(name: string): boolean {
  return isWordExt(extOf(name));
}

export function isPresentationName(name: string): boolean {
  return isPresentationExt(extOf(name));
}

async function fetchBuffer(url: string): Promise<ArrayBuffer> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return response.arrayBuffer();
}

function Loading() {
  const { t } = useTranslation("chat");
  return (
    <div className="flex items-center gap-2 px-5 py-4 text-xs text-muted-foreground">
      <Spinner className="size-3.5" />
      {t("artifact.loading")}
    </div>
  );
}

function Failed({ error }: { error: string }) {
  const { t } = useTranslation("chat");
  return (
    <p className="px-5 py-4 text-xs text-destructive">
      {t("artifact.readFailed", { error })}
    </p>
  );
}

const DOCX_STYLE = `body{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;line-height:1.6;color:#1f2328;max-width:820px;margin:0 auto;padding:40px 48px}img{max-width:100%;height:auto}table{border-collapse:collapse;margin:12px 0}td,th{border:1px solid #d0d7de;padding:4px 8px;vertical-align:top}h1,h2,h3{line-height:1.3}`;

/** .docx rendered to HTML by mammoth (text, headings, lists, tables, inline
 *  images). Layout-level fidelity (columns, headers/footers) is not kept. */
export function DocxPreview({ url, title }: { url: string; title: string }) {
  const [html, setHtml] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    setHtml(null);
    setError(null);
    fetchBuffer(url)
      .then(async (buffer) => {
        // mammoth is large; load it only when a Word file is previewed.
        const { default: mammoth } = await import("mammoth");
        const result = await mammoth.convertToHtml({ arrayBuffer: buffer });
        if (alive) setHtml(result.value);
      })
      .catch((e) => alive && setError(String(e)));
    return () => {
      alive = false;
    };
  }, [url]);

  if (error) return <Failed error={error} />;
  if (html == null) return <Loading />;
  return (
    <iframe
      title={title}
      sandbox=""
      className="h-full min-h-[520px] w-full bg-white"
      srcDoc={`<!doctype html><html><head><meta charset="utf-8"><style>${DOCX_STYLE}</style></head><body>${html}</body></html>`}
    />
  );
}

/** .pptx rendered slide-by-slide (stacked list) by pptx-preview. The library
 *  draws into a DOM node it owns, sized from the container on mount. */
export function PptxPreview({ url }: { url: string }) {
  const hostRef = useRef<HTMLDivElement>(null);
  const [state, setState] = useState<"loading" | "ready" | string>("loading");

  useEffect(() => {
    const host = hostRef.current;
    if (!host) return;
    let alive = true;
    let previewer: { destroy(): void } | null = null;
    setState("loading");
    Promise.all([fetchBuffer(url), import("pptx-preview")])
      .then(async ([buffer, { init }]) => {
        if (!alive) return;
        const width = Math.min(Math.max(host.clientWidth - 48, 320), 1280);
        const p = init(host, {
          width,
          height: Math.max(host.clientHeight, 360),
          mode: "list",
        });
        previewer = p;
        await p.preview(buffer);
        if (alive) setState("ready");
      })
      .catch((e) => alive && setState(String(e)));
    return () => {
      alive = false;
      try {
        previewer?.destroy();
      } catch {
        // destroy on a half-initialised previewer may throw; nothing to keep.
      }
      host.replaceChildren();
    };
  }, [url]);

  return (
    <div className="relative h-full w-full">
      <div
        ref={hostRef}
        // The library paints its scroller black between slides; let the
        // app surface show through instead.
        className="flex h-full w-full justify-center overflow-hidden bg-muted/30 [&_.pptx-preview-wrapper]:!bg-transparent"
      />
      {state === "loading" && (
        <div className="absolute inset-0 bg-background">
          <Loading />
        </div>
      )}
      {state !== "loading" && state !== "ready" && (
        <div className="absolute inset-0 bg-background">
          <Failed error={state} />
        </div>
      )}
    </div>
  );
}
