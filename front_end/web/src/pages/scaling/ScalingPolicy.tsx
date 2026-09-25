import { useEffect, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';

import { ScalingPreviewCard } from '../../components/scaling/ScalingPreviewCard';
import { WeekTimeline } from '../../components/scaling/WeekTimeline';
import { Badge } from '../../components/ui/Badge';
import { Button, ButtonLink } from '../../components/ui/Button';
import { EmptyState, ErrorPanel, LoadingPanel, Notice, PageHeader } from '../../components/ui/Feedback';
import { SelectField } from '../../components/ui/Field';
import { GlassCard } from '../../components/ui/GlassCard';
import { useToast } from '../../components/ui/Toast';
import {
  useDeleteSchedule,
  useSaveSchedule,
  useScalingPolicy,
  useScalingPreview,
  useSetPolicyTimeZone,
  useTimeZones,
} from '../../hooks/useBroker';
import { useConfirm } from '../../hooks/useConfirm';
import { useCan } from '../../hooks/useSession';
import { errorMessage } from '../../lib/api';
import { formatDuration } from '../../lib/format';
import { describeDays, intervalsOverlap, minutesOf, weekIntervals, weekMinuteOf, WEEKDAYS } from '../../lib/scheduleWeek';
import type { ScalingPolicy as Policy, ScalingRule, ScalingSchedule, ScheduleInput } from '../../types/broker';

function CardTitle({ children }: { children: React.ReactNode }) {
  return <h2 className="m-0 text-xs font-semibold tracking-wider text-muted uppercase">{children}</h2>;
}

function stopModeLabel(mode: string | null | undefined) {
  return mode === 'Deallocate' ? 'Deallocate' : mode === 'PowerOff' ? 'Power off' : 'Same as the default rule';
}

/**
 * Ramp-up, peak and ramp-down on weekdays, derived from the default rule, as a starting
 * point an administrator then adjusts.
 */
function businessDayTemplate(rule: ScalingRule): ScheduleInput[] {
  const cap = Math.max(1, Number(rule.MaxVMs) - 1);
  const base = Math.max(1, Number(rule.MinVMs));
  const values = {
    maxvms: String(rule.MaxVMs),
    scaleupratio: String(rule.ScaleUpRatio),
    scaleupincrement: String(rule.ScaleUpIncrement),
    scaledownratio: String(rule.ScaleDownRatio),
    scaledownincrement: String(rule.ScaleDownIncrement),
    stopmode: '' as const,
    enabled: true,
    days: WEEKDAYS,
  };
  return [
    { ...values, name: 'Ramp-up', start: '07:00', end: '08:30', minvms: String(Math.min(cap, base * 2)) },
    { ...values, name: 'Peak', start: '08:30', end: '17:00', minvms: String(Math.min(cap, base * 3)) },
    { ...values, name: 'Ramp-down', start: '17:00', end: '19:00', minvms: String(Math.min(cap, base * 2)) },
  ];
}

function TimeZoneEditor({ policy }: { policy: Policy }) {
  const { data: zones } = useTimeZones();
  const setZone = useSetPolicyTimeZone();
  const { showToast } = useToast();
  const [zone, setZoneValue] = useState(policy.TimeZone);

  useEffect(() => setZoneValue(policy.TimeZone), [policy.TimeZone]);

  return (
    <form
      className="flex flex-wrap items-end gap-2"
      onSubmit={(event) => {
        event.preventDefault();
        setZone.mutate(zone, {
          onSuccess: (result) => showToast(result.message, 'success'),
          onError: (cause) => showToast(errorMessage(cause, 'Unable to change the time zone.'), 'danger'),
        });
      }}
    >
      <SelectField
        label="Time zone"
        fieldClassName="min-w-64 flex-1"
        value={zone}
        onChange={(event) => setZoneValue(event.target.value)}
        options={(zones ?? [{ Name: policy.TimeZone, CurrentUtcOffset: '', IsCurrentlyDst: false }]).map((option) => ({
          value: option.Name,
          label: option.CurrentUtcOffset ? `(UTC${option.CurrentUtcOffset}) ${option.Name}` : option.Name,
        }))}
      />
      <Button type="submit" size="sm" disabled={setZone.isPending || zone === policy.TimeZone}>
        {setZone.isPending ? 'Saving…' : 'Use this time zone'}
      </Button>
    </form>
  );
}

export function ScalingPolicy() {
  const navigate = useNavigate();
  const can = useCan();
  const { showToast } = useToast();
  const { confirm, dialog } = useConfirm();
  const { data: policy, isPending, error } = useScalingPolicy();
  const preview = useScalingPreview();
  const deleteSchedule = useDeleteSchedule();
  const saveSchedule = useSaveSchedule();

  if (isPending) {
    return <LoadingPanel label="Loading the scaling policy" />;
  }

  if (error || !policy) {
    return <ErrorPanel message={errorMessage(error, 'Unable to retrieve the scaling policy.')} />;
  }

  const phase = policy.ActivePhase;
  const rule = policy.DefaultRule;
  const windows = policy.Schedules.map((schedule) => ({
    key: schedule.ScheduleID,
    name: schedule.Name,
    days: schedule.Days,
    start: minutesOf(schedule.StartTime) ?? 0,
    end: minutesOf(schedule.EndTime) ?? 0,
    enabled: schedule.Enabled,
  }));

  function requestDelete(schedule: ScalingSchedule) {
    confirm({
      title: `Delete ${schedule.Name}`,
      body: `Delete the ${schedule.Name} window (${describeDays(schedule.Days)} ${schedule.StartTime}–${schedule.EndTime})? The default rule applies at those times from the next scaling run.`,
      confirmLabel: 'Delete',
      variant: 'danger',
      onConfirm: async () => {
        try {
          const result = await deleteSchedule.mutateAsync(schedule.ScheduleID);
          showToast(result.message, 'success');
        } catch (cause) {
          showToast(errorMessage(cause, `Unable to delete ${schedule.Name}.`), 'danger');
        }
      },
    });
  }

  function requestTemplate() {
    if (!rule) {
      return;
    }
    const template = businessDayTemplate(rule);
    const clash = template.find((draft) =>
      policy?.Schedules.some(
        (schedule) =>
          schedule.Enabled &&
          intervalsOverlap(
            weekIntervals(draft.days, minutesOf(draft.start) ?? 0, minutesOf(draft.end) ?? 0),
            weekIntervals(schedule.Days, minutesOf(schedule.StartTime) ?? 0, minutesOf(schedule.EndTime) ?? 0),
          ),
      ),
    );
    if (clash) {
      showToast(`The business day windows would overlap an existing window at ${clash.start}–${clash.end}. Remove or change it first.`, 'warning');
      return;
    }

    confirm({
      title: 'Add business day windows',
      body: `Adds three weekday windows based on the default rule: Ramp-up 07:00–08:30 with at least ${template[0].minvms} hosts, Peak 08:30–17:00 with at least ${template[1].minvms}, and Ramp-down 17:00–19:00 with at least ${template[2].minvms}. The default rule applies at nights and weekends. Adjust them afterwards.`,
      confirmLabel: 'Add the windows',
      variant: 'primary',
      onConfirm: async () => {
        try {
          for (const draft of template) {
            await saveSchedule.mutateAsync(draft);
          }
          showToast('Added the business day windows. They apply from the next scaling run.', 'success');
        } catch (cause) {
          showToast(errorMessage(cause, 'Unable to add all the business day windows.'), 'danger');
        }
      },
    });
  }

  return (
    <>
      <PageHeader
        title="Scaling policy"
        subtitle="How many Linux hosts to keep ready, hour by hour across the week."
        icon="sliders"
        actions={
          <>
            <ButtonLink to="/scaling/log" size="sm" icon="activity">
              Activity log
            </ButtonLink>
            <ButtonLink to="/scaling/rules/history" size="sm" icon="clock">
              Rule history
            </ButtonLink>
            {can.admin ? (
              <ButtonLink to="/scaling/schedules/new" size="sm" variant="primary" icon="plus">
                Add a window
              </ButtonLink>
            ) : null}
          </>
        }
      />

      <div className="mb-4 grid grid-cols-1 gap-4 lg:grid-cols-2">
        <GlassCard className="p-5">
          <CardTitle>In force now</CardTitle>
          {phase ? (
            <>
              <p className="mt-3 mb-0 flex flex-wrap items-center gap-2 text-lg font-semibold">
                {phase.Name}
                {phase.Source === 'Schedule' ? (
                  <Badge tone="accent" icon="clock">Window</Badge>
                ) : (
                  <Badge tone="neutral" icon="sliders">Default rule</Badge>
                )}
              </p>
              <p className="mt-1 mb-0 text-sm text-muted">
                Keep {phase.MinVMs}–{phase.MaxVMs} hosts. Scale up by {phase.ScaleUpIncrement} at {phase.ScaleUpRatio}% in
                use, down by {phase.ScaleDownIncrement} at {phase.ScaleDownRatio}%. {stopModeLabel(phase.StopMode)} when
                scaling down.
              </p>
              {policy.NextChange ? (
                <p className="mt-3 mb-0 text-sm">
                  <span className="font-medium">{policy.NextChange.PhaseName}</span> takes over on{' '}
                  {policy.NextChange.AtLocal}, in {formatDuration(policy.NextChange.InMinutes * 60)}.
                </p>
              ) : (
                <p className="mt-3 mb-0 text-sm text-muted">No windows are enabled, so this applies all week.</p>
              )}
            </>
          ) : (
            <Notice tone="warning" className="mt-3">
              No scaling rule or window is configured, so the broker never starts or stops hosts.
              {can.admin ? (
                <>
                  {' '}
                  <Link to="/scaling/rules/create">Create the default rule</Link>.
                </>
              ) : null}
            </Notice>
          )}
        </GlassCard>

        <ScalingPreviewCard
          title="Next scaling run"
          preview={preview.data}
          busy={preview.isFetching}
          error={preview.error ? errorMessage(preview.error, 'The preview is unavailable.') : null}
        />
      </div>

      <GlassCard className="mb-4 p-5">
        <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
          <div>
            <CardTitle>The week</CardTitle>
            <p className="mt-1 mb-0 text-xs text-muted">
              Times are in {policy.TimeZone}. Changes apply from the next scaling run, every five minutes, so start a
              window a little before people arrive.
            </p>
          </div>
          {can.admin ? <TimeZoneEditor policy={policy} /> : null}
        </div>
        <WeekTimeline windows={windows} nowMinute={weekMinuteOf(policy.LocalTime)} timeZone={policy.TimeZone} />
      </GlassCard>

      <div className="grid grid-cols-1 gap-4 xl:grid-cols-3">
        <GlassCard className="p-5">
          <div className="mb-3 flex items-center justify-between gap-2">
            <CardTitle>Default rule</CardTitle>
            <div className="flex gap-1.5">
              <ButtonLink to="/scaling/rules" size="sm" variant="ghost">
                All rules
              </ButtonLink>
              {can.admin && rule ? (
                <ButtonLink to={`/scaling/rules/${rule.RuleID}/update`} size="sm" icon="pencil">
                  Edit
                </ButtonLink>
              ) : null}
            </div>
          </div>
          {rule ? (
            <dl className="m-0 grid grid-cols-2 gap-x-4 gap-y-2 text-sm">
              <dt className="text-muted">Hosts</dt>
              <dd className="m-0 tabular-nums">
                {rule.MinVMs}–{rule.MaxVMs}
              </dd>
              <dt className="text-muted">Scale up</dt>
              <dd className="m-0 tabular-nums">
                +{rule.ScaleUpIncrement} at {rule.ScaleUpRatio}%
              </dd>
              <dt className="text-muted">Scale down</dt>
              <dd className="m-0 tabular-nums">
                −{rule.ScaleDownIncrement} at {rule.ScaleDownRatio}%
              </dd>
              <dt className="text-muted">Stop mode</dt>
              <dd className="m-0">{stopModeLabel(rule.StopMode ?? 'PowerOff')}</dd>
            </dl>
          ) : (
            <EmptyState
              title="No default rule"
              message="Outside every window, hosts are never started or stopped."
              icon="sliders"
              action={
                can.admin ? (
                  <ButtonLink to="/scaling/rules/create" variant="primary" icon="plus">
                    Create the default rule
                  </ButtonLink>
                ) : undefined
              }
            />
          )}
        </GlassCard>

        <GlassCard className="overflow-hidden xl:col-span-2">
          <div className="flex flex-wrap items-center justify-between gap-2 border-b border-[var(--lb-hairline)] px-5 py-3">
            <CardTitle>Windows</CardTitle>
            {can.admin && rule ? (
              <Button size="sm" icon="plus" onClick={requestTemplate} disabled={saveSchedule.isPending}>
                Add business day windows
              </Button>
            ) : null}
          </div>
          {policy.Schedules.length ? (
            <div className="overflow-auto">
              <table className="lb-table">
                <caption className="sr-only">Scaling schedule windows</caption>
                <thead>
                  <tr>
                    <th scope="col">Window</th>
                    <th scope="col">When</th>
                    <th scope="col">Hosts</th>
                    <th scope="col">Up / down</th>
                    <th scope="col">Stop mode</th>
                    {can.admin ? (
                      <th scope="col" className="text-right">
                        Actions
                      </th>
                    ) : null}
                  </tr>
                </thead>
                <tbody>
                  {policy.Schedules.map((schedule) => (
                    <tr key={schedule.ScheduleID}>
                      <td className="font-semibold whitespace-nowrap">
                        {schedule.Name}
                        {schedule.Enabled ? null : (
                          <Badge tone="neutral" icon="dash-circle" className="ml-2">
                            Disabled
                          </Badge>
                        )}
                      </td>
                      <td className="text-xs whitespace-nowrap">
                        {describeDays(schedule.Days)} {schedule.StartTime}–{schedule.EndTime}
                        {schedule.CrossesMidnight ? <span className="text-muted"> (next day)</span> : null}
                      </td>
                      <td className="tabular-nums">
                        {schedule.MinVMs}–{schedule.MaxVMs}
                      </td>
                      <td className="text-xs tabular-nums whitespace-nowrap">
                        +{schedule.ScaleUpIncrement} at {schedule.ScaleUpRatio}% · −{schedule.ScaleDownIncrement} at{' '}
                        {schedule.ScaleDownRatio}%
                      </td>
                      <td className="text-xs">{stopModeLabel(schedule.StopMode)}</td>
                      {can.admin ? (
                        <td className="text-right whitespace-nowrap">
                          <div className="flex justify-end gap-1.5">
                            <Button
                              size="sm"
                              icon="pencil"
                              aria-label={`Edit ${schedule.Name}`}
                              onClick={() => navigate(`/scaling/schedules/${schedule.ScheduleID}`)}
                            >
                              Edit
                            </Button>
                            <Button
                              size="sm"
                              variant="danger"
                              icon="trash"
                              aria-label={`Delete ${schedule.Name}`}
                              onClick={() => requestDelete(schedule)}
                            >
                              Delete
                            </Button>
                          </div>
                        </td>
                      ) : null}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ) : (
            <div className="p-5">
              <EmptyState
                title="No windows yet"
                message="The default rule applies all week. Add a window for business hours, or start from the business day windows."
                icon="clock"
              />
            </div>
          )}
        </GlassCard>
      </div>

      {dialog}
    </>
  );
}
