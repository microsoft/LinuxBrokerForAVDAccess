import { useMemo } from 'react';

import { TimeSeriesChart } from '../charts/TimeSeriesChart';
import type { ChartSeries } from '../charts/TimeSeriesChart';
import { EmptyState, Spinner } from '../ui/Feedback';
import { GlassCard } from '../ui/GlassCard';
import { Icon } from '../Icon';
import { errorMessage } from '../../lib/api';
import { classNames } from '../../lib/format';
import type { UtilizationHours, UtilizationMetrics, UtilizationPoint } from '../../types/broker';

export const WINDOWS: Array<{ hours: UtilizationHours; label: string; phrase: string }> = [
  { hours: 24, label: '24 hours', phrase: 'the last 24 hours' },
  { hours: 168, label: '7 days', phrase: 'the last 7 days' },
];

export function windowPhrase(hours: UtilizationHours) {
  return WINDOWS.find((window) => window.hours === hours)?.phrase ?? `the last ${hours} hours`;
}

export function WindowToggle({
  hours,
  onChange,
  label,
}: {
  hours: UtilizationHours;
  onChange: (hours: UtilizationHours) => void;
  label: string;
}) {
  return (
    <div role="group" aria-label={label} className="flex gap-1">
      {WINDOWS.map((window) => {
        const active = window.hours === hours;
        return (
          <button
            key={window.hours}
            type="button"
            aria-pressed={active}
            onClick={() => onChange(window.hours)}
            className={classNames(
              'lb-btn px-2.5 py-1 text-xs',
              active
                ? 'border-transparent bg-[var(--lb-brand)] text-[var(--lb-on-brand)]'
                : 'border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] text-ink hover:border-[var(--lb-brand)]',
            )}
          >
            {window.label}
          </button>
        );
      })}
    </div>
  );
}

function range(values: Array<number | null>) {
  const present = values.filter((value): value is number => value !== null);
  return present.length ? { min: Math.min(...present), max: Math.max(...present) } : null;
}

/** What the chart shows, in words, for its accessible name. */
export function describeCapacity(series: UtilizationPoint[], hours: UtilizationHours) {
  const peak = range(series.map((point) => point.PeakInUse));
  const serviceable = range(series.map((point) => point.Serviceable));
  const maximum = range(series.map((point) => point.MaxVMs));
  const denied = series.reduce((total, point) => total + point.Denied, 0);

  const parts = [`Capacity over ${windowPhrase(hours)}.`];
  if (peak) parts.push(`At most ${peak.max} hosts were in use at once.`);
  if (serviceable) {
    parts.push(
      serviceable.min === serviceable.max
        ? `About ${Math.round(serviceable.max)} hosts could take a user.`
        : `Between ${Math.round(serviceable.min)} and ${Math.round(serviceable.max)} hosts could take a user.`,
    );
  }
  if (maximum) parts.push(`The scaling maximum was ${maximum.max === maximum.min ? maximum.max : `${maximum.min} to ${maximum.max}`}.`);
  parts.push(denied ? `${denied} checkout${denied === 1 ? '' : 's'} found no host.` : 'Every checkout found a host.');
  return parts.join(' ');
}

export interface CapacityCardProps {
  hours: UtilizationHours;
  onHoursChange: (hours: UtilizationHours) => void;
  data: UtilizationMetrics | undefined;
  busy: boolean;
  error: unknown;
  className?: string;
}

/** Powered-on, serviceable and in-use hosts over a day or a week, against the scaling maximum. */
export function CapacityCard({ hours, onHoursChange, data, busy, error, className }: CapacityCardProps) {
  const series = useMemo(() => data?.Series ?? [], [data]);
  // While another window loads, the previous one stays on screen and is described as such.
  const shownHours = data?.Hours ?? hours;
  const hasRuns = series.some((point) => point.Runs > 0);
  const hasCheckouts = series.some((point) => point.Checkouts > 0);

  const lines = useMemo<ChartSeries[]>(
    () => [
      {
        key: 'powered-on',
        label: 'Powered on',
        values: series.map((point) => point.PoweredOn),
        colour: 'var(--lb-ink-subtle)',
        dash: '1 5',
        width: 2.5,
      },
      {
        key: 'serviceable',
        label: 'Can take a user',
        values: series.map((point) => point.Serviceable),
        colour: 'var(--lb-ok-fg)',
        dash: '8 5',
      },
      {
        key: 'in-use',
        label: 'In use',
        values: series.map((point) => point.InUse),
        colour: 'var(--lb-accent-fg)',
        width: 2.5,
      },
      {
        key: 'max',
        label: 'Scaling maximum',
        values: series.map((point) => point.MaxVMs),
        colour: 'var(--lb-warn-fg)',
        dash: '3 3',
        step: true,
        width: 1.5,
      },
    ],
    [series],
  );
  const markers = useMemo(
    () => series.flatMap((point, index) => (point.Denied > 0 ? [{ index, count: point.Denied }] : [])),
    [series],
  );

  return (
    <GlassCard className={classNames('flex h-full flex-col', className)}>
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--lb-hairline)] px-4 py-3">
        <h2 className="m-0 flex items-center gap-2 text-sm font-semibold">
          <Icon name="activity" size={16} className="text-muted" />
          Capacity
          {busy ? <Spinner label="" /> : null}
        </h2>
        <WindowToggle hours={hours} onChange={onHoursChange} label="Capacity window" />
      </div>

      <div className="flex-1 p-4">
        {error && !data ? (
          <p className="m-0 text-sm text-[var(--lb-danger-fg)]">{errorMessage(error, 'Capacity trends could not be loaded.')}</p>
        ) : !data ? (
          <p className="m-0 text-sm text-muted">Loading capacity trends…</p>
        ) : !hasRuns && !hasCheckouts ? (
          <EmptyState
            title="No scaling runs in this window yet"
            message="The chart fills in as the scheduled task runs scaling and users check out hosts."
            icon="activity"
          />
        ) : (
          <TimeSeriesChart
            times={series.map((point) => point.BucketStartUtc)}
            bucketMinutes={data.BucketMinutes ?? 60}
            series={lines}
            markers={markers}
            markerLabel="checkouts found no host"
            summary={describeCapacity(series, shownHours)}
            caption={`Capacity over ${windowPhrase(shownHours)}, by ${data.BucketMinutes ?? 60}-minute interval`}
          />
        )}
      </div>
    </GlassCard>
  );
}
