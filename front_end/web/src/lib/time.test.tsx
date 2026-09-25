import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/react';

import { RelativeTime } from '../components/ui/RelativeTime';
import { absoluteUtc, brokerTimeSortValue, parseBrokerTime, relativeText } from './time';

const NOON = Date.UTC(2026, 8, 24, 12, 0, 0);

describe('broker times', () => {
  it.each([
    ['2026-09-24T12:00:00Z', NOON],
    ['2026-09-24T12:00:00.1234567Z', NOON + 123],
    ['Thu, 24 Sep 2026 12:00:00 GMT', NOON],
    ['2026-09-24 12:00:00', NOON],
    ['2026-09-24 12:00:00.500', NOON + 500],
    ['2026-09-24T12:00:00', NOON],
    ['2026-09-24 12:00:00 UTC', NOON],
    ['2026-09-24T14:00:00+02:00', NOON],
  ])('reads %s as UTC', (value, expected) => {
    expect(parseBrokerTime(value)?.getTime()).toBe(expected);
  });

  it.each([null, undefined, '', 'yesterday', '24/09/2026'])('refuses %s', (value) => {
    expect(parseBrokerTime(value)).toBeNull();
  });

  it('describes times relative to now, past and future', () => {
    const date = new Date(NOON);
    expect(relativeText(date, NOON + 10_000)).toBe('just now');
    expect(relativeText(date, NOON + 5 * 60_000)).toBe('5 min ago');
    expect(relativeText(date, NOON + 3 * 86_400_000)).toBe('3 days ago');
    expect(relativeText(date, NOON - 30_000)).toBe('just now');
    expect(relativeText(date, NOON - 2 * 3_600_000)).toBe('in 2 hours');
    expect(absoluteUtc(date)).toBe('2026-09-24 12:00:00 UTC');
  });

  it('sorts every shape by the time it names, unreadable ones last', () => {
    const values = ['2026-09-24 12:00:01', 'Thu, 24 Sep 2026 11:00:00 GMT', 'junk', '2026-09-24T11:30:00Z'];
    expect([...values].sort((a, b) => brokerTimeSortValue(a) - brokerTimeSortValue(b) || 0)).toEqual([
      'junk', 'Thu, 24 Sep 2026 11:00:00 GMT', '2026-09-24T11:30:00Z', '2026-09-24 12:00:01',
    ]);
  });
});

describe('RelativeTime', () => {
  it('renders a time element with the absolute time as its tooltip', () => {
    render(<RelativeTime value="2020-01-01 00:00:00" />);
    const time = screen.getByText(/ago$/);
    expect(time.tagName).toBe('TIME');
    expect(time).toHaveAttribute('dateTime', '2020-01-01T00:00:00.000Z');
    expect(time).toHaveAttribute('title', '2020-01-01 00:00:00 UTC');
  });

  it('can show the absolute time too', () => {
    render(<RelativeTime value="2020-01-01T00:00:00Z" showAbsolute />);
    expect(screen.getByText('2020-01-01 00:00:00 UTC')).toBeInTheDocument();
  });

  it('shows the open end of temporal history as current, and anything else as sent', () => {
    const { rerender } = render(<RelativeTime value="9999-12-31 23:59:59.9999999" />);
    expect(screen.getByText('Current')).toBeInTheDocument();
    rerender(<RelativeTime value="not a time" />);
    expect(screen.getByText('not a time')).toBeInTheDocument();
    rerender(<RelativeTime value={null} />);
    expect(screen.getByText('—')).toBeInTheDocument();
  });
});
