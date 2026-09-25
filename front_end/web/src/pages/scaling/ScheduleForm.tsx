import { useEffect, useState } from 'react';
import { useNavigate, useParams } from 'react-router-dom';

import { Breadcrumbs } from '../../components/layout/Breadcrumbs';
import { ScalingPreviewCard } from '../../components/scaling/ScalingPreviewCard';
import { WeekTimeline } from '../../components/scaling/WeekTimeline';
import { Button, ButtonLink } from '../../components/ui/Button';
import { ErrorPanel, LoadingPanel, Notice, PageHeader } from '../../components/ui/Feedback';
import { Checkbox, Switch, TextField } from '../../components/ui/Field';
import { GlassCard } from '../../components/ui/GlassCard';
import { useToast } from '../../components/ui/Toast';
import { usePreviewProposed, useSaveSchedule, useScalingPolicy } from '../../hooks/useBroker';
import { errorMessage } from '../../lib/api';
import {
  DAY_CODES,
  DAY_SHORT,
  describeDays,
  intervalsOverlap,
  minutesOf,
  weekIntervals,
  WEEKDAYS,
  WEEKEND,
} from '../../lib/scheduleWeek';
import type { ScalingSchedule, ScheduleDay, ScheduleInput } from '../../types/broker';
import { RuleFields } from './RuleForm';

const DAY_LABEL: Record<ScheduleDay, string> = {
  mon: 'Monday', tue: 'Tuesday', wed: 'Wednesday', thu: 'Thursday', fri: 'Friday', sat: 'Saturday', sun: 'Sunday',
};

function emptySchedule(): ScheduleInput {
  return {
    name: '',
    days: [...WEEKDAYS],
    start: '08:00',
    end: '18:00',
    enabled: true,
    minvms: '',
    maxvms: '',
    scaleupratio: '',
    scaleupincrement: '',
    scaledownratio: '',
    scaledownincrement: '',
    stopmode: '',
  };
}

function fromSchedule(schedule: ScalingSchedule): ScheduleInput {
  return {
    name: schedule.Name,
    days: [...schedule.Days],
    start: schedule.StartTime,
    end: schedule.EndTime,
    enabled: schedule.Enabled,
    minvms: String(schedule.MinVMs),
    maxvms: String(schedule.MaxVMs),
    scaleupratio: String(schedule.ScaleUpRatio),
    scaleupincrement: String(schedule.ScaleUpIncrement),
    scaledownratio: String(schedule.ScaleDownRatio),
    scaledownincrement: String(schedule.ScaleDownIncrement),
    stopmode: schedule.StopMode ?? '',
  };
}

const RULE_KEYS = ['minvms', 'maxvms', 'scaleupratio', 'scaleupincrement', 'scaledownratio', 'scaledownincrement'] as const;

