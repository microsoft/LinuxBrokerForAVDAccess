import { Button, ButtonLink } from '../../components/ui/Button';
import { TextField } from '../../components/ui/Field';
import { GlassCard } from '../../components/ui/GlassCard';
import type { ScalingRuleInput } from '../../types/broker';

export const EMPTY_RULE: ScalingRuleInput = {
  minvms: '',
  maxvms: '',
  scaleupratio: '',
  scaleupincrement: '',
  scaledownratio: '',
  scaledownincrement: '',
};

interface FieldSpec {
  key: keyof ScalingRuleInput;
  label: string;
  help: string;
  step?: string;
  max?: number;
}

const FIELDS: FieldSpec[] = [
  {
    key: 'minvms',
    label: 'Minimum VMs',
    help: 'Keep at least this many VMs powered on for baseline capacity.',
  },
  {
    key: 'maxvms',
    label: 'Maximum VMs',
    help: 'Do not power on more than this many VMs for this pool.',
  },
  {
    key: 'scaleupratio',
    label: 'Scale up ratio (%)',
    help: 'Power on more VMs when checked-out VMs rise above this percentage.',
    step: '0.01',
    max: 100,
  },
  {
    key: 'scaleupincrement',
    label: 'Scale up increment',
    help: 'Number of VMs to power on each time the scale-up threshold is met.',
  },
  {
    key: 'scaledownratio',
    label: 'Scale down ratio (%)',
    help: 'Power off VMs when checked-out VMs fall below this percentage.',
    step: '0.01',
    max: 100,
  },
  {
    key: 'scaledownincrement',
    label: 'Scale down increment',
    help: 'Number of idle VMs to power off each time the scale-down threshold is met.',
  },
];

export interface RuleFormProps {
  value: ScalingRuleInput;
  onChange: (value: ScalingRuleInput) => void;
  onSubmit: () => void;
  submitLabel: string;
  busy?: boolean;
  cancelTo: string;
}

/** Shared by rule creation and rule update, which take identical inputs. */
export function RuleForm({
  value,
  onChange,
  onSubmit,
  submitLabel,
  busy = false,
  cancelTo,
}: RuleFormProps) {
  return (
    <GlassCard className="max-w-4xl p-6">
      <form
        noValidate
        onSubmit={(event) => {
          event.preventDefault();
          onSubmit();
        }}
      >
        <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
          {FIELDS.map((field) => (
            <TextField
              key={field.key}
              label={field.label}
              help={field.help}
              type="number"
              min={0}
              max={field.max}
              step={field.step}
              required
              value={value[field.key]}
              onChange={(event) => onChange({ ...value, [field.key]: event.target.value })}
            />
          ))}
        </div>

        <div className="mt-6 flex flex-wrap gap-2">
          <Button type="submit" variant="primary" icon="check-circle" disabled={busy}>
            {busy ? 'Saving…' : submitLabel}
          </Button>
          <ButtonLink to={cancelTo}>Cancel</ButtonLink>
        </div>
      </form>
    </GlassCard>
  );
}
