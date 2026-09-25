import { useSyncExternalStore } from 'react';

/*
 * Portal preferences kept in localStorage: compact table rows, and whether the single-key
 * keyboard shortcuts are on (WCAG 2.1.4 asks that they can be turned off). Density is also
 * set before first paint by the inline script in index.html.
 */
export type Density = 'comfortable' | 'compact';

const DENSITY_KEY = 'lb-density';
const SHORTCUTS_KEY = 'lb-shortcuts';
const CHANGE_EVENT = 'lb-preferences';

function read(key: string): string | null {
  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
}

function write(key: string, value: string) {
  try {
    window.localStorage.setItem(key, value);
  } catch {
    // A stored preference is a convenience; failing to persist must not break the page.
  }
  window.dispatchEvent(new Event(CHANGE_EVENT));
}

export function readDensity(): Density {
  return read(DENSITY_KEY) === 'compact' ? 'compact' : 'comfortable';
}

export function applyDensity(density: Density) {
  if (density === 'compact') {
    document.documentElement.setAttribute('data-density', 'compact');
  } else {
    document.documentElement.removeAttribute('data-density');
  }
  write(DENSITY_KEY, density);
}

export function shortcutsEnabled(): boolean {
  return read(SHORTCUTS_KEY) !== 'off';
}

export function setShortcutsEnabled(enabled: boolean) {
  write(SHORTCUTS_KEY, enabled ? 'on' : 'off');
}

function subscribe(listener: () => void) {
  window.addEventListener(CHANGE_EVENT, listener);
  window.addEventListener('storage', listener);
  return () => {
    window.removeEventListener(CHANGE_EVENT, listener);
    window.removeEventListener('storage', listener);
  };
}

function snapshot() {
  return `${readDensity()}|${shortcutsEnabled() ? 'on' : 'off'}`;
}

export function usePreferences() {
  const value = useSyncExternalStore(subscribe, snapshot, snapshot);
  const [density, shortcuts] = value.split('|');
  return {
    density: density as Density,
    shortcuts: shortcuts === 'on',
    setDensity: applyDensity,
    setShortcuts: setShortcutsEnabled,
  };
}
