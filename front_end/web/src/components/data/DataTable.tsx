import { useId, useMemo, useState } from 'react';
import type { ReactNode } from 'react';

import { classNames } from '../../lib/format';
import { Icon } from '../Icon';
import { GlassCard } from '../ui/GlassCard';

export type SortType = 'text' | 'number' | 'date';

export interface Column<T> {
  /** Stable key, also used as the React key for the cell. */
  key: string;
  header: ReactNode;
  render: (row: T) => ReactNode;
  /** Omit to make the column unsortable. */
  sort?: SortType;
  /**
   * Value used for sorting and for the search box. Needed whenever the cell
   * renders a badge or a link rather than plain text.
   */
  value?: (row: T) => string | number | null | undefined;
  className?: string;
  headerClassName?: string;
}

type SortState = { key: string; direction: 'asc' | 'desc' } | null;

function cellText<T>(column: Column<T>, row: T): string {
  if (column.value) {
    const value = column.value(row);
    return value === null || value === undefined ? '' : String(value);
  }
  const rendered = column.render(row);
  return typeof rendered === 'string' || typeof rendered === 'number' ? String(rendered) : '';
}

function compare<T>(column: Column<T>, a: T, b: T): number {
  const left = cellText(column, a);
  const right = cellText(column, b);

  if (column.sort === 'number') {
    const nl = Number.parseFloat(left);
    const nr = Number.parseFloat(right);
    const safeLeft = Number.isNaN(nl) ? Number.NEGATIVE_INFINITY : nl;
    const safeRight = Number.isNaN(nr) ? Number.NEGATIVE_INFINITY : nr;
    return safeLeft - safeRight;
  }

  if (column.sort === 'date') {
    // Broker timestamps are 'YYYY-MM-DD HH:MM:SS'; the space needs replacing for
    // Date.parse to accept them consistently across engines.
    const dl = Date.parse(left.replace(' ', 'T'));
    const dr = Date.parse(right.replace(' ', 'T'));
    const safeLeft = Number.isNaN(dl) ? Number.NEGATIVE_INFINITY : dl;
    const safeRight = Number.isNaN(dr) ? Number.NEGATIVE_INFINITY : dr;
    return safeLeft - safeRight;
  }

  return left.localeCompare(right, undefined, { numeric: true, sensitivity: 'base' });
}

export interface DataTableProps<T> {
  columns: Array<Column<T>>;
  rows: T[];
  rowKey: (row: T) => string | number;
  /** Shows the search box and the "shown of total" counter. */
  searchable?: boolean;
  searchPlaceholder?: string;
  /** Plural noun for the counter, for example "VMs". */
  noun?: string;
  emptyMessage?: string;
  caption?: string;
}

/**
 * Sortable, filterable table.
 *
 * Replaces the `data-lb-sort` / `data-lb-value` / `data-lb-filter-target` hooks
 * that app.js used to wire up against the Jinja markup. Filtering and sorting are
 * client-side and apply to the rows currently on screen, which for the paged
 * views means the current page, exactly as before.
 */
export function DataTable<T>({
  columns,
  rows,
  rowKey,
  searchable = false,
  searchPlaceholder = 'Search…',
  noun = 'rows',
  emptyMessage = 'No results.',
  caption,
}: DataTableProps<T>) {
  const [query, setQuery] = useState('');
  const [sort, setSort] = useState<SortState>(null);
  const searchId = useId();
  const countId = useId();

  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) {
      return rows;
    }
    return rows.filter((row) =>
      columns.some((column) => cellText(column, row).toLowerCase().includes(needle)),
    );
  }, [columns, rows, query]);

  const sorted = useMemo(() => {
    if (!sort) {
      return filtered;
    }
    const column = columns.find((candidate) => candidate.key === sort.key);
    if (!column?.sort) {
      return filtered;
    }
    const factor = sort.direction === 'asc' ? 1 : -1;
    return [...filtered].sort((a, b) => compare(column, a, b) * factor);
  }, [columns, filtered, sort]);

  function toggleSort(column: Column<T>) {
    if (!column.sort) {
      return;
    }
    setSort((current) =>
      current?.key === column.key
        ? { key: column.key, direction: current.direction === 'asc' ? 'desc' : 'asc' }
        : { key: column.key, direction: 'asc' },
    );
  }

  const counter =
    filtered.length === rows.length
      ? `${rows.length} ${noun}`
      : `${filtered.length} shown of ${rows.length} ${noun}`;

  return (
    <div>
      {searchable ? (
        <div className="mb-3 flex flex-wrap items-center justify-between gap-3">
          <div className="relative min-w-0 flex-1 sm:max-w-sm">
            <label htmlFor={searchId} className="sr-only">
              {searchPlaceholder}
            </label>
            <Icon
              name="search"
              size={15}
              className="pointer-events-none absolute top-1/2 left-2.5 -translate-y-1/2 text-subtle"
            />
            <input
              id={searchId}
              type="search"
              className="lb-field pl-8 text-sm"
              placeholder={searchPlaceholder}
              autoComplete="off"
              value={query}
              aria-describedby={countId}
              onChange={(event) => setQuery(event.target.value)}
            />
          </div>
          <span id={countId} className="text-xs text-muted" aria-live="polite">
            {counter}
          </span>
        </div>
      ) : null}

      <GlassCard className="overflow-hidden">
        <div className="max-h-[70vh] overflow-auto">
          <table className="lb-table">
            {caption ? <caption className="sr-only">{caption}</caption> : null}
            <thead>
              <tr>
                {columns.map((column) => {
                  const active = sort?.key === column.key;
                  const ariaSort = !column.sort
                    ? undefined
                    : active
                      ? sort.direction === 'asc'
                        ? 'ascending'
                        : 'descending'
                      : 'none';

                  return (
                    <th
                      key={column.key}
                      scope="col"
                      aria-sort={ariaSort}
                      className={column.headerClassName}
                    >
                      {column.sort ? (
                        <button
                          type="button"
                          onClick={() => toggleSort(column)}
                          className="inline-flex items-center gap-1 font-semibold tracking-[inherit] text-inherit uppercase hover:text-[var(--lb-brand)]"
                        >
                          {column.header}
                          <Icon
                            name={
                              active
                                ? sort.direction === 'asc'
                                  ? 'chevron-up'
                                  : 'chevron-down'
                                : 'chevron-expand'
                            }
                            size={12}
                            className={active ? 'text-[var(--lb-brand)]' : 'opacity-50'}
                          />
                        </button>
                      ) : (
                        column.header
                      )}
                    </th>
                  );
                })}
              </tr>
            </thead>
            <tbody>
              {sorted.length === 0 ? (
                <tr>
                  <td colSpan={columns.length} className="py-10 text-center text-sm text-muted">
                    {emptyMessage}
                  </td>
                </tr>
              ) : (
                sorted.map((row) => (
                  <tr key={rowKey(row)}>
                    {columns.map((column) => (
                      <td key={column.key} className={classNames(column.className)}>
                        {column.render(row)}
                      </td>
                    ))}
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </GlassCard>
    </div>
  );
}
