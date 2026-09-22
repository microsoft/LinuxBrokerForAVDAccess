import { ButtonLink } from '../components/ui/Button';
import { GlassCard } from '../components/ui/GlassCard';
import { Icon } from '../components/Icon';

export interface ErrorPageProps {
  code?: number;
  title?: string;
  message?: string;
}

/**
 * Shared error shell.
 *
 * Replaces error.html, including its zero-argument fallback: rendered with no
 * props it still produces a usable page rather than a blank one.
 */
export function ErrorPage({
  code,
  title = 'Something went wrong',
  message = 'An unexpected error occurred. The issue has been logged.',
}: ErrorPageProps) {
  return (
    <div className="flex min-h-[60vh] items-center justify-center">
      <GlassCard className="mx-auto w-full max-w-xl p-10 text-center">
        <Icon name="alert-triangle" size={44} className="mx-auto text-[var(--lb-warn-fg)]" />
        {code ? (
          <p className="mt-4 mb-1 font-mono text-sm tracking-widest text-subtle">{code}</p>
        ) : null}
        <h1 className="mt-2 mb-2 text-2xl">{title}</h1>
        <p className="mx-auto mb-6 max-w-md text-sm text-muted">{message}</p>
        <ButtonLink to="/" variant="primary" icon="home">
          Back to dashboard
        </ButtonLink>
      </GlassCard>
    </div>
  );
}
