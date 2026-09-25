import { Icon } from '../Icon';
import { Badge } from '../ui/Badge';
import type { Tone } from '../ui/Badge';
import type { IconName } from '../Icon';

const STAGES: Array<{ label: string; tone: Tone; icon: IconName; text: string }> = [
  { label: 'Available', tone: 'ok', icon: 'check-circle', text: 'Free for the next user who signs in to Azure Virtual Desktop.' },
  { label: 'Checked out', tone: 'accent', icon: 'person', text: 'Assigned to one user, who can disconnect and come back to it.' },
  { label: 'Released', tone: 'info', icon: 'box-arrow-right', text: 'The user signed out. It stays theirs for the grace period, then returns.' },
];

const TERMS: Array<{ term: string; text: string }> = [
  {
    term: 'Release',
    text: 'Marks a checked-out host as released, as the host agent does when the user signs out. The user keeps it until the grace period ends and can reconnect to it.',
  },
  {
    term: 'Return',
    text: 'Ends the assignment now: the host is available again as soon as the broker removes the user from it (the cleanup).',
  },
  {
    term: 'Cleanup',
    text: 'After a return, the broker deletes the local account and unmounts the home directory. Until that succeeds the host is not given to anyone else; it is retried every two minutes.',
  },
  {
    term: 'Drain',
    text: 'Takes a host out of rotation without disturbing its user. No one new is assigned, and it moves to maintenance when the assignment ends.',
  },
  {
    term: 'Maintenance',
    text: 'Out of rotation: never assigned and never stopped or started by scaling. Return to service puts it back.',
  },
];

/** How a host moves through the broker, and what each action does to it. */
export function LifecycleExplainer({ className }: { className?: string }) {
  return (
    <details className={className}>
      <summary className="cursor-pointer text-sm text-muted">How a host moves through the broker</summary>
      <div className="mt-3">
        <ol
          aria-label="Host lifecycle"
          className="m-0 flex list-none flex-col gap-2 p-0 md:flex-row md:items-stretch md:gap-0"
        >
          {STAGES.map((stage, index) => (
            <li key={stage.label} className="flex items-stretch md:flex-1">
              <div className="flex-1 rounded-md border border-[var(--lb-hairline)] p-3">
                <Badge tone={stage.tone} icon={stage.icon}>
                  {stage.label}
                </Badge>
                <p className="mt-2 mb-0 text-xs text-muted">{stage.text}</p>
              </div>
              <span aria-hidden className="hidden items-center px-2 text-muted md:flex">
                <Icon name={index === STAGES.length - 1 ? 'arrow-return' : 'chevron-right'} size={16} />
              </span>
            </li>
          ))}
        </ol>
        <p className="mt-2 mb-0 text-xs text-muted">
          Then back to Available once the previous user has been removed.
        </p>
        <dl className="mt-4 mb-0 grid grid-cols-1 gap-x-4 gap-y-2 text-sm md:grid-cols-[auto_1fr]">
          {TERMS.map((entry) => (
            <div key={entry.term} className="contents">
              <dt className="font-semibold">{entry.term}</dt>
              <dd className="m-0 text-muted">{entry.text}</dd>
            </div>
          ))}
        </dl>
      </div>
    </details>
  );
}
