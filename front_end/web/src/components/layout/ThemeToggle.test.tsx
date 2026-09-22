import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

import { ThemeToggle } from './ThemeToggle';

describe('ThemeToggle', () => {
  it('starts from the attribute the pre-paint script set', () => {
    document.documentElement.setAttribute('data-theme', 'dark');
    render(<ThemeToggle />);
    expect(screen.getByRole('button', { name: 'Switch to light theme' })).toBeInTheDocument();
  });

  it('falls back to the stored preference when no attribute is present', () => {
    window.localStorage.setItem('lb-theme', 'dark');
    render(<ThemeToggle />);
    expect(screen.getByRole('button', { name: 'Switch to light theme' })).toBeInTheDocument();
  });

  it('switches the document theme and persists the choice', async () => {
    document.documentElement.setAttribute('data-theme', 'light');
    render(<ThemeToggle />);

    await userEvent.click(screen.getByRole('button', { name: 'Switch to dark theme' }));

    expect(document.documentElement).toHaveAttribute('data-theme', 'dark');
    expect(window.localStorage.getItem('lb-theme')).toBe('dark');
  });

  it('toggles back again', async () => {
    document.documentElement.setAttribute('data-theme', 'dark');
    render(<ThemeToggle />);

    await userEvent.click(screen.getByRole('button', { name: 'Switch to light theme' }));

    expect(document.documentElement).toHaveAttribute('data-theme', 'light');
    expect(window.localStorage.getItem('lb-theme')).toBe('light');
  });
});
