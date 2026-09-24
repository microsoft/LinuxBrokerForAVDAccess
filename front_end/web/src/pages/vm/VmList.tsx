import { useNavigate } from 'react-router-dom';
import { Link } from 'react-router-dom';

import { DataTable } from '../../components/data/DataTable';
import type { Column } from '../../components/data/DataTable';
import { Badge, NetworkBadge, PowerBadge, VmStatusBadge } from '../../components/ui/Badge';
import { Button, ButtonLink } from '../../components/ui/Button';
import { EmptyState, ErrorPanel, LoadingPanel, PageHeader } from '../../components/ui/Feedback';
import { useConfirm } from '../../hooks/useConfirm';
import { useCleanupVm, useDeleteVm, useReleaseVm, useReturnVm, useSetVmMaintenance, useVms } from '../../hooks/useBroker';
import { useToast } from '../../components/ui/Toast';
import { useCan } from '../../hooks/useSession';
import { errorMessage } from '../../lib/api';
import { valueOrDash } from '../../lib/format';
import { canRelease, canRetryCleanup, canReturn, canToggleMaintenance } from '../../lib/vmLifecycle';
import type { Vm } from '../../types/broker';

export function VmList() {
  const navigate = useNavigate();
  const { showToast } = useToast();
  const { confirm, dialog } = useConfirm();
  const { data: vms, isPending, error } = useVms();
  const can = useCan();

  const releaseVm = useReleaseVm();
  const returnVm = useReturnVm();
  const deleteVm = useDeleteVm();
  const cleanupVm = useCleanupVm();
  const maintenanceVm = useSetVmMaintenance();

  function confirmRelease(vm: Vm) {
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
          showToast(errorMessage(cause, `Unable to release '${vm.Hostname}'.`), 'danger');
        }
      },
    });
  }

  function confirmReturn(vm: Vm) {
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
          showToast(errorMessage(cause, `Unable to return '${vm.Hostname}'.`), 'danger');
        }
      },
    });
  }


  function confirmCleanup(vm: Vm) {
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
          showToast(errorMessage(cause, `Unable to retry cleanup on '${vm.Hostname}'.`), 'danger');
        }
      },
    });
  }

  function confirmMaintenance(vm: Vm) {
    const enabled = vm.VmStatus !== 'Maintenance';
    confirm({
      title: `${enabled ? 'Enable' : 'Disable'} maintenance for ${vm.Hostname}`,
      body: `${enabled ? 'Put' : 'Return'} ${vm.Hostname} ${enabled ? 'in maintenance' : 'to available'}?`,
      confirmLabel: enabled ? 'Enable maintenance' : 'Disable maintenance',
      variant: enabled ? 'warning' : 'primary',
      onConfirm: async () => {
        try {
          const result = await maintenanceVm.mutateAsync({ vmid: vm.VMID, enabled });
          showToast(result.message || `Maintenance ${enabled ? 'enabled' : 'disabled'} for '${vm.Hostname}'.`, 'success');
        } catch (cause) {
          showToast(errorMessage(cause, `Unable to update maintenance for '${vm.Hostname}'.`), 'danger');
        }
      },
    });
  }

  function confirmDelete(vm: Vm) {
    confirm({
      title: `Delete ${vm.Hostname}`,
      body: `Permanently delete ${vm.Hostname} (VMID ${vm.VMID}) from the broker? This cannot be undone.`,
      confirmLabel: 'Delete',
      variant: 'danger',
      onConfirm: async () => {
        try {
          await deleteVm.mutateAsync(vm.VMID);
          showToast('VM deleted successfully.', 'success');
        } catch (cause) {
          showToast(errorMessage(cause, 'Unable to delete VM.'), 'danger');
        }
      },
    });
  }

  const columns: Array<Column<Vm>> = [
    {
      key: 'vmid',
      header: 'VMID',
      sort: 'number',
      value: (vm) => vm.VMID,
      render: (vm) => <span className="font-mono text-xs">{vm.VMID}</span>,
    },
    {
      key: 'hostname',
      header: 'Hostname',
      sort: 'text',
      value: (vm) => vm.Hostname,
      className: 'font-semibold whitespace-nowrap',
      render: (vm) => (
        <Link to={`/vms/${vm.VMID}`} className="no-underline hover:underline">
          {vm.Hostname}
        </Link>
      ),
    },
    {
      key: 'ip',
      header: 'IP address',
      sort: 'text',
      value: (vm) => vm.IPAddress,
      className: 'font-mono text-xs',
      render: (vm) => valueOrDash(vm.IPAddress),
    },
    {
      key: 'power',
      header: 'Power',
      sort: 'text',
      value: (vm) => vm.PowerState,
      render: (vm) => <PowerBadge value={vm.PowerState} />,
    },
    {
      key: 'network',
      header: 'Network',
      sort: 'text',
      value: (vm) => vm.NetworkStatus,
      render: (vm) => <NetworkBadge value={vm.NetworkStatus} />,
    },
    {
      key: 'status',
      header: 'Status',
      sort: 'text',
      value: (vm) => vm.VmStatus,
      render: (vm) => (
        <span className="flex flex-wrap gap-1">
          <VmStatusBadge value={vm.VmStatus} />
          {vm.CleanupPending ? (
            <Badge tone="warn" icon="alert-triangle">Cleanup pending</Badge>
          ) : null}
        </span>
      ),
    },
    {
      key: 'username',
      header: 'Assigned to',
      sort: 'text',
      value: (vm) => vm.Username,
      render: (vm) => valueOrDash(vm.Username),
    },
    {
      key: 'actions',
      header: 'Actions',
      headerClassName: 'text-right',
      className: 'text-right',
      render: (vm) => (
        <div className="flex flex-wrap justify-end gap-1.5">
          <Button size="sm" icon="eye" onClick={() => navigate(`/vms/${vm.VMID}`)}>
            Details
          </Button>
          {can.admin ? (
            <Button size="sm" icon="pencil" onClick={() => navigate(`/vms/${vm.VMID}/update`)}>
              Edit
            </Button>
          ) : null}
          {/*
            ReleaseVm moves a CheckedOut host to Released; ReturnVm moves CheckedOut
            or Released back to Available. Offering either on an already Available
            host was misleading, so both are gated on the lifecycle rules.
          */}
          {can.operate && canRelease(vm) ? (
            <Button
              size="sm"
              variant="warning"
              icon="box-arrow-right"
              onClick={() => confirmRelease(vm)}
              aria-label={`Release ${vm.Hostname}`}
            >
              Release
            </Button>
          ) : null}
          {can.operate && canReturn(vm) ? (
            <Button
              size="sm"
              variant="primary"
              icon="arrow-return"
              onClick={() => confirmReturn(vm)}
              aria-label={`Return ${vm.Hostname}`}
            >
              Return
            </Button>
          ) : null}
          {can.operate && canRetryCleanup(vm) ? (
            <Button size="sm" variant="warning" icon="refresh" onClick={() => confirmCleanup(vm)} aria-label={`Retry cleanup on ${vm.Hostname}`}>
              Retry cleanup
            </Button>
          ) : null}
          {can.operate && canToggleMaintenance(vm) ? (
            <Button size="sm" variant="warning" icon="wrench" onClick={() => confirmMaintenance(vm)} aria-label={`Toggle maintenance for ${vm.Hostname}`}>
              {vm.VmStatus === 'Maintenance' ? 'End maintenance' : 'Maintenance'}
            </Button>
          ) : null}
          {can.admin ? (
            <Button
              size="sm"
              variant="danger"
              icon="trash"
              onClick={() => confirmDelete(vm)}
              aria-label={`Delete ${vm.Hostname}`}
            >
              Delete
            </Button>
          ) : null}
        </div>
      ),
    },
  ];

  return (
    <>
      <PageHeader
        title="Virtual machines"
        subtitle="Linux hosts registered with the broker."
        icon="server"
        actions={
          <>
            <ButtonLink to="/vms/history" size="sm" icon="clock">
              History
            </ButtonLink>
            {can.admin ? (
              <>
                <ButtonLink to="/vms/checkout" size="sm" icon="person">
                  Checkout VM
                </ButtonLink>
                <ButtonLink to="/vms/add" size="sm" variant="primary" icon="plus">
                  Add VM
                </ButtonLink>
              </>
            ) : null}
          </>
        }
      />

      {isPending ? <LoadingPanel label="Loading virtual machines" /> : null}

      {error ? (
        <ErrorPanel message={errorMessage(error, 'Unable to retrieve VM data.')} />
      ) : null}

      {vms && vms.length === 0 ? (
        <EmptyState
          title="No virtual machines found"
          message="Register a Linux host to start brokering AVD sessions."
          icon="server"
          action={
            can.admin ? (
              <ButtonLink to="/vms/add" variant="primary" icon="plus">
                Add your first VM
              </ButtonLink>
            ) : undefined
          }
        />
      ) : null}

      {vms && vms.length > 0 ? (
        <DataTable
          columns={columns}
          rows={vms}
          rowKey={(vm) => vm.VMID}
          searchable
          searchPlaceholder="Search hostname, IP, status or user…"
          noun="VMs"
          caption="Virtual machines registered with the broker"
        />
      ) : null}

      {dialog}
    </>
  );
}
