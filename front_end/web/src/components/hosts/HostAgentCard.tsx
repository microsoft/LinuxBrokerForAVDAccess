import { DetailList } from '../layout/Breadcrumbs';
import { Badge } from '../ui/Badge';
import { Notice, Spinner } from '../ui/Feedback';
import { GlassCard } from '../ui/GlassCard';
import { HealthFlagBadge, HealthStatusBadge } from '../ui/HealthBadges';
import { useHostHealth } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import { describeSeconds, formatAge, formatMegabytes, formatUtc, valueOrDash } from '../../lib/format';
import type { HostHealth, HostSession } from '../../types/broker';

function osLabel(host: HostHealth) {
  if (host.OsName) {
    return host.OsName;
  }
  const parts = [host.OsId, host.OsVersion].filter(Boolean);
  return parts.length ? parts.join(' ') : null;
}

function sessionLabel(session: HostSession, nowSeconds: number) {
  if (session.state === 'disconnected') {
    return session.disconnectedSince
      ? `disconnected ${formatAge(nowSeconds - session.disconnectedSince)}`
      : 'disconnected';
  }
  if (session.state === 'active') {
    return session.idleSeconds !== null && session.idleSeconds !== undefined
      ? `active, idle ${describeSeconds(session.idleSeconds)}`
      : 'active';
  }
  return 'state unknown';
}

/** Scripts whose version differs from the agent's, which means a partly migrated host. */
function mismatchedScripts(host: HostHealth) {
  return Object.entries(host.ScriptVersions ?? {}).filter(([, version]) => version !== host.AgentVersion);
}

export function HostAgentCard({ hostname }: { hostname: string }) {
  const { data, isPending, error } = useHostHealth(hostname);
  const host = data?.Hosts?.find((candidate) => candidate.Hostname === hostname) ?? data?.Hosts?.[0];

  return (
    <GlassCard className="p-5">
      <div className="mb-1 flex flex-wrap items-center justify-between gap-2">
        <h2 className="m-0 text-xs font-semibold tracking-wider text-muted uppercase">Host agent</h2>
        {host ? <HealthStatusBadge status={host.Status} /> : null}
      </div>

      {isPending ? (
        <div className="py-6">
          <Spinner label="Loading the latest heartbeat" />
        </div>
      ) : error ? (
        <Notice tone="warning" className="mt-3">
          {errorMessage(error, 'Unable to retrieve this host’s heartbeat.')}
        </Notice>
      ) : !host ? (
        <p className="mt-3 mb-0 text-sm text-muted">This host is not registered with the broker.</p>
      ) : host.HeartbeatAgeSeconds === null ? (
        <p className="mt-3 mb-0 text-sm text-muted">
          No heartbeat yet. The host agent reports its version, desktop, xrdp and NFS state on
          every reconcile run once it is version {data?.ExpectedAgentVersion} or later. Update it
          with <span className="font-mono">deploy/Migrate-LinuxHostReleaseAgent.ps1</span>.
        </p>
      ) : (
        <HostAgentDetails host={host} expectedVersion={data?.ExpectedAgentVersion} />
      )}
    </GlassCard>
  );
}

function HostAgentDetails({ host, expectedVersion }: { host: HostHealth; expectedVersion?: string }) {
  const nowSeconds = Math.floor(Date.now() / 1000);
  const mismatched = mismatchedScripts(host);

  return (
    <DetailList
      items={[
        {
          label: 'Problems',
          value: host.Flags.length ? (
            <span className="flex flex-wrap gap-1">
              {host.Flags.map((flag) => (
                <HealthFlagBadge key={flag} flag={flag} />
              ))}
            </span>
          ) : (
            'None reported'
          ),
        },
        {
          label: 'Last heartbeat',
          value: <span title={formatUtc(host.LastHeartbeatUtc)}>{formatAge(host.HeartbeatAgeSeconds)}</span>,
        },
        {
          label: 'Agent version',
          value: (
            <span className="flex flex-wrap items-center gap-2">
              <span className="font-mono">{valueOrDash(host.AgentVersion)}</span>
              {expectedVersion && host.AgentVersion !== expectedVersion ? (
                <span className="text-xs text-muted">expected {expectedVersion}</span>
              ) : null}
            </span>
          ),
        },
        ...(mismatched.length
          ? [
              {
                label: 'Scripts behind',
                value: (
                  <ul className="m-0 list-none p-0 text-xs">
                    {mismatched.map(([name, version]) => (
                      <li key={name}>
                        <span className="font-mono">{name}</span>{' '}
                        <span className="text-muted">{version ? `is ${version}` : 'predates versioning'}</span>
                      </li>
                    ))}
                  </ul>
                ),
              },
            ]
          : []),
        {
          label: 'Operating system',
          value: (
            <span>
              {valueOrDash(osLabel(host))}
              {host.KernelVersion ? (
                <span className="ml-2 font-mono text-xs text-muted">{host.KernelVersion}</span>
              ) : null}
            </span>
          ),
        },
        { label: 'Desktop', value: valueOrDash(host.Desktop) },
        {
          label: 'xrdp',
          value: (
            <span className="flex flex-wrap items-center gap-2">
              <span className="font-mono">{valueOrDash(host.XrdpVersion)}</span>
              {host.XrdpActive === true ? (
                <Badge tone="ok" icon="check-circle">Running</Badge>
              ) : host.XrdpActive === false ? (
                <Badge tone="danger" icon="x-circle">Not running</Badge>
              ) : null}
            </span>
          ),
        },
        {
          label: 'NFS homes',
          value:
            host.NfsReachable === null ? (
              'Not checked yet: no home has been mounted on this host'
            ) : (
              <span className="flex flex-wrap items-center gap-2">
                {host.NfsReachable ? (
                  <Badge tone="ok" icon="check-circle">Answering</Badge>
                ) : (
                  <Badge tone="danger" icon="alert-triangle">Not answering</Badge>
                )}
                <span className="text-xs text-muted">{host.NfsMountCount ?? 0} mounted</span>
              </span>
            ),
        },
        {
          label: 'Load',
          value:
            host.LoadAverage === null
              ? valueOrDash(null)
              : `${host.LoadAverage.toFixed(2)}${host.CpuCount ? ` on ${host.CpuCount} CPUs` : ''}`,
        },
        {
          label: 'Memory available',
          value:
            host.MemoryAvailableMb === null
              ? valueOrDash(null)
              : `${formatMegabytes(host.MemoryAvailableMb)}${host.MemoryTotalMb ? ` of ${formatMegabytes(host.MemoryTotalMb)}` : ''}`,
        },
        {
          label: 'Root disk free',
          value: host.RootDiskFreePct === null ? valueOrDash(null) : `${host.RootDiskFreePct}%`,
        },
        { label: 'Up for', value: host.UptimeSeconds === null ? valueOrDash(null) : describeSeconds(host.UptimeSeconds) },
        {
          label: 'Sessions',
          value: host.Sessions.length ? (
            <ul className="m-0 list-none p-0">
              {host.Sessions.map((session) => (
                <li key={session.username}>
                  <strong>{session.username}</strong>{' '}
                  <span className="text-muted">{sessionLabel(session, nowSeconds)}</span>
                </li>
              ))}
            </ul>
          ) : (
            'None'
          ),
        },
      ]}
    />
  );
}
