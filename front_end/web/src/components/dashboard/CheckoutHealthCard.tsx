import { GlassCard } from '../ui/GlassCard';
import { Icon } from '../Icon';
import { classNames, formatAge, formatDuration, formatNumber } from '../../lib/format';
import type { CheckoutStats, UtilizationHours } from '../../types/broker';
import { windowPhrase } from './CapacityCard';

/** A checkout time in milliseconds: "850 ms", "2.4 s". */
export function formatMilliseconds(value: number | null | undefined): string {
  if (value === null || value === undefined || Number.isNaN(value)) {
    return '—';
  }
  return value < 1000 ? `${Math.round(value)} ms` : `${(value / 1000).toFixed(1)} s`;
}

/** Seconds since an ISO-8601 UTC time, from the browser's clock. */
export function secondsSince(utc: string | null | undefined, now = Date.now()): number | null {
  if (!utc) return null;
  const parsed = Date.parse(utc);
  return Number.isNaN(parsed) ? null : Math.max(0, Math.round((now - parsed) / 1000));
}

function Figure({
  label,
  value,
  detail,
  tone,
}: {
  label: string;
  value: string;
  detail?: string;
  tone?: 'danger' | 'warn';
}) {
  const colour = tone === 'danger' ? 'var(--lb-danger-fg)' : tone === 'warn' ? 'var(--lb-warn-fg)' : undefined;
  return (
    <div>
      <dt className="text-xs text-muted">{label}</dt>
      <dd className="m-0">
        <span className="block text-xl font-semibold tabular-nums" style={{ color: colour }}>
          {value}
        </span>
        {detail ? <span className="block text-xs text-muted">{detail}</span> : null}
      </dd>
    </div>
  );
}

/** How checkouts went: unmet demand, how long users waited, and how long hosts take to start. */
export function CheckoutHealthCard({
  stats,
  hours,
  className,
}: {
  stats: CheckoutStats | undefined;
  hours: UtilizationHours;
  className?: string;
}) {
  const failed = stats ? stats.ProvisionFailed + stats.Errors : 0;
  const lastDenied = secondsSince(stats?.LastDeniedUtc);

  return (
    <GlassCard className={classNames('flex h-full flex-col', className)}>
      <div className="flex items-center justify-between gap-2 border-b border-[var(--lb-hairline)] px-4 py-3">
        <h2 className="m-0 flex items-center gap-2 text-sm font-semibold">
          <Icon name="person" size={16} className="text-muted" />
          Checkout health
        </h2>
        <span className="text-xs text-muted">{windowPhrase(hours)}</span>
      </div>

      {stats ? (
        <dl className="m-0 grid flex-1 grid-cols-2 content-start gap-x-4 gap-y-4 p-4">
          <Figure
            label="Checkouts"
            value={formatNumber(stats.Total)}
            detail={`${formatNumber(stats.Assigned)} new · ${formatNumber(stats.Reused)} reconnects`}
          />
          <Figure
            label="Found no host"
            value={formatNumber(stats.NoneAvailable)}
            tone={stats.NoneAvailable ? 'danger' : undefined}
            detail={
              stats.NoneAvailable
                ? `${stats.DeniedPercent ?? 0}% of checkouts · last ${formatAge(lastDenied)}`
                : 'Every checkout found a host'
            }
          />
          <Figure
            label="Time to connect"
            value={formatMilliseconds(stats.P50Ms)}
            detail={stats.P95Ms !== null ? `Median · 95% within ${formatMilliseconds(stats.P95Ms)}` : 'No checkouts yet'}
          />
          <Figure
            label="Host start to ready"
            value={formatDuration(stats.StartP50Seconds)}
            detail={
              stats.HostStarts
                ? `Median of ${formatNumber(stats.HostStarts)} start${stats.HostStarts === 1 ? '' : 's'} · 95% within ${formatDuration(stats.StartP95Seconds)}`
                : 'No host was started'
            }
          />
          {failed ? (
            <Figure
              label="Failed checkouts"
              value={formatNumber(failed)}
              tone="warn"
              detail={`${formatNumber(stats.ProvisionFailed)} could not set up the user · ${formatNumber(stats.Errors)} broker error${stats.Errors === 1 ? '' : 's'}`}
            />
          ) : null}
        </dl>
      ) : (
        <p className="m-0 p-4 text-sm text-muted">Loading checkout health…</p>
      )}
    </GlassCard>
  );
}
