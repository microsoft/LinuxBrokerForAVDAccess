import { Link, useParams } from 'react-router-dom';

import { Breadcrumbs } from '../../components/layout/Breadcrumbs';
import { SessionStateBadge, sessionDetail } from '../../components/sessions/SessionState';
import { ActionMenu } from '../../components/ui/ActionMenu';
import { AuditOutcomeBadge, Badge } from '../../components/ui/Badge';
import { Button, ButtonLink } from '../../components/ui/Button';
import { EmptyState, ErrorPanel, LoadingPanel, Notice, PageHeader } from '../../components/ui/Feedback';
import { GlassCard } from '../../components/ui/GlassCard';
import { useToast } from '../../components/ui/Toast';
import { useProfileReset, useUserDetails } from '../../hooks/useBroker';
import { useConfirm } from '../../hooks/useConfirm';
import { useSessionActions } from '../../hooks/useSessionActions';
import { useCan } from '../../hooks/useSession';
import { errorMessage } from '../../lib/api';
import { formatDuration, formatUtc, valueOrDash } from '../../lib/format';
import type { BrokerUserDetails } from '../../types/broker';

function CardTitle({ children }: { children: React.ReactNode }) {
  return <h2 className="mb-3 text-xs font-semibold tracking-wider text-muted uppercase">{children}</h2>;
}

function CurrentSessions({ user, actionsFor }: { user: BrokerUserDetails; actionsFor: ReturnType<typeof useSessionActions>['actionsFor'] }) {
  if (!user.Sessions.length) {
    return (
      <p className="m-0 text-sm text-muted">
        {user.Username} has no Linux host and no reported session. The next checkout from Azure Virtual Desktop assigns one.
      </p>
    );
  }

  return (
    <ul className="m-0 flex list-none flex-col divide-y divide-[var(--lb-hairline)] p-0">
      {user.Sessions.map((session) => {
        const items = actionsFor(session);
        return (
          <li key={session.Hostname} className="flex flex-wrap items-center justify-between gap-3 py-3 first:pt-0 last:pb-0">
            <div className="min-w-0">
              <div className="flex flex-wrap items-center gap-2">
                {session.VMID ? (
                  <Link to={`/vms/${session.VMID}`} className="font-semibold no-underline hover:underline">
                    {session.Hostname}
                  </Link>
                ) : (
                  <span className="font-semibold">{session.Hostname}</span>
                )}
                <SessionStateBadge state={session.State} />
                {session.DrainRequested ? <Badge tone="warn" icon="box-arrow-right">Host draining</Badge> : null}
              </div>
              <p className="mt-1 mb-0 text-xs text-muted">
                {sessionDetail(session)}
                {session.AvdHost ? ` · from ${session.AvdHost}` : ''}
                {session.AssignedForSeconds !== null ? ` · assigned ${formatDuration(session.AssignedForSeconds)} ago` : ''}
              </p>
            </div>
            {items.length ? (
              <ActionMenu label={`Session actions for ${session.Username} on ${session.Hostname}`} text="Session" items={items} />
            ) : null}
          </li>
        );
      })}
    </ul>
  );
}

