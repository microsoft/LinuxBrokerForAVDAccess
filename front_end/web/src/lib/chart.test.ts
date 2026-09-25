import { describe, expect, it } from 'vitest';

import { formatBucket, isolatedPoints, linePath, niceScale, stepPath, timeAxisLabels } from './chart';

const identity = (value: number) => value;

describe('niceScale', () => {
  it.each([
    [0, 1, [0, 1]],
    [1.2, 2, [0, 1, 2]],
    [3, 3, [0, 1, 2, 3]],
    [7, 8, [0, 2, 4, 6, 8]],
    [23, 30, [0, 10, 20, 30]],
    [45, 60, [0, 20, 40, 60]],
  ])('scales %s to a top of %s', (max, top, ticks) => {
    expect(niceScale(max)).toMatchObject({ top, ticks });
  });

  it('never divides by zero for an empty or broken series', () => {
    expect(niceScale(Number.NaN).top).toBe(1);
    expect(niceScale(-4).top).toBe(1);
  });
});

describe('paths', () => {
  it('breaks a line where values are missing', () => {
    expect(linePath([1, 2, null, 4, 5], identity, identity)).toBe('M0,1 L1,2 M3,4 L4,5');
    expect(linePath([null, null], identity, identity)).toBe('');
  });

  it('marks values with no neighbour so they can be drawn as dots', () => {
    expect(isolatedPoints([1, null, 3, null, null, 6, 7])).toEqual([0, 2]);
    expect(isolatedPoints([5])).toEqual([0]);
  });

  it('draws a limit level across each bucket with risers between changes', () => {
    const start = (index: number) => index * 10;
    const end = (index: number) => index * 10 + 10;
    expect(stepPath([6, 6, 8, null, 4], start, end, identity)).toBe('M0,6 L10,6 L10,6 L20,6 L20,8 L30,8 M40,4 L50,4');
  });
});

describe('time axis', () => {
  function localTimes(count: number, minutes: number) {
    // A week with no daylight saving change in either hemisphere.
    const first = new Date(2026, 6, 13, 0, 0, 0).getTime();
    return Array.from({ length: count }, (_, index) => new Date(first + index * minutes * 60_000).toISOString());
  }

  it('labels every three hours over a day', () => {
    const labels = timeAxisLabels(localTimes(96, 15), 15);
    expect(labels.map((label) => label.index)).toEqual([0, 12, 24, 36, 48, 60, 72, 84]);
    expect(labels[1].label).toMatch(/03/);
  });

  it('labels each midnight over a week', () => {
    const labels = timeAxisLabels(localTimes(168, 60), 60);
    expect(labels.map((label) => label.index)).toEqual([0, 24, 48, 72, 96, 120, 144]);
  });

  it('shows an unparseable time as sent', () => {
    expect(formatBucket('not a time')).toBe('not a time');
    expect(timeAxisLabels(['not a time'], 15)).toEqual([]);
  });
});
