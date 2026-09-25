import { describe, expect, it } from 'vitest';

import { describeDays, intervalsOverlap, minutesOf, timeText, weekIntervals, weekMinuteOf } from './scheduleWeek';

describe('scheduleWeek', () => {
  it('mirrors the broker’s week intervals, across midnight and the Sunday wrap', () => {
    expect(weekIntervals(['mon', 'wed'], 540, 1020)).toEqual([[540, 1020], [2 * 1440 + 540, 2 * 1440 + 1020]]);
    expect(weekIntervals(['fri'], 1320, 120)).toEqual([[4 * 1440 + 1320, 5 * 1440 + 120]]);
    expect(weekIntervals(['sun'], 1380, 60)).toEqual([[6 * 1440 + 1380, 10080], [0, 60]]);
    expect(weekIntervals(['tue'], 1080, 0)).toEqual([[1440 + 1080, 2 * 1440]]);
  });

  it('treats touching windows as not overlapping', () => {
    const business = weekIntervals(['mon'], 480, 1080);
    expect(intervalsOverlap(business, weekIntervals(['mon'], 1080, 1320))).toBe(false);
    expect(intervalsOverlap(business, weekIntervals(['mon'], 1020, 1320))).toBe(true);
    expect(intervalsOverlap(business, weekIntervals(['sun'], 1380, 540))).toBe(true);
  });

  it('parses and prints times', () => {
    expect(minutesOf('07:30')).toBe(450);
    expect(minutesOf('7:30')).toBeNull();
    expect(minutesOf('24:00')).toBeNull();
    expect(timeText(450)).toBe('07:30');
    expect(timeText(1440 + 60)).toBe('01:00');
  });

  it('describes days the way people write them', () => {
    expect(describeDays(['mon', 'tue', 'wed', 'thu', 'fri'])).toBe('Mon\u2013Fri');
    expect(describeDays(['sat', 'sun'])).toBe('Sat, Sun');
    expect(describeDays(['sun', 'mon'])).toBe('Mon, Sun');
    expect(describeDays(['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'])).toBe('Every day');
  });

  it('finds the minute of the week from a local time without the browser’s zone', () => {
    // 2026-09-24 is a Thursday.
    expect(weekMinuteOf('2026-09-24T10:15:00')).toBe(3 * 1440 + 615);
    expect(weekMinuteOf('2026-09-27T23:59:00')).toBe(6 * 1440 + 1439);
    expect(weekMinuteOf('soon')).toBeNull();
  });
});
