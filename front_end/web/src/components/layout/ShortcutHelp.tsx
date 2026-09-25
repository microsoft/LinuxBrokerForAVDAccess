import { useId } from 'react';
import { Link } from 'react-router-dom';

import { SECTION_SHORTCUTS } from '../../hooks/useKeyboardShortcuts';
import { Button } from '../ui/Button';
import { Modal } from '../ui/Modal';

function Keys({ keys }: { keys: string[] }) {
  return (
    <span className="flex items-center gap-1">
      {keys.map((key, index) => (
        <span key={`${key}-${index}`} className="flex items-center gap-1">
          {index ? <span className="text-xs text-muted">then</span> : null}
          <kbd className="rounded border border-[var(--lb-neutral-bd)] bg-[var(--lb-neutral-bg)] px-1.5 py-0.5 font-mono text-xs">
            {key}
          </kbd>
        </span>
      ))}
    </span>
  );
}

/** Every keyboard shortcut, and where to turn them off. */
export function ShortcutHelp({ open, onClose }: { open: boolean; onClose: () => void }) {
  const titleId = useId();
  const rows: Array<{ keys: string[]; label: string }> = [
    { keys: ['/'], label: 'Search this page' },
    ...SECTION_SHORTCUTS.map((shortcut) => ({ keys: ['g', shortcut.key], label: `Go to ${shortcut.label}` })),
    { keys: ['?'], label: 'Show these shortcuts' },
  ];

  return (
    <Modal open={open} labelledBy={titleId} onClose={onClose}>
      <h2 id={titleId} className="mt-0 mb-4 text-lg font-semibold">
        Keyboard shortcuts
      </h2>
      <table className="lb-table">
        <caption className="sr-only">Keyboard shortcuts</caption>
        <tbody>
          {rows.map((row) => (
            <tr key={row.label}>
              <td>
                <Keys keys={row.keys} />
              </td>
              <td className="text-sm">{row.label}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <p className="mt-4 mb-0 text-xs text-muted">
        Shortcuts never fire while you type in a field. You can turn them off in{' '}
        <Link to="/profile" onClick={onClose}>
          your profile
        </Link>
        .
      </p>
      <div className="mt-5 flex justify-end">
        <Button onClick={onClose}>Close</Button>
      </div>
    </Modal>
  );
}
