import { useEffect, useState } from 'react';

const TICK_MS = 1000;

export interface AutoRefresh {
  enabled: boolean;
  setEnabled: (enabled: boolean) => void;
  /** Feed straight into a TanStack Query `refetchInterval`. */
  intervalMs: number | false;
  /** "Off", or a countdown such as "in 12s". */
  status: string;
  secondsRemaining: number;
}

/**
 * Countdown for the dashboard's auto-refresh switch.
 *
 * The Jinja version reloaded the whole page on a timer. Here the countdown is
 * only the visible status; the actual refetch is TanStack Query's, so the page
 * updates in place without losing scroll position or focus.
 */
export function useAutoRefresh(intervalSeconds = 30): AutoRefresh {
  const [enabled, setEnabled] = useState(false);
  const [secondsRemaining, setSecondsRemaining] = useState(intervalSeconds);

  useEffect(() => {
    if (!enabled) {
      setSecondsRemaining(intervalSeconds);
      return;
    }

    const timer = setInterval(() => {
      setSecondsRemaining((current) => (current <= 1 ? intervalSeconds : current - 1));
    }, TICK_MS);

    return () => clearInterval(timer);
  }, [enabled, intervalSeconds]);

  return {
    enabled,
    setEnabled,
    intervalMs: enabled ? intervalSeconds * 1000 : false,
    status: enabled ? `in ${secondsRemaining}s` : 'Off',
    secondsRemaining,
  };
}
