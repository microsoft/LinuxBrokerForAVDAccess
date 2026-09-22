import type { SessionInfo } from '../types/broker';

const API_PREFIX = '/api/ui';

/** A non-2xx response from the BFF, carrying the message it chose to surface. */
export class ApiError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

/*
 * The CSRF token is tied to the Flask session and is handed to us by
 * /api/ui/session. It is cached here so a mutation does not need an extra round
 * trip, and refreshed whenever the server rejects a token as stale.
 */
let csrfToken: string | null = null;

export function setCsrfToken(token: string | null) {
  csrfToken = token;
}

export function getCsrfToken() {
  return csrfToken;
}

/**
 * Send the operator to the server-side sign-in redirect.
 *
 * `fetch` cannot follow the 302 to Entra ID, so the BFF answers an expired
 * session with a 401 and the browser navigates here instead.
 */
export function redirectToLogin() {
  window.location.assign('/login');
}

async function readError(response: Response): Promise<string> {
  try {
    const payload = await response.json();
    if (payload && typeof payload.error === 'string') {
      return payload.error;
    }
  } catch {
    /* A proxy or crash can return HTML; fall through to the generic message. */
  }
  return `The request failed (HTTP ${response.status}).`;
}

interface RequestOptions {
  method?: 'GET' | 'POST';
  body?: unknown;
  /** Set for the session bootstrap, which must not bounce an anonymous visitor. */
  allowUnauthenticated?: boolean;
  signal?: AbortSignal;
}

async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const { method = 'GET', body, allowUnauthenticated = false, signal } = options;

  const headers: Record<string, string> = { Accept: 'application/json' };
  if (body !== undefined) {
    headers['Content-Type'] = 'application/json';
  }
  if (method !== 'GET' && csrfToken) {
    // Flask-WTF accepts the token from this header as well as a form field.
    headers['X-CSRFToken'] = csrfToken;
  }

  const response = await fetch(`${API_PREFIX}${path}`, {
    method,
    headers,
    // The BFF authenticates with the Flask session cookie.
    credentials: 'same-origin',
    body: body === undefined ? undefined : JSON.stringify(body),
    signal,
  });

  if (response.status === 401 && !allowUnauthenticated) {
    redirectToLogin();
    throw new ApiError('Your session has expired. Please sign in again.', 401);
  }

  if (!response.ok) {
    throw new ApiError(await readError(response), response.status);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return (await response.json()) as T;
}

export function apiGet<T>(path: string, signal?: AbortSignal) {
  return request<T>(path, { signal });
}

export function apiPost<T>(path: string, body?: unknown) {
  return request<T>(path, { method: 'POST', body });
}

/**
 * Fetch the session bootstrap and cache the CSRF token it carries.
 *
 * Anonymous callers get a normal 200 with `authenticated: false`, because the
 * signed-out landing page has to render without bouncing to Entra ID.
 */
export async function fetchSession(signal?: AbortSignal): Promise<SessionInfo> {
  const session = await request<SessionInfo>('/session', {
    allowUnauthenticated: true,
    signal,
  });
  setCsrfToken(session.csrfToken);
  return session;
}

/** Turn any thrown value into something safe to show the operator. */
export function errorMessage(error: unknown, fallback = 'Something went wrong.'): string {
  if (error instanceof ApiError || error instanceof Error) {
    return error.message || fallback;
  }
  return fallback;
}

/** Build a query string, dropping empty values so unset filters are simply absent. */
export function queryString(params: Record<string, string | number | boolean | undefined>) {
  const search = new URLSearchParams();

  for (const [key, value] of Object.entries(params)) {
    if (value === undefined || value === '' || value === false) {
      continue;
    }
    search.set(key, String(value));
  }

  const encoded = search.toString();
  return encoded ? `?${encoded}` : '';
}
