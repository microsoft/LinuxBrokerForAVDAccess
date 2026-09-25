import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/react';

import { MaintenanceProgress, runIsLive, runTitle } from '../../components/maintenance/MaintenanceStatus';
import { validateRunForm } from './NewMaintenanceRun';

const FORM = {
  name: '',
  patchMode: 'Security' as const,
  batchSize: '2',
  minReady: '',
  deadline: false,
  deadlineMinutes: '60',
  warningMinutes: '15',
  warningMessage: '',
  includePoweredOff: false,
  maxFailures: '1',
  canaryCount: '0',
};

describe('the new run form', () => {
  it('accepts sensible settings', () => {
    expect(validateRunForm(FORM, 3)).toEqual({});
    expect(validateRunForm({ ...FORM, minReady: '0', deadline: true }, 1)).toEqual({});
  });

  it('names each problem', () => {
    expect(validateRunForm({ ...FORM, batchSize: '0', minReady: 'x', maxFailures: '', canaryCount: '51' }, 0)).toEqual({
      hosts: 'Choose at least one host.',
      batchSize: 'Enter a whole number from 1 to 50.',
      minReady: 'Enter a whole number, or leave it blank.',
      maxFailures: 'Enter a whole number from 1 to 1000.',
      canaryCount: 'Enter a whole number from 0 to 50.',
    });
    expect(validateRunForm({ ...FORM, deadline: true, deadlineMinutes: '10', warningMinutes: '10' }, 1)).toEqual({
      warningMinutes: 'The warning must come before the deadline.',
    });
    expect(validateRunForm({ ...FORM, deadline: true, deadlineMinutes: '2' }, 1).deadlineMinutes).toBe('Enter 5 to 1440 minutes.');
  });
});

describe('maintenance status', () => {
  it('summarises progress for screen readers and keeps the numbers visible', () => {
    render(<MaintenanceProgress counts={{ Total: 5, Pending: 1, InProgress: 1, Succeeded: 2, Failed: 1, Skipped: 0, Cancelled: 0 }} />);
    expect(screen.getByRole('img', { name: '2 of 5 hosts done, 1 in progress, 1 waiting, 1 failed' })).toBeInTheDocument();
    expect(screen.getByText('Failed')).toHaveTextContent('Failed 1');
    expect(screen.queryByText('Skipped')).not.toBeInTheDocument();
  });

  it('names runs and tells live ones apart', () => {
    expect(runTitle({ RunID: 4, Name: null })).toBe('Maintenance run 4');
    expect(runTitle({ RunID: 4, Name: 'Patch night' })).toBe('Patch night (run 4)');
    expect(runIsLive('Stopping')).toBe(true);
    expect(runIsLive('Completed')).toBe(false);
  });
});
