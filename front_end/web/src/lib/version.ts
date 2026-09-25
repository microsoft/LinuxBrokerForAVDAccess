/** Dotted numeric versions, such as a host agent's "1.1.0". Anything else never compares as newer. */
export function parseVersion(value: string | null | undefined): number[] | null {
  if (!value) return null;
  const match = /^(\d+)(?:\.(\d+))?(?:\.(\d+))?/.exec(value.trim());
  return match ? [Number(match[1]), Number(match[2] ?? 0), Number(match[3] ?? 0)] : null;
}

export function versionAtLeast(value: string | null | undefined, minimum: string): boolean {
  const version = parseVersion(value);
  const floor = parseVersion(minimum);
  if (!version || !floor) return false;
  for (let index = 0; index < 3; index += 1) {
    if (version[index] !== floor[index]) return version[index] > floor[index];
  }
  return true;
}

/** Patching needs patch-host.sh, which host agent 1.1.0 ships. */
export const PATCH_AGENT_VERSION = '1.1.0';
