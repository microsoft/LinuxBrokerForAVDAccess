import { useNavigate } from 'react-router-dom';
import { Link } from 'react-router-dom';

import { DataTable } from '../../components/data/DataTable';
import type { Column } from '../../components/data/DataTable';
import { Button, ButtonLink } from '../../components/ui/Button';
import { EmptyState, ErrorPanel, LoadingPanel, PageHeader } from '../../components/ui/Feedback';
import { useToast } from '../../components/ui/Toast';
import { useConfirm } from '../../hooks/useConfirm';
import { useDeleteScalingRule, useScalingRules } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import type { ScalingRule } from '../../types/broker';

export function RuleList() {
  const navigate = useNavigate();
  const { showToast } = useToast();
  const { confirm, dialog } = useConfirm();
  const { data: rules, isPending, error } = useScalingRules();
  const deleteRule = useDeleteScalingRule();

  const columns: Array<Column<ScalingRule>> = [
    {
      key: 'ruleid',
      header: 'Rule ID',
      sort: 'number',
      value: (rule) => rule.RuleID,
      className: 'font-mono text-xs',
      render: (rule) => (
        <Link to={`/scaling/rules/${rule.RuleID}`} className="no-underline hover:underline">
          {rule.RuleID}
        </Link>
      ),
    },
    {
      key: 'min',
      header: 'Min VMs',
      sort: 'number',
      value: (rule) => rule.MinVMs,
      className: 'tabular-nums',
      render: (rule) => rule.MinVMs,
    },
    {
      key: 'max',
      header: 'Max VMs',
      sort: 'number',
      value: (rule) => rule.MaxVMs,
      className: 'tabular-nums',
      render: (rule) => rule.MaxVMs,
    },
    {
      key: 'upratio',
      header: 'Scale up ratio (%)',
      sort: 'number',
      value: (rule) => rule.ScaleUpRatio,
      className: 'tabular-nums',
      render: (rule) => rule.ScaleUpRatio,
    },
    {
      key: 'upinc',
      header: 'Scale up increment',
      sort: 'number',
      value: (rule) => rule.ScaleUpIncrement,
      className: 'tabular-nums',
      render: (rule) => rule.ScaleUpIncrement,
    },
    {
      key: 'downratio',
      header: 'Scale down ratio (%)',
      sort: 'number',
      value: (rule) => rule.ScaleDownRatio,
      className: 'tabular-nums',
      render: (rule) => rule.ScaleDownRatio,
    },
    {
      key: 'downinc',
      header: 'Scale down increment',
      sort: 'number',
      value: (rule) => rule.ScaleDownIncrement,
      className: 'tabular-nums',
      render: (rule) => rule.ScaleDownIncrement,
    },
    {
      key: 'actions',
      header: 'Actions',
      headerClassName: 'text-right',
      className: 'text-right',
      render: (rule) => (
        <div className="flex flex-wrap justify-end gap-1.5">
          <Button
            size="sm"
            icon="eye"
            onClick={() => navigate(`/scaling/rules/${rule.RuleID}`)}
            aria-label={`View details of rule ${rule.RuleID}`}
          >
            Details
          </Button>
          <Button
            size="sm"
            icon="pencil"
            onClick={() => navigate(`/scaling/rules/${rule.RuleID}/update`)}
            aria-label={`Edit rule ${rule.RuleID}`}
          >
            Edit
          </Button>
          <Button
            size="sm"
            variant="danger"
            icon="trash"
            aria-label={`Delete rule ${rule.RuleID}`}
            onClick={() =>
              confirm({
                title: 'Delete scaling rule?',
                body: `Delete scaling rule #${rule.RuleID}? This cannot be undone.`,
                confirmLabel: 'Delete',
                variant: 'danger',
                onConfirm: async () => {
                  try {
                    await deleteRule.mutateAsync(rule.RuleID);
                    showToast('Scaling rule deleted successfully.', 'success');
                  } catch (cause) {
                    showToast(errorMessage(cause, 'Unable to delete scaling rule.'), 'danger');
                  }
                },
              })
            }
          >
            Delete
          </Button>
        </div>
      ),
    },
  ];

  return (
    <>
      <PageHeader
        title="Scaling rules"
        subtitle="Manage automatic VM capacity thresholds and review scaling history."
        icon="sliders"
        actions={
          <>
            <ButtonLink to="/scaling/rules/create" size="sm" variant="primary" icon="plus">
              Add rule
            </ButtonLink>
            <ButtonLink to="/scaling/log" size="sm" icon="activity">
              Activity log
            </ButtonLink>
            <ButtonLink to="/scaling/rules/history" size="sm" icon="clock">
              Rule history
            </ButtonLink>
          </>
        }
      />

      {isPending ? <LoadingPanel label="Loading scaling rules" /> : null}

      {error ? (
        <ErrorPanel message={errorMessage(error, 'Unable to retrieve scaling rules.')} />
      ) : null}

      {rules && rules.length === 0 ? (
        <EmptyState
          title="No scaling rules found"
          message="Create a rule to define how Linux Broker powers VMs on and off."
          icon="sliders"
          action={
            <ButtonLink to="/scaling/rules/create" variant="primary" icon="plus">
              Create scaling rule
            </ButtonLink>
          }
        />
      ) : null}

      {rules && rules.length > 0 ? (
        <DataTable
          columns={columns}
          rows={rules}
          rowKey={(rule) => rule.RuleID}
          searchable
          searchPlaceholder="Search scaling rules…"
          noun="rules"
          caption="Scaling rules that govern pool capacity"
        />
      ) : null}

      {dialog}
    </>
  );
}
