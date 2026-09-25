import { useEffect, useMemo, useState } from 'react';
import { useSearchParams } from 'react-router-dom';

import { DataTable } from '../../components/data/DataTable';
import type { Column } from '../../components/data/DataTable';
import { Pagination, PerPageSelect } from '../../components/data/Pagination';
import { AuditOutcomeBadge, EmptyValue } from '../../components/ui/Badge';
import { Button, ButtonAnchor } from '../../components/ui/Button';
import { EmptyState, ErrorPanel, LoadingPanel, PageHeader, Spinner } from '../../components/ui/Feedback';
import { SelectField, TextField } from '../../components/ui/Field';
import { GlassCard } from '../../components/ui/GlassCard';
import { RelativeTime } from '../../components/ui/RelativeTime';
import { useAuditLog } from '../../hooks/useBroker';
import { errorMessage, queryString } from '../../lib/api';
import type { AuditEntry, AuditFilterValues } from '../../types/broker';

const FILTER_KEYS: Array<keyof AuditFilterValues> = ['from', 'to', 'actor', 'action', 'target', 'outcome'];
const DEFAULT_PER_PAGE = 25;

const OUTCOME_OPTIONS = [
  { value: '', label: 'Any outcome' },
  { value: 'success', label: 'Succeeded' },
  { value: 'failure', label: 'Failed' },
  { value: 'denied', label: 'Denied' },
];

// Suggestions for the action filter. A value ending in a dot matches every action under it.
const ACTION_SUGGESTIONS = [
  'vm.', 'vm.start', 'vm.stop', 'vm.restart', 'vm.drain', 'vm.undrain', 'vm.return', 'vm.release',
  'vm.delete', 'vm.add', 'vm.update_attributes', 'vm.maintenance', 'vm.cleanup_retry', 'vm.power_sync',
  'vm.power_corrected', 'vm.release_expired', 'vm.cleanup_completed', 'vm.drain_completed',
  'scaling.', 'scaling.power_on', 'scaling.power_off', 'scaling.deallocate', 'scaling.rule_update',
  'settings.', 'settings.update', 'settings.apply', 'audit.purge', 'host.heartbeat',
  'session.', 'session.signout', 'session.message', 'user.', 'user.reset_profile_requested',
  'user.reset_profile_applied', 'user.reset_profile_cancelled',
];

function readInt(value: string | null, fallback: number, max: number) {
  const parsed = Number.parseInt(value ?? '', 10);
  return Number.isNaN(parsed) ? fallback : Math.min(max, Math.max(1, parsed));
}

/** Filters and paging live in the URL, so a filtered view can be bookmarked and shared. */
function useAuditQuery() {
  const [searchParams, setSearchParams] = useSearchParams();

  const filters = useMemo<AuditFilterValues>(
    () => ({
      from: searchParams.get('from') ?? '',
      to: searchParams.get('to') ?? '',
      actor: searchParams.get('actor') ?? '',
      action: searchParams.get('action') ?? '',
      target: searchParams.get('target') ?? '',
      outcome: (searchParams.get('outcome') ?? '') as AuditFilterValues['outcome'],
    }),
    [searchParams],
  );
  const page = readInt(searchParams.get('page'), 1, Number.MAX_SAFE_INTEGER);
  const perPage = readInt(searchParams.get('per_page'), DEFAULT_PER_PAGE, 200);

  function update(next: Record<string, string | number | undefined>) {
    setSearchParams(
      (current) => {
        const params = new URLSearchParams(current);
        for (const [key, value] of Object.entries(next)) {
          if (value === undefined || value === '') {
            params.delete(key);
          } else {
            params.set(key, String(value));
          }
        }
        return params;
      },
      { replace: true },
    );
  }

  const filterQuery = queryString({ ...filters });

  return {
    filters,
    page,
    perPage,
    filterQuery,
    search: queryString({ ...filters, page, per_page: perPage }),
    setFilters: (next: AuditFilterValues) => update({ ...next, page: undefined }),
    setPage: (next: number) => update({ page: next }),
    setPerPage: (next: number) => update({ per_page: next, page: undefined }),
  };
}

const ACTOR_TYPE_LABEL: Record<AuditEntry['ActorType'], string> = {
  user: 'User',
  service: 'Service identity',
  system: 'Broker',
};

const OutcomeBadge = AuditOutcomeBadge;

const COLUMNS: Array<Column<AuditEntry>> = [
  {
    key: 'when',
    header: 'When (UTC)',
    className: 'font-mono text-xs whitespace-nowrap',
    render: (entry) => <RelativeTime value={entry.OccurredAtUtc} showAbsolute />,
  },
  {
    key: 'actor',
    header: 'Who',
    value: (entry) => entry.ActorName ?? entry.ActorOid,
    render: (entry) =>
      entry.ActorName || entry.ActorOid ? (
        <span className="flex flex-col gap-0.5">
          <span className="font-medium break-all">{entry.ActorName ?? entry.ActorOid}</span>
          <span className="text-xs text-muted">{ACTOR_TYPE_LABEL[entry.ActorType] ?? entry.ActorType}</span>
        </span>
      ) : (
        <span className="font-medium">{ACTOR_TYPE_LABEL[entry.ActorType] ?? entry.ActorType}</span>
      ),
  },
  {
    key: 'action',
    header: 'Action',
    value: (entry) => entry.Action,
    className: 'font-mono text-xs whitespace-nowrap',
    render: (entry) => entry.Action,
  },
  {
    key: 'target',
    header: 'Target',
    value: (entry) => entry.TargetId,
    className: 'text-xs',
    render: (entry) =>
      entry.TargetId ? (
        <span>
          <span className="text-muted">{entry.TargetType ?? 'target'}</span>{' '}
          <span className="font-semibold break-all">{entry.TargetId}</span>
        </span>
      ) : (
        <EmptyValue />
      ),
  },
  {
    key: 'outcome',
    header: 'Outcome',
    value: (entry) => entry.Outcome,
    render: (entry) => <OutcomeBadge outcome={entry.Outcome} />,
  },
  {
    key: 'detail',
    header: 'Detail',
    className: 'text-xs',
    render: (entry) =>
      entry.Detail ? (
        <details>
          <summary className="cursor-pointer text-muted">View</summary>
          <pre className="mt-1 mb-0 max-w-[48ch] overflow-auto rounded-[var(--radius-glass-sm)] bg-[var(--lb-neutral-bg)] p-2 text-xs whitespace-pre-wrap">
            {JSON.stringify(entry.Detail, null, 2)}
          </pre>
          {entry.CorrelationId ? (
            <p className="mt-1 mb-0 text-muted">
              Correlation <span className="font-mono">{entry.CorrelationId}</span>
            </p>
          ) : null}
        </details>
      ) : (
        <EmptyValue />
      ),
  },
];

