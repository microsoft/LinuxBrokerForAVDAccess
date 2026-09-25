import { classNames } from '../../lib/format';
import { DAY_CODES, DAY_SHORT, describeDays, timeText, weekIntervals, WEEK_MINUTES } from '../../lib/scheduleWeek';
import type { DayCode } from '../../lib/scheduleWeek';

export interface TimelineWindow {
  key: string | number;
  name: string;
  days: DayCode[];
  start: number;
  end: number;
  enabled: boolean;
  /** The window being edited. */
  highlight?: boolean;
  /** Overlaps the highlighted window. */
  clash?: boolean;
}

export interface WeekTimelineProps {
  windows: TimelineWindow[];
  /** Minute of the week, Monday 00:00 = 0, in the policy's time zone. */
  nowMinute?: number | null;
  timeZone: string;
  className?: string;
}

const TONES = ['accent', 'info', 'ok', 'warn'] as const;

const WIDTH = 1000;
const LABEL = 48;
const PLOT = WIDTH - LABEL - 8;
const HEADER = 20;
const ROW = 26;
const GAP = 6;
const HEIGHT = HEADER + DAY_CODES.length * (ROW + GAP);

interface Segment {
  day: number;
  from: number;
  to: number;
}

/** A window's minutes of the week, cut at each midnight so every piece sits on one row. */
function segments(window: TimelineWindow): Segment[] {
  const pieces: Segment[] = [];
  for (const [start, end] of weekIntervals(window.days, window.start, window.end)) {
    let cursor = start;
    while (cursor < end) {
      const day = Math.floor(cursor / 1440);
      const dayEnd = Math.min(end, (day + 1) * 1440, WEEK_MINUTES);
      pieces.push({ day, from: cursor - day * 1440, to: dayEnd - day * 1440 });
      cursor = dayEnd;
    }
  }
  return pieces;
}

function toneOf(window: TimelineWindow, index: number) {
  if (window.clash) return 'danger';
  if (window.highlight) return 'accent';
  return TONES[index % TONES.length];
}

function x(minute: number) {
  return LABEL + (minute / 1440) * PLOT;
}

