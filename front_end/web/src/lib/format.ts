export const DASH = '\u2014';

/** Render a possibly-empty value without collapsing the row it sits in. */
export function valueOrDash(value: unknown): string {
  if (value === null || value === undefined) {
    return DASH;
  }
  const text = String(value).trim();
  return text === '' ? DASH : text;
}

export function isBlank(value: unknown): boolean {
  return value === null || value === undefined || String(value).trim() === '';
}

/*
 * Broker timestamps arrive as 'YYYY-MM-DD HH:MM:SS' in the database's own time
 * zone, with no offset. They are shown as sent rather than parsed into a Date,
 * because guessing a zone would silently shift every timestamp in the portal.
 */
export function formatTimestamp(value: string | null | undefined): string {
  return valueOrDash(value);
}

/** Sort key for a timestamp cell. Unparseable values sort last. */
export function timestampSortValue(value: string | null | undefined): number {
  if (isBlank(value)) {
    return Number.NEGATIVE_INFINITY;
  }
  const parsed = Date.parse(String(value).replace(' ', 'T'));
  return Number.isNaN(parsed) ? Number.NEGATIVE_INFINITY : parsed;
}

export function formatNumber(value: number | null | undefined): string {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return DASH;
  }
  return value.toLocaleString();
}

export function formatPercent(value: number | null | undefined, fractionDigits = 0): string {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return DASH;
  }
  return `${value.toFixed(fractionDigits)}%`;
}

/** Human-readable duration for the seconds-based host settings fields. */
export function describeSeconds(seconds: number | null | undefined): string {
  if (seconds === null || seconds === undefined || Number.isNaN(seconds)) {
    return DASH;
  }
  if (seconds === 0) {
    return 'disabled';
  }
  if (seconds < 60) {
    return `${seconds} seconds`;
  }
  if (seconds < 3600) {
    const minutes = seconds / 60;
    return `${Number.isInteger(minutes) ? minutes : minutes.toFixed(1)} minutes`;
  }
  const hours = seconds / 3600;
  return `${Number.isInteger(hours) ? hours : hours.toFixed(1)} hours`;
}

export function classNames(...values: Array<string | false | null | undefined>): string {
  return values.filter(Boolean).join(' ');
}
