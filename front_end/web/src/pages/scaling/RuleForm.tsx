import { Button, ButtonLink } from '../../components/ui/Button';
import { SelectField, TextField } from '../../components/ui/Field';
import { Notice } from '../../components/ui/Feedback';
import { GlassCard } from '../../components/ui/GlassCard';
import type { ScalingRuleInput } from '../../types/broker';

export const EMPTY_RULE: ScalingRuleInput = {
  minvms: '',
  maxvms: '',
  scaleupratio: '',
  scaleupincrement: '',
  scaledownratio: '',
  scaledownincrement: '',
  stopmode: 'PowerOff',
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
    help: 'Keep at least this many VMs powered on for baseline capacity. Must be at least 1.',
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

type RuleValues = Omit<ScalingRuleInput, 'stopmode'> & { stopmode: ScalingRuleInput['stopmode'] | '' };

export interface RuleFieldsProps<T extends RuleValues> {
  value: T;
  onChange: (value: T) => void;
  /** Offer "the default rule's" as the stop mode, for a schedule window. */
  inheritStopMode?: boolean;
}

/** The scaling values and stop mode, shared by the default rule and schedule windows. */
export function RuleFields<T extends RuleValues>({ value, onChange, inheritStopMode = false }: RuleFieldsProps<T>) {
  return (
    <>
      <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
        {FIELDS.map((field) => (
          <TextField
            key={field.key}
            label={field.label}
            help={field.help}
            type="number"
            min={field.key === 'minvms' ? 1 : 0}
            max={field.max}
            step={field.step}
            required
            value={value[field.key]}
            onChange={(event) => onChange({ ...value, [field.key]: event.target.value })}
          />
        ))}

        <SelectField
          label="When scaling down"
          help="Choose what the scaler asks Azure to do with idle hosts."
          options={[
            ...(inheritStopMode ? [{ value: '', label: 'Same as the default rule' }] : []),
            { value: 'PowerOff', label: 'Power off' },
            { value: 'Deallocate', label: 'Deallocate' },
          ]}
          value={value.stopmode}
          onChange={(event) => onChange({ ...value, stopmode: event.target.value as T['stopmode'] })}
        />
      </div>

      {value.stopmode === 'Deallocate' ? (
        <Notice tone="warning" className="mt-5">
          Deallocate stops compute billing, but disks and IPs can still bill. Starts take longer,
          capacity-constrained regions or sizes can fail with AllocationFailed and retry later,
          and the temporary resource disk is wiped. Private IP addresses and host names are kept.
        </Notice>
      ) : value.stopmode === 'PowerOff' ? (
        <Notice tone="info" className="mt-5">
          Powered-off VMs keep their compute allocation and continue to be billed for compute;
          they start quickly.
        </Notice>
      ) : null}
    </>
  );
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
        <RuleFields value={value} onChange={onChange} />

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
