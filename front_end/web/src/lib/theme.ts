export type Theme = 'light' | 'dark';

const STORAGE_KEY = 'lb-theme';

/*
 * The theme is an attribute on <html>, set before first paint by the inline
 * script in index.html so the page never flashes the wrong palette. This module
 * owns the runtime toggle and keeps localStorage in step.
 */

function isTheme(value: unknown): value is Theme {
  return value === 'light' || value === 'dark';
}

export function readStoredTheme(): Theme | null {
  try {
    const stored = window.localStorage.getItem(STORAGE_KEY);
    return isTheme(stored) ? stored : null;
  } catch {
    // Storage can be unavailable in hardened browser configurations.
    return null;
  }
}

export function prefersDark(): boolean {
  return typeof window.matchMedia === 'function'
    ? window.matchMedia('(prefers-color-scheme: dark)').matches
    : false;
}

export function resolveInitialTheme(): Theme {
  const attribute = document.documentElement.getAttribute('data-theme');
  if (isTheme(attribute)) {
    return attribute;
  }
  return readStoredTheme() ?? (prefersDark() ? 'dark' : 'light');
}

export function applyTheme(theme: Theme) {
  document.documentElement.setAttribute('data-theme', theme);
  try {
    window.localStorage.setItem(STORAGE_KEY, theme);
  } catch {
    // A stored preference is a convenience; failing to persist must not break the toggle.
  }
}

export function nextTheme(theme: Theme): Theme {
  return theme === 'dark' ? 'light' : 'dark';
}
