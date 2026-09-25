import { Button } from '../components/ui/Button';
import { useToast } from '../components/ui/Toast';
import { runTitle } from '../components/maintenance/MaintenanceStatus';
import { errorMessage } from '../lib/api';
import type { MaintenanceRun } from '../types/broker';
import { useMaintenanceRunAction } from './useBroker';
import { useConfirm } from './useConfirm';

type RunAction = 'pause' | 'resume' | 'cancel';

/** Pause, resume and cancel for a maintenance run, with a confirmation before a cancel. */
export function useMaintenanceActions() {
  const action = useMaintenanceRunAction();
  const { confirm, dialog } = useConfirm();
  const { showToast } = useToast();

  async function perform(run: MaintenanceRun, kind: RunAction) {
    try {
      const result = await action.mutateAsync({ runId: run.RunID, action: kind });
      showToast(result.message, 'success');
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to change the maintenance run.'), 'danger');
    }
  }

  function request(run: MaintenanceRun, kind: RunAction) {
    if (kind !== 'cancel') {
      void perform(run, kind);
      return;
    }
    confirm({
      title: `Cancel ${runTitle(run)}?`,
      body: 'Hosts still waiting for their users are put back in service at once. Hosts being patched or restarted finish first, so none is left half-patched.',
      confirmLabel: 'Cancel the run',
      variant: 'danger',
      onConfirm: () => perform(run, 'cancel'),
    });
  }

  function buttons(run: MaintenanceRun) {
    if (run.Status !== 'Active' && run.Status !== 'Paused') {
      return null;
    }
    return (
      <>
        {run.Status === 'Active' ? (
          <Button size="sm" icon="clock" disabled={action.isPending} onClick={() => request(run, 'pause')}>
            Pause
          </Button>
        ) : (
          <Button size="sm" variant="primary" icon="refresh" disabled={action.isPending} onClick={() => request(run, 'resume')}>
            Resume
          </Button>
        )}
        <Button size="sm" variant="danger" icon="x-circle" disabled={action.isPending} onClick={() => request(run, 'cancel')}>
          Cancel run
        </Button>
      </>
    );
  }

  return { buttons, dialog };
}
