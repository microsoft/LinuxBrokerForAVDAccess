import { formatAge } from './format';

/*
 * Broker times arrive in three shapes: ISO-8601 with a Z from the newer endpoints, RFC 1123
 * ("Wed, 24 Sep 2026 12:00:00 GMT") where Flask serialized a datetime, and the legacy
 * "YYYY-MM-DD HH:MM:SS" from DATETIME columns. The broker runs on Azure SQL, whose clock is
 * UTC, so a time without a zone is read as UTC.
 */
const LEGACY = /^(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}(?::\d{2}(?:\.\d{1,7})?)?)$/;

export function parseBrokerTime(value: string | null | undefined): Date | null {
  if (!value) return null;
  const text = String(value).trim();
  if (!text) return null;

  const legacy = LEGACY.exec(text);
  if (legacy) {
    // JavaScript parses at most milliseconds.
    const time = legacy[2].replace(/(\.\d{3})\d+$/, '$1');
    const parsed = new Date(`${legacy[1]}T${time}Z`);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }

  if (/^\d{4}-\d{2}-\d{2}[T ]/.test(text) || /GMT$|UTC$|[+-]\d{2}:?\d{2}$/.test(text)) {
    const normalized = text
      .replace(/ UTC$/, 'Z')
      .replace(/^(\d{4}-\d{2}-\d{2}) (\d)/, '$1T$2')
      .replace(/(\.\d{3})\d+/, '$1');
    const parsed = new Date(normalized);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }
  return null;
}

/** "YYYY-MM-DD HH:MM:SS UTC", for tooltips and exports. */
export function absoluteUtc(date: Date): string {
  const iso = date.toISOString();
  return `${iso.slice(0, 10)} ${iso.slice(11, 19)} UTC`;
}

/** "5 min ago" or, for a time still to come, "in 5 min". */
export function relativeText(date: Date, now: number): string {
  const seconds = Math.round((now - date.getTime()) / 1000);
  if (seconds >= -60) {
    return formatAge(Math.max(0, seconds));
  }
  return `in ${formatAge(-seconds).replace(' ago', '')}`;
}

/** Sort key for a broker time: unparseable values sort last. */
export function brokerTimeSortValue(value: string | null | undefined): number {
  return parseBrokerTime(value)?.getTime() ?? Number.NEGATIVE_INFINITY;
}
