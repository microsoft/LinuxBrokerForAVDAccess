import { useSyncExternalStore } from 'react';

import { DASH, valueOrDash } from '../../lib/format';
import { absoluteUtc, parseBrokerTime, relativeText } from '../../lib/time';

/*
 * One shared clock for every relative time on the page, so a table of a hundred rows sets
 * one timer rather than a hundred. It ticks every 30 seconds while anything listens.
 */
const TICK_MS = 30_000;
const listeners = new Set<() => void>();
let now = Date.now();
let timer: ReturnType<typeof setInterval> | null = null;

function subscribe(listener: () => void) {
  listeners.add(listener);
  if (timer === null) {
    now = Date.now();
    timer = setInterval(() => {
      now = Date.now();
      listeners.forEach((notify) => notify());
    }, TICK_MS);
  }
  return () => {
    listeners.delete(listener);
    if (!listeners.size && timer !== null) {
      clearInterval(timer);
      timer = null;
    }
  };
}

export function useNow() {
  return useSyncExternalStore(subscribe, () => now, () => now);
}

export interface RelativeTimeProps {
  value: string | null | undefined;
  /** Also show the absolute UTC time, for audit and history tables. */
  showAbsolute?: boolean;
  className?: string;
}

/**
 * "5 min ago" in a <time> element, with the absolute UTC time as its tooltip. A value that
 * is not a time is shown as sent.
 */
export function RelativeTime({ value, showAbsolute = false, className }: RelativeTimeProps) {
  const current = useNow();
  const date = parseBrokerTime(value);
  if (!date) {
    return <span className={className}>{value ? valueOrDash(value) : DASH}</span>;
  }

  const absolute = absoluteUtc(date);
  // Temporal history marks the current version as valid until the year 9999.
  if (date.getUTCFullYear() >= 9999) {
    return (
      <span className={className} title="Still in force">
        Current
      </span>
    );
  }
  return (
    <time dateTime={date.toISOString()} title={absolute} className={className}>
      {relativeText(date, current)}
      {showAbsolute ? <span className="block font-mono text-[0.7rem] text-muted">{absolute}</span> : null}
    </time>
  );
}