export function UserDetails() {
  const { username } = useParams<{ username: string }>();
  const { data: user, isPending, error } = useUserDetails(username);
  const can = useCan();
  const { showToast } = useToast();
  const { confirm, dialog } = useConfirm();
  const sessionActions = useSessionActions();
  const profileReset = useProfileReset();

  if (isPending) {
    return <LoadingPanel label="Loading the user" />;
  }

  if (error || !user) {
    return (
      <ErrorPanel
        message={errorMessage(error, 'Unable to retrieve the user.')}
        action={
          <ButtonLink to="/sessions" icon="chevron-left">
            Back to sessions
          </ButtonLink>
        }
      />
    );
  }

  const name = user.Username;
  const pending = user.ProfileReset;

  function requestReset() {
    confirm({
      title: `Reset ${name}'s profile`,
      body: user?.Sessions.some((session) => session.HasAssignment)
        ? `${name} gets an empty home directory the next time they sign in after the current session ends. The current profile is kept on the share, renamed, and can be restored by an administrator.`
        : `${name} gets an empty home directory the next time they sign in. The current profile is kept on the share, renamed, and can be restored by an administrator.`,
      confirmLabel: 'Reset profile',
      variant: 'danger',
      requireText: name,
      onConfirm: async () => {
        try {
          const result = await profileReset.mutateAsync({ username: name });
          showToast(result.message, 'success');
        } catch (cause) {
          showToast(errorMessage(cause, `Unable to reset ${name}'s profile.`), 'danger');
        }
      },
    });
  }

  function cancelReset() {
    confirm({
      title: `Keep ${name}'s profile`,
      body: `Cancel the profile reset? ${name} keeps their current profile at the next sign-in.`,
      confirmLabel: 'Cancel the reset',
      variant: 'primary',
      onConfirm: async () => {
        try {
          const result = await profileReset.mutateAsync({ username: name, cancel: true });
          showToast(result.message, 'success');
        } catch (cause) {
          showToast(errorMessage(cause, 'Unable to cancel the profile reset.'), 'danger');
        }
      },
    });
  }

  return (
    <>
      <Breadcrumbs items={[{ label: 'Sessions', to: '/sessions' }, { label: name }]} />

      <PageHeader
        title={name}
        subtitle={user.Uid !== null ? `Linux user ID ${user.Uid}` : 'Not provisioned on a host yet'}
        icon="person"
        actions={
          <>
            <ButtonLink to="/sessions" size="sm" icon="chevron-left">
              Back to sessions
            </ButtonLink>
            {can.admin && user.Uid !== null ? (
              pending ? (
                <Button size="sm" icon="x" onClick={cancelReset}>
                  Cancel profile reset
                </Button>
              ) : (
                <Button size="sm" variant="danger" icon="refresh" onClick={requestReset}>
                  Reset profile
                </Button>
              )
            ) : null}
          </>
        }
      />

      {pending ? (
        <Notice tone="warning" className="mb-4">
          <strong>Profile reset pending.</strong>{' '}
          {pending.RequestedBy ? `${pending.RequestedBy} asked` : 'An administrator asked'} for a fresh profile on{' '}
          {formatUtc(pending.RequestedAtUtc)}. It is applied the next time {name} signs in to a new host; the current
          profile is kept, renamed.
        </Notice>
      ) : null}

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
        <GlassCard className="p-5">
          <CardTitle>Right now</CardTitle>
          <CurrentSessions user={user} actionsFor={sessionActions.actionsFor} />
        </GlassCard>

        <GlassCard className="p-5">
          <CardTitle>Hosts in the last 90 days</CardTitle>
          {user.HostHistory.length ? (
            <div className="overflow-auto">
              <table className="lb-table">
                <thead>
                  <tr>
                    <th scope="col">Host</th>
                    <th scope="col">First on it (UTC)</th>
                    <th scope="col">Last on it (UTC)</th>
                    <th scope="col" className="text-right">
                      Assignments
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {user.HostHistory.map((entry) => (
                    <tr key={entry.VMID}>
                      <td className="whitespace-nowrap">
                        <Link to={`/vms/${entry.VMID}`} className="font-semibold no-underline hover:underline">
                          {entry.Hostname}
                        </Link>
                        {entry.IsCurrent ? <span className="ml-2 text-xs text-muted">now</span> : null}
                      </td>
                      <td className="font-mono text-xs whitespace-nowrap">{formatUtc(entry.FirstSeenUtc).replace(' UTC', '')}</td>
                      <td className="font-mono text-xs whitespace-nowrap">
                        {entry.IsCurrent ? 'Now' : formatUtc(entry.LastSeenUtc).replace(' UTC', '')}
                      </td>
                      <td className="text-right tabular-nums">{entry.Assignments}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <p className="m-0 text-sm text-muted">No host assignments in the last 90 days.</p>
          )}
        </GlassCard>
      </div>

      <GlassCard className="mt-4 p-5">
        <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
          <CardTitle>Recent actions on {name}</CardTitle>
          <Link to={`/audit?target=${encodeURIComponent(name)}`} className="text-xs no-underline hover:underline">
            View in the audit log
          </Link>
        </div>
        {user.RecentActivity.length ? (
          <div className="overflow-auto">
            <table className="lb-table">
              <thead>
                <tr>
                  <th scope="col">When (UTC)</th>
                  <th scope="col">Action</th>
                  <th scope="col">Who</th>
                  <th scope="col">Outcome</th>
                </tr>
              </thead>
              <tbody>
                {user.RecentActivity.map((entry) => (
                  <tr key={entry.AuditId}>
                    <td className="font-mono text-xs whitespace-nowrap">{formatUtc(entry.OccurredAtUtc).replace(' UTC', '')}</td>
                    <td className="font-mono text-xs whitespace-nowrap">{entry.Action}</td>
                    <td className="text-xs">{valueOrDash(entry.ActorName ?? entry.ActorOid)}</td>
                    <td>
                      <AuditOutcomeBadge outcome={entry.Outcome} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <EmptyState
            title="Nothing recorded yet"
            message={`Sign-outs, messages and profile resets for ${name} are listed here.`}
            icon="shield"
          />
        )}
      </GlassCard>

      {dialog}
      {sessionActions.dialog}
    </>
  );
}
