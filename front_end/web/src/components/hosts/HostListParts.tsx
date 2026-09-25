import { useSyncExternalStore } from 'react';

import { classNames } from '../../lib/format';
import { Icon } from '../Icon';
import { Button } from '../ui/Button';
import { Checkbox } from '../ui/Field';
import type { BulkRun } from '../../hooks/useBulkHostActions';
import type { VmListSort, VmListStatus } from '../../types/broker';

export const STATUS_CHIPS: Array<{ key: VmListStatus; label: string }> = [
  { key: 'all', label: 'All hosts' },
  { key: 'ready', label: 'Ready' },
  { key: 'in-use', label: 'In use' },
  { key: 'released', label: 'Released' },
  { key: 'maintenance', label: 'Maintenance' },
  { key: 'draining', label: 'Draining' },
  { key: 'unreachable', label: 'Unreachable' },
  { key: 'off', label: 'Powered off' },
  { key: 'cleanup', label: 'Cleanup pending' },
];

export function StatusChips({
  counts,
  active,
  onChange,
}: {
  counts: Partial<Record<VmListStatus, number>> | undefined;
  active: VmListStatus;
  onChange: (status: VmListStatus) => void;
}) {
  return (
    <div role="group" aria-label="Show hosts" className="flex flex-wrap gap-1.5">
      {STATUS_CHIPS.map((chip) => {
        const pressed = chip.key === active;
        const count = counts?.[chip.key];
        return (
          <button
            key={chip.key}
            type="button"
            aria-pressed={pressed}
            disabled={!pressed && chip.key !== 'all' && count === 0}
            onClick={() => onChange(chip.key)}
            className={classNames(
              'lb-btn px-2.5 py-1 text-xs disabled:opacity-40',
              pressed
                ? 'border-transparent bg-[var(--lb-brand)] text-[var(--lb-on-brand)]'
                : 'border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] text-ink hover:border-[var(--lb-brand)]',
            )}
          >
            {chip.label}
            {count !== undefined ? <span className="tabular-nums opacity-80">{count}</span> : null}
          </button>
        );
      })}
    </div>
  );
}

export type OptionalColumn = 'ip' | 'os' | 'agent' | 'settings' | 'heartbeat' | 'sessions' | 'vmid' | 'updated';

export const OPTIONAL_COLUMNS: Array<{ key: OptionalColumn; label: string; sort?: VmListSort }> = [
  { key: 'ip', label: 'IP address', sort: 'ip' },
  { key: 'os', label: 'OS', sort: 'os' },
  { key: 'agent', label: 'Agent', sort: 'agent' },
  { key: 'settings', label: 'Settings' },
  { key: 'heartbeat', label: 'Last heartbeat', sort: 'heartbeat' },
  { key: 'sessions', label: 'Sessions', sort: 'sessions' },
  { key: 'vmid', label: 'VMID', sort: 'vmid' },
  { key: 'updated', label: 'Last updated', sort: 'updated' },
];

const COLUMNS_KEY = 'lb-host-columns';
const COLUMNS_EVENT = 'lb-host-columns';
const DEFAULT_COLUMNS: OptionalColumn[] = ['ip', 'agent', 'heartbeat'];

function readColumns(): string {
  try {
    const stored = window.localStorage.getItem(COLUMNS_KEY);
    const parsed: unknown = stored ? JSON.parse(stored) : DEFAULT_COLUMNS;
    const keys = OPTIONAL_COLUMNS.map((column) => column.key);
    return Array.isArray(parsed) ? parsed.filter((key): key is OptionalColumn => keys.includes(key)).join(',') : DEFAULT_COLUMNS.join(',');
  } catch {
    return DEFAULT_COLUMNS.join(',');
  }
}

function subscribeColumns(listener: () => void) {
  window.addEventListener(COLUMNS_EVENT, listener);
  return () => window.removeEventListener(COLUMNS_EVENT, listener);
}

