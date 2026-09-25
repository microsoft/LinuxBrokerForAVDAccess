import { PageHeader } from '../components/ui/Feedback';
import { GlassCard } from '../components/ui/GlassCard';
import { Switch } from '../components/ui/Field';
import { ButtonAnchor } from '../components/ui/Button';
import { useSession } from '../hooks/useSession';
import { valueOrDash } from '../lib/format';
import { usePreferences } from '../lib/preferences';

export function Profile() {
  const session = useSession();
  const preferences = usePreferences();
  const user = session.user;

  const rows: Array<{ label: string; value: string }> = [
    { label: 'Name', value: valueOrDash(user?.name) },
    { label: 'Username', value: valueOrDash(user?.username) },
    { label: 'Object ID', value: valueOrDash(user?.objectId) },
    { label: 'Tenant ID', value: valueOrDash(user?.tenantId) },
    { label: 'Roles', value: session.roles.length ? session.roles.join(', ') : 'None' },
    { label: 'Effective permissions', value: ['read', 'operate', 'admin'].filter((key) => session.permissions[key as keyof typeof session.permissions]).join(', ') || 'None' },
    { label: 'Legacy access', value: session.legacyAccess ? 'Yes' : 'No' },
  ];

  return (
    <>
      <PageHeader
        title="Profile"
        subtitle="The account this portal session is signed in with, and how the portal behaves for you."
        icon="person"
        actions={
          <ButtonAnchor href="/logout" icon="box-arrow-right">
            Sign out
          </ButtonAnchor>
        }
      />

      <div className="flex max-w-2xl flex-col gap-4">
        <GlassCard className="p-6">
          <dl className="m-0 grid grid-cols-1 gap-5 sm:grid-cols-2">
            {rows.map((row) => (
              <div key={row.label}>
                <dt className="text-xs font-semibold tracking-wide text-muted uppercase">
                  {row.label}
                </dt>
                <dd className="mt-1 mb-0 font-mono text-sm break-all">{row.value}</dd>
              </div>
            ))}
          </dl>
        </GlassCard>

        <GlassCard className="p-6">
          <h2 className="mt-0 mb-4 text-xs font-semibold tracking-wider text-muted uppercase">Preferences</h2>
          <div className="flex flex-col gap-5">
            <Switch
              label="Compact tables"
              help="Tighter rows, so more hosts and sessions fit on a screen."
              checked={preferences.density === 'compact'}
              onChange={(compact) => preferences.setDensity(compact ? 'compact' : 'comfortable')}
            />
            <Switch
              label="Keyboard shortcuts"
              help="Press ? to see them. Turn them off if single keys clash with your screen reader or other tools."
              checked={preferences.shortcuts}
              onChange={preferences.setShortcuts}
            />
          </div>
          <p className="mt-4 mb-0 text-xs text-muted">Saved in this browser only.</p>
        </GlassCard>
      </div>
    </>
  );
}
