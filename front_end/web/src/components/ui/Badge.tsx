import { classNames, DASH, isBlank } from '../../lib/format';
import { Icon } from '../Icon';
import type { IconName } from '../Icon';

export type Tone = 'ok' | 'accent' | 'info' | 'warn' | 'danger' | 'neutral';

export interface BadgeProps {
  tone?: Tone;
  icon: IconName;
  children: React.ReactNode;
  className?: string;
}

/**
 * Status pill.
 *
 * Every badge pairs colour with an icon and text, so status is never conveyed by
 * colour alone (WCAG 1.4.1). Keep that pattern for any new status.
 */
export function Badge({ tone = 'neutral', icon, children, className }: BadgeProps) {
  return (
    <span className={classNames('lb-badge', `lb-tone-${tone}`, className)}>
      <Icon name={icon} size={12} />
      <span>{children}</span>
    </span>
  );
}

/** Placeholder for an absent value, so an empty cell does not collapse its row. */
export function EmptyValue() {
  return <span className="text-subtle">{DASH}</span>;
}

interface StatusDescriptor {
  tone: Tone;
  icon: IconName;
  label: string;
}

function renderStatus(
  value: string | null | undefined,
  map: Record<string, StatusDescriptor>,
) {
  if (isBlank(value)) {
    return <EmptyValue />;
  }

  const key = String(value);
  const descriptor = map[key] ?? { tone: 'neutral' as Tone, icon: 'dash-circle' as IconName, label: key };

  return (
    <Badge tone={descriptor.tone} icon={descriptor.icon}>
      {descriptor.label}
    </Badge>
  );
}

const VM_STATUS: Record<string, StatusDescriptor> = {
  Available: { tone: 'ok', icon: 'check-circle', label: 'Available' },
  CheckedOut: { tone: 'accent', icon: 'person', label: 'Checked out' },
  Maintenance: { tone: 'warn', icon: 'wrench', label: 'Maintenance' },
  Released: { tone: 'info', icon: 'arrow-return', label: 'Released' },
};

const POWER_STATE: Record<string, StatusDescriptor> = {
  On: { tone: 'ok', icon: 'power', label: 'On' },
  Off: { tone: 'neutral', icon: 'power', label: 'Off' },
};

const NETWORK_STATUS: Record<string, StatusDescriptor> = {
  Reachable: { tone: 'ok', icon: 'wifi', label: 'Reachable' },
  Unreachable: { tone: 'danger', icon: 'wifi-off', label: 'Unreachable' },
};

const SCALING_ACTION: Record<string, StatusDescriptor> = {
  'Scale Up': { tone: 'ok', icon: 'arrow-up', label: 'Scale up' },
  'Scale Down': { tone: 'warn', icon: 'arrow-down', label: 'Scale down' },
  'No Action': { tone: 'neutral', icon: 'dash-circle', label: 'No action' },
};

export const VmStatusBadge = ({ value }: { value: string | null | undefined }) =>
  renderStatus(value, VM_STATUS);

export const PowerBadge = ({ value }: { value: string | null | undefined }) =>
  renderStatus(value, POWER_STATE);

export const NetworkBadge = ({ value }: { value: string | null | undefined }) =>
  renderStatus(value, NETWORK_STATUS);

export const ActionBadge = ({ value }: { value: string | null | undefined }) =>
  renderStatus(value, SCALING_ACTION);
