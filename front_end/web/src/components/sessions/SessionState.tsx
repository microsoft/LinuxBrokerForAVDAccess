import { Badge } from '../ui/Badge';
import type { Tone } from '../ui/Badge';
import type { IconName } from '../Icon';
import { formatDuration } from '../../lib/format';
import type { BrokerSession, SessionState } from '../../types/broker';

interface StateDescriptor {
  label: string;
  tone: Tone;
  icon: IconName;
  help: string;
}

/** Every state the broker reports, in the order the filters show them. */
export const SESSION_STATES: Record<SessionState, StateDescriptor> = {
  active: {
    label: 'Active',
    tone: 'ok',
    icon: 'person',
    help: 'Connected and in use. Idle time comes from the last host report.',
  },
  disconnected: {
    label: 'Disconnected',
    tone: 'info',
    icon: 'wifi-off',
    help: 'The desktop is still running without a connection. The user can reconnect to it until the grace period ends.',
  },
  released: {
    label: 'In grace period',
    tone: 'info',
    icon: 'clock',
    help: 'The user disconnected. The host stays theirs until the grace period ends, then returns to the pool.',
  },
  connecting: {
    label: 'Connecting',
    tone: 'accent',
    icon: 'refresh',
    help: 'Checked out moments ago; the host has not reported the session yet.',
  },
  'not-connected': {
    label: 'Never connected',
    tone: 'warn',
    icon: 'alert-triangle',
    help: 'Checked out, but the host has never reported the user signed in. Return the host if they are not coming back.',
  },
  'cleanup-pending': {
    label: 'Cleanup pending',
    tone: 'warn',
    icon: 'refresh',
    help: 'The assignment ended and the broker is still removing the account from the host. It retries automatically.',
  },
  unmanaged: {
    label: 'Not brokered',
    tone: 'neutral',
    icon: 'dash-circle',
    help: 'Signed in to a host without a broker assignment, for example an administrator.',
  },
  unknown: {
    label: 'Unknown',
    tone: 'neutral',
    icon: 'info-circle',
    help: 'The host has not reported recently, so the session state cannot be confirmed.',
  },
};

export function SessionStateBadge({ state }: { state: SessionState }) {
  const descriptor = SESSION_STATES[state] ?? SESSION_STATES.unknown;
  return (
    <Badge tone={descriptor.tone} icon={descriptor.icon}>
      {descriptor.label}
    </Badge>
  );
}

/** One line saying what an operator needs to know about the session now. */
export function sessionDetail(session: BrokerSession): string {
  const idle =
    session.IdleSeconds !== null && session.IdleSeconds >= 60 ? `idle ${formatDuration(session.IdleSeconds)}` : null;

  switch (session.State) {
    case 'active':
      return idle ? `In use, ${idle}` : 'In use';
    case 'disconnected': {
      const since =
        session.DisconnectedForSeconds !== null
          ? `Disconnected ${formatDuration(session.DisconnectedForSeconds)} ago`
          : 'Disconnected';
      if (session.GraceRemainingSeconds !== null) {
        return `${since}; grace ends in ${formatDuration(session.GraceRemainingSeconds)}`;
      }
      if (session.GracePeriodSeconds !== null && session.DisconnectedForSeconds !== null) {
        return `${since}; signed out in ${formatDuration(Math.max(0, session.GracePeriodSeconds - session.DisconnectedForSeconds))}`;
      }
      return since;
    }
    case 'released':
      return session.GraceRemainingSeconds
        ? `Grace ends in ${formatDuration(session.GraceRemainingSeconds)}`
        : 'Grace period over; the host returns to the pool shortly';
    case 'connecting':
      return session.LastCheckoutAgeSeconds !== null
        ? `Checked out ${formatDuration(session.LastCheckoutAgeSeconds)} ago`
        : 'Checked out just now';
    case 'not-connected':
      return session.LastCheckoutAgeSeconds !== null
        ? `Checked out ${formatDuration(session.LastCheckoutAgeSeconds)} ago; no session since`
        : 'Checked out; no session since';
    case 'cleanup-pending':
      return 'Removing the account from the host';
    case 'unmanaged':
      return idle ? `Signed in without an assignment, ${idle}` : 'Signed in without an assignment';
    default:
      return session.HeartbeatAgeSeconds === null
        ? 'The host has never reported'
        : `No host report for ${formatDuration(session.HeartbeatAgeSeconds)}`;
  }
}

/** Whether the host reports the user's desktop running, so a message can reach it. */
export function hasDesktop(session: Pick<BrokerSession, 'State'>) {
  return session.State === 'active' || session.State === 'disconnected' || session.State === 'unmanaged';
}
