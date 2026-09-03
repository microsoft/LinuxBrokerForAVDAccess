import { describe, expect, it } from 'vitest';
import { render, screen } from '@testing-library/react';
import { MemoryRouter } from 'react-router-dom';

import { ErrorPage } from './ErrorPage';

/*
 * Ports the Jinja assertions from test_error_template_exists_and_renders_without_arguments:
 * error.html had to work both with no arguments and with full detail, because
 * route_user.profile called it bare.
 */
describe('ErrorPage', () => {
  function renderPage(props: Parameters<typeof ErrorPage>[0] = {}) {
    return render(
      <MemoryRouter>
        <ErrorPage {...props} />
      </MemoryRouter>,
    );
  }

  it('renders a usable page with no props at all', () => {
    const { container } = renderPage();
    expect(screen.getByText('Something went wrong')).toBeInTheDocument();
    expect(container.textContent).not.toContain('500');
  });

  it('renders the supplied code, title and message', () => {
    renderPage({ code: 500, title: 'Test error', message: 'friendly' });
    expect(screen.getByText('500')).toBeInTheDocument();
    expect(screen.getByText('Test error')).toBeInTheDocument();
    expect(screen.getByText('friendly')).toBeInTheDocument();
  });

  it('always offers a way back to the dashboard', () => {
    renderPage();
    expect(screen.getByRole('link', { name: /Back to dashboard/ })).toHaveAttribute('href', '/');
  });
});
