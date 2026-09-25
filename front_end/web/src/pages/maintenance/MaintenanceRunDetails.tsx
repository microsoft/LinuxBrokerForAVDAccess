import { Link, useParams } from 'react-router-dom';

import { Breadcrumbs } from '../../components/layout/Breadcrumbs';
import {
  HOST_STATES,
  HostStateBadge,
  MaintenanceProgress,
  PATCH_MODES,
  RunStatusBadge,
  runTitle,
} from '../../components/maintenance/MaintenanceStatus';
import { Badge, EmptyValue } from '../../components/ui/Badge';
import { ButtonLink } from '../../components/ui/Button';
import { ErrorPanel, LoadingPanel, Notice, PageHeader, Spinner } from '../../components/ui/Feedback';
import { GlassCard } from '../../components/ui/GlassCard';
import { RelativeTime } from '../../components/ui/RelativeTime';
import { useMaintenanceRun } from '../../hooks/useBroker';
import { useMaintenanceActions } from '../../hooks/useMaintenanceActions';
import { useCan } from '../../hooks/useSession';
import { errorMessage } from '../../lib/api';
import { formatDuration, formatUtc, valueOrDash } from '../../lib/format';
import type { MaintenanceHost, MaintenanceHostState, MaintenanceRun } from '../../types/broker';
import { RunReadiness } from './MaintenanceRuns';

const STATE_ORDER: MaintenanceHostState[] = [
  'Pending', 'Draining', 'Starting', 'Patching', 'Restarting', 'Verifying', 'Succeeded', 'Failed', 'Skipped', 'Cancelled',
];

function Setting({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div>
      <dt className="text-xs text-muted">{label}</dt>
      <dd className="m-0 text-sm">{children}</dd>
    </div>
  );
}

function RunSettings({ run }: { run: MaintenanceRun }) {
  return (
    <GlassCard className="h-full p-5">
      <h2 className="mt-0 mb-3 text-xs font-semibold tracking-wider text-muted uppercase">Settings</h2>
      <dl className="m-0 grid grid-cols-2 gap-x-4 gap-y-3">
        <Setting label="What it does">{PATCH_MODES[run.PatchMode].label}</Setting>
        <Setting label="Hosts at a time">{run.BatchSize}</Setting>
        <Setting label="Ready hosts kept">
          {run.MinReadyOverride === null ? 'The scaling minimum' : run.MinReadyOverride}
        </Setting>
        <Setting label="Users">
          {run.SignOutDeadlineMinutes
            ? `Warned, then signed out after ${run.SignOutDeadlineMinutes} min`
            : 'Waited for, never signed out'}
        </Setting>
        {run.SignOutDeadlineMinutes ? (
          <Setting label="Warning">{run.WarningMinutes} min before sign-out</Setting>
        ) : null}
        <Setting label="Powered-off hosts">{run.IncludePoweredOff ? 'Started, patched and stopped again' : 'Skipped'}</Setting>
        <Setting label="Stops after">
          {run.MaxFailures} failure{run.MaxFailures === 1 ? '' : 's'}
        </Setting>
        <Setting label="Canary">
          {run.CanaryCount ? `Pauses after the first ${run.CanaryCount}${run.CanaryReached ? ' (done)' : ''}` : 'None'}
        </Setting>
      </dl>
      {run.WarningMessage ? (
        <p className="mt-4 mb-0 text-xs text-muted">
          Warning shown to users: <span className="text-ink">“{run.WarningMessage}”</span>
        </p>
      ) : null}
    </GlassCard>
  );
}

function AgentCell({ host, patching }: { host: MaintenanceHost; patching: boolean }) {
  if (!host.AgentVersion) {
    return <EmptyValue />;
  }
  return (
    <span className="flex flex-wrap items-center gap-1.5">
      <span className="font-mono text-xs">{host.AgentVersion}</span>
      {patching && !host.AgentCanPatch ? (
        <span title="Patching needs host agent 1.1.0. Update it with deploy/Migrate-LinuxHostReleaseAgent.ps1.">
          <Badge tone="warn" icon="alert-triangle">Too old to patch</Badge>
        </span>
      ) : null}
    </span>
  );
}

