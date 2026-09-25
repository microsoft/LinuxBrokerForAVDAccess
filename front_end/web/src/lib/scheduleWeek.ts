/*
 * Scaling schedule windows as minutes of the week, Monday 00:00 being minute 0. This mirrors
 * dbo.fnScheduleWeekIntervals and the API, so the editor can show a clash before saving.
 */

export type DayCode = 'mon' | 'tue' | 'wed' | 'thu' | 'fri' | 'sat' | 'sun';

export const DAY_CODES: DayCode[] = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
export const DAY_SHORT: Record<DayCode, string> = {
  mon: 'Mon', tue: 'Tue', wed: 'Wed', thu: 'Thu', fri: 'Fri', sat: 'Sat', sun: 'Sun',
};
export const WEEKDAYS: DayCode[] = ['mon', 'tue', 'wed', 'thu', 'fri'];
export const WEEKEND: DayCode[] = ['sat', 'sun'];

export const WEEK_MINUTES = 7 * 1440;

/** "HH:MM" as minutes after midnight, or null when it is not a time. */
export function minutesOf(value: string | null | undefined): number | null {
  const match = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(String(value ?? '').trim());
  return match ? Number(match[1]) * 60 + Number(match[2]) : null;
}

export function timeText(minutes: number): string {
  const within = ((minutes % 1440) + 1440) % 1440;
  return `${String(Math.floor(within / 60)).padStart(2, '0')}:${String(within % 60).padStart(2, '0')}`;
}

export type Interval = [number, number];

export function weekIntervals(days: DayCode[], start: number, end: number): Interval[] {
  const intervals: Interval[] = [];
  DAY_CODES.forEach((day, index) => {
    if (!days.includes(day)) {
      return;
    }
    const from = index * 1440 + start;
    const to = index * 1440 + end + (end <= start ? 1440 : 0);
    intervals.push([from, Math.min(to, WEEK_MINUTES)]);
    if (to > WEEK_MINUTES) {
      intervals.push([0, to - WEEK_MINUTES]);
    }
  });
  return intervals;
}

export function intervalsOverlap(first: Interval[], second: Interval[]): boolean {
  return first.some(([aStart, aEnd]) => second.some(([bStart, bEnd]) => aStart < bEnd && bStart < aEnd));
}

/** "Mon–Fri", "Sat, Sun", "Every day", or a list, in week order. */
export function describeDays(days: DayCode[]): string {
  const chosen = DAY_CODES.filter((day) => days.includes(day));
  if (chosen.length === 7) {
    return 'Every day';
  }
  if (!chosen.length) {
    return 'No days';
  }
  const indexes = chosen.map((day) => DAY_CODES.indexOf(day));
  const contiguous = indexes.every((index, position) => position === 0 || index === indexes[position - 1] + 1);
  if (contiguous && chosen.length >= 3) {
    return `${DAY_SHORT[chosen[0]]}\u2013${DAY_SHORT[chosen[chosen.length - 1]]}`;
  }
  return chosen.map((day) => DAY_SHORT[day]).join(', ');
}

/** The minute of the week of a local ISO time such as "2026-09-24T10:15:00". */
export function weekMinuteOf(localTime: string | null | undefined): number | null {
  const match = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/.exec(String(localTime ?? ''));
  if (!match) {
    return null;
  }
  // Computed from the calendar date alone, so the browser's own time zone never enters it.
  const day = new Date(Date.UTC(Number(match[1]), Number(match[2]) - 1, Number(match[3]))).getUTCDay();
  const mondayBased = (day + 6) % 7;
  return mondayBased * 1440 + Number(match[4]) * 60 + Number(match[5]);
}
