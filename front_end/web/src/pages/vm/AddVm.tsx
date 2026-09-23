import { useState } from 'react';
import { useNavigate } from 'react-router-dom';

import { Breadcrumbs } from '../../components/layout/Breadcrumbs';
import { Button, ButtonLink } from '../../components/ui/Button';
import { Notice, PageHeader } from '../../components/ui/Feedback';
import { GlassCard } from '../../components/ui/GlassCard';
import { SelectField, TextAreaField, TextField } from '../../components/ui/Field';
import { useToast } from '../../components/ui/Toast';
import { useAddVm } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import { NETWORK_STATUSES, POWER_STATES, UNASSIGNED_VM_STATUSES } from '../../types/broker';
import type { VmInput } from '../../types/broker';

const IPV4 = /^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/;

const EMPTY: VmInput = {
  hostname: '',
  ipaddress: '',
  powerstate: 'On',
  networkstatus: 'Reachable',
  vmstatus: 'Available',
  description: '',
};

export function AddVm() {
  const navigate = useNavigate();
  const { showToast } = useToast();
  const addVm = useAddVm();

  const [form, setForm] = useState<VmInput>(EMPTY);
  const [errors, setErrors] = useState<Record<string, string>>({});

  function set<K extends keyof VmInput>(key: K, value: VmInput[K]) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  function validate() {
    const next: Record<string, string> = {};
    if (!form.hostname.trim()) {
      next.hostname = "Enter the host's name.";
    }
    if (!IPV4.test(form.ipaddress.trim())) {
      next.ipaddress = 'Enter a valid IPv4 address, for example 10.0.0.4.';
    }
    setErrors(next);
    return Object.keys(next).length === 0;
  }

  async function submit(event: React.FormEvent) {
    event.preventDefault();
    if (!validate()) {
      return;
    }

    try {
      await addVm.mutateAsync(form);
      showToast('VM added to inventory. Trusted deployment enrollment is required before checkout.', 'success');
      navigate('/vms');
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to add VM.'), 'danger');
    }
  }

  return (
    <>
      <Breadcrumbs items={[{ label: 'Virtual machines', to: '/vms' }, { label: 'Add VM' }]} />

      <PageHeader
        title="Add virtual machine"
        subtitle="Add an unassigned Linux host to broker inventory."
        icon="plus"
      />

      <GlassCard className="max-w-4xl p-6">
        <Notice className="mb-5">
          Adding a VM creates an inventory record only. A deployment operator must import the host
          from Azure Resource Manager (ARM) and enroll its host identity before the broker can offer
          it for checkout. Setting Available, On, and Reachable here does not grant that trust.
        </Notice>
        <form onSubmit={submit} noValidate>
          <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
            <TextField
              label="Hostname"
              value={form.hostname}
              placeholder="linux-host-01"
              autoComplete="off"
              required
              error={errors.hostname}
              onChange={(event) => set('hostname', event.target.value)}
            />
            <TextField
              label="IP address"
              value={form.ipaddress}
              placeholder="10.0.0.4"
              autoComplete="off"
              required
              help="IPv4 address the broker uses to reach the host."
              error={errors.ipaddress}
              onChange={(event) => set('ipaddress', event.target.value)}
            />
          </div>

          <div className="mt-5 grid grid-cols-1 gap-5 md:grid-cols-3">
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
              options={UNASSIGNED_VM_STATUSES.map((value) => ({ value, label: value }))}
              help="New hosts cannot be assigned to a user. The broker manages workspace leases."
              onChange={(event) => set('vmstatus', event.target.value)}
            />
          </div>

          <TextAreaField
            label="Description (optional)"
            className="mt-5"
            rows={3}
            value={form.description ?? ''}
            onChange={(event) => set('description', event.target.value)}
          />

          <div className="mt-6 flex flex-wrap gap-2">
            <Button type="submit" variant="primary" icon="plus" disabled={addVm.isPending}>
              {addVm.isPending ? 'Adding…' : 'Add VM'}
            </Button>
            <ButtonLink to="/vms">Cancel</ButtonLink>
          </div>
        </form>
      </GlassCard>
    </>
  );
}
