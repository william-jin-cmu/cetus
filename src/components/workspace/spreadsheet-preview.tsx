"use client";

import { useEffect, useState } from "react";
import { Spinner } from "@/components/ui/spinner";
import { useTranslation } from "@/lib/i18n";
import { cn } from "@/lib/utils";

/** Workbook formats SheetJS parses that we preview as a grid. */
const SPREADSHEET_EXTS = new Set(["xlsx", "xlsm", "xls", "xlsb", "ods"]);

export function isSpreadsheetExt(ext: string): boolean {
  return SPREADSHEET_EXTS.has(ext.toLowerCase());
}

export function isSpreadsheetName(name: string): boolean {
  const dot = name.lastIndexOf(".");
  return dot >= 0 && isSpreadsheetExt(name.slice(dot + 1));
}

export interface SheetData {
  name: string;
  /** Formatted cell text, row-major, already clipped to the preview limits. */
  rows: string[][];
  /** 0-based sheet coordinates of rows[0][0], so headers match Excel's. */
  startRow: number;
  startCol: number;
  /** Rows / columns in the sheet's used range beyond what `rows` holds. */
  hiddenRows: number;
  hiddenCols: number;
}

interface Limits {
  maxRows: number;
  maxCols: number;
  /** Parse only the first sheet (thumbnails). */
  firstSheetOnly?: boolean;
}

const FULL_LIMITS: Limits = { maxRows: 1000, maxCols: 60 };
const THUMB_LIMITS: Limits = { maxRows: 14, maxCols: 8, firstSheetOnly: true };

async function loadWorkbook(url: string, limits: Limits): Promise<SheetData[]> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  const buffer = await response.arrayBuffer();
  // ~1MB; load only when a spreadsheet is actually previewed.
  const XLSX = await import("xlsx");
  const workbook = XLSX.read(buffer, {
    type: "array",
    // Stop parsing rows past the preview window — big sheets stay cheap.
    sheetRows: limits.maxRows + 1,
    cellDates: true,
    sheets: limits.firstSheetOnly ? 0 : undefined,
  });
  const names = limits.firstSheetOnly
    ? workbook.SheetNames.slice(0, 1)
    : workbook.SheetNames;
  return names.map((name) => {
    const sheet = workbook.Sheets[name];
    const ref = sheet?.["!fullref"] ?? sheet?.["!ref"];
    if (!sheet || !ref) {
      return { name, rows: [], startRow: 0, startCol: 0, hiddenRows: 0, hiddenCols: 0 };
    }
    const full = XLSX.utils.decode_range(ref);
    const used = XLSX.utils.decode_range(sheet["!ref"] ?? ref);
    const totalRows = full.e.r - full.s.r + 1;
    const totalCols = full.e.c - full.s.c + 1;
    const range = {
      s: used.s,
      e: {
        r: Math.min(used.e.r, used.s.r + limits.maxRows - 1),
        c: Math.min(used.e.c, used.s.c + limits.maxCols - 1),
      },
    };
    const raw = XLSX.utils.sheet_to_json(sheet, {
      header: 1,
      range,
      raw: false,
      defval: "",
      blankrows: true,
    }) as unknown[][];
    const width = range.e.c - range.s.c + 1;
    const rows = raw.map((row) => {
      const out = row.map((cell) => (cell == null ? "" : String(cell)));
      while (out.length < width) out.push("");
      return out;
    });
    return {
      name,
      rows,
      startRow: used.s.r,
      startCol: used.s.c,
      hiddenRows: Math.max(0, totalRows - rows.length),
      hiddenCols: Math.max(0, totalCols - width),
    };
  });
}

function useWorkbook(url: string, limits: Limits) {
  const [sheets, setSheets] = useState<SheetData[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    setSheets(null);
    setError(null);
    loadWorkbook(url, limits)
      .then((s) => alive && setSheets(s))
      .catch((e) => alive && setError(String(e)));
    return () => {
      alive = false;
    };
    // limits are module constants; url is the only real dependency.
  }, [url]);

  return { sheets, error };
}

function columnLabel(index: number): string {
  let n = index + 1;
  let label = "";
  while (n > 0) {
    const rem = (n - 1) % 26;
    label = String.fromCharCode(65 + rem) + label;
    n = Math.floor((n - 1) / 26);
  }
  return label;
}

