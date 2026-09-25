import { afterEach, describe, expect, it, vi } from 'vitest';
import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

import { BulkResults, ColumnChooser, SortHeader, StatusChips } from './HostListParts';
import { hostListSearch, readHostListView } from '../../pages/vm/VmList';

describe('the host list view in the address bar', () => {
  it('falls back to the defaults for anything it does not recognise', () => {
    expect(readHostListView(new URLSearchParams('page=0&per_page=9000&status=bogus&sort=password&dir=sideways'))).toEqual({
      page: 1, perPage: 200, q: '', status: 'all', sort: 'hostname', dir: 'asc',
    });
    expect(readHostListView(new URLSearchParams(''))).toMatchObject({ page: 1, perPage: 50 });
  });

  it('reads a shared link', () => {
    const view = readHostListView(new URLSearchParams('q=%20host-0%20&status=in-use&sort=heartbeat&dir=desc&page=3&per_page=25'));
    expect(view).toEqual({ page: 3, perPage: 25, q: 'host-0', status: 'in-use', sort: 'heartbeat', dir: 'desc' });
  });

  it('always asks the BFF for a page, with the search only when there is one', () => {
    const view = readHostListView(new URLSearchParams(''));
    expect(hostListSearch(view)).toBe('?page=1&per_page=50&status=all&sort=hostname&dir=asc');
    expect(hostListSearch({ ...view, q: 'a&b' })).toBe('?page=1&per_page=50&status=all&sort=hostname&dir=asc&q=a%26b');
  });
});

describe('StatusChips', () => {
  it('marks the chip shown and disables the empty ones', async () => {
    const onChange = vi.fn();
    render(<StatusChips counts={{ all: 3, ready: 2, 'in-use': 1, released: 0 }} active="ready" onChange={onChange} />);
    const chips = screen.getByRole('group', { name: 'Show hosts' });

    expect(within(chips).getByRole('button', { name: /^Ready/ })).toHaveAttribute('aria-pressed', 'true');
    expect(within(chips).getByRole('button', { name: /^Released/ })).toBeDisabled();
    // Counts not reported yet leave the chip usable.
    expect(within(chips).getByRole('button', { name: /^Maintenance/ })).toBeEnabled();

    await userEvent.click(within(chips).getByRole('button', { name: /^In use/ }));
    expect(onChange).toHaveBeenCalledWith('in-use');
  });
});

describe('SortHeader', () => {
  it('reports the sort to assistive technology and flips it', async () => {
    const onSort = vi.fn();
    render(
      <table>
        <thead>
          <tr>
            <SortHeader label="Hostname" sortKey="hostname" sort="hostname" dir="asc" onSort={onSort} />
            <SortHeader label="Power" sortKey="power" sort="hostname" dir="asc" onSort={onSort} />
            <SortHeader label="Settings" sort="hostname" dir="asc" onSort={onSort} />
          </tr>
        </thead>
      </table>,
    );

    expect(screen.getByRole('columnheader', { name: 'Hostname' })).toHaveAttribute('aria-sort', 'ascending');
    expect(screen.getByRole('columnheader', { name: 'Power' })).toHaveAttribute('aria-sort', 'none');
    expect(screen.getByRole('columnheader', { name: 'Settings' })).not.toHaveAttribute('aria-sort');
    expect(screen.queryByRole('button', { name: 'Settings' })).not.toBeInTheDocument();

    await userEvent.click(screen.getByRole('button', { name: 'Power' }));
    expect(onSort).toHaveBeenCalledWith('power');
  });
});

describe('ColumnChooser', () => {
  afterEach(() => window.localStorage.removeItem('lb-host-columns'));

  it('keeps the columns in their table order whatever order they are ticked in', async () => {
    const onChange = vi.fn();
    render(<ColumnChooser columns={['heartbeat']} onChange={onChange} />);

    await userEvent.click(screen.getByRole('checkbox', { name: 'IP address' }));
    expect(onChange).toHaveBeenLastCalledWith(['ip', 'heartbeat']);
    await userEvent.click(screen.getByRole('checkbox', { name: 'Last heartbeat' }));
    expect(onChange).toHaveBeenLastCalledWith([]);
  });
});

describe('BulkResults', () => {
  it('names each host that failed and each one skipped', async () => {
    const onDismiss = vi.fn();
    render(
      <BulkResults
        run={{
          label: 'Start',
          outcomes: [
            { hostname: 'linux-host-01', ok: true, message: 'Start requested.' },
            { hostname: 'linux-host-02', ok: false, message: 'Azure refused the request.' },
          ],
          skipped: ['linux-host-03', 'linux-host-04'],
        }}
        onDismiss={onDismiss}
      />,
    );

    expect(screen.getByText('Start: 1 done, 1 failed, 2 skipped')).toBeInTheDocument();
    expect(screen.getByText(/Azure refused the request/).closest('li')).toHaveTextContent('linux-host-02: Azure refused the request.');
    expect(screen.getByText('Skipped: linux-host-03, linux-host-04.')).toBeInTheDocument();
    await userEvent.click(screen.getByRole('button', { name: 'Dismiss the results' }));
    expect(onDismiss).toHaveBeenCalled();
  });
});
