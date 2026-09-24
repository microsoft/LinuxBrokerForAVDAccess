import type { IconName } from '../Icon';
import { Badge } from './Badge';
import type { Tone } from './Badge';
import type { HealthFlag, HostHealth } from '../../types/broker';

interface Descriptor {
  label: string;
  tone: Tone;
  icon: IconName;
  /** What the flag means and what to do about it, for tooltips and the legend. */
  help: string;
}

export const HEALTH_FLAGS: Record<HealthFlag, Descriptor> = {
  'no-heartbeat': {
    label: 'No heartbeat',
    tone: 'warn',
    icon: 'wifi-off',
    help: 'The host is on but has never reported. Its agent predates heartbeats; run deploy/Migrate-LinuxHostReleaseAgent.ps1.',
  },
  stale: {
    label: 'Stale',
    tone: 'warn',
    icon: 'clock',
    help: 'The host is on but its last heartbeat is older than three reconcile intervals. The agent may be stuck.',
  },
  'xrdp-down': {
    label: 'xrdp down',
    tone: 'danger',
    icon: 'x-circle',
    help: 'The xrdp service is not active, so users cannot connect to this host.',
  },
  'nfs-unreachable': {
    label: 'NFS unreachable',
    tone: 'danger',
    icon: 'alert-triangle',
    help: 'Home directories on the NFS share are not answering, so profiles cannot load.',
  },
  'low-disk': {
    label: 'Low disk',
    tone: 'warn',
    icon: 'alert-triangle',
    help: 'Less than 10% of the root disk is free.',
  },
  'agent-outdated': {
    label: 'Agent outdated',
    tone: 'info',
    icon: 'arrow-up',
    help: 'The host agent, or one of its scripts, is older than this broker expects.',
  },
  'settings-drift': {
    label: 'Settings drift',
    tone: 'info',
    icon: 'sliders',
    help: 'The host has not applied the current settings version yet. It converges on its next reconcile run.',
  },
};

export function HealthFlagBadge({ flag }: { flag: HealthFlag }) {
  const descriptor = HEALTH_FLAGS[flag];
  return (
    <span title={descriptor.help}>
      <Badge tone={descriptor.tone} icon={descriptor.icon}>
        {descriptor.label}
      </Badge>
    </span>
  );
}

const STATUS: Record<HostHealth['Status'], Omit<Descriptor, 'help'>> = {
  healthy: { label: 'Healthy', tone: 'ok', icon: 'check-circle' },
  attention: { label: 'Needs attention', tone: 'warn', icon: 'alert-triangle' },
  off: { label: 'Off', tone: 'neutral', icon: 'power' },
};

export function HealthStatusBadge({ status }: { status: HostHealth['Status'] }) {
  const descriptor = STATUS[status] ?? STATUS.attention;
  return (
    <Badge tone={descriptor.tone} icon={descriptor.icon}>
      {descriptor.label}
    </Badge>
  );
}
