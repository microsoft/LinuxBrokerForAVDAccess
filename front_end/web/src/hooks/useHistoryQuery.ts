import { useCallback, useMemo } from 'react';
import { useSearchParams } from 'react-router-dom';

import type { HistoryFilterValues } from '../types/broker';

export const DEFAULT_PER_PAGE = 10;
const MAX_PER_PAGE = 200;

export interface HistoryQuery {
  filters: HistoryFilterValues;
  page: number;
  perPage: number;
  /** Query string sent to the BFF, and the cache key for the request. */
  search: string;
  setFilters: (filters: HistoryFilterValues) => void;
  setPage: (page: number) => void;
  setPerPage: (perPage: number) => void;
}

function readInt(value: string | null, fallback: number, min: number, max: number) {
  const parsed = Number.parseInt(value ?? '', 10);
  if (Number.isNaN(parsed)) {
    return fallback;
  }
  return Math.min(max, Math.max(min, parsed));
}

function readFlag(value: string | null) {
  return value === '1' || value === 'true' || value === 'on' || value === 'yes';
}

/**
 * Keeps the history filter bar and pagination in the URL.
 *
 * The Jinja pages stored these in the Flask session and used POST-redirect-GET,
 * which meant two tabs overwrote each other's criteria and a filtered view could
 * not be shared. Query parameters fix both, and the BFF reads the same names.
 */
export function useHistoryQuery(): HistoryQuery {
  const [searchParams, setSearchParams] = useSearchParams();

  const filters = useMemo<HistoryFilterValues>(
    () => ({
      startdate: searchParams.get('startdate') ?? '',
      enddate: searchParams.get('enddate') ?? '',
      limit: searchParams.get('limit') ?? '',
      ignore_dates: readFlag(searchParams.get('ignore_dates')),
      ignore_limit: readFlag(searchParams.get('ignore_limit')),
    }),
    [searchParams],
  );

  const page = readInt(searchParams.get('page'), 1, 1, Number.MAX_SAFE_INTEGER);
  const perPage = readInt(searchParams.get('per_page'), DEFAULT_PER_PAGE, 1, MAX_PER_PAGE);

  const update = useCallback(
    (next: Partial<HistoryFilterValues & { page: number; per_page: number }>) => {
      setSearchParams(
        (current) => {
          const params = new URLSearchParams(current);

          for (const [key, value] of Object.entries(next)) {
            // Unset filters are removed rather than sent as an empty value, which
            // keeps shared links short and matches what the BFF omits.
            if (value === undefined || value === '' || value === false) {
              params.delete(key);
            } else if (value === true) {
              params.set(key, '1');
            } else {
              params.set(key, String(value));
            }
          }

          return params;
        },
        { replace: true },
      );
    },
    [setSearchParams],
  );

  const setFilters = useCallback(
    (next: HistoryFilterValues) => {
      // A new filter always returns to page one; staying on page 9 of a result set
      // that no longer has nine pages just shows an empty table.
      update({ ...next, page: 1 });
    },
    [update],
  );

  const setPage = useCallback((next: number) => update({ page: next }), [update]);

  const setPerPage = useCallback((next: number) => update({ per_page: next, page: 1 }), [update]);

  const search = useMemo(() => {
    const params = new URLSearchParams();
    params.set('page', String(page));
    params.set('per_page', String(perPage));

    if (filters.ignore_dates) {
      params.set('ignore_dates', '1');
    } else {
      if (filters.startdate) params.set('startdate', filters.startdate);
      if (filters.enddate) params.set('enddate', filters.enddate);
    }

    if (filters.ignore_limit) {
      params.set('ignore_limit', '1');
    } else if (filters.limit) {
      params.set('limit', filters.limit);
    }

    return `?${params.toString()}`;
  }, [filters, page, perPage]);

  return { filters, page, perPage, search, setFilters, setPage, setPerPage };
}
