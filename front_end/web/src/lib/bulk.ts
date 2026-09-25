/** Run `worker` over every item, at most `limit` at a time, keeping the results in order. */
export async function runBounded<T, R>(items: T[], limit: number, worker: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length);
  let next = 0;

  async function lane() {
    while (next < items.length) {
      const index = next;
      next += 1;
      results[index] = await worker(items[index]);
    }
  }

  await Promise.all(Array.from({ length: Math.max(1, Math.min(limit, items.length)) }, lane));
  return results;
}

export interface BulkOutcome {
  hostname: string;
  ok: boolean;
  message: string;
}

/** "Drained 3 hosts; 1 failed", for the toast after a bulk action. */
export function summarizeBulk(verb: string, outcomes: BulkOutcome[], skipped: number): string {
  const done = outcomes.filter((outcome) => outcome.ok).length;
  const failed = outcomes.length - done;
  const parts = [`${verb} ${done} host${done === 1 ? '' : 's'}`];
  if (failed) parts.push(`${failed} failed`);
  if (skipped) parts.push(`${skipped} skipped`);
  return `${parts.join('; ')}.`;
}
