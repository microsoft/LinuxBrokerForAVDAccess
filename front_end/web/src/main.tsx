import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { BrowserRouter } from 'react-router-dom';
import { QueryClientProvider } from '@tanstack/react-query';

import './styles/theme.css';
import { App } from './App';
import { createQueryClient } from './lib/queryClient';
import { ToastProvider } from './components/ui/Toast';

const container = document.getElementById('root');

if (!container) {
  throw new Error('The #root element is missing from the page shell.');
}

createRoot(container).render(
  <StrictMode>
    <QueryClientProvider client={createQueryClient()}>
      <BrowserRouter>
        <ToastProvider>
          <App />
        </ToastProvider>
      </BrowserRouter>
    </QueryClientProvider>
  </StrictMode>,
);