/** The optional columns this browser shows, kept between visits. */
export function useHostColumns() {
  const value = useSyncExternalStore(subscribeColumns, readColumns, readColumns);
  const columns = (value ? value.split(',') : []) as OptionalColumn[];
  function setColumns(next: OptionalColumn[]) {
    try {
      window.localStorage.setItem(COLUMNS_KEY, JSON.stringify(next));
    } catch {
      // Not persisted; the choice still applies until the page reloads.
    }
    window.dispatchEvent(new Event(COLUMNS_EVENT));
  }
  return { columns, setColumns };
}

export function ColumnChooser({
  columns,
  onChange,
}: {
  columns: OptionalColumn[];
  onChange: (columns: OptionalColumn[]) => void;
}) {
  return (
    <details className="relative">
      <summary className="lb-btn cursor-pointer list-none border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] px-2.5 py-1.5 text-xs">
        <Icon name="sliders" size={14} />
        Columns
      </summary>
      <div className="lb-glass lb-glass-strong absolute right-0 z-20 mt-1 w-56 p-3">
        <fieldset className="m-0 border-0 p-0">
          <legend className="mb-2 text-xs font-semibold text-muted">Show columns</legend>
          <div className="flex flex-col gap-1.5">
            {OPTIONAL_COLUMNS.map((column) => (
              <Checkbox
                key={column.key}
                label={column.label}
                checked={columns.includes(column.key)}
                onChange={(checked) =>
                  onChange(
                    OPTIONAL_COLUMNS.map((entry) => entry.key).filter((key) =>
                      key === column.key ? checked : columns.includes(key),
                    ),
                  )
                }
              />
            ))}
          </div>
        </fieldset>
      </div>
    </details>
  );
}

export function SortHeader({
  label,
  sortKey,
  sort,
  dir,
  onSort,
  className,
}: {
  label: string;
  sortKey?: VmListSort;
  sort: VmListSort;
  dir: 'asc' | 'desc';
  onSort: (key: VmListSort) => void;
  className?: string;
}) {
  if (!sortKey) {
    return (
      <th scope="col" className={className}>
        {label}
      </th>
    );
  }
  const active = sort === sortKey;
  return (
    <th scope="col" className={className} aria-sort={active ? (dir === 'asc' ? 'ascending' : 'descending') : 'none'}>
      <button
        type="button"
        onClick={() => onSort(sortKey)}
        className="inline-flex items-center gap-1 font-semibold tracking-[inherit] text-inherit uppercase hover:text-[var(--lb-brand)]"
      >
        {label}
        <Icon
          name={active ? (dir === 'asc' ? 'chevron-up' : 'chevron-down') : 'chevron-expand'}
          size={12}
          className={active ? 'text-[var(--lb-brand)]' : 'opacity-50'}
        />
      </button>
    </th>
  );
}

/** What a bulk action did to each host. */
export function BulkResults({ run, onDismiss }: { run: BulkRun; onDismiss: () => void }) {
  const failed = run.outcomes.filter((outcome) => !outcome.ok);
  return (
    <div className="lb-inset mb-3 p-3 text-sm" role="status">
      <div className="flex items-start justify-between gap-2">
        <strong>
          {run.label}: {run.outcomes.length - failed.length} done
          {failed.length ? `, ${failed.length} failed` : ''}
          {run.skipped.length ? `, ${run.skipped.length} skipped` : ''}
        </strong>
        <Button size="sm" variant="ghost" icon="x" onClick={onDismiss} aria-label="Dismiss the results">
          Dismiss
        </Button>
      </div>
      {failed.length ? (
        <ul className="m-0 mt-2 list-none p-0 text-[var(--lb-danger-fg)]">
          {failed.map((outcome) => (
            <li key={outcome.hostname}>
              <span className="font-medium">{outcome.hostname}</span>: {outcome.message}
            </li>
          ))}
        </ul>
      ) : null}
      {run.skipped.length ? (
        <p className="m-0 mt-2 text-xs text-muted">Skipped: {run.skipped.join(', ')}.</p>
      ) : null}
    </div>
  );
}