function HostTable({ run, hosts }: { run: MaintenanceRun; hosts: MaintenanceHost[] }) {
  const patching = run.PatchMode !== 'RebootOnly';
  return (
    <GlassCard className="overflow-hidden">
      <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--lb-hairline)] px-4 py-3">
        <h2 className="m-0 text-sm font-semibold">Hosts, in the order they are taken</h2>
        <span className="text-xs text-muted">{hosts.length} hosts</span>
      </div>
      <div className="overflow-x-auto">
        <table className="lb-table">
          <caption className="sr-only">Each host in {runTitle(run)} and how far it has got</caption>
          <thead>
            <tr>
              <th scope="col" className="text-right">#</th>
              <th scope="col">Host</th>
              <th scope="col">Step</th>
              <th scope="col">What is happening</th>
              <th scope="col">User</th>
              <th scope="col">Agent</th>
              <th scope="col" className="text-right">In this step</th>
            </tr>
          </thead>
          <tbody>
            {hosts.map((host) => (
              <tr key={host.RunHostID}>
                <td className="text-right text-muted tabular-nums">{host.Position}</td>
                <td className="whitespace-nowrap">
                  {host.Registered ? <Link to={`/vms/${host.VMID}`}>{host.Hostname}</Link> : host.Hostname}
                  {host.WasPoweredOff ? <span className="block text-xs text-muted">Was powered off</span> : null}
                </td>
                <td>
                  <HostStateBadge state={host.State} />
                  {host.RebootRequired === 'yes' && host.State !== 'Succeeded' ? (
                    <span className="block text-xs text-muted">Needs its restart</span>
                  ) : null}
                </td>
                <td className="max-w-[36ch] text-sm">{valueOrDash(host.Detail ?? HOST_STATES[host.State]?.help)}</td>
                <td className="text-sm">{host.Username ?? <EmptyValue />}</td>
                <td>
                  <AgentCell host={host} patching={patching} />
                </td>
                <td className="text-right text-xs whitespace-nowrap tabular-nums">
                  {host.CompletedAtUtc ? <RelativeTime value={host.CompletedAtUtc} /> : formatDuration(host.StepAgeSeconds)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </GlassCard>
  );
}

export function MaintenanceRunDetails() {
  const { runid } = useParams<{ runid: string }>();
  const { data, isPending, isFetching, error } = useMaintenanceRun(runid);
  const can = useCan();
  const actions = useMaintenanceActions();

  if (isPending) {
    return <LoadingPanel label="Loading the maintenance run" />;
  }

  if (error || !data) {
    return (
      <ErrorPanel
        message={errorMessage(error, 'Unable to retrieve the maintenance run.')}
        action={
          <ButtonLink to="/vms/maintenance" icon="chevron-left">
            All maintenance runs
          </ButtonLink>
        }
      />
    );
  }

  const { Run: run, Hosts: hosts } = data;
  const tooOld = run.PatchMode !== 'RebootOnly'
    ? hosts.filter((host) => host.Registered && host.AgentVersion && !host.AgentCanPatch && ['Pending', 'Draining'].includes(host.State))
    : [];

  return (
    <>
      <Breadcrumbs
        items={[{ label: 'Hosts', to: '/vms' }, { label: 'Maintenance', to: '/vms/maintenance' }, { label: `Run ${run.RunID}` }]}
      />
      <PageHeader
        title={runTitle(run)}
        subtitle={`${PATCH_MODES[run.PatchMode].label} for ${run.Counts.Total} host${run.Counts.Total === 1 ? '' : 's'}, started ${formatUtc(run.CreatedAtUtc)}${run.CreatedBy ? ` by ${run.CreatedBy}` : ''}.`}
        icon="wrench"
        actions={
          <>
            {isFetching ? <Spinner label="" /> : null}
            <RunStatusBadge status={run.Status} />
            {can.admin ? actions.buttons(run) : null}
            <ButtonLink to="/vms/maintenance" size="sm" icon="chevron-left">
              All runs
            </ButtonLink>
          </>
        }
      />

      {run.StatusReason ? <Notice tone={run.Status === 'Failed' ? 'danger' : 'warning'} className="mb-4">{run.StatusReason}</Notice> : null}
      {run.WaitReason ? <Notice tone="info" className="mb-4">{run.WaitReason}</Notice> : null}
      {tooOld.length ? (
        <Notice tone="warning" className="mb-4">
          {tooOld.map((host) => host.Hostname).slice(0, 5).join(', ')}
          {tooOld.length > 5 ? ` and ${tooOld.length - 5} more` : ''} run a host agent older than 1.1.0 and will fail when
          their turn comes. Update them with deploy/Migrate-LinuxHostReleaseAgent.ps1 before then.
        </Notice>
      ) : null}

      <div className="mb-4 grid grid-cols-1 gap-4 xl:grid-cols-3">
        <GlassCard className="p-5 xl:col-span-2">
          <h2 className="mt-0 mb-3 text-xs font-semibold tracking-wider text-muted uppercase">Progress</h2>
          <MaintenanceProgress counts={run.Counts} />
          <div className="mt-4">
            {run.EndedAtUtc ? (
              <p className="m-0 text-xs text-muted">Ended <RelativeTime value={run.EndedAtUtc} />.</p>
            ) : (
              <RunReadiness run={run} />
            )}
          </div>
        </GlassCard>
        <RunSettings run={run} />
      </div>

      <HostTable run={run} hosts={hosts} />

      <details className="mt-4 text-sm">
        <summary className="cursor-pointer text-muted">What the steps mean</summary>
        <dl className="mt-2 mb-0 grid grid-cols-1 gap-x-4 gap-y-2 md:grid-cols-[auto_1fr]">
          {STATE_ORDER.map((state) => (
            <div key={state} className="contents">
              <dt>
                <HostStateBadge state={state} />
              </dt>
              <dd className="m-0 text-muted">{HOST_STATES[state].help}</dd>
            </div>
          ))}
        </dl>
      </details>

      {actions.dialog}
    </>
  );
}