export function ScheduleForm() {
  const { scheduleid } = useParams<{ scheduleid: string }>();
  const editing = Boolean(scheduleid);
  const navigate = useNavigate();
  const { showToast } = useToast();
  const { data: policy, isPending, error } = useScalingPolicy();
  const save = useSaveSchedule(scheduleid);
  const proposed = usePreviewProposed();

  const [form, setForm] = useState<ScheduleInput>(emptySchedule);
  const [seeded, setSeeded] = useState(false);

  const existing = policy?.Schedules.find((schedule) => String(schedule.ScheduleID) === scheduleid);

  // Seeded once, so a background refetch cannot overwrite edits in progress. A new window
  // starts from the default rule's values.
  useEffect(() => {
    if (!policy || seeded) {
      return;
    }
    if (existing) {
      setForm(fromSchedule(existing));
    } else if (!editing && policy.DefaultRule) {
      const rule = policy.DefaultRule;
      setForm((current) => ({
        ...current,
        minvms: String(rule.MinVMs),
        maxvms: String(rule.MaxVMs),
        scaleupratio: String(rule.ScaleUpRatio),
        scaleupincrement: String(rule.ScaleUpIncrement),
        scaledownratio: String(rule.ScaleDownRatio),
        scaledownincrement: String(rule.ScaleDownIncrement),
      }));
    }
    setSeeded(true);
  }, [policy, existing, editing, seeded]);

  if (isPending) {
    return <LoadingPanel label="Loading the scaling policy" />;
  }

  if (error || !policy || (editing && !existing)) {
    return (
      <ErrorPanel
        message={error ? errorMessage(error, 'Unable to retrieve the scaling policy.') : 'That scaling window no longer exists.'}
        action={
          <ButtonLink to="/scaling" icon="chevron-left">
            Back to the policy
          </ButtonLink>
        }
      />
    );
  }

  const start = minutesOf(form.start);
  const end = minutesOf(form.end);
  const timesValid = start !== null && end !== null && start !== end;
  const draftIntervals = timesValid && form.days.length ? weekIntervals(form.days, start, end) : [];
  const others = policy.Schedules.filter((schedule) => String(schedule.ScheduleID) !== scheduleid);
  const clashes = form.enabled
    ? others.filter(
        (schedule) =>
          schedule.Enabled &&
          intervalsOverlap(
            draftIntervals,
            weekIntervals(schedule.Days, minutesOf(schedule.StartTime) ?? 0, minutesOf(schedule.EndTime) ?? 0),
          ),
      )
    : [];

  const timeline = [
    ...others.map((schedule) => ({
      key: schedule.ScheduleID,
      name: schedule.Name,
      days: schedule.Days,
      start: minutesOf(schedule.StartTime) ?? 0,
      end: minutesOf(schedule.EndTime) ?? 0,
      enabled: schedule.Enabled,
      clash: clashes.some((clash) => clash.ScheduleID === schedule.ScheduleID),
    })),
    ...(timesValid && form.days.length
      ? [{ key: 'draft', name: form.name.trim() || 'This window', days: form.days, start: start ?? 0, end: end ?? 0, enabled: form.enabled, highlight: true }]
      : []),
  ];

  const complete = form.name.trim() && form.days.length && timesValid && RULE_KEYS.every((key) => String(form[key]).trim() !== '');

  function toggleDay(day: ScheduleDay, checked: boolean) {
    setForm((current) => ({
      ...current,
      days: checked ? DAY_CODES.filter((code) => code === day || current.days.includes(code)) : current.days.filter((code) => code !== day),
    }));
  }

  async function submit() {
    try {
      const result = await save.mutateAsync({ ...form, name: form.name.trim() });
      showToast(result.message, 'success');
      navigate('/scaling');
    } catch (cause) {
      showToast(errorMessage(cause, 'Unable to save the scaling window.'), 'danger');
    }
  }

  function preview() {
    proposed.mutate({
      rule: {
        ...Object.fromEntries(RULE_KEYS.map((key) => [key, String(form[key])])),
        ...(form.stopmode ? { stopmode: form.stopmode } : {}),
        name: form.name.trim() || 'This window',
      },
    });
  }

  const title = editing ? `Edit ${existing?.Name ?? 'window'}` : 'Add a scaling window';

  return (
    <>
      <Breadcrumbs items={[{ label: 'Scaling policy', to: '/scaling' }, { label: editing ? existing?.Name ?? 'Window' : 'New window' }]} />

      <PageHeader
        title={title}
        subtitle={`Overrides the default rule on the days and times you choose, in ${policy.TimeZone}.`}
        icon="clock"
        actions={
          <ButtonLink to="/scaling" size="sm" icon="chevron-left">
            Back to the policy
          </ButtonLink>
        }
      />

      <form
        noValidate
        onSubmit={(event) => {
          event.preventDefault();
          if (complete && !clashes.length) {
            void submit();
          }
        }}
      >
        <div className="grid grid-cols-1 gap-4 xl:grid-cols-5">
          <GlassCard className="p-6 xl:col-span-3">
            <div className="grid grid-cols-1 gap-5 md:grid-cols-2">
              <TextField
                label="Name"
                help="Shown on the timeline and in the activity log, for example Business hours."
                maxLength={64}
                required
                value={form.name}
                onChange={(event) => setForm({ ...form, name: event.target.value })}
              />
              <Switch
                className="md:mt-7"
                label="Enabled"
                help="A disabled window is kept but never applies."
                checked={form.enabled}
                onChange={(enabled) => setForm({ ...form, enabled })}
              />
            </div>

            <fieldset className="mt-5 border-0 p-0">
              <legend className="mb-2 text-sm font-medium text-ink">Days</legend>
              <div className="flex flex-wrap gap-x-4 gap-y-2">
                {DAY_CODES.map((day) => (
                  <Checkbox
                    key={day}
                    label={<span title={DAY_LABEL[day]}>{DAY_SHORT[day]}</span>}
                    checked={form.days.includes(day)}
                    onChange={(checked) => toggleDay(day, checked)}
                  />
                ))}
              </div>
              <div className="mt-2 flex flex-wrap gap-1.5">
                <Button size="sm" variant="ghost" onClick={() => setForm({ ...form, days: [...WEEKDAYS] })}>
                  Weekdays
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setForm({ ...form, days: [...WEEKEND] })}>
                  Weekend
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setForm({ ...form, days: [...DAY_CODES] })}>
                  Every day
                </Button>
              </div>
              {!form.days.length ? <p className="mt-1 mb-0 text-xs text-[var(--lb-danger-fg)]">Choose at least one day.</p> : null}
            </fieldset>

            <div className="mt-5 grid grid-cols-1 gap-5 md:grid-cols-2">
              <TextField
                label="Starts"
                type="time"
                required
                value={form.start}
                onChange={(event) => setForm({ ...form, start: event.target.value })}
              />
              <TextField
                label="Ends"
                type="time"
                required
                value={form.end}
                error={start !== null && start === end ? 'The window must end at a different time than it starts.' : undefined}
                help={timesValid && end !== null && start !== null && end <= start ? `Runs overnight, ending at ${form.end} the next day.` : 'The end time is not included.'}
                onChange={(event) => setForm({ ...form, end: event.target.value })}
              />
            </div>

            <h2 className="mt-7 mb-4 text-xs font-semibold tracking-wider text-muted uppercase">During this window</h2>
            <RuleFields value={form} onChange={setForm} inheritStopMode />

            {clashes.length ? (
              <Notice tone="danger" className="mt-5">
                This window overlaps{' '}
                {clashes.map((clash) => `${clash.Name} (${describeDays(clash.Days)} ${clash.StartTime}–${clash.EndTime})`).join(', ')}.
                Change the days or times, or disable one of them.
              </Notice>
            ) : null}

            <div className="mt-6 flex flex-wrap gap-2">
              <Button type="submit" variant="primary" icon="check-circle" disabled={save.isPending || !complete || clashes.length > 0}>
                {save.isPending ? 'Saving…' : editing ? 'Save changes' : 'Add window'}
              </Button>
              <Button icon="eye" disabled={!complete || proposed.isPending} onClick={preview}>
                Preview with these values
              </Button>
              <ButtonLink to="/scaling">Cancel</ButtonLink>
            </div>
          </GlassCard>

          <div className="flex flex-col gap-4 xl:col-span-2">
            <ScalingPreviewCard
              title="If these values applied now"
              preview={proposed.data}
              busy={proposed.isPending}
              error={proposed.error ? errorMessage(proposed.error, 'The preview is unavailable.') : null}
              placeholder="Preview what the next scaling run would do with these values and the hosts as they are now. Nothing is changed."
            />
            <GlassCard className="p-5">
              <h2 className="mb-3 text-xs font-semibold tracking-wider text-muted uppercase">On the week</h2>
              <WeekTimeline windows={timeline} timeZone={policy.TimeZone} />
            </GlassCard>
          </div>
        </div>
      </form>
    </>
  );
}
