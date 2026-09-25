import { Badge } from '../ui/Badge';
import type { Tone } from '../ui/Badge';
import type { IconName } from '../Icon';
import type {
  MaintenanceCounts,
  MaintenanceHostState,
  MaintenancePatchMode,
  MaintenanceRunStatus,
} from '../../types/broker';

interface Descriptor {
  label: string;
  tone: Tone;
  icon: IconName;
}

const RUN_STATUS: Record<MaintenanceRunStatus, Descriptor> = {
  Active: { label: 'Running', tone: 'accent', icon: 'refresh' },
  Paused: { label: 'Paused', tone: 'warn', icon: 'clock' },
  Stopping: { label: 'Stopping', tone: 'warn', icon: 'dash-circle' },
  Completed: { label: 'Completed', tone: 'ok', icon: 'check-circle' },
  Cancelled: { label: 'Cancelled', tone: 'neutral', icon: 'x-circle' },
  Failed: { label: 'Failed', tone: 'danger', icon: 'alert-triangle' },
};

export const HOST_STATES: Record<MaintenanceHostState, Descriptor & { help: string }> = {
  Pending: { label: 'Waiting', tone: 'neutral', icon: 'clock', help: 'Not started. Taken when a batch slot frees up and enough hosts stay ready.' },
  Draining: { label: 'Draining', tone: 'info', icon: 'arrow-down', help: 'Out of rotation, waiting for its user to leave or be signed out.' },
  Starting: { label: 'Starting', tone: 'accent', icon: 'power', help: 'Was powered off, so it is being started to patch it.' },
  Patching: { label: 'Patching', tone: 'accent', icon: 'wrench', help: 'Installing updates.' },
  Restarting: { label: 'Restarting', tone: 'accent', icon: 'refresh', help: 'Restart requested through Azure.' },
  Verifying: { label: 'Verifying', tone: 'accent', icon: 'activity', help: 'Waiting for it to come back reachable, report a fresh boot and run xrdp.' },
  Succeeded: { label: 'Done', tone: 'ok', icon: 'check-circle', help: 'Patched or restarted, and put back the way the run found it.' },
  Failed: { label: 'Failed', tone: 'danger', icon: 'x-circle', help: 'Left out of rotation for you to look at. The reason is shown.' },
  Skipped: { label: 'Skipped', tone: 'neutral', icon: 'dash-circle', help: 'Not patched: returned to service by hand, powered off, or removed.' },
  Cancelled: { label: 'Cancelled', tone: 'neutral', icon: 'x-circle', help: 'The run stopped before this host was patched.' },
};

export const PATCH_MODES: Record<MaintenancePatchMode, { label: string; help: string }> = {
  Security: { label: 'Security updates', help: 'Installs security updates only, then restarts each host.' },
  All: { label: 'All updates', help: 'Installs every available update, then restarts each host.' },
  RebootOnly: { label: 'Restart only', help: 'Restarts each host without installing anything. Works with any host agent.' },
};

export function RunStatusBadge({ status }: { status: MaintenanceRunStatus }) {
  const descriptor = RUN_STATUS[status] ?? RUN_STATUS.Active;
  return (
    <Badge tone={descriptor.tone} icon={descriptor.icon}>
      {descriptor.label}
    </Badge>
  );
}

export function HostStateBadge({ state }: { state: MaintenanceHostState }) {
  const descriptor = HOST_STATES[state] ?? HOST_STATES.Pending;
  return (
    <span title={descriptor.help}>
      <Badge tone={descriptor.tone} icon={descriptor.icon}>
        {descriptor.label}
      </Badge>
    </span>
  );
}

export function runIsLive(status: MaintenanceRunStatus) {
  return status === 'Active' || status === 'Paused' || status === 'Stopping';
}

export function runTitle(run: { RunID: number; Name: string | null }) {
  return run.Name ? `${run.Name} (run ${run.RunID})` : `Maintenance run ${run.RunID}`;
}

const SEGMENTS: Array<{ key: keyof MaintenanceCounts; label: string; colour: string }> = [
  { key: 'Succeeded', label: 'Done', colour: 'var(--lb-ok-fg)' },
  { key: 'Failed', label: 'Failed', colour: 'var(--lb-danger-fg)' },
  { key: 'InProgress', label: 'In progress', colour: 'var(--lb-accent-fg)' },
  { key: 'Skipped', label: 'Skipped', colour: 'var(--lb-ink-subtle)' },
  { key: 'Cancelled', label: 'Cancelled', colour: 'var(--lb-neutral-bd)' },
];

/** How far a run has got, as a bar with a legend that carries the numbers. */
export function MaintenanceProgress({ counts }: { counts: MaintenanceCounts }) {
  const total = counts.Total || 1;
  const summary = `${counts.Succeeded} of ${counts.Total} hosts done, ${counts.InProgress} in progress, ${counts.Pending} waiting, ${counts.Failed} failed`;
  const shown = SEGMENTS.filter((segment) => counts[segment.key] > 0);
  return (
    <div>
      <div role="img" aria-label={summary} className="flex h-2.5 w-full overflow-hidden rounded-full bg-[var(--lb-neutral-bg)]">
        {shown.map((segment) => (
          <div key={segment.key} style={{ width: `${(counts[segment.key] / total) * 100}%`, background: segment.colour }} />
        ))}
      </div>
      <ul className="m-0 mt-2 flex list-none flex-wrap gap-x-4 gap-y-1 p-0 text-xs text-muted">
        {shown.map((segment) => (
          <li key={segment.key} className="flex items-center gap-1.5">
            <i aria-hidden className="inline-block size-2 rounded-full" style={{ background: segment.colour }} />
            {segment.label} <span className="text-ink tabular-nums">{counts[segment.key]}</span>
          </li>
        ))}
        <li className="flex items-center gap-1.5">
          <i aria-hidden className="inline-block size-2 rounded-full bg-[var(--lb-neutral-bg)] ring-1 ring-[var(--lb-neutral-bd)]" />
          Waiting <span className="text-ink tabular-nums">{counts.Pending}</span>
        </li>
      </ul>
    </div>
  );
}
