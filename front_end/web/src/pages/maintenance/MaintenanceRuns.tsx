import { Link } from 'react-router-dom';

import { Breadcrumbs } from '../../components/layout/Breadcrumbs';
import {
  MaintenanceProgress,
  PATCH_MODES,
  RunStatusBadge,
  runTitle,
} from '../../components/maintenance/MaintenanceStatus';
import { ButtonLink } from '../../components/ui/Button';
import { EmptyState, ErrorPanel, LoadingPanel, Notice, PageHeader } from '../../components/ui/Feedback';
import { GlassCard } from '../../components/ui/GlassCard';
import { useMaintenanceRuns } from '../../hooks/useBroker';
import { useMaintenanceActions } from '../../hooks/useMaintenanceActions';
import { useCan } from '../../hooks/useSession';
import { errorMessage } from '../../lib/api';
import { formatAge, formatUtc, valueOrDash } from '../../lib/format';
import type { MaintenanceRun } from '../../types/broker';

/** The scheduled task advances a run every minute; much longer means it is not running. */
const STALLED_AFTER_SECONDS = 5 * 60;

export function RunReadiness({ run }: { run: MaintenanceRun }) {
  const stalled = run.Status !== 'Paused' && (run.LastTickAgeSeconds ?? 0) > STALLED_AFTER_SECONDS;
  return (
    <>
      <p className="m-0 text-xs text-muted">
        {run.ReadyNow !== undefined && run.ReadyNow !== null ? (
          <>
            <span className="font-medium text-ink tabular-nums">{run.ReadyNow}</span> hosts ready for users now; the run keeps at
            least <span className="font-medium text-ink tabular-nums">{run.MinReadyInForce ?? 0}</span>
            {run.MinReadyOverride === null ? ' (the scaling minimum)' : ''}.{' '}
          </>
        ) : null}
        {run.LastTickAtUtc ? <>Last advanced {formatAge(run.LastTickAgeSeconds)}.</> : <>Not advanced yet.</>}
      </p>
      {stalled ? (
        <Notice tone="warning" className="mt-3">
          This run has not been advanced for {formatAge(run.LastTickAgeSeconds).replace(' ago', '')}. Check that the scheduled
          task function app is running a build with the AdvanceMaintenance timer.
        </Notice>
      ) : null}
    </>
  );
}

function ActiveRun({ run, actions }: { run: MaintenanceRun; actions: React.ReactNode }) {
  return (
    <GlassCard className="mb-5 p-5">
      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <h2 className="m-0 flex flex-wrap items-center gap-2 text-base font-semibold">
            <Link to={`/vms/maintenance/${run.RunID}`} className="no-underline hover:underline">
              {runTitle(run)}
            </Link>
            <RunStatusBadge status={run.Status} />
          </h2>
          <p className="mt-1 mb-0 text-sm text-muted">
            {PATCH_MODES[run.PatchMode].label} · {run.BatchSize} at a time · started {formatUtc(run.CreatedAtUtc)}
            {run.CreatedBy ? ` by ${run.CreatedBy}` : ''}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          {actions}
          <ButtonLink to={`/vms/maintenance/${run.RunID}`} size="sm" icon="eye">
            Details
          </ButtonLink>
        </div>
      </div>

      <MaintenanceProgress counts={run.Counts} />

      {run.StatusReason ? <Notice tone="warning" className="mt-4">{run.StatusReason}</Notice> : null}
      {run.WaitReason ? <Notice tone="info" className="mt-4">{run.WaitReason}</Notice> : null}

      <div className="mt-4">
        <RunReadiness run={run} />
      </div>
    </GlassCard>
  );
}

function RunTable({ runs }: { runs: MaintenanceRun[] }) {
  return (
    <GlassCard className="overflow-hidden">
      <div className="border-b border-[var(--lb-hairline)] px-4 py-3">
        <h2 className="m-0 text-sm font-semibold">Recent runs</h2>
      </div>
      <div className="overflow-x-auto">
        <table className="lb-table">
          <thead>
            <tr>
              <th scope="col">Run</th>
              <th scope="col">Status</th>
              <th scope="col">Mode</th>
              <th scope="col" className="text-right">Done</th>
              <th scope="col" className="text-right">Failed</th>
              <th scope="col">Started</th>
              <th scope="col">Ended</th>
            </tr>
          </thead>
          <tbody>
            {runs.map((run) => (
              <tr key={run.RunID}>
                <td>
                  <Link to={`/vms/maintenance/${run.RunID}`}>{runTitle(run)}</Link>
                </td>
                <td>
                  <RunStatusBadge status={run.Status} />
                </td>
                <td className="text-sm">{PATCH_MODES[run.PatchMode].label}</td>
                <td className="text-right tabular-nums">
                  {run.Counts.Succeeded} / {run.Counts.Total}
                </td>
                <td className="text-right tabular-nums" style={{ color: run.Counts.Failed ? 'var(--lb-danger-fg)' : undefined }}>
                  {run.Counts.Failed}
                </td>
                <td className="text-xs whitespace-nowrap">
                  {formatUtc(run.CreatedAtUtc)}
                  <span className="block text-muted">{valueOrDash(run.CreatedBy)}</span>
                </td>
                <td className="text-xs whitespace-nowrap">{formatUtc(run.EndedAtUtc)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </GlassCard>
  );
}

export function MaintenanceRuns() {
  const { data, isPending, error } = useMaintenanceRuns(15_000);
  const can = useCan();
  const actions = useMaintenanceActions();
  const available = data?.Available !== false;

  return (
    <>
      <Breadcrumbs items={[{ label: 'VM management', to: '/vms' }, { label: 'Maintenance' }]} />
      <PageHeader
        title="Rolling maintenance"
        subtitle="Patch or restart hosts a batch at a time, keeping enough hosts ready for users."
        icon="wrench"
        actions={
          can.admin && available && data && !data.Active ? (
            <ButtonLink to="/vms/maintenance/new" variant="primary" size="sm" icon="plus">
              New run
            </ButtonLink>
          ) : null
        }
      />

      {isPending ? <LoadingPanel label="Loading maintenance runs" /> : null}
      {error ? <ErrorPanel message={errorMessage(error, 'Unable to retrieve maintenance runs.')} /> : null}

      {data && !available ? (
        <Notice tone="info">
          Rolling maintenance needs the broker API and database from this release. Upgrade them, then start a run here.
        </Notice>
      ) : null}

      {data?.Active ? <ActiveRun run={data.Active} actions={can.admin ? actions.buttons(data.Active) : null} /> : null}

      {data && available && !data.Runs.length ? (
        <EmptyState
          title="No maintenance runs yet"
          message="A run takes a few hosts out of rotation at a time, installs updates with each host's package manager, restarts it and puts it back, while users keep working on the rest."
          icon="wrench"
          action={
            can.admin ? (
              <ButtonLink to="/vms/maintenance/new" variant="primary" size="sm" icon="plus">
                Start a run
              </ButtonLink>
            ) : undefined
          }
        />
      ) : null}

      {data?.Runs.length ? <RunTable runs={data.Runs} /> : null}

      {actions.dialog}
    </>
  );
}
