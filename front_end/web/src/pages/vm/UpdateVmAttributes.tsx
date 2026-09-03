import { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';

import { Breadcrumbs } from '../../components/layout/Breadcrumbs';
import { Button, ButtonLink } from '../../components/ui/Button';
import { ErrorPanel, LoadingPanel, PageHeader } from '../../components/ui/Feedback';
import { GlassCard } from '../../components/ui/GlassCard';
import { SelectField } from '../../components/ui/Field';
import { useToast } from '../../components/ui/Toast';
import { useUpdateVmAttributes, useVm } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import { NETWORK_STATUSES, POWER_STATES } from '../../types/broker';
import type { VmAttributesInput } from '../../types/broker';

const VM_STATUS_OPTIONS = [
  { value: 'Available', label: 'Available' },
  { value: 'CheckedOut', label: 'Checked out' },
  { value: 'Maintenance', label: 'Maintenance' },
  { value: 'Released', label: 'Released' },
];

export function UpdateVmAttributes() {
  const { vmid = '' } = useParams<{ vmid: string }>();
  const navigate = useNavigate();
  const { showToast } = useToast();
  const { data: vm, isPending, error } = useVm(vmid);
  const update = useUpdateVmAttributes(vmid);

  const [form, setForm] = useState<VmAttributesInput | null>(null);

  // Seed the form once the VM arrives, rather than rendering empty selects that
  // would silently reset an attribute the operator did not intend to change.
  useEffect(() => {
    if (vm) {
      setForm({
        powerstate: vm.PowerState ?? 'On',
        networkstatus: vm.NetworkStatus ?? 'Reachable',
        vmstatus: vm.VmStatus ?? 'Available',
      });
    }
  }, [vm]);

  if (isPending) {
    return <LoadingPanel label="Loading VM details" />;
  }

  if (error || !vm || !form) {
    return (
      <ErrorPanel
        message={errorMessage(error, 'Unable to retrieve VM details.')}
        action={
          <ButtonLink to="/vms" icon="chevron-left">
            Back to list
          </ButtonLink>
        }
      />
    );
  }

  function set<K extends keyof VmAttributesInput>(key: K, value: VmAttributesInput[K]) {
    setForm((current) => (current ? { ...current, [key]: value } : current));
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!form) {
      return;
    }

    try {
      await update.mutateAsync(form);
      showToast('VM attributes updated successfully.', 'success');
      navigate(`/vms/${vmid}`);
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to update VM attributes.'), 'danger');
    }
  }

  return (
    <>
      <Breadcrumbs
        items={[
          { label: 'Virtual machines', to: '/vms' },
          { label: vm.Hostname, to: `/vms/${vm.VMID}` },
          { label: 'Update' },
        ]}
      />

      <PageHeader
        title={`Update ${vm.Hostname}`}
        subtitle="Change the attributes the broker records for this host."
        icon="pencil"
      />

      <GlassCard className="max-w-3xl p-6">
        <form onSubmit={submit} noValidate>
          <div className="grid grid-cols-1 gap-5 md:grid-cols-3">
            <SelectField
              label="Power state"
              value={form.powerstate}
              options={POWER_STATES.map((value) => ({ value, label: value }))}
              onChange={(event) => set('powerstate', event.target.value)}
            />
            <SelectField
              label="Network status"
              value={form.networkstatus}
              options={NETWORK_STATUSES.map((value) => ({ value, label: value }))}
              onChange={(event) => set('networkstatus', event.target.value)}
            />
            <SelectField
              label="VM status"
              value={form.vmstatus}
              options={VM_STATUS_OPTIONS}
              help="Only Available hosts are offered for checkout."
              onChange={(event) => set('vmstatus', event.target.value)}
            />
          </div>

          <div className="mt-6 flex flex-wrap gap-2">
            <Button type="submit" variant="primary" icon="check-circle" disabled={update.isPending}>
              {update.isPending ? 'Saving…' : 'Save changes'}
            </Button>
            <ButtonLink to={`/vms/${vm.VMID}`}>Cancel</ButtonLink>
          </div>
        </form>
      </GlassCard>
    </>
  );
}
