import { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';

import { ButtonLink } from '../../components/ui/Button';
import { ErrorPanel, LoadingPanel, PageHeader } from '../../components/ui/Feedback';
import { useToast } from '../../components/ui/Toast';
import { useConfirm } from '../../hooks/useConfirm';
import { useScalingRule, useUpdateScalingRule } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import type { ScalingRuleInput } from '../../types/broker';
import { EMPTY_RULE, RuleForm } from './RuleForm';

export function UpdateRule() {
  const { ruleid = '' } = useParams<{ ruleid: string }>();
  const navigate = useNavigate();
  const { showToast } = useToast();
  const { data: rule, isPending, error } = useScalingRule(ruleid);
  const updateRule = useUpdateScalingRule(ruleid);
  const { confirm, dialog } = useConfirm();

  const [form, setForm] = useState<ScalingRuleInput>(EMPTY_RULE);
  const [seeded, setSeeded] = useState(false);

  // Seeded once, so a background refetch cannot overwrite edits in progress.
  useEffect(() => {
    if (rule && !seeded) {
      setForm({
        minvms: String(rule.MinVMs ?? ''),
        maxvms: String(rule.MaxVMs ?? ''),
        scaleupratio: String(rule.ScaleUpRatio ?? ''),
        scaleupincrement: String(rule.ScaleUpIncrement ?? ''),
        scaledownratio: String(rule.ScaleDownRatio ?? ''),
        scaledownincrement: String(rule.ScaleDownIncrement ?? ''),
        stopmode: rule.StopMode ?? 'PowerOff',
      });
      setSeeded(true);
    }
  }, [rule, seeded]);

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

  const loadedRule = rule;

  async function save() {
    try {
      await updateRule.mutateAsync(form);
      showToast('Scaling rule updated successfully.', 'success');
      navigate(`/scaling/rules/${ruleid}`);
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to update scaling rule.'), 'danger');
    }
  }

  function submit() {
    if ((loadedRule.StopMode ?? 'PowerOff') !== 'Deallocate' && form.stopmode === 'Deallocate') {
      confirm({
        title: 'Use deallocate for scale down?',
        body: 'Deallocate stops compute billing but starts take longer, can hit AllocationFailed capacity errors, and wipes the temporary resource disk.',
        confirmLabel: 'Use deallocate',
        variant: 'warning',
        onConfirm: save,
      });
      return;
    }
    void save();
  }

  return (
    <>
      <PageHeader
        title={`Update scaling rule #${loadedRule.RuleID}`}
        subtitle="Adjust the thresholds that grow and shrink the pool."
        icon="pencil"
        actions={
          <ButtonLink to={`/scaling/rules/${loadedRule.RuleID}`} size="sm" icon="chevron-left">
            Back to rule
          </ButtonLink>
        }
      />

      <RuleForm
        value={form}
        onChange={setForm}
        onSubmit={submit}
        submitLabel="Save changes"
        busy={updateRule.isPending}
        cancelTo={`/scaling/rules/${loadedRule.RuleID}`}
      />
      {dialog}
    </>
  );
}
