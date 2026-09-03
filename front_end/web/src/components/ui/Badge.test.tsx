import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/react';

import { ActionBadge, NetworkBadge, PowerBadge, VmStatusBadge } from './Badge';

/*
 * Status must never be conveyed by colour alone (WCAG 1.4.1). Every badge pairs a
 * colour with an icon and a text label, and these tests hold that line.
 */
describe('status badges', () => {
  it.each([
    ['Available', 'Available'],
    ['CheckedOut', 'Checked out'],
    ['Maintenance', 'Maintenance'],
    ['Released', 'Released'],
  ])('renders VM status %s with the label %s', (value, label) => {
    const { container } = render(<VmStatusBadge value={value} />);
    expect(screen.getByText(label)).toBeInTheDocument();
    expect(container.querySelector('svg')).toBeInTheDocument();
  });

  it('renders an unknown VM status verbatim rather than hiding it', () => {
    render(<VmStatusBadge value="Rebuilding" />);
    expect(screen.getByText('Rebuilding')).toBeInTheDocument();
  });

  it.each([null, undefined, '', '   '])('renders a dash for %p', (value) => {
    const { container } = render(<VmStatusBadge value={value} />);
    expect(container.textContent).toBe('\u2014');
    expect(container.querySelector('svg')).not.toBeInTheDocument();
  });

  it('pairs power state with an icon', () => {
    const { container } = render(<PowerBadge value="On" />);
    expect(screen.getByText('On')).toBeInTheDocument();
    expect(container.querySelector('svg')).toBeInTheDocument();
  });

  it('distinguishes reachable from unreachable by icon and text', () => {
    const reachable = render(<NetworkBadge value="Reachable" />);
    expect(screen.getByText('Reachable')).toBeInTheDocument();
    reachable.unmount();

    render(<NetworkBadge value="Unreachable" />);
    expect(screen.getByText('Unreachable')).toBeInTheDocument();
  });

  it.each([
    ['Scale Up', 'Scale up'],
    ['Scale Down', 'Scale down'],
    ['No Action', 'No action'],
  ])('renders the scaling action %s as %s', (value, label) => {
    render(<ActionBadge value={value} />);
    expect(screen.getByText(label)).toBeInTheDocument();
  });
});