export function AuditLog() {
  const query = useAuditQuery();
  const { data, isPending, isFetching, error } = useAuditLog(query.search);
  const [draft, setDraft] = useState<AuditFilterValues>(query.filters);

  // The form follows the URL, so back and forward navigation restore what is shown.
  useEffect(() => {
    setDraft(query.filters);
  }, [query.filters]);

  function set<K extends keyof AuditFilterValues>(key: K, value: AuditFilterValues[K]) {
    setDraft((current) => ({ ...current, [key]: value }));
  }

  function apply(event: React.FormEvent) {
    event.preventDefault();
    query.setFilters(
      Object.fromEntries(FILTER_KEYS.map((key) => [key, String(draft[key]).trim()])) as unknown as AuditFilterValues,
    );
  }

  const filtered = FILTER_KEYS.some((key) => query.filters[key]);

  return (
    <>
      <PageHeader
        title="Audit log"
        subtitle="Who changed what: every portal action, every denied attempt, and the changes the broker makes on its own."
        icon="shield"
        actions={
          <ButtonAnchor href={`/api/ui/audit/export.csv${query.filterQuery}`} size="sm" icon="arrow-down" download>
            Export CSV
          </ButtonAnchor>
        }
      />

      <GlassCard className="mb-4 p-4">
        <form onSubmit={apply} noValidate aria-label="Filter the audit log">
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-6">
            <TextField label="From (UTC)" type="date" value={draft.from} onChange={(event) => set('from', event.target.value)} />
            <TextField label="To (UTC)" type="date" value={draft.to} onChange={(event) => set('to', event.target.value)} />
            <TextField
              label="Who"
              placeholder="Name or object ID"
              value={draft.actor}
              onChange={(event) => set('actor', event.target.value)}
            />
            <TextField
              label="Action"
              placeholder="vm. for every VM action"
              list="lb-audit-actions"
              value={draft.action}
              onChange={(event) => set('action', event.target.value)}
            />
            <TextField
              label="Target"
              placeholder="Hostname or rule"
              value={draft.target}
              onChange={(event) => set('target', event.target.value)}
            />
            <SelectField
              label="Outcome"
              value={draft.outcome}
              options={OUTCOME_OPTIONS}
              onChange={(event) => set('outcome', event.target.value as AuditFilterValues['outcome'])}
            />
          </div>
          <datalist id="lb-audit-actions">
            {ACTION_SUGGESTIONS.map((action) => (
              <option key={action} value={action} />
            ))}
          </datalist>
          <div className="mt-3 flex flex-wrap items-center gap-2">
            <Button type="submit" variant="primary" size="sm" icon="funnel">
              Apply filters
            </Button>
            {filtered ? (
              <Button
                size="sm"
                variant="ghost"
                onClick={() => query.setFilters({ from: '', to: '', actor: '', action: '', target: '', outcome: '' })}
              >
                Clear
              </Button>
            ) : null}
            {isFetching && !isPending ? <Spinner label="Updating" /> : null}
          </div>
        </form>
      </GlassCard>

      {isPending ? <LoadingPanel label="Loading the audit log" /> : null}

      {error ? <ErrorPanel message={errorMessage(error, 'Unable to retrieve the audit log.')} /> : null}

      {data && data.items.length === 0 ? (
        <EmptyState
          title={filtered ? 'Nothing matches these filters' : 'No audit entries yet'}
          message={
            filtered
              ? 'Widen the date range or clear a filter. An action filter ending in a dot, such as vm., matches every action under it.'
              : 'Entries appear here as soon as someone acts on a host, a scaling rule or the host settings, and when the broker scales or cleans up on its own.'
          }
          icon="shield"
        />
      ) : null}

      {data && data.items.length > 0 ? (
        <>
          <DataTable
            columns={COLUMNS}
            rows={data.items}
            rowKey={(entry) => entry.AuditId}
            noun="entries"
            caption="Audit entries, newest first"
          />
          <div className="mt-3 flex flex-wrap items-center justify-between gap-3">
            <span className="text-xs text-muted">
              {data.total} {data.total === 1 ? 'entry' : 'entries'}, newest first
            </span>
            <div className="flex flex-wrap items-center gap-3">
              <PerPageSelect perPage={query.perPage} onPerPageChange={query.setPerPage} />
              <Pagination page={data.page} totalPages={data.totalPages} onPageChange={query.setPage} />
            </div>
          </div>
        </>
      ) : null}
    </>
  );
}
