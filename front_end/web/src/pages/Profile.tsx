import { PageHeader } from '../components/ui/Feedback';
import { GlassCard } from '../components/ui/GlassCard';
import { ButtonAnchor } from '../components/ui/Button';
import { useSession } from '../hooks/useSession';
import { valueOrDash } from '../lib/format';

export function Profile() {
  const session = useSession();
  const user = session.user;

  const rows: Array<{ label: string; value: string }> = [
    { label: 'Name', value: valueOrDash(user?.name) },
    { label: 'Username', value: valueOrDash(user?.username) },
    { label: 'Object ID', value: valueOrDash(user?.objectId) },
    { label: 'Tenant ID', value: valueOrDash(user?.tenantId) },
  ];

  return (
    <>
      <PageHeader
        title="Profile"
        subtitle="The account this portal session is signed in with."
        icon="person"
        actions={
          <ButtonAnchor href="/logout" icon="box-arrow-right">
            Sign out
          </ButtonAnchor>
        }
      />

      <GlassCard className="max-w-2xl p-6">
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
    </>
  );
}
