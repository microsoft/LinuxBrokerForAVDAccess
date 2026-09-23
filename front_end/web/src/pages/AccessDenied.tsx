import { ButtonAnchor } from '../components/ui/Button';
import { GlassCard } from '../components/ui/GlassCard';
import { Icon } from '../components/Icon';
import { useSignOut } from '../hooks/useSession';

export function AccessDenied() {
  const signOut = useSignOut();

  return (
    <div className="flex min-h-[60vh] items-center justify-center">
      <GlassCard className="mx-auto w-full max-w-xl p-10 text-center">
        <Icon name="alert-triangle" size={44} className="mx-auto text-[var(--lb-warn-fg)]" />
        <h1 className="mt-4 mb-2 text-2xl">Administrator access required</h1>
        <p className="mx-auto mb-6 max-w-md text-sm text-muted">
          This portal is for broker administrators. Your AVD access is unchanged.
        </p>
        <ButtonAnchor href="/logout" variant="primary" icon="box-arrow-right" onClick={signOut}>
          Sign out or switch account
        </ButtonAnchor>
      </GlassCard>
    </div>
  );
}
