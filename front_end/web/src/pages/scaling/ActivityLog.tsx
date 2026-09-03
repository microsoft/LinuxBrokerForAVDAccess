import { HistoryView } from '../../components/data/HistoryView';
import type { Column } from '../../components/data/DataTable';
import { ActionBadge } from '../../components/ui/Badge';
import { ButtonLink } from '../../components/ui/Button';
import { PageHeader } from '../../components/ui/Feedback';
import { useActivityLog } from '../../hooks/useBroker';
import { useHistoryQuery } from '../../hooks/useHistoryQuery';
import { errorMessage } from '../../lib/api';
import { valueOrDash } from '../../lib/format';
import type { ActivityLogEntry } from '../../types/broker';

export function ActivityLog() {
  const query = useHistoryQuery();
  const { data, isPending, isFetching, error } = useActivityLog(query.search);

  const columns: Array<Column<ActivityLogEntry>> = [
    {
      key: 'id',
      header: 'Activity ID',
      sort: 'number',
      value: (row) => row.ActivityID,
      className: 'font-mono text-xs',
      render: (row) => row.ActivityID,
    },
    {
      key: 'when',
      header: 'Check timestamp',
      sort: 'date',
      value: (row) => row.CheckTimestamp,
      className: 'font-mono text-xs whitespace-nowrap',
      render: (row) => valueOrDash(row.CheckTimestamp),
    },
    {
      key: 'running',
      header: 'Running VMs',
      sort: 'number',
      value: (row) => row.CurrentRunningVMs,
      className: 'tabular-nums',
      render: (row) => valueOrDash(row.CurrentRunningVMs),
    },
    {
      key: 'inuse',
      header: 'In use VMs',
      sort: 'number',
      value: (row) => row.CurrentInUseVMs,
      className: 'tabular-nums',
      render: (row) => valueOrDash(row.CurrentInUseVMs),
    },
    {
      key: 'action',
      header: 'Action taken',
      sort: 'text',
      value: (row) => row.ActionTaken,
      render: (row) => <ActionBadge value={row.ActionTaken} />,
    },
    {
      key: 'on',
      header: 'Powered on',
      sort: 'number',
      value: (row) => row.VMsPoweredOn,
      className: 'tabular-nums',
      render: (row) => valueOrDash(row.VMsPoweredOn),
    },
    {
      key: 'off',
      header: 'Powered off',
      sort: 'number',
      value: (row) => row.VMsPoweredOff,
      className: 'tabular-nums',
      render: (row) => valueOrDash(row.VMsPoweredOff),
    },
    {
      key: 'total',
      header: 'New total VMs',
      sort: 'number',
      value: (row) => row.NewTotalVMs,
      className: 'tabular-nums',
      render: (row) => valueOrDash(row.NewTotalVMs),
    },
    {
      key: 'outcome',
      header: 'Outcome',
      sort: 'text',
      value: (row) => row.Outcome,
      className: 'max-w-[24ch] truncate text-xs',
      render: (row) => <span title={row.Outcome ?? ''}>{valueOrDash(row.Outcome)}</span>,
    },
    {
      key: 'notes',
      header: 'Notes',
      sort: 'text',
      value: (row) => row.Notes,
      className: 'max-w-[30ch] truncate text-xs',
      render: (row) => <span title={row.Notes ?? ''}>{valueOrDash(row.Notes)}</span>,
    },
  ];

  return (
    <>
      <PageHeader
        title="Scaling activity log"
        subtitle="Every evaluation the scaling task has performed."
        icon="activity"
        actions={
          <ButtonLink to="/scaling/rules" size="sm" icon="chevron-left">
            Back to rules
          </ButtonLink>
        }
      />

      <HistoryView
        query={query}
        data={data}
        isPending={isPending}
        isFetching={isFetching}
        error={error}
        errorText={errorMessage(error, 'Unable to retrieve the scaling activity log.')}
        columns={columns}
        rowKey={(row) => row.ActivityID}
        emptyTitle="No scaling activity"
        emptyMessage="Adjust the filter above and apply it to search the activity log."
        emptyIcon="activity"
        noun="records"
        caption="Scaling task activity log"
      />
    </>
  );
}
