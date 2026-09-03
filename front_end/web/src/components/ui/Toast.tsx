import { createContext, useCallback, useContext, useMemo, useRef, useState } from 'react';
import type { ReactNode } from 'react';

import { classNames } from '../../lib/format';
import { Icon } from '../Icon';
import type { IconName } from '../Icon';

export type ToastTone = 'success' | 'info' | 'warning' | 'danger';

export interface Toast {
  id: number;
  message: string;
  tone: ToastTone;
}

interface ToastContextValue {
  toasts: Toast[];
  showToast: (message: string, tone?: ToastTone) => void;
  dismissToast: (id: number) => void;
}

const ToastContext = createContext<ToastContextValue | null>(null);

const AUTO_DISMISS_MS = 8000;

/**
 * Replaces Flask's flash messages.
 *
 * Messages are announced through a polite live region so an operator using a
 * screen reader hears the outcome of an action they cannot see.
 */
export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);
  const nextId = useRef(1);
  const timers = useRef(new Map<number, ReturnType<typeof setTimeout>>());

  const dismissToast = useCallback((id: number) => {
    const timer = timers.current.get(id);
    if (timer) {
      clearTimeout(timer);
      timers.current.delete(id);
    }
    setToasts((current) => current.filter((toast) => toast.id !== id));
  }, []);

  const showToast = useCallback(
    (message: string, tone: ToastTone = 'info') => {
      const id = nextId.current;
      nextId.current += 1;

      setToasts((current) => [...current, { id, message, tone }]);

      // Failures stay until dismissed; an operator should not have to catch an
      // error message before it disappears.
      if (tone !== 'danger') {
        timers.current.set(
          id,
          setTimeout(() => dismissToast(id), AUTO_DISMISS_MS),
        );
      }
    },
    [dismissToast],
  );

  const value = useMemo(
    () => ({ toasts, showToast, dismissToast }),
    [toasts, showToast, dismissToast],
  );

  return (
    <ToastContext.Provider value={value}>
      {children}
      <ToastRegion toasts={toasts} onDismiss={dismissToast} />
    </ToastContext.Provider>
  );
}

export function useToast() {
  const context = useContext(ToastContext);
  if (!context) {
    throw new Error('useToast must be used inside a ToastProvider.');
  }
  return context;
}

const TONE: Record<ToastTone, { cls: string; icon: IconName }> = {
  success: { cls: 'lb-tone-ok', icon: 'check-circle' },
  info: { cls: 'lb-tone-info', icon: 'info-circle' },
  warning: { cls: 'lb-tone-warn', icon: 'alert-triangle' },
  danger: { cls: 'lb-tone-danger', icon: 'alert-triangle' },
};

function ToastRegion({ toasts, onDismiss }: { toasts: Toast[]; onDismiss: (id: number) => void }) {
  return (
    <div
      className="pointer-events-none fixed inset-x-0 bottom-0 z-40 flex flex-col items-center gap-2 p-4 sm:items-end"
      aria-live="polite"
      aria-atomic="false"
    >
      {toasts.map((toast) => {
        const { cls, icon } = TONE[toast.tone];
        return (
          <div
            key={toast.id}
            role={toast.tone === 'danger' || toast.tone === 'warning' ? 'alert' : 'status'}
            className={classNames(
              'lb-glass lb-glass-strong pointer-events-auto flex w-full max-w-md items-start gap-2.5 p-3.5 text-sm',
              'border-[var(--tone-bd)] text-[var(--tone-fg)]',
              cls,
            )}
          >
            <Icon name={icon} size={16} className="mt-0.5 shrink-0" />
            <div className="min-w-0 flex-1">{toast.message}</div>
            <button
              type="button"
              onClick={() => onDismiss(toast.id)}
              className="shrink-0 rounded p-0.5 opacity-70 hover:opacity-100"
              aria-label="Dismiss message"
            >
              <Icon name="x" size={14} />
            </button>
          </div>
        );
      })}
    </div>
  );
}
