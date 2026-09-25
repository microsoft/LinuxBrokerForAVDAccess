import { describe, expect, it } from 'vitest';
import { render, screen, within } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

import { LifecycleExplainer } from './LifecycleExplainer';

describe('LifecycleExplainer', () => {
  it('shows the lifecycle in order and spells out release versus return', async () => {
    render(<LifecycleExplainer />);
    await userEvent.click(screen.getByText('How a host moves through the broker'));

    const stages = within(screen.getByRole('list', { name: 'Host lifecycle' })).getAllByRole('listitem');
    expect(stages.map((stage) => stage.querySelector('.lb-badge')?.textContent)).toEqual(['Available', 'Checked out', 'Released']);
    expect(screen.getByText('Release').nextElementSibling).toHaveTextContent('can reconnect to it');
    expect(screen.getByText('Return').nextElementSibling).toHaveTextContent('Ends the assignment now');
    expect(screen.getByText('Drain')).toBeInTheDocument();
    expect(screen.getByText('Maintenance')).toBeInTheDocument();
  });
});
