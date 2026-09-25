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

/**
 * How long ago something happened, from an age in seconds the broker computed
 * against its own clock, so no time zone is ever guessed.
 */
export function formatAge(seconds: number | null | undefined): string {
  if (seconds === null || seconds === undefined || Number.isNaN(seconds)) {
    return DASH;
  }
  if (seconds < 45) {
    return 'just now';
  }
  if (seconds < 90) {
    return '1 min ago';
  }
  if (seconds < 3600) {
    return `${Math.round(seconds / 60)} min ago`;
  }
  if (seconds < 86400) {
    const hours = Math.round(seconds / 3600);
    return `${hours} hour${hours === 1 ? '' : 's'} ago`;
  }
  const days = Math.round(seconds / 86400);
  return `${days} day${days === 1 ? '' : 's'} ago`;
}

/**
 * An ISO-8601 UTC timestamp from the newer endpoints, shown as
 * 'YYYY-MM-DD HH:MM:SS UTC'. Anything else is shown as sent.
 */
export function formatUtc(value: string | null | undefined): string {
  if (isBlank(value)) {
    return DASH;
  }
  const text = String(value);
  const match = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})(?:\.\d+)?Z$/.exec(text);
  return match ? `${match[1]} ${match[2]} UTC` : text;
}

export function formatMegabytes(value: number | null | undefined): string {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return DASH;
  }
  return value >= 1024 ? `${(value / 1024).toFixed(1)} GB` : `${value} MB`;
}

/** A length of time, such as how long a session has been idle: "45 s", "12 min", "2 h 5 min". */
export function formatDuration(seconds: number | null | undefined): string {
  if (seconds === null || seconds === undefined || Number.isNaN(seconds)) {
    return DASH;
  }
  const total = Math.max(0, Math.round(seconds));
  if (total < 60) {
    return `${total} s`;
  }
  const minutes = Math.round(total / 60);
  if (minutes < 60) {
    return `${minutes} min`;
  }
  if (minutes < 24 * 60) {
    const hours = Math.floor(minutes / 60);
    const rest = minutes % 60;
    return rest ? `${hours} h ${rest} min` : `${hours} h`;
  }
  const hours = Math.round(minutes / 60);
  const days = Math.floor(hours / 24);
  const rest = hours % 24;
  return rest ? `${days} d ${rest} h` : `${days} d`;
}
