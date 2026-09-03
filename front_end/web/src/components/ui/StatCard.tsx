import { Link } from 'react-router-dom';

import { classNames, formatNumber } from '../../lib/format';
import { Icon } from '../Icon';
import type { IconName } from '../Icon';

export type StatTone = 'brand' | 'ok' | 'accent' | 'warn' | 'neutral';

const ACCENT: Record<StatTone, string> = {
  brand: 'var(--lb-brand)',
  ok: 'var(--lb-ok-fg)',
  accent: 'var(--lb-accent-fg)',
  warn: 'var(--lb-warn-fg)',
  neutral: 'var(--lb-ink-subtle)',
};

export interface StatCardProps {
  label: string;
  value: number;
  hint?: string;
  icon: IconName;
  tone?: StatTone;
  to?: string;
}

export function StatCard({ label, value, hint, icon, tone = 'brand', to }: StatCardProps) {
  const accent = ACCENT[tone];

  const body = (
    <>
      {/* The tinted wash is what makes the counter read as a lens over the backdrop. */}
      <span
        aria-hidden
        className="pointer-events-none absolute inset-0 rounded-[inherit] opacity-70"
        style={{ background: `radial-gradient(120% 100% at 0% 0%, ${accent}22, transparent 62%)` }}
      />
      <span className="relative flex items-center gap-1.5 text-xs font-semibold tracking-wide text-muted uppercase">
        <Icon name={icon} size={13} style={{ color: accent }} />
        {label}
      </span>
      <span className="relative mt-2 block text-3xl font-semibold tabular-nums" style={{ color: accent }}>
        {formatNumber(value)}
      </span>
      {hint ? <span className="relative mt-1 block text-xs text-muted">{hint}</span> : null}
    </>
  );

  const className = classNames(
    'lb-glass relative block overflow-hidden p-4 no-underline',
    to && 'lb-interactive',
  );

  return to ? (
    <Link to={to} className={className}>
      {body}
    </Link>
  ) : (
    <div className={className}>{body}</div>
  );
}
