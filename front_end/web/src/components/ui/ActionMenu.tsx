import { useCallback, useEffect, useId, useRef, useState } from 'react';
import { createPortal } from 'react-dom';

import { classNames } from '../../lib/format';
import { Icon } from '../Icon';
import type { IconName } from '../Icon';

export interface ActionMenuItem {
  key: string;
  label: string;
  icon: IconName;
  onSelect: () => void;
  tone?: 'default' | 'warning' | 'danger';
  disabled?: boolean;
}

export interface ActionMenuProps {
  /** Accessible name of the trigger, for example "Host actions for linux-host-01". */
  label: string;
  items: ActionMenuItem[];
  /** Visible trigger text. */
  text?: string;
}

const MENU_WIDTH = 224;

const TONE_CLASS: Record<NonNullable<ActionMenuItem['tone']>, string> = {
  default: 'text-ink',
  warning: 'text-[var(--lb-warn-fg)]',
  danger: 'text-[var(--lb-danger-fg)]',
};

/**
 * A menu button (WAI-ARIA menu pattern) for a row's secondary actions.
 *
 * The menu is portalled to the body and positioned against the trigger, because
 * tables scroll inside an overflow container that would clip an inline dropdown.
 * Arrow keys, Home and End move between items; Escape and Tab close it; focus goes
 * back to the trigger whenever it closes.
 */
export function ActionMenu({ label, items, text = 'Actions' }: ActionMenuProps) {
  const [open, setOpen] = useState(false);
  const [position, setPosition] = useState<{ top: number; left: number } | null>(null);
  const triggerRef = useRef<HTMLButtonElement>(null);
  const menuRef = useRef<HTMLDivElement>(null);
  const triggerId = useId();
  const menuId = useId();

  const enabled = items.filter((item) => !item.disabled);

  const close = useCallback((restoreFocus = true) => {
    setOpen(false);
    if (restoreFocus) {
      triggerRef.current?.focus();
    }
  }, []);

  const place = useCallback(() => {
    if (!triggerRef.current) {
      return;
    }
    const rect = triggerRef.current.getBoundingClientRect();
    const left = Math.max(8, Math.min(rect.right - MENU_WIDTH, window.innerWidth - MENU_WIDTH - 8));
    setPosition({ top: rect.bottom + 4, left });
  }, []);

  // Placed before it opens, so the first render is already visible and focusable.
  const openMenu = useCallback(() => {
    place();
    setOpen(true);
  }, [place]);

  useEffect(() => {
    if (!open) {
      return;
    }

    menuRef.current
      ?.querySelector<HTMLButtonElement>('[role="menuitem"]:not([disabled])')
      ?.focus({ preventScroll: true });

    function onPointerDown(event: MouseEvent) {
      const target = event.target as Node;
      if (!menuRef.current?.contains(target) && !triggerRef.current?.contains(target)) {
        close(false);
      }
    }

    // The menu is fixed to the viewport, so it follows its trigger when the page or the
    // table scrolls, or the window resizes.
    let frame = 0;
    function onViewportChange() {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(place);
    }

    document.addEventListener('mousedown', onPointerDown);
    window.addEventListener('resize', onViewportChange);
    window.addEventListener('scroll', onViewportChange, true);

    return () => {
      cancelAnimationFrame(frame);
      document.removeEventListener('mousedown', onPointerDown);
      window.removeEventListener('resize', onViewportChange);
      window.removeEventListener('scroll', onViewportChange, true);
    };
  }, [open, close, place]);

  function onMenuKeyDown(event: React.KeyboardEvent<HTMLDivElement>) {
    const menuItems = Array.from(
      menuRef.current?.querySelectorAll<HTMLButtonElement>('[role="menuitem"]:not([disabled])') ?? [],
    );
    const index = menuItems.indexOf(document.activeElement as HTMLButtonElement);

    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      close();
    } else if (event.key === 'Tab') {
      close(false);
    } else if (event.key === 'ArrowDown') {
      event.preventDefault();
      menuItems[(index + 1) % menuItems.length]?.focus();
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      menuItems[(index - 1 + menuItems.length) % menuItems.length]?.focus();
    } else if (event.key === 'Home') {
      event.preventDefault();
      menuItems[0]?.focus();
    } else if (event.key === 'End') {
      event.preventDefault();
      menuItems[menuItems.length - 1]?.focus();
    }
  }

  function onTriggerKeyDown(event: React.KeyboardEvent<HTMLButtonElement>) {
    if ((event.key === 'ArrowDown' || event.key === 'ArrowUp') && !open) {
      event.preventDefault();
      openMenu();
    }
  }

  if (items.length === 0) {
    return null;
  }

  return (
    <>
      <button
        ref={triggerRef}
        id={triggerId}
        type="button"
        className="lb-btn border-[var(--lb-hairline)] bg-[var(--lb-glass-bg-strong)] px-2.5 py-1.5 text-xs text-ink hover:border-[var(--lb-brand)] hover:text-[var(--lb-brand)]"
        aria-label={label}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-controls={open ? menuId : undefined}
        disabled={enabled.length === 0}
        onClick={() => (open ? close(false) : openMenu())}
        onKeyDown={onTriggerKeyDown}
      >
        {text}
        <Icon name="chevron-down" size={12} />
      </button>

      {open
        ? createPortal(
            <div
              ref={menuRef}
              id={menuId}
              role="menu"
              aria-labelledby={triggerId}
              onKeyDown={onMenuKeyDown}
              className="lb-glass lb-glass-strong fixed z-40 py-1 text-left"
              style={{ top: position?.top ?? 0, left: position?.left ?? 0, width: MENU_WIDTH }}
            >
              {items.map((item) => (
                <button
                  key={item.key}
                  type="button"
                  role="menuitem"
                  disabled={item.disabled}
                  className={classNames(
                    'flex w-full items-center gap-2 px-3 py-2 text-left text-sm',
                    'hover:bg-[var(--lb-hover)] focus-visible:bg-[var(--lb-hover)] disabled:cursor-not-allowed disabled:opacity-50',
                    TONE_CLASS[item.tone ?? 'default'],
                  )}
                  onClick={() => {
                    close();
                    item.onSelect();
                  }}
                >
                  <Icon name={item.icon} size={14} />
                  {item.label}
                </button>
              ))}
            </div>,
            document.body,
          )
        : null}
    </>
  );
}
