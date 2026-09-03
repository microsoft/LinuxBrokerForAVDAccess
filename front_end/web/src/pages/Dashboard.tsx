import { Link } from 'react-router-dom';

import { ActionBadge } from '../components/ui/Badge';
import { ButtonLink } from '../components/ui/Button';
import {
  EmptyState,
  ErrorPanel,
  LoadingPanel,
  Notice,
  PageHeader,
  Spinner,
} from '../components/ui/Feedback';
import { GlassCard } from '../components/ui/GlassCard';
import { Switch } from '../components/ui/Field';
import { StatCard } from '../components/ui/StatCard';
import { Icon } from '../components/Icon';
import { useAutoRefresh } from '../hooks/useAutoRefresh';
import { useDashboard } from '../hooks/useBroker';
import { errorMessage } from '../lib/api';
import { formatNumber, valueOrDash } from '../lib/format';
import type { DashboardStats } from '../types/broker';

const SEGMENTS = [
  { key: 'checked_out', label: 'Checked out', colour: 'var(--lb-accent-fg)' },
  { key: 'available', label: 'Available', colour: 'var(--lb-ok-fg)' },
  { key: 'released', label: 'Released', colour: 'var(--lb-info-fg)' },
  { key: 'maintenance', label: 'Maintenance', colour: 'var(--lb-warn-fg)' },
  { key: 'other', label: 'Other', colour: 'var(--lb-ink-subtle)' },
] as const;

export function Dashboard() {
  const autoRefresh = useAutoRefresh(30);
  const { data, isPending, isFetching, error, refetch } = useDashboard(autoRefresh.intervalMs);

  const stats = data?.stats ?? null;
  const unavailable = Boolean(data?.apiError) || (data !== undefined && stats === null);

  return (
    <>
      <PageHeader
        title="Pool overview"
        subtitle="Current state of the brokered Linux host pool."
        icon="gauge"
        actions={
          <>
            <Switch
              label={
                <span className="text-xs whitespace-nowrap text-muted">
                  Auto refresh {autoRefresh.status}
                </span>
              }
              checked={autoRefresh.enabled}
              onChange={autoRefresh.setEnabled}
            />
            {isFetching ? <Spinner label="" /> : null}
            <button
              type="button"
              className="lb-btn border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] px-2.5 py-1.5 text-xs"
              onClick={() => void refetch()}
            >
              <Icon name="refresh" size={14} />
              Refresh
            </button>
            <ButtonLink to="/vms/checkout" variant="primary" size="sm" icon="person">
              Checkout VM
            </ButtonLink>
          </>
        }
      />

      {isPending ? <LoadingPanel label="Loading pool data" /> : null}

      {error ? (
        <ErrorPanel message={errorMessage(error, 'The dashboard could not be loaded.')} />
      ) : null}

      {unavailable ? (
        <Notice tone="warning" className="mb-5">
          <strong>Pool data unavailable.</strong> The broker API could not be reached, so the
          counters below cannot be shown. Scaling rules and VM management may still work.
        </Notice>
      ) : null}

      {stats ? (
        <>
          <div className="mb-5 grid grid-cols-2 gap-4 lg:grid-cols-4">
            <StatCard
              label="Total VMs"
              value={stats.total}
              hint={`${stats.powered_on} powered on \u00b7 ${stats.powered_off} off`}
              icon="server"
              tone="brand"
              to="/vms"
            />
            <StatCard
              label="Ready"
              value={stats.ready}
              hint="On, reachable and unassigned"
              icon="check-circle"
              tone="ok"
              to="/vms"
            />
            <StatCard
              label="Checked out"
              value={stats.checked_out}
              hint={`${stats.utilization}% of the pool in use`}
              icon="person"
              tone="accent"
              to="/vms"
            />
            <StatCard
              label="Needs attention"
              value={stats.attention}
              hint={`${stats.unreachable} unreachable \u00b7 ${stats.maintenance} maintenance`}
              icon="alert-triangle"
              tone={stats.attention ? 'warn' : 'neutral'}
              to="/vms"
            />
          </div>

          <div className="grid grid-cols-1 gap-4 xl:grid-cols-2">
            <PoolComposition stats={stats} />
            <RecentActivity entries={data?.recentActivity ?? []} />
          </div>

          <div className="mt-4 grid grid-cols-1 gap-4 md:grid-cols-2">
            <QuickLinks
              icon="server"
              title="VM management"
              description="View, add, update and release the Linux hosts in the pool."
              links={[
                { to: '/vms', label: 'All VMs', primary: true },
                { to: '/vms/add', label: 'Add VM' },
                { to: '/vms/history', label: 'History' },
              ]}
            />
            <QuickLinks
              icon="sliders"
              title="Scaling management"
              description="Tune the thresholds that grow and shrink the pool automatically."
              links={[
                { to: '/scaling/rules', label: 'Scaling rules', primary: true },
                { to: '/scaling/log', label: 'Activity log' },
                { to: '/scaling/rules/history', label: 'Rule history' },
              ]}
            />
          </div>
        </>
      ) : null}
    </>
  );
}

