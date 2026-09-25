import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';

/** "g" then one of these letters goes to that section. */
export const SECTION_SHORTCUTS: Array<{ key: string; label: string; to: string }> = [
  { key: 'o', label: 'Overview', to: '/' },
  { key: 'h', label: 'Hosts', to: '/vms' },
  { key: 'm', label: 'Maintenance', to: '/vms/maintenance' },
  { key: 's', label: 'Sessions', to: '/sessions' },
  { key: 'c', label: 'Scaling', to: '/scaling' },
  { key: 'e', label: 'Settings', to: '/settings/hosts' },
  { key: 'a', label: 'Audit', to: '/audit' },
];

const SEQUENCE_MS = 1500;
const NOT_TYPING = new Set(['checkbox', 'radio', 'button', 'submit', 'reset', 'range', 'color', 'file', 'image']);

function isTyping(target: EventTarget | null) {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  const tag = target.tagName;
  if (tag === 'TEXTAREA' || tag === 'SELECT') return true;
  return tag === 'INPUT' && !NOT_TYPING.has((target as HTMLInputElement).type);
}

/** The search box a page marks as its main one, else the first search field. */
export function findSearchField(): HTMLInputElement | null {
  return (
    document.querySelector<HTMLInputElement>('[data-shortcut="search"]') ??
    document.querySelector<HTMLInputElement>('input[type="search"]')
  );
}

/**
 * The portal's keyboard shortcuts: "/" to search, "g" then a letter to change section,
 * "?" for help. Keys typed into a field, or pressed with a modifier, are left alone.
 */
export function useKeyboardShortcuts(enabled: boolean) {
  const navigate = useNavigate();
  const [helpOpen, setHelpOpen] = useState(false);
  const pendingSince = useRef<number | null>(null);

  useEffect(() => {
    if (!enabled) {
      return undefined;
    }

    function onKeyDown(event: KeyboardEvent) {
      if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey || isTyping(event.target)) {
        return;
      }
      // Leave the keyboard to an open dialog.
      if (document.querySelector('[role="dialog"], [role="alertdialog"]')) {
        return;
      }

      const pending = pendingSince.current;
      pendingSince.current = null;
      if (pending !== null && Date.now() - pending < SEQUENCE_MS) {
        const section = SECTION_SHORTCUTS.find((shortcut) => shortcut.key === event.key.toLowerCase());
        if (section) {
          event.preventDefault();
          navigate(section.to);
        }
        return;
      }

      if (event.key === 'g') {
        pendingSince.current = Date.now();
      } else if (event.key === '/') {
        const search = findSearchField();
        if (search) {
          event.preventDefault();
          search.focus();
        }
      } else if (event.key === '?') {
        event.preventDefault();
        setHelpOpen(true);
      }
    }

    window.addEventListener('keydown', onKeyDown);
    return () => window.removeEventListener('keydown', onKeyDown);
  }, [enabled, navigate]);

  return { helpOpen, openHelp: () => setHelpOpen(true), closeHelp: () => setHelpOpen(false) };
}