/** Full workbook preview: grid with Excel-style headers and sheet tabs. */
export function SpreadsheetPreview({ url }: { url: string }) {
  const { t } = useTranslation("chat");
  const { sheets, error } = useWorkbook(url, FULL_LIMITS);
  const [active, setActive] = useState(0);

  if (error) {
    return (
      <p className="px-5 py-4 text-xs text-destructive">
        {t("artifact.readFailed", { error })}
      </p>
    );
  }
  if (sheets == null) {
    return (
      <div className="flex items-center gap-2 px-5 py-4 text-xs text-muted-foreground">
        <Spinner className="size-3.5" />
        {t("artifact.loading")}
      </div>
    );
  }
  if (sheets.length === 0) {
    return <p className="px-5 py-4 text-xs text-muted-foreground">No sheets</p>;
  }

  const sheet = sheets[Math.min(active, sheets.length - 1)];
  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="min-h-0 flex-1 overflow-auto">
        <SheetGrid sheet={sheet} />
        {(sheet.hiddenRows > 0 || sheet.hiddenCols > 0) && (
          <p className="px-3 py-2 text-xs text-muted-foreground">
            Showing first {sheet.rows.length} rows
            {sheet.rows[0] ? ` × ${sheet.rows[0].length} columns` : ""}. Open
            the file to see everything.
          </p>
        )}
      </div>
      {sheets.length > 1 && (
        <div
          role="tablist"
          className="flex shrink-0 gap-0.5 overflow-x-auto border-t border-border bg-muted/40 px-2 py-1"
        >
          {sheets.map((s, i) => (
            <button
              key={`${i}:${s.name}`}
              type="button"
              role="tab"
              aria-selected={i === active}
              onClick={() => setActive(i)}
              className={cn(
                "shrink-0 rounded-md px-3 py-1 text-xs transition-colors",
                i === active
                  ? "bg-background font-medium text-foreground shadow-sm"
                  : "text-muted-foreground hover:bg-background/60 hover:text-foreground",
              )}
            >
              {s.name}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

function SheetGrid({ sheet }: { sheet: SheetData }) {
  if (sheet.rows.length === 0) {
    return <p className="px-5 py-4 text-xs text-muted-foreground">Empty sheet</p>;
  }
  const width = sheet.rows[0].length;
  return (
    <table className="border-separate border-spacing-0 text-xs">
      <thead>
        <tr>
          <th className="sticky left-0 top-0 z-20 min-w-10 border-b border-r border-border bg-muted" />
          {Array.from({ length: width }, (_, c) => (
            <th
              key={c}
              className="sticky top-0 z-10 min-w-20 border-b border-r border-border bg-muted px-2 py-1 font-medium text-muted-foreground"
            >
              {columnLabel(sheet.startCol + c)}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {sheet.rows.map((row, r) => (
          <tr key={r}>
            <th className="sticky left-0 z-10 border-b border-r border-border bg-muted px-2 py-1 text-right font-medium tabular-nums text-muted-foreground">
              {sheet.startRow + r + 1}
            </th>
            {row.map((cell, c) => (
              <td
                key={c}
                className="max-w-72 border-b border-r border-border bg-background px-2 py-1 align-top"
                title={cell.length > 40 ? cell : undefined}
              >
                <span className="line-clamp-3 whitespace-pre-wrap break-words">
                  {cell}
                </span>
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

/** Small read-only grid of the first sheet's top-left corner, for tiles. */
export function SpreadsheetThumbnail({
  url,
  fallback,
}: {
  url: string;
  fallback: React.ReactNode;
}) {
  const { sheets, error } = useWorkbook(url, THUMB_LIMITS);
  const sheet = sheets?.[0];
  if (error || !sheet || sheet.rows.length === 0) return <>{fallback}</>;
  return (
    <div className="h-full w-full overflow-hidden bg-card">
      <table className="w-full table-fixed border-collapse text-2xs leading-tight">
        <tbody>
          {sheet.rows.map((row, r) => (
            <tr key={r} className={r === 0 ? "bg-muted/70 font-medium" : undefined}>
              {row.map((cell, c) => (
                <td
                  key={c}
                  className="truncate border-b border-r border-border/70 px-1.5 py-1 text-foreground/80"
                >
                  {cell}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
