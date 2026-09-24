import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

import { ActionMenu } from './ActionMenu';
import type { ActionMenuItem } from './ActionMenu';

function setup(items?: ActionMenuItem[]) {
  const start = vi.fn();
  const stop = vi.fn();
  const drain = vi.fn();

  render(
    <ActionMenu
      label="Host actions for linux-host-01"
      text="Host"
      items={
        items ?? [
          { key: 'start', label: 'Start', icon: 'power', onSelect: start },
          { key: 'stop', label: 'Stop', icon: 'power', tone: 'warning', onSelect: stop },
          { key: 'drain', label: 'Drain', icon: 'box-arrow-right', onSelect: drain },
        ]
      }
    />,
  );

  return { start, stop, drain, trigger: screen.getByRole('button', { name: 'Host actions for linux-host-01' }) };
}

describe('ActionMenu', () => {
  it('is a closed menu button until it is opened', () => {
    const { trigger } = setup();
    expect(trigger).toHaveAttribute('aria-haspopup', 'menu');
    expect(trigger).toHaveAttribute('aria-expanded', 'false');
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
  });

  it('opens with the first item focused and runs the chosen action', async () => {
    const { trigger, stop, start } = setup();

    await userEvent.click(trigger);

    expect(trigger).toHaveAttribute('aria-expanded', 'true');
    const items = screen.getAllByRole('menuitem');
    expect(items.map((item) => item.textContent)).toEqual(['Start', 'Stop', 'Drain']);
    expect(items[0]).toHaveFocus();

    await userEvent.click(screen.getByRole('menuitem', { name: 'Stop' }));
    expect(stop).toHaveBeenCalledTimes(1);
    expect(start).not.toHaveBeenCalled();
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });

  it('moves with the arrow keys, Home and End, and wraps', async () => {
    const { trigger, drain } = setup();
    await userEvent.click(trigger);

    await userEvent.keyboard('{ArrowDown}');
    expect(screen.getByRole('menuitem', { name: 'Stop' })).toHaveFocus();
    await userEvent.keyboard('{End}');
    expect(screen.getByRole('menuitem', { name: 'Drain' })).toHaveFocus();
    await userEvent.keyboard('{ArrowDown}');
    expect(screen.getByRole('menuitem', { name: 'Start' })).toHaveFocus();
    await userEvent.keyboard('{ArrowUp}');
    expect(screen.getByRole('menuitem', { name: 'Drain' })).toHaveFocus();
    await userEvent.keyboard('{Home}');
    expect(screen.getByRole('menuitem', { name: 'Start' })).toHaveFocus();

    await userEvent.keyboard('{End}{Enter}');
    expect(drain).toHaveBeenCalledTimes(1);
  });

  it('closes on Escape and returns focus to the trigger', async () => {
    const { trigger, start } = setup();
    await userEvent.click(trigger);
    await userEvent.keyboard('{Escape}');

    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
    expect(start).not.toHaveBeenCalled();
  });

  it('closes when the pointer goes down outside it', async () => {
    const { trigger } = setup();
    await userEvent.click(trigger);
    await userEvent.click(document.body);
    expect(screen.queryByRole('menu')).not.toBeInTheDocument();
  });

  it('opens from the keyboard with the down arrow', async () => {
    const { trigger } = setup();
    trigger.focus();
    await userEvent.keyboard('{ArrowDown}');
    expect(screen.getByRole('menu')).toBeInTheDocument();
  });

  it('renders nothing when there is nothing the operator may do', () => {
    render(<ActionMenu label="Host actions for linux-host-02" items={[]} />);
    expect(screen.queryByRole('button', { name: 'Host actions for linux-host-02' })).not.toBeInTheDocument();
  });
});
