"""Server-side sessions for the portal.

A session holds the operator's access token, so it stays on the server and the
browser only carries an opaque id. One instance can keep sessions on local disk,
but two or more cannot: a sign-in completed on one instance would be unknown to
the next. Deployments therefore keep them in Redis, reached over a private
endpoint and authenticated with the web app's managed identity. Local runs and
tests keep the disk store.

Only the routes that use the session load it. The page shell, static assets and
the health probe never touch the store, so they keep working while it is down and
the portal can explain the outage instead of failing to load.
"""

import logging
import os
from dataclasses import dataclass
from datetime import timedelta
from typing import Optional

from flask import g, has_request_context, request
from flask.sessions import NullSession, SessionInterface
from flask_session import Session

from function_bff import API_PREFIX

# A child of the logger app.py sends to Application Insights.
logger = logging.getLogger('linuxbroker.frontend.sessions')

BACKEND_FILESYSTEM = 'filesystem'
BACKEND_REDIS = 'redis'
BACKENDS = (BACKEND_FILESYSTEM, BACKEND_REDIS)

DEFAULT_LIFETIME_HOURS = 12
MAX_LIFETIME_HOURS = 720
# Azure Managed Redis listens on 10000. Azure Cache for Redis uses 6380.
DEFAULT_REDIS_PORT = 10000
# The Entra resource Redis tokens are issued for. If a cloud rejects it, set
# REDIS_ENTRA_RESOURCE to the application ID acca5fbb-b7e4-4009-81f1-37e38fd66d78.
DEFAULT_REDIS_ENTRA_RESOURCE = 'https://redis.azure.com'

# The routes outside the JSON API that read or write the session.
SESSION_ROUTES = frozenset({'/login', '/getAToken', '/logout'})

_STORE_FAILED = '_session_store_failed'


def uses_session(path):
    return path in SESSION_ROUTES or path == API_PREFIX or path.startswith(API_PREFIX + '/')


class SessionStoreUnavailable(Exception):
    """The session store could not be reached. The portal answers 503."""


class SessionNotUsedHere(NullSession):
    """Stands in for the session on routes that never use it.

    Reads find nothing. Writes raise and name the route, rather than being
    silently dropped, so a new route that needs a session fails in tests.
    """

    def _refuse(self, *args, **kwargs):
        path = request.path if has_request_context() else 'This route'
        raise RuntimeError(
            f"{path} does not load the session. Add it to session_store.SESSION_ROUTES "
            "if it needs one."
        )

    __setitem__ = __delitem__ = clear = pop = popitem = update = setdefault = _refuse


class PortalSessionInterface(SessionInterface):
    """Wraps the storage backend with the route rule and outage handling."""

    null_session_class = SessionNotUsedHere

    def __init__(self, backend, store_errors=()):
        self.backend = backend
        self.store_errors = tuple(store_errors)

    def open_session(self, app, request):
        if not uses_session(request.path):
            return self.make_null_session(app)
        try:
            return self.backend.open_session(app, request)
        except self.store_errors as error:
            raise _unavailable(error) from error

    def save_session(self, app, session, response):
        # There is no session when opening it failed. After a failed save, Flask
        # saves again while finalizing the error response; that attempt is skipped
        # rather than waiting on the store a second time.
        if session is None or g.get(_STORE_FAILED):
            return
        try:
            self.backend.save_session(app, session, response)
        except self.store_errors as error:
            if not session.modified:
                # Only the expiry refresh was lost. The view has already acted, so
                # its response stands rather than reporting a failure.
                logger.warning("Could not refresh the session's expiry in the session store: %s", error)
                return
            raise _unavailable(error) from error


def _unavailable(error):
    setattr(g, _STORE_FAILED, True)
    return SessionStoreUnavailable(
        f"The session store could not be reached ({type(error).__name__}: {error})."
    )


@dataclass(frozen=True)
class SessionSettings:
    backend: str
    lifetime_hours: int
    cookie_secure: bool
    redis_host: Optional[str]
    redis_port: int
    redis_entra_resource: str


def _text(environ, name):
    return (environ.get(name) or '').strip()


def _whole_number(environ, name, default, minimum, maximum):
    raw = _text(environ, name)
    if not raw:
        return default
    try:
        value = int(raw)
    except ValueError:
        value = None
    if value is None or not minimum <= value <= maximum:
        raise RuntimeError(f"{name} must be a whole number from {minimum} to {maximum}, not '{raw}'.")
    return value


