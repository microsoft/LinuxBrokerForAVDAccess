import { describe, expect, it, vi } from 'vitest';
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

import { MessageDialog } from './MessageDialog';

describe('MessageDialog', () => {
  it('focuses the message, counts characters and refuses one that is too long', async () => {
    const onSend = vi.fn();
    render(
      <MessageDialog open title="Message alice" recipients="The message is shown in alice's desktop." onSend={onSend} onCancel={() => {}} />,
    );

    const field = screen.getByLabelText('Message');
    expect(field).toHaveFocus();
    const send = screen.getByRole('button', { name: 'Send message' });
    expect(send).toBeDisabled();

    await userEvent.type(field, '  Saving now  ');
    expect(screen.getByText('10 / 500')).toBeInTheDocument();
    await userEvent.click(send);
    expect(onSend).toHaveBeenCalledWith('Saving now');

    await userEvent.clear(field);
    await userEvent.click(field);
    await userEvent.paste('x'.repeat(501));
    expect(screen.getByText('1 character over the 500 limit')).toBeInTheDocument();
    expect(send).toBeDisabled();
  });

  it('closes on Escape', async () => {
    const onCancel = vi.fn();
    render(<MessageDialog open title="Message everyone" recipients="Every session." onSend={() => {}} onCancel={onCancel} />);
    await userEvent.keyboard('{Escape}');
    expect(onCancel).toHaveBeenCalled();
  });
});
