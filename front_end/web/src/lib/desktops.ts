import type { HostHealth } from '../types/broker';

/** The desktops that count screen blank and lock delays in whole minutes, by heartbeat value. */
const MINUTE_DESKTOPS: ReadonlyArray<readonly [string, string]> = [
  ['xfce', 'Xfce'],
  ['mate', 'MATE'],
];

/** The names of the desktops among these hosts that count screen delays in whole minutes. */
export function minuteDesktops(hosts: ReadonlyArray<Pick<HostHealth, 'Desktop'>>): string[] {
  const reported = new Set(hosts.map((host) => host.Desktop));
  return MINUTE_DESKTOPS.filter(([desktop]) => reported.has(desktop)).map(([, name]) => name);
}
