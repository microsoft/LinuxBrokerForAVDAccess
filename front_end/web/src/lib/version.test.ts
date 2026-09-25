import { describe, expect, it } from 'vitest';

import { parseVersion, versionAtLeast } from './version';

describe('host agent versions', () => {
  it.each([
    ['1.1.0', '1.1.0', true],
    ['1.2', '1.1.0', true],
    ['2.0.0', '1.1.0', true],
    ['1.0.9', '1.1.0', false],
    ['1.1.0-rc1', '1.1.0', true],
    [null, '1.1.0', false],
    ['legacy', '1.1.0', false],
  ])('%s is at least %s: %s', (version, minimum, expected) => {
    expect(versionAtLeast(version, minimum)).toBe(expected);
  });

  it('parses the numbers it can', () => {
    expect(parseVersion(' 1.10 ')).toEqual([1, 10, 0]);
    expect(parseVersion('')).toBeNull();
  });
});
