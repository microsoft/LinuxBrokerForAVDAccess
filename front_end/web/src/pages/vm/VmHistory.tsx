import { Breadcrumbs } from '../../components/layout/Breadcrumbs';
import { HistoryView } from '../../components/data/HistoryView';
import type { Column } from '../../components/data/DataTable';
import { NetworkBadge, PowerBadge, VmStatusBadge } from '../../components/ui/Badge';
import { ButtonLink } from '../../components/ui/Button';
import { PageHeader } from '../../components/ui/Feedback';
import { useVmHistory } from '../../hooks/useBroker';
import { useHistoryQuery } from '../../hooks/useHistoryQuery';
import { errorMessage } from '../../lib/api';
import { valueOrDash } from '../../lib/format';
import type { Vm } from '../../types/broker';

const MONO = 'font-mono text-xs whitespace-nowrap';

export function VmHistory() {
  const query = useHistoryQuery();
  const { data, isPending, isFetching, error } = useVmHistory(query.search);

  const columns: Array<Column<Vm>> = [
    {
      key: 'vmid',
      header: 'VMID',
      sort: 'number',
      value: (row) => row.VMID,
      className: 'font-mono text-xs',
      render: (row) => row.VMID,
    },
    {
      key: 'hostname',
      header: 'Hostname',
      sort: 'text',
      value: (row) => row.Hostname,
      className: 'font-semibold whitespace-nowrap',
      render: (row) => valueOrDash(row.Hostname),
    },
    {
      key: 'ip',
      header: 'IP address',
      sort: 'text',
      value: (row) => row.IPAddress,
      className: 'font-mono text-xs',
      render: (row) => valueOrDash(row.IPAddress),
    },
    {
      key: 'power',
      header: 'Power',
      sort: 'text',
      value: (row) => row.PowerState,
      render: (row) => <PowerBadge value={row.PowerState} />,
    },
    {
      key: 'network',
      header: 'Network',
      sort: 'text',
      value: (row) => row.NetworkStatus,
      render: (row) => <NetworkBadge value={row.NetworkStatus} />,
    },
    {
      key: 'status',
      header: 'Status',
      sort: 'text',
      value: (row) => row.VmStatus,
      render: (row) => <VmStatusBadge value={row.VmStatus} />,
    },
    {
      key: 'description',
      header: 'Description',
      value: (row) => row.Description,
      className: 'max-w-[22ch] truncate text-xs',
      render: (row) => <span title={row.Description ?? ''}>{valueOrDash(row.Description)}</span>,
    },
    {
      key: 'created',
      header: 'Created',
      sort: 'date',
      value: (row) => row.CreateDate,
      className: MONO,
      render: (row) => valueOrDash(row.CreateDate),
    },
    {
      key: 'updated',
      header: 'Last updated',
      sort: 'date',
      value: (row) => row.LastUpdateDate,
      className: MONO,
      render: (row) => valueOrDash(row.LastUpdateDate),
    },
    {
      key: 'from',
      header: 'Valid from',
      sort: 'date',
      value: (row) => row.SysStartTime,
      className: MONO,
      render: (row) => valueOrDash(row.SysStartTime),
    },
    {
      key: 'to',
      header: 'Valid to',
      sort: 'date',
      value: (row) => row.SysEndTime,
      className: MONO,
      render: (row) => valueOrDash(row.SysEndTime),
    },
  ];

  return (
    <>
      <Breadcrumbs items={[{ label: 'Virtual machines', to: '/vms' }, { label: 'History' }]} />

      <PageHeader
        title="Virtual machine history"
        subtitle="Point-in-time record of every VM state change."
        icon="clock"
        actions={
          <ButtonLink to="/vms" size="sm" icon="chevron-left">
            Back to list
          </ButtonLink>
        }
      />

      <HistoryView
        query={query}
        data={data}
        isPending={isPending}
        isFetching={isFetching}
        error={error}
        errorText={errorMessage(error, 'Unable to retrieve VM history.')}
        columns={columns}
        // A historical row repeats VMID across versions, so the temporal start
        // time is part of the key.
        rowKey={(row) => `${row.VMID}-${row.SysStartTime ?? ''}`}
        emptyTitle="No history records"
        emptyMessage="Adjust the filter above and apply it to search the VM history."
        noun="records"
        caption="Virtual machine state history"
      />
    </>
  );
}