def _flag(environ, name, default):
    raw = _text(environ, name).lower()
    if not raw:
        return default
    if raw in ('1', 'true', 'yes', 'on'):
        return True
    if raw in ('0', 'false', 'no', 'off'):
        return False
    raise RuntimeError(f"{name} must be true or false, not '{raw}'.")


def read_settings(environ=None):
    environ = os.environ if environ is None else environ

    backend = _text(environ, 'SESSION_BACKEND').lower() or BACKEND_FILESYSTEM
    if backend not in BACKENDS:
        raise RuntimeError(f"SESSION_BACKEND must be 'filesystem' or 'redis', not '{backend}'.")

    settings = SessionSettings(
        backend=backend,
        lifetime_hours=_whole_number(environ, 'SESSION_LIFETIME_HOURS', DEFAULT_LIFETIME_HOURS,
                                     1, MAX_LIFETIME_HOURS),
        # Browsers accept Secure cookies from http://localhost, so this only needs
        # turning off when the portal is reached over plain HTTP by another name.
        cookie_secure=_flag(environ, 'SESSION_COOKIE_SECURE', True),
        redis_host=_text(environ, 'REDIS_HOST') or None,
        redis_port=_whole_number(environ, 'REDIS_PORT', DEFAULT_REDIS_PORT, 1, 65535),
        redis_entra_resource=_text(environ, 'REDIS_ENTRA_RESOURCE') or DEFAULT_REDIS_ENTRA_RESOURCE,
    )

    if settings.backend == BACKEND_REDIS and not settings.redis_host:
        raise RuntimeError("SESSION_BACKEND is 'redis' but REDIS_HOST is not set.")

    return settings


def build_redis_client(settings):
    """A Redis client that signs in as the web app's system-assigned managed identity."""
    # Imported here so the disk store, used by local runs and tests, does not load them.
    import redis
    from redis.backoff import ExponentialWithJitterBackoff
    from redis.retry import Retry
    from redis_entraid.cred_provider import create_from_managed_identity
    from redis_entraid.identity_provider import ManagedIdentityType

    credentials = create_from_managed_identity(
        identity_type=ManagedIdentityType.SYSTEM_ASSIGNED,
        resource=settings.redis_entra_resource,
    )

    return redis.Redis(
        host=settings.redis_host,
        port=settings.redis_port,
        ssl=True,
        credential_provider=credentials,
        # RESP2 signs in with a plain AUTH, which Azure Managed Redis and Azure
        # Cache for Redis both accept. It also keeps redis-py's maintenance
        # notifications off; they can move a client to an address the private
        # endpoint does not serve.
        protocol=2,
        # Fail within seconds when the store is down, so the operator gets a 503
        # rather than a page that hangs.
        socket_connect_timeout=2,
        socket_timeout=2,
        socket_keepalive=True,
        health_check_interval=60,
        retry=Retry(ExponentialWithJitterBackoff(base=0.05, cap=0.5), 2),
    )


def redis_store_errors():
    from redis.auth.err import InvalidTokenSchemaErr, RequestTokenErr, TokenRenewalErr
    from redis.exceptions import RedisError

    # Token failures are not RedisErrors, but they leave the store just as unreachable.
    return (RedisError, RequestTokenErr, TokenRenewalErr, InvalidTokenSchemaErr)


def configure_sessions(app, environ=None):
    """Apply the cookie policy and attach the session store the environment names."""
    settings = read_settings(environ)

    app.config.update(
        SESSION_TYPE=settings.backend,
        SESSION_PERMANENT=True,
        # Each request that loads the session pushes its expiry out again, so this
        # is how long the portal remembers an idle operator. Redis drops the entry
        # at the same moment.
        PERMANENT_SESSION_LIFETIME=timedelta(hours=settings.lifetime_hours),
        SESSION_REFRESH_EACH_REQUEST=True,
        SESSION_COOKIE_SECURE=settings.cookie_secure,
        SESSION_COOKIE_HTTPONLY=True,
        # Lax still sends the cookie on the top-level redirect back from Entra ID.
        SESSION_COOKIE_SAMESITE='Lax',
    )

    store_errors = ()
    if settings.backend == BACKEND_REDIS:
        app.config['SESSION_REDIS'] = build_redis_client(settings)
        store_errors = redis_store_errors()

    Session(app)
    app.session_interface = PortalSessionInterface(app.session_interface, store_errors)
    return settings
