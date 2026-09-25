import { describe, expect, it } from 'vitest';

import { runBounded, summarizeBulk } from './bulk';

describe('runBounded', () => {
  it('never runs more than the limit at once and keeps the results in order', async () => {
    let running = 0;
    let peak = 0;
    const results = await runBounded([30, 5, 20, 1, 10, 2], 2, async (ms) => {
      running += 1;
      peak = Math.max(peak, running);
      await new Promise((resolve) => setTimeout(resolve, ms));
      running -= 1;
      return ms * 2;
    });

    expect(peak).toBe(2);
    expect(results).toEqual([60, 10, 40, 2, 20, 4]);
  });

  it('handles an empty list and a limit larger than the list', async () => {
    expect(await runBounded([], 4, async (item: number) => item)).toEqual([]);
    expect(await runBounded([1, 2], 10, async (item) => item + 1)).toEqual([2, 3]);
  });
});

describe('summarizeBulk', () => {
  const ok = (hostname: string) => ({ hostname, ok: true, message: 'Done.' });
  const failed = (hostname: string) => ({ hostname, ok: false, message: 'No.' });

  it('counts what was done, what failed and what was skipped', () => {
    expect(summarizeBulk('Drained', [ok('a'), ok('b')], 0)).toBe('Drained 2 hosts.');
    expect(summarizeBulk('Started', [ok('a')], 0)).toBe('Started 1 host.');
    expect(summarizeBulk('Stopped', [ok('a'), failed('b')], 3)).toBe('Stopped 1 host; 1 failed; 3 skipped.');
    expect(summarizeBulk('Deleted', [failed('a')], 0)).toBe('Deleted 0 hosts; 1 failed.');
  });
});
