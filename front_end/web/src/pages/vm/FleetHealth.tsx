import { Link, useSearchParams } from 'react-router-dom';

import { Breadcrumbs } from '../../components/layout/Breadcrumbs';
import { DataTable } from '../../components/data/DataTable';
import type { Column } from '../../components/data/DataTable';
import { Badge } from '../../components/ui/Badge';
import { ButtonLink } from '../../components/ui/Button';
import { EmptyState, ErrorPanel, LoadingPanel, PageHeader, Spinner } from '../../components/ui/Feedback';
import { Switch } from '../../components/ui/Field';
import { HEALTH_FLAGS, HealthFlagBadge, HealthStatusBadge } from '../../components/ui/HealthBadges';
import { Icon } from '../../components/Icon';
import { useAutoRefresh } from '../../hooks/useAutoRefresh';
import { useFleetHealth } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import { classNames, describeSeconds, formatAge, formatMegabytes, formatUtc, valueOrDash } from '../../lib/format';
import type { FleetHealthSummary, HealthFlag, HostHealth } from '../../types/broker';

type Filter = 'all' | 'attention' | 'off' | HealthFlag;

const FILTERS: Array<{ key: Filter; label: string; count: (summary: FleetHealthSummary) => number }> = [
  { key: 'all', label: 'All hosts', count: (summary) => summary.Total },
  { key: 'attention', label: 'Needs attention', count: (summary) => summary.Attention },
  { key: 'no-heartbeat', label: HEALTH_FLAGS['no-heartbeat'].label, count: (summary) => summary.NoHeartbeat },
  { key: 'stale', label: HEALTH_FLAGS.stale.label, count: (summary) => summary.Stale },
  { key: 'xrdp-down', label: HEALTH_FLAGS['xrdp-down'].label, count: (summary) => summary.XrdpDown },
  { key: 'nfs-unreachable', label: HEALTH_FLAGS['nfs-unreachable'].label, count: (summary) => summary.NfsUnreachable },
  { key: 'low-disk', label: HEALTH_FLAGS['low-disk'].label, count: (summary) => summary.LowDisk },
  { key: 'agent-outdated', label: HEALTH_FLAGS['agent-outdated'].label, count: (summary) => summary.AgentOutdated },
  { key: 'settings-drift', label: HEALTH_FLAGS['settings-drift'].label, count: (summary) => summary.SettingsDrift },
  { key: 'off', label: 'Powered off', count: (summary) => summary.Off },
];

function matches(host: HostHealth, filter: Filter) {
  if (filter === 'all') return true;
  if (filter === 'attention') return host.Status === 'attention';
  if (filter === 'off') return host.Status === 'off';
  return host.Flags.includes(filter);
}

function osLabel(host: HostHealth) {
  const parts = [host.OsId, host.OsVersion].filter(Boolean);
  return parts.length ? parts.join(' ') : null;
}

/** Readings from a heartbeat that is no longer current are shown, but muted. */
function Reading({ host, children }: { host: HostHealth; children: React.ReactNode }) {
  return host.Reporting ? (
    <>{children}</>
  ) : (
    <span className="text-muted" title="As of the last heartbeat, which is no longer current">
      {children}
    </span>
  );
}

const MONO = 'font-mono text-xs whitespace-nowrap';

