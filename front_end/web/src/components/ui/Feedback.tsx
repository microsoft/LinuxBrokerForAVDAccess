import type { ReactNode } from 'react';

import { classNames } from '../../lib/format';
import { Icon } from '../Icon';
import type { IconName } from '../Icon';
import { GlassCard } from './GlassCard';

export interface PageHeaderProps {
  title: string;
  subtitle?: string;
  icon?: IconName;
  actions?: ReactNode;
}

export function PageHeader({ title, subtitle, icon, actions }: PageHeaderProps) {
  return (
    <div className="mb-5 flex flex-wrap items-start justify-between gap-4">
      <div>
        <h1 className="flex items-center gap-2 text-2xl">
          {icon ? <Icon name={icon} size={22} className="text-muted" /> : null}
          {title}
        </h1>
        {subtitle ? <p className="mt-1 mb-0 text-sm text-muted">{subtitle}</p> : null}
      </div>
      {actions ? <div className="flex flex-wrap items-center gap-2">{actions}</div> : null}
    </div>
  );
}

export interface EmptyStateProps {
  title: string;
  message?: string;
  icon?: IconName;
  action?: ReactNode;
}

export function EmptyState({ title, message, icon = 'list', action }: EmptyStateProps) {
  return (
    <GlassCard className="px-6 py-12 text-center">
      <Icon name={icon} size={40} className="mx-auto text-subtle opacity-60" />
      <p className="mt-3 mb-1 font-semibold">{title}</p>
      {message ? <p className="mb-0 text-sm text-muted">{message}</p> : null}
      {action ? <div className="mt-4 flex justify-center">{action}</div> : null}
    </GlassCard>
  );
}

export type NoticeTone = 'info' | 'success' | 'warning' | 'danger';

const NOTICE_TONE: Record<NoticeTone, { cls: string; icon: IconName }> = {
  info: { cls: 'lb-tone-info', icon: 'info-circle' },
  success: { cls: 'lb-tone-ok', icon: 'check-circle' },
  warning: { cls: 'lb-tone-warn', icon: 'alert-triangle' },
  danger: { cls: 'lb-tone-danger', icon: 'alert-triangle' },
};

export interface NoticeProps {
  tone?: NoticeTone;
  children: ReactNode;
  className?: string;
}

/** Inline explanatory or warning panel. Always pairs its colour with an icon. */
export function Notice({ tone = 'info', children, className }: NoticeProps) {
  const { cls, icon } = NOTICE_TONE[tone];

  return (
    <div
      role={tone === 'danger' || tone === 'warning' ? 'alert' : undefined}
      className={classNames(
        'flex items-start gap-2 rounded-[var(--radius-glass-sm)] border px-3.5 py-3 text-sm',
        'border-[var(--tone-bd)] bg-[var(--tone-bg)] text-[var(--tone-fg)]',
        cls,
        className,
      )}
    >
      <Icon name={icon} size={16} className="mt-0.5 shrink-0" />
      <div className="min-w-0">{children}</div>
    </div>
  );
}

export function Spinner({ label = 'Loading' }: { label?: string }) {
  return (
    <span className="inline-flex items-center gap-2 text-sm text-muted" role="status">
      <span
        aria-hidden
        className="size-4 animate-spin rounded-full border-2 border-[var(--lb-hairline)] border-t-[var(--lb-brand)]"
      />
      {label}
    </span>
  );
}

export function LoadingPanel({ label = 'Loading' }: { label?: string }) {
  return (
    <GlassCard className="px-6 py-12 text-center">
      <Spinner label={label} />
    </GlassCard>
  );
}

export function ErrorPanel({
  title = 'Something went wrong',
  message,
  action,
}: {
  title?: string;
  message: string;
  action?: ReactNode;
}) {
  return (
    <GlassCard className="px-6 py-10 text-center">
      <Icon name="alert-triangle" size={36} className="mx-auto text-[var(--lb-danger-fg)]" />
      <p className="mt-3 mb-1 font-semibold">{title}</p>
      <p className="mb-0 text-sm text-muted">{message}</p>
      {action ? <div className="mt-4 flex justify-center">{action}</div> : null}
    </GlassCard>
  );
}
