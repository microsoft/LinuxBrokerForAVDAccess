import { useEffect, useState } from 'react';

import { applyTheme, nextTheme, resolveInitialTheme } from '../../lib/theme';
import type { Theme } from '../../lib/theme';
import { Icon } from '../Icon';

export function ThemeToggle() {
  const [theme, setTheme] = useState<Theme>('light');

  // Read on mount rather than during render: the attribute is set by the inline
  // script in index.html, which does not exist during a server-side render or a test.
  useEffect(() => {
    setTheme(resolveInitialTheme());
  }, []);

  function toggle() {
    const next = nextTheme(theme);
    setTheme(next);
    applyTheme(next);
  }

  const goingDark = theme === 'light';

  return (
    <button
      type="button"
      onClick={toggle}
      className="rounded-[var(--radius-glass-sm)] border border-white/25 p-2 text-white/90 transition-colors hover:bg-white/15 hover:text-white"
      aria-label={goingDark ? 'Switch to dark theme' : 'Switch to light theme'}
      title={goingDark ? 'Switch to dark theme' : 'Switch to light theme'}
    >
      <Icon name={goingDark ? 'moon' : 'sun'} size={16} />
    </button>
  );
}
