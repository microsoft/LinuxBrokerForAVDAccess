import { describe, expect, it } from 'vitest';

import { minuteDesktops } from './desktops';

describe('desktops that count screen delays in minutes', () => {
  it('names each one the hosts report, once and in a fixed order', () => {
    expect(
      minuteDesktops([{ Desktop: 'mate' }, { Desktop: 'gnome' }, { Desktop: 'xfce' }, { Desktop: 'mate' }]),
    ).toEqual(['Xfce', 'MATE']);
  });

  it('is empty for GNOME, other desktops and hosts that have not reported', () => {
    expect(minuteDesktops([{ Desktop: 'gnome' }, { Desktop: 'kde' }, { Desktop: null }])).toEqual([]);
    expect(minuteDesktops([])).toEqual([]);
  });
});