function PoolComposition({ stats }: { stats: DashboardStats }) {
  const segments = SEGMENTS.filter((segment) => stats[segment.key] > 0);

  const summary = `${stats.checked_out} checked out, ${stats.available} available, ${stats.released} released, ${stats.maintenance} in maintenance out of ${stats.total} VMs`;

  return (
    <GlassCard className="flex h-full flex-col">
      <div className="flex items-center justify-between gap-2 border-b border-[var(--lb-hairline)] px-4 py-3">
        <strong className="flex items-center gap-2 text-sm">
          <Icon name="activity" size={16} className="text-muted" />
          Pool composition
        </strong>
        <span className="text-xs text-muted">{formatNumber(stats.total)} VMs</span>
      </div>

      <div className="flex-1 p-4">
        {stats.total ? (
          <>
            <div
              role="img"
              aria-label={summary}
              className="flex h-3 w-full overflow-hidden rounded-full bg-[var(--lb-neutral-bg)]"
            >
              {segments.map((segment) => (
                <div
                  key={segment.key}
                  style={{ width: `${stats.pct[segment.key]}%`, background: segment.colour }}
                />
              ))}
            </div>

            <div className="mt-3 flex flex-wrap gap-x-4 gap-y-1.5 text-xs text-muted">
              {SEGMENTS.filter(
                (segment) => segment.key !== 'other' || stats.other > 0,
              ).map((segment) => (
                <span key={segment.key} className="flex items-center gap-1.5">
                  <i
                    aria-hidden
                    className="inline-block size-2 rounded-full"
                    style={{ background: segment.colour }}
                  />
                  {segment.label} ({stats[segment.key]})
                </span>
              ))}
            </div>

            <dl className="mt-5 mb-0 grid grid-cols-2 gap-4">
              <Metric label="Powered on" value={`${stats.powered_on}`} suffix={`/ ${stats.total}`} />
              <Metric
                label="Unreachable"
                value={`${stats.unreachable}`}
                tone={stats.unreachable ? 'danger' : undefined}
              />
              <Metric
                label="Ready for checkout"
                value={`${stats.ready}`}
                tone={stats.ready ? 'ok' : 'danger'}
              />
              <Metric label="Utilization" value={`${stats.utilization}%`} />
            </dl>
          </>
        ) : (
          <EmptyState
            title="No virtual machines registered"
            message="Add a VM to start brokering sessions."
            icon="server"
          />
        )}
      </div>
    </GlassCard>
  );
}

function Metric({
  label,
  value,
  suffix,
  tone,
}: {
  label: string;
  value: string;
  suffix?: string;
  tone?: 'ok' | 'danger';
}) {
  const colour =
    tone === 'ok' ? 'var(--lb-ok-fg)' : tone === 'danger' ? 'var(--lb-danger-fg)' : undefined;

  return (
    <div>
      <dt className="text-xs text-muted">{label}</dt>
      <dd className="mt-0.5 mb-0 text-xl font-semibold tabular-nums" style={{ color: colour }}>
        {value}
        {suffix ? <span className="ml-1 text-sm font-normal text-muted">{suffix}</span> : null}
      </dd>
    </div>
  );
}

function RecentActivity({
  entries,
}: {
  entries: Array<{
    ActivityID: number;
    CheckTimestamp: string | null;
    ActionTaken: string | null;
    Outcome: string | null;
    NewTotalVMs: number | null;
  }>;
}) {
  return (
    <GlassCard className="flex h-full flex-col overflow-hidden">
      <div className="flex items-center justify-between gap-2 border-b border-[var(--lb-hairline)] px-4 py-3">
        <strong className="flex items-center gap-2 text-sm">
          <Icon name="clock" size={16} className="text-muted" />
          Recent scaling activity
        </strong>
        <Link to="/scaling/log" className="text-xs no-underline hover:underline">
          View full log
        </Link>
      </div>

      {entries.length ? (
        <div className="flex-1 overflow-auto">
          <table className="lb-table">
            <thead>
              <tr>
                <th scope="col">When</th>
                <th scope="col">Action</th>
                <th scope="col">Outcome</th>
                <th scope="col" className="text-right">
                  Total VMs
                </th>
              </tr>
            </thead>
            <tbody>
              {entries.map((entry) => (
                <tr key={entry.ActivityID}>
                  <td className="font-mono text-xs whitespace-nowrap">
                    {valueOrDash(entry.CheckTimestamp)}
                  </td>
                  <td>
                    <ActionBadge value={entry.ActionTaken} />
                  </td>
                  <td className="text-xs">{valueOrDash(entry.Outcome)}</td>
                  <td className="text-right tabular-nums">{valueOrDash(entry.NewTotalVMs)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      ) : (
        <div className="flex-1 p-4">
          <EmptyState
            title="No recent scaling activity"
            message="Runs will appear here once the scaling task has executed."
            icon="clock"
          />
        </div>
      )}
    </GlassCard>
  );
}

function QuickLinks({
  icon,
  title,
  description,
  links,
}: {
  icon: 'server' | 'sliders';
  title: string;
  description: string;
  links: Array<{ to: string; label: string; primary?: boolean }>;
}) {
  return (
    <GlassCard className="h-full p-4">
      <h2 className="mb-2 flex items-center gap-2 text-sm font-semibold">
        <Icon name={icon} size={16} className="text-muted" />
        {title}
      </h2>
      <p className="mb-3 text-xs text-muted">{description}</p>
      <div className="flex flex-wrap gap-2">
        {links.map((link) => (
          <ButtonLink
            key={link.to}
            to={link.to}
            size="sm"
            variant={link.primary ? 'primary' : 'secondary'}
          >
            {link.label}
          </ButtonLink>
        ))}
      </div>
    </GlassCard>
  );
}
