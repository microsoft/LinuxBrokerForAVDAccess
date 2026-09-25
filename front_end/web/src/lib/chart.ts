/*
 * Geometry for the inline SVG charts. Kept free of React so the scale, paths and axis
 * labels can be tested on their own.
 */

export interface Scale {
  top: number;
  step: number;
  ticks: number[];
}

/** A y axis from zero with at most five whole-number steps that reach past `max`. */
export function niceScale(max: number): Scale {
  const ceiling = Number.isFinite(max) && max > 0 ? max : 1;
  const rough = ceiling / 4;
  const magnitude = 10 ** Math.floor(Math.log10(Math.max(rough, 1)));
  const step = Math.max(1, [1, 2, 5, 10].map((factor) => factor * magnitude).find((candidate) => candidate >= rough) ?? 10 * magnitude);
  const top = Math.max(step, Math.ceil(ceiling / step) * step);
  const ticks: number[] = [];
  for (let tick = 0; tick <= top; tick += step) {
    ticks.push(tick);
  }
  return { top, step, ticks };
}

type Coordinate = (index: number) => number;
type Value = (value: number) => number;

function point(x: number, y: number) {
  return `${Math.round(x * 10) / 10},${Math.round(y * 10) / 10}`;
}

/** A line through the values, broken wherever a value is missing. */
export function linePath(values: Array<number | null>, xOf: Coordinate, yOf: Value): string {
  const parts: string[] = [];
  let drawing = false;
  values.forEach((value, index) => {
    if (value === null || Number.isNaN(value)) {
      drawing = false;
      return;
    }
    parts.push(`${drawing ? 'L' : 'M'}${point(xOf(index), yOf(value))}`);
    drawing = true;
  });
  return parts.join(' ');
}

/** Values with no neighbour on either side, which a line cannot show: they get a dot. */
export function isolatedPoints(values: Array<number | null>): number[] {
  return values.flatMap((value, index) => {
    const missing = (at: number) => at < 0 || at >= values.length || values[at] === null;
    return value !== null && missing(index - 1) && missing(index + 1) ? [index] : [];
  });
}

/** A step line: level across each bucket, with a riser where the value changes. */
export function stepPath(values: Array<number | null>, startOf: Coordinate, endOf: Coordinate, yOf: Value): string {
  const parts: string[] = [];
  let previous: number | null = null;
  values.forEach((value, index) => {
    if (value === null || Number.isNaN(value)) {
      previous = null;
      return;
    }
    const y = yOf(value);
    parts.push(`${previous === null ? 'M' : 'L'}${point(startOf(index), y)}`);
    parts.push(`L${point(endOf(index), y)}`);
    previous = value;
  });
  return parts.join(' ');
}

export interface AxisLabel {
  index: number;
  label: string;
}

const hourFormat = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit', hourCycle: 'h23' });
const dayFormat = new Intl.DateTimeFormat(undefined, { weekday: 'short', day: 'numeric' });
const bucketFormat = new Intl.DateTimeFormat(undefined, {
  weekday: 'short',
  day: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
});

/**
 * Where to label the time axis, in the browser's time zone: every three hours over a day,
 * every midnight over a longer span. A label goes on the bucket that holds the boundary, so
 * zones with a half-hour offset still get one.
 */
export function timeAxisLabels(times: string[], bucketMinutes: number): AxisLabel[] {
  const spanHours = (times.length * bucketMinutes) / 60;
  const daily = spanHours > 36;
  const labels: AxisLabel[] = [];
  times.forEach((time, index) => {
    const date = new Date(time);
    if (Number.isNaN(date.getTime())) return;
    const minuteOfDay = date.getHours() * 60 + date.getMinutes();
    const boundary = daily ? 1440 : 180;
    if (minuteOfDay % boundary < bucketMinutes) {
      labels.push({ index, label: daily ? dayFormat.format(date) : hourFormat.format(date) });
    }
  });
  return labels;
}

/** A bucket's start in the browser's time zone, for the readout and the table. */
export function formatBucket(time: string): string {
  const date = new Date(time);
  return Number.isNaN(date.getTime()) ? time : bucketFormat.format(date);
}
