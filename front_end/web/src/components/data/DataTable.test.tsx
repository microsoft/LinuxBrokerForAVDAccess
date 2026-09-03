import { describe, expect, it } from 'vitest';
import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

import { DataTable } from './DataTable';
import type { Column } from './DataTable';

interface Row {
  id: number;
  hostname: string;
  vms: number;
  seen: string;
  status: string;
}

const ROWS: Row[] = [
  { id: 1, hostname: 'linux-host-03', vms: 10, seen: '2026-08-03 09:00:00', status: 'Maintenance' },
  { id: 2, hostname: 'linux-host-01', vms: 2, seen: '2026-08-01 10:00:00', status: 'Available' },
  { id: 3, hostname: 'linux-host-02', vms: 30, seen: '2026-08-02 11:00:00', status: 'CheckedOut' },
];

const COLUMNS: Array<Column<Row>> = [
  {
    key: 'hostname',
    header: 'Hostname',
    sort: 'text',
    value: (row) => row.hostname,
    render: (row) => row.hostname,
  },
  { key: 'vms', header: 'VMs', sort: 'number', value: (row) => row.vms, render: (row) => row.vms },
  {
    key: 'seen',
    header: 'Last seen',
    sort: 'date',
    value: (row) => row.seen,
    render: (row) => row.seen,
  },
  {
    key: 'status',
    header: 'Status',
    // The cell renders a badge, so the sort and search value has to be supplied.
    value: (row) => row.status,
    render: (row) => <span data-testid="badge">{row.status}</span>,
  },
];

function hostnames() {
  const body = screen.getAllByRole('rowgroup')[1];
  return within(body)
    .getAllByRole('row')
    .map((row) => within(row).getAllByRole('cell')[0].textContent);
}

function renderTable() {
  return render(
    <DataTable
      columns={COLUMNS}
      rows={ROWS}
      rowKey={(row) => row.id}
      searchable
      searchPlaceholder="Search hosts…"
      noun="hosts"
    />,
  );
}

describe('DataTable', () => {
  it('renders rows in the given order until a column is sorted', () => {
    renderTable();
    expect(hostnames()).toEqual(['linux-host-03', 'linux-host-01', 'linux-host-02']);
  });

  it('sorts text ascending then descending, and reports it to assistive technology', async () => {
    renderTable();
    const header = screen.getByRole('columnheader', { name: /Hostname/ });

    await userEvent.click(within(header).getByRole('button'));
    expect(hostnames()).toEqual(['linux-host-01', 'linux-host-02', 'linux-host-03']);
    expect(header).toHaveAttribute('aria-sort', 'ascending');

    await userEvent.click(within(header).getByRole('button'));
    expect(hostnames()).toEqual(['linux-host-03', 'linux-host-02', 'linux-host-01']);
    expect(header).toHaveAttribute('aria-sort', 'descending');
  });

  it('sorts numbers numerically rather than lexically', async () => {
    renderTable();
    await userEvent.click(
      within(screen.getByRole('columnheader', { name: /VMs/ })).getByRole('button'),
    );
    // A lexical sort would put 10 before 2.
    expect(hostnames()).toEqual(['linux-host-01', 'linux-host-03', 'linux-host-02']);
  });

  it('sorts broker timestamps chronologically', async () => {
    renderTable();
    await userEvent.click(
      within(screen.getByRole('columnheader', { name: /Last seen/ })).getByRole('button'),
    );
    expect(hostnames()).toEqual(['linux-host-01', 'linux-host-02', 'linux-host-03']);
  });

  it('filters on the supplied value, so badge cells are still searchable', async () => {
    renderTable();
    await userEvent.type(screen.getByRole('searchbox'), 'CheckedOut');
    expect(hostnames()).toEqual(['linux-host-02']);
    expect(screen.getByText('1 shown of 3 hosts')).toBeInTheDocument();
  });

  it('shows the plain total when nothing is filtered out', () => {
    renderTable();
    expect(screen.getByText('3 hosts')).toBeInTheDocument();
  });

  it('explains an empty result rather than showing a blank table', async () => {
    renderTable();
    await userEvent.type(screen.getByRole('searchbox'), 'no-such-host');
    expect(screen.getByText('No results.')).toBeInTheDocument();
  });

  it('leaves unsortable columns without a sort control', () => {
    renderTable();
    const header = screen.getByRole('columnheader', { name: 'Status' });
    expect(within(header).queryByRole('button')).not.toBeInTheDocument();
    expect(header).not.toHaveAttribute('aria-sort');
  });
});
