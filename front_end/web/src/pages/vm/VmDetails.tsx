import { useNavigate, useParams } from 'react-router-dom';

import { Breadcrumbs, DetailList } from '../../components/layout/Breadcrumbs';
import { HostAgentCard } from '../../components/hosts/HostAgentCard';
import { Badge, NetworkBadge, PowerBadge, VmStatusBadge } from '../../components/ui/Badge';
import { Button, ButtonLink } from '../../components/ui/Button';
import { ErrorPanel, LoadingPanel, Notice, PageHeader } from '../../components/ui/Feedback';
import { GlassCard } from '../../components/ui/GlassCard';
import { useToast } from '../../components/ui/Toast';
import { useConfirm } from '../../hooks/useConfirm';
import { useHostActions } from '../../hooks/useHostActions';
import { useCan } from '../../hooks/useSession';
import { useCleanupVm, useDeleteVm, useReleaseVm, useReturnVm, useVm } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import { valueOrDash } from '../../lib/format';
import { canRelease, canRetryCleanup, canReturn, isAssigned } from '../../lib/vmLifecycle';

function ActionGroup({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div className="flex flex-col gap-2">
      <h3 className="m-0 text-xs font-medium text-muted">{title}</h3>
      {children}
    </div>
  );
}

export function VmDetails() {
  const { vmid } = useParams<{ vmid: string }>();
  const navigate = useNavigate();
  const { showToast } = useToast();
  const { confirm, dialog } = useConfirm();
  const hostActions = useHostActions();
  const { data: vm, isPending, error } = useVm(vmid);
  const can = useCan();

  const releaseVm = useReleaseVm();
  const returnVm = useReturnVm();
  const deleteVm = useDeleteVm();
  const cleanupVm = useCleanupVm();

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

  const hostItems = hostActions.actionsFor(vm);
  const assignmentActions = can.operate && (canRelease(vm) || canReturn(vm));

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
              <ButtonLink to={`/vms/${vm.VMID}/update`} size="sm" icon="pencil">
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
              {
                label: 'VM status',
                value: (
                  <span className="flex flex-wrap gap-1">
                    <VmStatusBadge value={vm.VmStatus} />
                    {vm.DrainRequested ? <Badge tone="warn" icon="box-arrow-right">Draining</Badge> : null}
                    {vm.CleanupPending ? <Badge tone="warn" icon="alert-triangle">Cleanup pending</Badge> : null}
                  </span>
                ),
              },
              {
                label: 'IP address',
                value: <span className="font-mono">{valueOrDash(vm.IPAddress)}</span>,
              },
              { label: 'Assigned to', value: valueOrDash(vm.Username) },
              { label: 'AVD host', value: valueOrDash(vm.AvdHost) },
              { label: 'Released', value: valueOrDash(vm.ReleasedDate) },
              ...(vm.DrainRequested ? [{ label: 'Drain requested', value: valueOrDash(vm.DrainRequestedDate) }] : []),
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

          <div className="flex flex-col gap-4">
            {hostItems.length ? (
              <ActionGroup title="Power and rotation">
                {hostItems.map((item) => (
                  <Button
                    key={item.key}
                    variant={item.tone === 'warning' ? 'warning' : 'secondary'}
                    icon={item.icon}
                    className="w-full"
                    onClick={item.onSelect}
                  >
                    {item.label}
                  </Button>
                ))}
                {can.operate && !can.admin && isAssigned(vm) && vm.PowerState === 'On' ? (
                  <p className="m-0 text-xs text-muted">
                    {vm.Username ?? 'A user'} is assigned to this host, so only an administrator can
                    stop or restart it. Drain it to take it out of rotation without ending the session.
                  </p>
                ) : null}
              </ActionGroup>
            ) : null}

            {assignmentActions ? (
              <ActionGroup title="Assignment">
                {canRelease(vm) ? (
                  <Button
                    variant="warning"
                    icon="box-arrow-right"
                    className="w-full"
                    onClick={() =>
                      confirm({
                        title: `Release ${vm.Hostname}`,
                        body: `Release ${vm.Hostname}? ${vm.Username ?? 'The session owner'} will be signed out and the host marked as released.`,
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

                {canReturn(vm) ? (
                  <Button
                    variant="primary"
                    icon="arrow-return"
                    className="w-full"
                    onClick={() =>
                      confirm({
                        title: `Return ${vm.Hostname}`,
                        body: `Return ${vm.Hostname} to the pool? ${vm.Username ?? 'The current user'}'s assignment ends and the host becomes available once their account is removed.`,
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
              </ActionGroup>
            ) : null}

            {can.operate && canRetryCleanup(vm) ? (
              <ActionGroup title="Cleanup">
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
              </ActionGroup>
            ) : null}

            {!can.operate ? (
              <Notice tone="info">Your role can view this host but not act on it.</Notice>
            ) : null}

            {can.admin ? (
              <>
                <hr className="m-0 border-[var(--lb-hairline)]" />
                <Button
                  variant="danger"
                  icon="trash"
                  className="w-full"
                  onClick={() =>
                    confirm({
                      title: `Delete ${vm.Hostname}`,
                      body: vm.Username
                        ? `Permanently delete ${vm.Hostname} (VMID ${vm.VMID}) from the broker? ${vm.Username} is assigned to it, and the broker stops tracking that assignment. This cannot be undone.`
                        : `Permanently delete ${vm.Hostname} (VMID ${vm.VMID}) from the broker? This cannot be undone.`,
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
              </>
            ) : null}
          </div>
        </GlassCard>
      </div>

      <div className="mt-4">
        <HostAgentCard hostname={vm.Hostname} />
      </div>

      {dialog}
      {hostActions.dialog}
    </>
  );
}
