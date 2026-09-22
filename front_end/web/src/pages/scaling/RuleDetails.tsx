import { useParams } from 'react-router-dom';

import { Breadcrumbs, DetailList } from '../../components/layout/Breadcrumbs';
import { ButtonLink } from '../../components/ui/Button';
import { ErrorPanel, LoadingPanel, PageHeader } from '../../components/ui/Feedback';
import { GlassCard } from '../../components/ui/GlassCard';
import { useScalingRule } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import { valueOrDash } from '../../lib/format';

export function RuleDetails() {
  const { ruleid } = useParams<{ ruleid: string }>();
  const { data: rule, isPending, error } = useScalingRule(ruleid);

  if (isPending) {
    return <LoadingPanel label="Loading scaling rule" />;
  }

  if (error || !rule) {
    return (
      <ErrorPanel
        message={errorMessage(error, 'Unable to retrieve scaling rule details.')}
        action={
          <ButtonLink to="/scaling/rules" icon="chevron-left">
            Back to rules
          </ButtonLink>
        }
      />
    );
  }

  return (
    <>
      <Breadcrumbs
        items={[
          { label: 'Scaling rules', to: '/scaling/rules' },
          { label: `Rule #${rule.RuleID}` },
        ]}
      />

      <PageHeader
        title={`Scaling rule #${rule.RuleID}`}
        subtitle="Thresholds the scaling task evaluates on each run."
        icon="sliders"
        actions={
          <>
            <ButtonLink to="/scaling/rules" size="sm" icon="chevron-left">
              Back to rules
            </ButtonLink>
            <ButtonLink
              to={`/scaling/rules/${rule.RuleID}/update`}
              size="sm"
              variant="primary"
              icon="pencil"
            >
              Update rule
            </ButtonLink>
          </>
        }
      />

      <GlassCard className="max-w-3xl p-5">
        <DetailList
          items={[
            { label: 'Minimum VMs', value: valueOrDash(rule.MinVMs) },
            { label: 'Maximum VMs', value: valueOrDash(rule.MaxVMs) },
            { label: 'Scale up ratio', value: `${valueOrDash(rule.ScaleUpRatio)}%` },
            { label: 'Scale up increment', value: valueOrDash(rule.ScaleUpIncrement) },
            { label: 'Scale down ratio', value: `${valueOrDash(rule.ScaleDownRatio)}%` },
            { label: 'Scale down increment', value: valueOrDash(rule.ScaleDownIncrement) },
          ]}
        />
      </GlassCard>
    </>
  );
}
