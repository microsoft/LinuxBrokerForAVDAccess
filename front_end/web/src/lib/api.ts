import type { SessionInfo } from '../types/broker';

const API_PREFIX = '/api/ui';

/** A non-2xx response from the BFF, carrying the message it chose to surface. */
export class ApiError extends Error {
  readonly status: number;
  readonly code?: string;

  constructor(message: string, status: number, code?: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
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

export function isAuthorizationError(error: unknown): error is ApiError {
  return error instanceof ApiError && (
    error.status === 401 || error.status === 403
    || (error.status === 503 && error.code === 'authorization_unavailable')
  );
}

async function readError(response: Response): Promise<ApiError> {
  try {
    const payload = await response.json();
    if (payload && typeof payload.error === 'string') {
      return new ApiError(
        payload.error,
        response.status,
        typeof payload.code === 'string' ? payload.code : undefined,
      );
    }
  } catch {
    /* A proxy or crash can return HTML; fall through to the generic message. */
  }
  return new ApiError(`The request failed (HTTP ${response.status}).`, response.status);
}

interface RequestOptions {
  method?: 'GET' | 'POST';
  body?: unknown;
  signal?: AbortSignal;
}

async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const { method = 'GET', body, signal } = options;

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
    cache: 'no-store',
    body: body === undefined ? undefined : JSON.stringify(body),
    signal,
  });

  if (!response.ok) {
    throw await readError(response);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  const payload: T = await response.json();
  signal?.throwIfAborted();
  return payload;
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
  const session = await request<unknown>('/session', { signal });
  if (!isSessionInfo(session)) {
    throw new ApiError(
      'Administrator access could not be verified. Please try again later.',
      503,
      'authorization_unavailable',
    );
  }
  setCsrfToken(session.csrfToken);
  return session;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null;
}

function isSessionInfo(value: unknown): value is SessionInfo {
  if (!isRecord(value) || typeof value.authenticated !== 'boolean'
      || typeof value.version !== 'string' || typeof value.csrfToken !== 'string'
      || !value.csrfToken || !isRecord(value.capabilities)
      || typeof value.capabilities.manage !== 'boolean'
      || typeof value.capabilities.connect !== 'boolean') {
    return false;
  }
  if (!value.authenticated) {
    return value.subject === null && value.user === null
      && !value.capabilities.manage && !value.capabilities.connect;
  }
  const { subject, user } = value;
  return isRecord(subject) && typeof subject.tenantId === 'string' && !!subject.tenantId.trim()
    && typeof subject.objectId === 'string' && !!subject.objectId.trim()
    && isRecord(user) && user.tenantId === subject.tenantId && user.objectId === subject.objectId
    && (user.name === null || typeof user.name === 'string')
    && (user.username === null || typeof user.username === 'string');
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
