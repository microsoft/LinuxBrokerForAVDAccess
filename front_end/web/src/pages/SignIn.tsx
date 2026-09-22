import { GlassCard } from '../components/ui/GlassCard';
import { ButtonAnchor } from '../components/ui/Button';
import { Icon } from '../components/Icon';

export function SignIn() {
  return (
    <div className="flex min-h-[60vh] items-center justify-center">
      <GlassCard className="mx-auto w-full max-w-xl p-10 text-center">
        <Icon name="server" size={44} className="mx-auto text-subtle opacity-60" />
        <h1 className="mt-4 mb-2 text-2xl">Linux Broker Management Portal</h1>
        <p className="mx-auto mb-6 max-w-md text-sm text-muted">
          Broker Linux hosts to Azure Virtual Desktop sessions, and manage the pool&apos;s
          autoscaling rules. Sign in with your organizational account to continue.
        </p>
        {/* A full navigation: Flask starts the MSAL redirect, so this must not be a router link. */}
        <ButtonAnchor href="/login" variant="primary" icon="box-arrow-right">
          Sign in
        </ButtonAnchor>
      </GlassCard>
    </div>
  );
}
