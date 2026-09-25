import { Link } from 'react-router-dom';

import { Badge } from '../ui/Badge';
import { Spinner } from '../ui/Feedback';
import { GlassCard } from '../ui/GlassCard';
import { Icon } from '../Icon';
import type { ScalingPreview } from '../../types/broker';

export interface ScalingPreviewCardProps {
  preview: ScalingPreview | undefined;
  title: string;
  busy?: boolean;
  error?: string | null;
  /** Shown before the first preview, for the editor. */
  placeholder?: string;
}

function ActionBadgeFor({ action }: { action: ScalingPreview['Action'] }) {
  if (action === 'PowerOn') return <Badge tone="ok" icon="arrow-up">Scale up</Badge>;
  if (action === 'PowerOff') return <Badge tone="warn" icon="arrow-down">Scale down</Badge>;
  return <Badge tone="neutral" icon="dash-circle">No change</Badge>;
}

/** What a scaling run would do with the current counts, and why. */
export function ScalingPreviewCard({ preview, title, busy = false, error = null, placeholder }: ScalingPreviewCardProps) {
  return (
    <GlassCard className="flex h-full flex-col p-5" aria-live="polite">
      <div className="mb-3 flex items-center justify-between gap-2">
        <h2 className="m-0 text-xs font-semibold tracking-wider text-muted uppercase">{title}</h2>
        {busy ? <Spinner label="" /> : null}
      </div>

      {error ? (
        <p className="m-0 text-sm text-[var(--lb-danger-fg)]">{error}</p>
      ) : !preview ? (
        <p className="m-0 text-sm text-muted">{placeholder ?? 'Working out what the next run would do…'}</p>
      ) : (
        <>
          <div className="flex flex-wrap items-center gap-2">
            <ActionBadgeFor action={preview.Action} />
            <strong className="text-base">{preview.Summary}</strong>
          </div>
          {preview.Reason ? <p className="mt-2 mb-0 text-sm text-muted">{preview.Reason}</p> : null}

          <dl className="mt-4 mb-0 grid grid-cols-2 gap-x-4 gap-y-3 text-sm sm:grid-cols-4">
            <div>
              <dt className="text-xs text-muted">Can take a user</dt>
              <dd className="m-0 font-semibold tabular-nums">{preview.Counts.Serviceable}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted">In use</dt>
              <dd className="m-0 font-semibold tabular-nums">{preview.Counts.InUse}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted">Powered on</dt>
              <dd className="m-0 font-semibold tabular-nums">{preview.Counts.PoweredOn}</dd>
            </div>
            <div>
              <dt className="text-xs text-muted">Utilization</dt>
              <dd className="m-0 font-semibold tabular-nums">
                {preview.Counts.Utilization === null ? '—' : `${Math.round(preview.Counts.Utilization)}%`}
              </dd>
            </div>
          </dl>

          {preview.Phase.MinVMs !== null ? (
            <p className="mt-4 mb-0 text-xs text-muted">
              Using <span className="font-medium text-ink">{preview.Phase.Name ?? 'the default rule'}</span>: keep{' '}
              {preview.Phase.MinVMs}–{preview.Phase.MaxVMs} hosts, scale up at {preview.Phase.ScaleUpRatio}% and down at{' '}
              {preview.Phase.ScaleDownRatio}%.
              {preview.Phase.MaintenanceSurge ? (
                <>
                  {' '}
                  The minimum includes one extra host while a{' '}
                  <Link to="/vms/maintenance">maintenance run</Link> waits for a spare ready host.
                </>
              ) : null}
            </p>
          ) : (
            <p className="mt-4 mb-0 text-xs text-muted">
              <Icon name="info-circle" size={12} className="mr-1 inline align-[-2px]" />
              No scaling rule is configured, so hosts are never started or stopped.{' '}
              <Link to="/scaling/rules/create">Create a default rule</Link>
            </p>
          )}
        </>
      )}
    </GlassCard>
  );
}
