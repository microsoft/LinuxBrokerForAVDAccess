import { Link } from 'react-router-dom';

import { HEALTH_FLAGS } from '../ui/HealthBadges';
import { GlassCard } from '../ui/GlassCard';
import { Icon } from '../Icon';
import type { IconName } from '../Icon';
import { formatAge, formatDuration } from '../../lib/format';
import type { AttentionItem, AttentionItems, AttentionSeverity } from '../../types/broker';

const SEVERITY: Record<AttentionSeverity, { icon: IconName; colour: string; label: string }> = {
  critical: { icon: 'x-circle', colour: 'var(--lb-danger-fg)', label: 'Critical' },
  warning: { icon: 'alert-triangle', colour: 'var(--lb-warn-fg)', label: 'Warning' },
  info: { icon: 'info-circle', colour: 'var(--lb-info-fg)', label: 'Notice' },
};

interface Described {
  text: React.ReactNode;
  to: string;
  action: string;
}

function plural(count: number, noun: string) {
  return `${count} ${noun}${count === 1 ? '' : 's'}`;
}

function hostList(hostnames: string[] | undefined, count: number) {
  const names = hostnames ?? [];
  const more = count - names.length;
  return `${names.join(', ')}${more > 0 ? ` and ${more} more` : ''}`;
}

/** What an item means in words, and where an operator goes to act on it. */
export function describeAttention(item: AttentionItem): Described {
  const host = item.Hostname ?? 'A host';
  const hostLink = item.VMID ? `/vms/${item.VMID}` : '/vms';
  const lasted = formatDuration(item.AgeSeconds);

  switch (item.Kind) {
    case 'no-ready-hosts':
      return {
        text: <>No host can take a new user: anyone who needs one now will be turned away.</>,
        to: '/vms',
        action: 'View hosts',
      };
    case 'denied-checkouts':
      return {
        text: (
          <>
            {plural(item.Count ?? 0, 'checkout')} found no host in the last hour, most recently {formatAge(item.AgeSeconds)}.
          </>
        ),
        to: '/scaling',
        action: 'Review scaling',
      };
    case 'unreachable':
      return {
        text: (
          <>
            <strong>{host}</strong> is powered on but has not been reachable for {lasted}.
          </>
        ),
        to: hostLink,
        action: 'Open host',
      };
    case 'cleanup-stuck':
      return {
        text: (
          <>
            <strong>{host}</strong> has not removed {item.Username ? <strong>{item.Username}</strong> : 'its last user'} after {lasted},
            so it cannot be given to anyone else.
          </>
        ),
        to: hostLink,
        action: 'Open host',
      };
    case 'never-connected':
      return {
        text: (
          <>
            <strong>{item.Username ?? 'A user'}</strong> checked out <strong>{host}</strong> {lasted} ago but is not signed in.
          </>
        ),
        to: item.Username ? `/users/${encodeURIComponent(item.Username)}` : '/sessions',
        action: 'Open user',
      };
    case 'maintenance-failed':
      return {
        text: (
          <>
            Maintenance could not finish <strong>{host}</strong>, so it is out of rotation
            {item.Detail ? `: ${item.Detail.replace(/\.$/, '')}` : ''}.
          </>
        ),
        to: item.RunID ? `/vms/maintenance/${item.RunID}` : '/vms/maintenance',
        action: 'Open run',
      };
    case 'health': {
      const flag = item.Flag ? HEALTH_FLAGS[item.Flag] : undefined;
      const count = item.Count ?? item.Hostnames?.length ?? 0;
      return {
        text: (
          <>
            {plural(count, 'host')} {flag ? <strong>{flag.label.toLowerCase()}</strong> : 'need a look'}: {hostList(item.Hostnames, count)}.
          </>
        ),
        to: item.Flag ? `/vms/health?show=${item.Flag}` : '/vms/health',
        action: 'Fleet health',
      };
    }
    default:
      return { text: <>{host} needs attention.</>, to: hostLink, action: 'Open' };
  }
}

function itemKey(item: AttentionItem, index: number) {
  return `${item.Kind}-${item.Flag ?? ''}-${item.VMID ?? ''}-${item.Username ?? ''}-${index}`;
}

/** What needs an operator now. Renders nothing when all is well. */
export function AttentionPanel({ data }: { data: AttentionItems | undefined }) {
  if (!data?.Available || !data.Items.length) {
    return null;
  }

  const critical = data.Summary.Critical ?? 0;

  return (
    <GlassCard
      className="mb-5 overflow-hidden"
      style={{ borderColor: critical ? 'var(--lb-danger-bd)' : 'var(--lb-warn-bd)' }}
    >
      <section aria-labelledby="attention-heading">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--lb-hairline)] px-4 py-3">
          <h2 id="attention-heading" className="m-0 flex items-center gap-2 text-sm font-semibold">
            <Icon
              name={critical ? 'x-circle' : 'alert-triangle'}
              size={16}
              style={{ color: critical ? 'var(--lb-danger-fg)' : 'var(--lb-warn-fg)' }}
            />
            Needs attention now
          </h2>
          <span className="text-xs text-muted">
            {plural(data.Summary.Total, 'item')}
            {critical ? ` · ${critical} critical` : ''}
          </span>
        </div>
        <ul className="m-0 list-none divide-y divide-[var(--lb-hairline)] p-0">
          {data.Items.map((item, index) => {
            const severity = SEVERITY[item.Severity] ?? SEVERITY.warning;
            const described = describeAttention(item);
            return (
              <li key={itemKey(item, index)} className="flex items-start gap-3 px-4 py-2.5 text-sm">
                <Icon name={severity.icon} size={16} className="mt-0.5 shrink-0" style={{ color: severity.colour }} />
                <span className="sr-only">{severity.label}: </span>
                <span className="min-w-0 flex-1">{described.text}</span>
                <Link to={described.to} className="shrink-0 text-xs whitespace-nowrap no-underline hover:underline">
                  {described.action}
                </Link>
              </li>
            );
          })}
        </ul>
        {data.Incomplete ? (
          <p className="m-0 border-t border-[var(--lb-hairline)] px-4 py-2 text-xs text-muted">
            Only host health is shown: the broker database does not report its own checks yet.
          </p>
        ) : null}
      </section>
    </GlassCard>
  );
}
