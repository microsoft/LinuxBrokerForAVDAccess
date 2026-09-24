import { useNavigate, useParams } from 'react-router-dom';

import { Breadcrumbs, DetailList } from '../../components/layout/Breadcrumbs';
import { Badge, NetworkBadge, PowerBadge, VmStatusBadge } from '../../components/ui/Badge';
import { Button, ButtonLink } from '../../components/ui/Button';
import { ErrorPanel, LoadingPanel, Notice, PageHeader } from '../../components/ui/Feedback';
import { GlassCard } from '../../components/ui/GlassCard';
import { useToast } from '../../components/ui/Toast';
import { useConfirm } from '../../hooks/useConfirm';
import { useCan } from '../../hooks/useSession';
import { useCleanupVm, useDeleteVm, useReleaseVm, useReturnVm, useSetVmMaintenance, useVm } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import { valueOrDash } from '../../lib/format';
import { canRelease, canRetryCleanup, canReturn, canToggleMaintenance } from '../../lib/vmLifecycle';

export function VmDetails() {
  const { vmid } = useParams<{ vmid: string }>();
  const navigate = useNavigate();
  const { showToast } = useToast();
  const { confirm, dialog } = useConfirm();
  const { data: vm, isPending, error } = useVm(vmid);
  const can = useCan();

  const releaseVm = useReleaseVm();
  const returnVm = useReturnVm();
  const deleteVm = useDeleteVm();
  const cleanupVm = useCleanupVm();
  const maintenanceVm = useSetVmMaintenance();

  if (isPending) {
    return <LoadingPanel label="Loading VM details" />;
  }

  if (error || !vm) {
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

  return (
    <>
      <Breadcrumbs items={[{ label: 'Virtual machines', to: '/vms' }, { label: vm.Hostname }]} />

      <PageHeader
        title={vm.Hostname}
        subtitle={`VMID ${vm.VMID}`}
        icon="server"
        actions={
          <>
            <ButtonLink to="/vms" size="sm" icon="chevron-left">
              Back to list
            </ButtonLink>
            {can.admin ? (
              <ButtonLink to={`/vms/${vm.VMID}/update`} size="sm" variant="primary" icon="pencil">
                Update attributes
              </ButtonLink>
            ) : null}
          </>
        }
      />

      <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
        <GlassCard className="p-5 lg:col-span-2">
          <h2 className="mb-1 text-xs font-semibold tracking-wider text-muted uppercase">
            Details
          </h2>
          <DetailList
            items={[
              { label: 'Power state', value: <PowerBadge value={vm.PowerState} /> },
              { label: 'Network status', value: <NetworkBadge value={vm.NetworkStatus} /> },
              { label: 'VM status', value: <span className="flex flex-wrap gap-1"><VmStatusBadge value={vm.VmStatus} />{vm.CleanupPending ? <Badge tone="warn" icon="alert-triangle">Cleanup pending</Badge> : null}</span> },
              {
                label: 'IP address',
                value: <span className="font-mono">{valueOrDash(vm.IPAddress)}</span>,
              },
              { label: 'Assigned to', value: valueOrDash(vm.Username) },
              { label: 'AVD host', value: valueOrDash(vm.AvdHost) },
              { label: 'Released', value: valueOrDash(vm.ReleasedDate) },
              { label: 'Cleanup user', value: valueOrDash(vm.CleanupUsername) },
              { label: 'Last power change', value: valueOrDash(vm.PowerStateChangedDate) },
              {
                label: 'Last updated',
                value: <span className="font-mono">{valueOrDash(vm.LastUpdateDate)}</span>,
              },
              { label: 'Description', value: valueOrDash(vm.Description) },
            ]}
          />
        </GlassCard>

        <GlassCard className="h-full p-5">
          <h2 className="mb-3 text-xs font-semibold tracking-wider text-muted uppercase">
            Actions
          </h2>

          <div className="flex flex-col gap-2">
            {can.operate && canRelease(vm) ? (
              <Button
                variant="warning"
                icon="box-arrow-right"
                className="w-full"
                onClick={() =>
                  confirm({
                    title: `Release ${vm.Hostname}`,
                    body: `Release ${vm.Hostname}? The session owner will be signed out and the host marked as released.`,
                    confirmLabel: 'Release',
                    variant: 'warning',
                    onConfirm: async () => {
                      try {
                        await releaseVm.mutateAsync(vm.Hostname);
                        showToast(`VM '${vm.Hostname}' released successfully.`, 'success');
                      } catch (cause) {
                        showToast(errorMessage(cause, 'Unable to release the VM.'), 'danger');
                      }
                    },
                  })
                }
              >
                Release
              </Button>
            ) : null}

            {can.operate && canReturn(vm) ? (
              <Button
                variant="primary"
                icon="arrow-return"
                className="w-full"
                onClick={() =>
                  confirm({
                    title: `Return ${vm.Hostname}`,
                    body: `Return ${vm.Hostname} to the pool? It will become available for checkout again.`,
                    confirmLabel: 'Return',
                    variant: 'primary',
                    onConfirm: async () => {
                      try {
                        const result = await returnVm.mutateAsync(vm.VMID);
                        showToast(result.CleanupPending ? `VM '${vm.Hostname}' returned; cleanup is pending.` : `VM '${vm.Hostname}' returned successfully.`, result.CleanupPending ? 'warning' : 'success');
                      } catch (cause) {
                        showToast(errorMessage(cause, 'Unable to return the VM.'), 'danger');
                      }
                    },
                  })
                }
              >
                Return
              </Button>
            ) : null}

            {vm.VmStatus === 'Available' ? (
              <Notice tone="info">
                This host is available. Release and return apply only to hosts that are currently
                checked out or released.
              </Notice>
            ) : null}

            {can.operate && canRetryCleanup(vm) ? (
              <Button
                variant="warning"
                icon="refresh"
                className="w-full"
                onClick={() =>
                  confirm({
                    title: `Retry cleanup on ${vm.Hostname}`,
                    body: `Retry cleanup of the previous user's account and mounts on ${vm.Hostname}?`,
                    confirmLabel: 'Retry cleanup',
                    variant: 'warning',
                    onConfirm: async () => {
                      try {
                        const result = await cleanupVm.mutateAsync(vm.VMID);
                        showToast(result.message || `Cleanup retried for '${vm.Hostname}'.`, 'success');
                      } catch (cause) {
                        showToast(errorMessage(cause, 'Unable to retry cleanup.'), 'danger');
                      }
                    },
                  })
                }
              >
                Retry cleanup
              </Button>
            ) : null}

            {can.operate && canToggleMaintenance(vm) ? (
              <Button
                variant="warning"
                icon="wrench"
                className="w-full"
                onClick={() =>
                  confirm({
                    title: `${vm.VmStatus === 'Maintenance' ? 'Disable' : 'Enable'} maintenance for ${vm.Hostname}`,
                    body: `${vm.VmStatus === 'Maintenance' ? 'Return' : 'Put'} ${vm.Hostname} ${vm.VmStatus === 'Maintenance' ? 'to available' : 'in maintenance'}?`,
                    confirmLabel: vm.VmStatus === 'Maintenance' ? 'Disable maintenance' : 'Enable maintenance',
                    variant: 'warning',
                    onConfirm: async () => {
                      try {
                        await maintenanceVm.mutateAsync({ vmid: vm.VMID, enabled: vm.VmStatus !== 'Maintenance' });
                        showToast('Maintenance updated successfully.', 'success');
                      } catch (cause) {
                        showToast(errorMessage(cause, 'Unable to update maintenance.'), 'danger');
                      }
                    },
                  })
                }
              >
                {vm.VmStatus === 'Maintenance' ? 'End maintenance' : 'Maintenance'}
              </Button>
            ) : null}

            <hr className="my-2 border-[var(--lb-hairline)]" />

            {can.admin ? (
            <Button
              variant="danger"
              icon="trash"
              className="w-full"
              onClick={() =>
                confirm({
                  title: `Delete ${vm.Hostname}`,
                  body: `Permanently delete ${vm.Hostname} (VMID ${vm.VMID}) from the broker? This cannot be undone.`,
                  confirmLabel: 'Delete',
                  variant: 'danger',
                  onConfirm: async () => {
                    try {
                      await deleteVm.mutateAsync(vm.VMID);
                      showToast('VM deleted successfully.', 'success');
                      navigate('/vms');
                    } catch (cause) {
                      showToast(errorMessage(cause, 'Unable to delete VM.'), 'danger');
                    }
                  },
                })
              }
            >
              Delete
            </Button>
            ) : null}
          </div>
        </GlassCard>
      </div>

      {dialog}
    </>
  );
}
