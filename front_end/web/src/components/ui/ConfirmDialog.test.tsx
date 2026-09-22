import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

import { ConfirmDialog } from './ConfirmDialog';

function setup(overrides: Partial<React.ComponentProps<typeof ConfirmDialog>> = {}) {
  const onConfirm = vi.fn();
  const onCancel = vi.fn();

  render(
    <ConfirmDialog
      open
      title="Delete linux-host-01"
      body="Permanently delete linux-host-01 (VMID 1) from the broker? This cannot be undone."
      confirmLabel="Delete"
      onConfirm={onConfirm}
      onCancel={onCancel}
      {...overrides}
    />,
  );

  return { onConfirm, onCancel };
}

describe('ConfirmDialog', () => {
  it('renders nothing while closed, so no action can be taken by accident', () => {
    const { onConfirm } = setup({ open: false });
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it('names the specific resource in an accessible dialog', () => {
    setup();
    const dialog = screen.getByRole('dialog');
    expect(dialog).toHaveAttribute('aria-modal', 'true');
    expect(screen.getByText('Delete linux-host-01')).toBeInTheDocument();
    expect(screen.getByText(/Permanently delete linux-host-01/)).toBeInTheDocument();
  });

  it('only runs the action once the operator confirms', async () => {
    const { onConfirm, onCancel } = setup();

    await userEvent.click(screen.getByRole('button', { name: 'Cancel' }));
    expect(onConfirm).not.toHaveBeenCalled();
    expect(onCancel).toHaveBeenCalledTimes(1);

    await userEvent.click(screen.getByRole('button', { name: 'Delete' }));
    expect(onConfirm).toHaveBeenCalledTimes(1);
  });

  it('focuses the confirm button so the keyboard path is immediate', () => {
    setup();
    expect(screen.getByRole('button', { name: 'Delete' })).toHaveFocus();
  });

  it('cancels on Escape', async () => {
    const { onCancel, onConfirm } = setup();
    await userEvent.keyboard('{Escape}');
    expect(onCancel).toHaveBeenCalledTimes(1);
    expect(onConfirm).not.toHaveBeenCalled();
  });

  it('keeps Tab inside the dialog', async () => {
    setup();
    const close = screen.getByRole('button', { name: 'Close' });
    const confirm = screen.getByRole('button', { name: 'Delete' });

    // Confirm is the last control, so Tab must wrap back to the first one.
    confirm.focus();
    await userEvent.tab();
    expect(close).toHaveFocus();
  });

  it('disables both actions while the request is in flight', () => {
    setup({ busy: true });
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeDisabled();
    expect(screen.getByRole('button', { name: 'Working…' })).toBeDisabled();
  });
});
