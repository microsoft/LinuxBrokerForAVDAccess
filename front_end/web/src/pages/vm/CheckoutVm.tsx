import { useState } from 'react';
import { useNavigate } from 'react-router-dom';

import { Breadcrumbs } from '../../components/layout/Breadcrumbs';
import { Button, ButtonLink } from '../../components/ui/Button';
import { Notice, PageHeader } from '../../components/ui/Feedback';
import { GlassCard } from '../../components/ui/GlassCard';
import { TextField } from '../../components/ui/Field';
import { useToast } from '../../components/ui/Toast';
import { useSession } from '../../hooks/useSession';
import { useCheckoutVm } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';

export function CheckoutVm() {
  const navigate = useNavigate();
  const session = useSession();
  const { showToast } = useToast();
  const checkout = useCheckoutVm();

  // Pre-filled with the signed-in account, which is the common case; an admin
  // brokering on someone else's behalf edits it.
  const [username, setUsername] = useState(session.user?.username ?? '');
  const [avdhost, setAvdhost] = useState('');
  const [errors, setErrors] = useState<Record<string, string>>({});

  async function submit(event: React.FormEvent) {
    event.preventDefault();

    const next: Record<string, string> = {};
    if (!username.trim()) {
      next.username = 'Enter the username to assign the host to.';
    }
    if (!avdhost.trim()) {
      next.avdhost = 'Enter the AVD session host.';
    }
    setErrors(next);
    if (Object.keys(next).length > 0) {
      return;
    }

    try {
      const vm = await checkout.mutateAsync({ username: username.trim(), avdhost: avdhost.trim() });
      showToast(`Assigned ${vm.Hostname} to ${username.trim()}.`, 'success');
      navigate(`/vms/${vm.VMID}`);
    } catch (cause) {
      showToast(errorMessage(cause, 'The broker could not assign a host.'), 'danger');
    }
  }

  return (
    <>
      <Breadcrumbs items={[{ label: 'Hosts', to: '/vms' }, { label: 'Test brokering' }]} />

      <PageHeader
        title="Test brokering"
        subtitle="Ask the broker for a host the way Azure Virtual Desktop does, to check that brokering works end to end."
        icon="person"
      />

      <GlassCard className="max-w-2xl p-6">
        <form onSubmit={submit} noValidate className="flex flex-col gap-5">
          <TextField
            label="Username"
            value={username}
            autoComplete="off"
            required
            help="Pre-filled with your signed-in account. Change it to broker a host on behalf of another user."
            error={errors.username}
            onChange={(event) => setUsername(event.target.value)}
          />

          <TextField
            label="AVD host"
            value={avdhost}
            placeholder="avd-session-host-01"
            autoComplete="off"
            required
            help="The Azure Virtual Desktop session host initiating the connection."
            error={errors.avdhost}
            onChange={(event) => setAvdhost(event.target.value)}
          />

          <Notice tone="warning">
            This really assigns a host: it stays the user's until it is released, so release it from its page when the
            test is done. Only ready hosts (on, reachable and unassigned) can be assigned. The host's password is never
            shown.
          </Notice>

          <div className="flex flex-wrap gap-2">
            <Button type="submit" variant="primary" icon="person" disabled={checkout.isPending}>
              {checkout.isPending ? 'Assigning…' : 'Assign a host'}
            </Button>
            <ButtonLink to="/vms">Cancel</ButtonLink>
          </div>
        </form>
      </GlassCard>
    </>
  );
}