const COLUMNS: Array<Column<HostHealth>> = [
  {
    key: 'hostname',
    header: 'Host',
    sort: 'text',
    value: (host) => host.Hostname,
    className: 'font-semibold whitespace-nowrap',
    render: (host) => (
      <Link to={`/vms/${host.VMID}`} className="no-underline hover:underline">
        {host.Hostname}
      </Link>
    ),
  },
  {
    key: 'status',
    header: 'Health',
    sort: 'text',
    value: (host) => host.Status,
    render: (host) => (
      <span className="flex flex-wrap gap-1">
        <HealthStatusBadge status={host.Status} />
        {host.Flags.map((flag) => (
          <HealthFlagBadge key={flag} flag={flag} />
        ))}
      </span>
    ),
  },
  {
    key: 'seen',
    header: 'Last heartbeat',
    sort: 'number',
    // Hosts that never reported sort after the oldest one.
    value: (host) => host.HeartbeatAgeSeconds ?? Number.MAX_SAFE_INTEGER,
    className: 'whitespace-nowrap text-xs',
    render: (host) =>
      host.HeartbeatAgeSeconds === null ? (
        <span className="text-muted">Never</span>
      ) : (
        <span title={formatUtc(host.LastHeartbeatUtc)}>{formatAge(host.HeartbeatAgeSeconds)}</span>
      ),
  },
  {
    key: 'agent',
    header: 'Agent',
    sort: 'text',
    value: (host) => host.AgentVersion,
    className: MONO,
    render: (host) => valueOrDash(host.AgentVersion),
  },
  {
    key: 'os',
    header: 'OS',
    sort: 'text',
    value: (host) => osLabel(host),
    className: 'whitespace-nowrap text-xs',
    render: (host) => <span title={host.OsName ?? undefined}>{valueOrDash(osLabel(host))}</span>,
  },
  {
    key: 'desktop',
    header: 'Desktop',
    sort: 'text',
    value: (host) => host.Desktop,
    className: 'text-xs',
    render: (host) => valueOrDash(host.Desktop),
  },
  {
    key: 'xrdp',
    header: 'xrdp',
    sort: 'text',
    value: (host) => host.XrdpVersion,
    className: 'whitespace-nowrap text-xs',
    render: (host) => (
      <Reading host={host}>
        <span className="flex items-center gap-1.5">
          <span className="font-mono">{valueOrDash(host.XrdpVersion)}</span>
          {host.XrdpActive === false ? <Icon name="x-circle" size={13} className="text-[var(--lb-danger-fg)]" title="xrdp is not running" /> : null}
        </span>
      </Reading>
    ),
  },
  {
    key: 'nfs',
    header: 'NFS',
    sort: 'text',
    value: (host) => (host.NfsReachable === null ? 'unknown' : host.NfsReachable ? 'answering' : 'not answering'),
    className: 'whitespace-nowrap text-xs',
    render: (host) =>
      host.NfsReachable === null ? (
        <span className="text-muted">Not checked</span>
      ) : (
        <Reading host={host}>
          {host.NfsReachable ? (
            'Answering'
          ) : (
            <span className="font-medium text-[var(--lb-danger-fg)]">Not answering</span>
          )}
        </Reading>
      ),
  },
  {
    key: 'load',
    header: 'Load',
    sort: 'number',
    value: (host) => host.LoadAverage,
    className: 'text-xs tabular-nums whitespace-nowrap',
    render: (host) =>
      host.LoadAverage === null ? (
        valueOrDash(null)
      ) : (
        <Reading host={host}>{`${host.LoadAverage.toFixed(2)}${host.CpuCount ? ` / ${host.CpuCount}` : ''}`}</Reading>
      ),
  },
  {
    key: 'memory',
    header: 'Memory free',
    sort: 'number',
    value: (host) => host.MemoryAvailableMb,
    className: 'text-xs tabular-nums whitespace-nowrap',
    render: (host) => <Reading host={host}>{formatMegabytes(host.MemoryAvailableMb)}</Reading>,
  },
  {
    key: 'disk',
    header: 'Disk free',
    sort: 'number',
    value: (host) => host.RootDiskFreePct,
    className: 'text-xs tabular-nums',
    render: (host) =>
      host.RootDiskFreePct === null ? valueOrDash(null) : <Reading host={host}>{`${host.RootDiskFreePct}%`}</Reading>,
  },
  {
    key: 'sessions',
    header: 'Sessions',
    sort: 'number',
    value: (host) => host.Sessions.length,
    className: 'text-xs',
    render: (host) =>
      host.Sessions.length
        ? host.Sessions.map((session) => `${session.username} (${session.state})`).join(', ')
        : host.HeartbeatAgeSeconds === null
          ? valueOrDash(null)
          : 'None',
  },
];