/** When each schedule window applies across the week, with the default rule everywhere else. */
export function WeekTimeline({ windows, nowMinute = null, timeZone, className }: WeekTimelineProps) {
  const summary = windows.length
    ? `${windows
        .map(
          (window) =>
            `${window.name}${window.enabled ? '' : ' (disabled)'}: ${describeDays(window.days)} ${timeText(window.start)} to ${timeText(window.end)}`,
        )
        .join('; ')}. The default rule applies at all other times. Times are in ${timeZone}.`
    : `No schedule windows: the default rule applies all week. Times are in ${timeZone}.`;

  const nowDay = nowMinute !== null && nowMinute >= 0 ? Math.floor(nowMinute / 1440) : null;

  return (
    <div className={className}>
      {/* Scrolls on a narrow screen rather than shrinking the labels past reading. */}
      <div className="overflow-x-auto" tabIndex={0} role="group" aria-label="Week timeline">
        <svg viewBox={`0 0 ${WIDTH} ${HEIGHT}`} role="img" aria-label={summary} className="block h-auto w-full min-w-[56rem]">
          {[0, 3, 6, 9, 12, 15, 18, 21, 24].map((hour) => (
            <g key={hour}>
              <line
                x1={x(hour * 60)}
                x2={x(hour * 60)}
                y1={HEADER - 4}
                y2={HEIGHT - GAP}
                stroke="var(--lb-hairline)"
                strokeWidth={hour % 6 === 0 ? 1.2 : 0.6}
              />
              {hour % 6 === 0 ? (
                <text
                  x={x(hour * 60)}
                  y={12}
                  fontSize={11}
                  textAnchor={hour === 0 ? 'start' : hour === 24 ? 'end' : 'middle'}
                  fill="var(--lb-ink-subtle)"
                >
                  {`${String(hour).padStart(2, '0')}:00`}
                </text>
              ) : null}
            </g>
          ))}

          {DAY_CODES.map((day, index) => {
            const top = HEADER + index * (ROW + GAP);
            return (
              <g key={day}>
                <text
                  x={0}
                  y={top + ROW / 2 + 4}
                  fontSize={12}
                  fontWeight={index === nowDay ? 700 : 600}
                  fill={index === nowDay ? 'var(--lb-ink)' : 'var(--lb-ink-muted)'}
                >
                  {DAY_SHORT[day]}
                </text>
                <rect x={LABEL} y={top} width={PLOT} height={ROW} rx={4} fill="var(--lb-neutral-bg)" />
              </g>
            );
          })}

          {windows.map((window, index) => {
            const tone = toneOf(window, index);
            return segments(window).map((segment) => {
              const top = HEADER + segment.day * (ROW + GAP);
              const left = x(segment.from);
              const width = Math.max(2, x(segment.to) - left);
              const room = Math.floor((width - 12) / 6.5);
              return (
                <g key={`${window.key}-${segment.day}-${segment.from}`}>
                  <rect
                    x={left}
                    y={top + 1}
                    width={width}
                    height={ROW - 2}
                    rx={4}
                    fill={window.enabled ? `var(--lb-${tone}-bg)` : 'transparent'}
                    stroke={window.enabled ? `var(--lb-${tone}-bd)` : 'var(--lb-neutral-bd)'}
                    strokeWidth={window.highlight || window.clash ? 2 : 1}
                    strokeDasharray={window.enabled ? undefined : '5 4'}
                  />
                  {room >= 6 ? (
                    <text
                      x={left + 8}
                      y={top + ROW / 2 + 4}
                      fontSize={11}
                      fontWeight={600}
                      fill={window.enabled ? `var(--lb-${tone}-fg)` : 'var(--lb-ink-subtle)'}
                    >
                      {window.name.length > room ? `${window.name.slice(0, room - 1)}…` : window.name}
                    </text>
                  ) : null}
                </g>
              );
            });
          })}

          {nowDay !== null && nowMinute !== null ? (
            <line
              x1={x(nowMinute % 1440)}
              x2={x(nowMinute % 1440)}
              y1={HEADER + nowDay * (ROW + GAP) - 3}
              y2={HEADER + nowDay * (ROW + GAP) + ROW + 3}
              stroke="var(--lb-danger-fg)"
              strokeWidth={2.5}
              strokeLinecap="round"
            />
          ) : null}
        </svg>
      </div>

      <ul className="m-0 mt-3 flex list-none flex-wrap gap-x-5 gap-y-1.5 p-0 text-xs text-muted">
        {windows.map((window, index) => {
          const tone = toneOf(window, index);
          return (
            <li key={window.key} className="flex items-center gap-1.5">
              <i
                aria-hidden
                className={classNames('inline-block size-3 rounded-sm border', window.enabled ? '' : 'border-dashed')}
                style={
                  window.enabled
                    ? { background: `var(--lb-${tone}-bg)`, borderColor: `var(--lb-${tone}-bd)` }
                    : { borderColor: 'var(--lb-neutral-bd)' }
                }
              />
              <span className="font-medium text-ink">{window.name}</span>
              <span>
                {describeDays(window.days)} {timeText(window.start)}–{timeText(window.end)}
                {window.enabled ? '' : ' · disabled'}
                {window.clash ? ' · overlaps' : ''}
              </span>
            </li>
          );
        })}
        <li className="flex items-center gap-1.5">
          <i aria-hidden className="inline-block size-3 rounded-sm bg-[var(--lb-neutral-bg)]" />
          <span>Default rule at all other times</span>
        </li>
        {nowDay !== null ? (
          <li className="flex items-center gap-1.5">
            <i aria-hidden className="inline-block h-3 w-0.5 rounded bg-[var(--lb-danger-fg)]" />
            <span>Now</span>
          </li>
        ) : null}
      </ul>
    </div>
  );
}
