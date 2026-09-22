import { HistoryView } from '../../components/data/HistoryView';
import type { Column } from '../../components/data/DataTable';
import { ButtonLink } from '../../components/ui/Button';
import { PageHeader } from '../../components/ui/Feedback';
import { useRuleHistory } from '../../hooks/useBroker';
import { useHistoryQuery } from '../../hooks/useHistoryQuery';
import { errorMessage } from '../../lib/api';
import { valueOrDash } from '../../lib/format';
import type { ScalingRule } from '../../types/broker';

const MONO = 'font-mono text-xs whitespace-nowrap';

export function RuleHistory() {
  const query = useHistoryQuery();
  const { data, isPending, isFetching, error } = useRuleHistory(query.search);

  const columns: Array<Column<ScalingRule>> = [
    {
      key: 'ruleid',
      header: 'Rule ID',
      sort: 'number',
      value: (row) => row.RuleID,
      className: 'font-mono text-xs',
      render: (row) => row.RuleID,
    },
    {
      key: 'min',
      header: 'Min VMs',
      sort: 'number',
      value: (row) => row.MinVMs,
      className: 'tabular-nums',
      render: (row) => valueOrDash(row.MinVMs),
    },
    {
      key: 'max',
      header: 'Max VMs',
      sort: 'number',
      value: (row) => row.MaxVMs,
      className: 'tabular-nums',
      render: (row) => valueOrDash(row.MaxVMs),
    },
    {
      key: 'upratio',
      header: 'Scale up ratio (%)',
      sort: 'number',
      value: (row) => row.ScaleUpRatio,
      className: 'tabular-nums',
      render: (row) => valueOrDash(row.ScaleUpRatio),
    },
    {
      key: 'upinc',
      header: 'Scale up increment',
      sort: 'number',
      value: (row) => row.ScaleUpIncrement,
      className: 'tabular-nums',
      render: (row) => valueOrDash(row.ScaleUpIncrement),
    },
    {
      key: 'downratio',
      header: 'Scale down ratio (%)',
      sort: 'number',
      value: (row) => row.ScaleDownRatio,
      className: 'tabular-nums',
      render: (row) => valueOrDash(row.ScaleDownRatio),
    },
    {
      key: 'downinc',
      header: 'Scale down increment',
      sort: 'number',
      value: (row) => row.ScaleDownIncrement,
      className: 'tabular-nums',
      render: (row) => valueOrDash(row.ScaleDownIncrement),
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
      <PageHeader
        title="Scaling rule history"
        subtitle="Point-in-time record of every scaling rule change."
        icon="clock"
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
        errorText={errorMessage(error, 'Unable to retrieve the scaling rules history.')}
        columns={columns}
        // A rule appears once per revision, so the temporal start time is part of the key.
        rowKey={(row) => `${row.RuleID}-${row.SysStartTime ?? ''}`}
        emptyTitle="No rule history records"
        emptyMessage="Adjust the filter above and apply it to search the rule history."
        noun="records"
        caption="Scaling rule revision history"
      />
    </>
  );
}
