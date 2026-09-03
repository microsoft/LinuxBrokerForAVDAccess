import { useState } from 'react';
import { useNavigate } from 'react-router-dom';

import { ButtonLink } from '../../components/ui/Button';
import { PageHeader } from '../../components/ui/Feedback';
import { useToast } from '../../components/ui/Toast';
import { useCreateScalingRule } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import { EMPTY_RULE, RuleForm } from './RuleForm';

export function CreateRule() {
  const navigate = useNavigate();
  const { showToast } = useToast();
  const createRule = useCreateScalingRule();
  const [form, setForm] = useState(EMPTY_RULE);

  async function submit() {
    try {
      await createRule.mutateAsync(form);
      showToast('Scaling rule created successfully.', 'success');
      navigate('/scaling/rules');
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to create scaling rule.'), 'danger');
    }
  }

  return (
    <>
      <PageHeader
        title="Create scaling rule"
        subtitle="Define when Linux Broker should power VMs on or off."
        icon="plus"
        actions={
          <ButtonLink to="/scaling/rules" size="sm" icon="chevron-left">
            Back to rules
          </ButtonLink>
        }
      />

      <RuleForm
        value={form}
        onChange={setForm}
        onSubmit={() => void submit()}
        submitLabel="Create rule"
        busy={createRule.isPending}
        cancelTo="/scaling/rules"
      />
    </>
  );
}