export function FleetHealth() {
  const autoRefresh = useAutoRefresh(30);
  const { data, isPending, isFetching, error, refetch } = useFleetHealth(autoRefresh.intervalMs);
  const [searchParams, setSearchParams] = useSearchParams();

  const requested = (searchParams.get('show') ?? 'all') as Filter;
  const filter: Filter = FILTERS.some((candidate) => candidate.key === requested) ? requested : 'all';

  function choose(next: Filter) {
    setSearchParams(
      (current) => {
        const params = new URLSearchParams(current);
        if (next === 'all') {
          params.delete('show');
        } else {
          params.set('show', next);
        }
        return params;
      },
      { replace: true },
    );
  }

  const hosts = data?.Hosts ?? [];
  const shown = hosts.filter((host) => matches(host, filter));

  return (
    <>
      <Breadcrumbs items={[{ label: 'Virtual machines', to: '/vms' }, { label: 'Fleet health' }]} />

      <PageHeader
        title="Fleet health"
        subtitle="What each Linux host agent reported on its last reconcile run. Checkout readiness is still decided by the reachability probe."
        icon="activity"
        actions={
          <>
            <Switch
              label={<span className="text-xs whitespace-nowrap text-muted">Auto refresh {autoRefresh.status}</span>}
              checked={autoRefresh.enabled}
              onChange={autoRefresh.setEnabled}
            />
            {isFetching && !isPending ? <Spinner label="" /> : null}
            <button
              type="button"
              className="lb-btn border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] px-2.5 py-1.5 text-xs"
              onClick={() => void refetch()}
            >
              <Icon name="refresh" size={14} />
              Refresh
            </button>
            <ButtonLink to="/vms" size="sm" icon="chevron-left">
              Back to list
            </ButtonLink>
          </>
        }
      />

      {isPending ? <LoadingPanel label="Loading fleet health" /> : null}

      {error ? <ErrorPanel message={errorMessage(error, 'Unable to retrieve fleet health.')} /> : null}

      {data && hosts.length === 0 ? (
        <EmptyState
          title="No Linux hosts registered"
          message="Hosts appear here once they are registered with the broker and their agent starts reporting."
          icon="server"
        />
      ) : null}

      {data && hosts.length > 0 ? (
        <>
          <div role="group" aria-label="Show hosts" className="mb-3 flex flex-wrap items-center gap-1.5">
            {FILTERS.map((option) => {
              const count = option.count(data.Summary);
              const active = option.key === filter;
              return (
                <button
                  key={option.key}
                  type="button"
                  aria-pressed={active}
                  disabled={!active && count === 0 && option.key !== 'all'}
                  onClick={() => choose(option.key)}
                  className={classNames(
                    'lb-btn px-2.5 py-1 text-xs disabled:opacity-40',
                    active
                      ? 'border-transparent bg-[var(--lb-brand)] text-[var(--lb-on-brand)]'
                      : 'border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] text-ink hover:border-[var(--lb-brand)]',
                  )}
                >
                  {option.label}
                  <span className="tabular-nums opacity-80">{count}</span>
                </button>
              );
            })}
          </div>

          <p className="mb-3 text-xs text-muted">
            {data.Summary.Reporting} of {data.Summary.PoweredOn} powered-on hosts reported within the
            last {describeSeconds(data.StaleAfterSeconds)}. Hosts are expected to run agent{' '}
            <span className="font-mono">{data.ExpectedAgentVersion}</span>
            {data.CurrentSettingsVersion ? (
              <>
                {' '}and settings version <span className="font-mono">{data.CurrentSettingsVersion}</span>
              </>
            ) : null}
            .
          </p>

          <DataTable
            columns={COLUMNS}
            rows={shown}
            rowKey={(host) => host.VMID}
            searchable
            searchPlaceholder="Search host, OS, agent or user…"
            noun="hosts"
            emptyMessage="No host matches this filter."
            caption="Latest heartbeat and health of every Linux host"
          />

          <details className="mt-4 text-sm">
            <summary className="cursor-pointer text-muted">What the flags mean</summary>
            <dl className="mt-2 mb-0 grid grid-cols-1 gap-x-4 gap-y-2 md:grid-cols-[auto_1fr]">
              {(Object.keys(HEALTH_FLAGS) as HealthFlag[]).map((flag) => (
                <div key={flag} className="contents">
                  <dt>
                    <Badge tone={HEALTH_FLAGS[flag].tone} icon={HEALTH_FLAGS[flag].icon}>
                      {HEALTH_FLAGS[flag].label}
                    </Badge>
                  </dt>
                  <dd className="m-0 text-muted">{HEALTH_FLAGS[flag].help}</dd>
                </div>
              ))}
            </dl>
          </details>
        </>
      ) : null}
    </>
  );
}
