"""Portal session storage: the disk store for local runs, Redis for deployments.

Covers the settings, the Redis client with the managed identity stubbed out, the
cookie policy, one instance honouring another's sign-in, the routes that never
touch the store, and what the operator sees when the store is down.
"""

from collections import Counter
from datetime import timedelta

import pytest
import redis
from flask import Flask, jsonify, session
from flask.sessions import SessionInterface
from flask_session.redis import RedisSessionInterface

import session_store
from conftest import API, UI_SESSION_PATH, sign_in

REDIS_ENV = {
    "SESSION_BACKEND": "redis",
    "REDIS_HOST": "portal.eastus.redis.azure.net",
    "REDIS_PORT": "10000",
}

OUTAGE = "Error 111 connecting to portal.eastus.redis.azure.net:10000. Connection refused."


class FakeRedisServer:
    """Answers for every redis.Redis client in a test, so nothing leaves the machine."""

    def __init__(self):
        self.data = {}
        self.sets = []
        self.failing = set()
        self.attempts = Counter()

    def _call(self, operation):
        self.attempts[operation] += 1
        if operation in self.failing:
            raise redis.exceptions.ConnectionError(OUTAGE)

    def install(self, monkeypatch):
        server = self

        def get(client, name):
            server._call("get")
            return server.data.get(name)

        def set_(client, name, value, ex=None, **kwargs):
            server._call("set")
            server.sets.append((name, ex))
            server.data[name] = value
            return True

        def delete(client, *names):
            server._call("delete")
            return sum(server.data.pop(name, None) is not None for name in names)

        monkeypatch.setattr(redis.Redis, "get", get)
        monkeypatch.setattr(redis.Redis, "set", set_)
        monkeypatch.setattr(redis.Redis, "delete", delete)


class UnreachableStore(SessionInterface):
    """A backend that fails the way Redis does when it cannot be reached."""

    def __init__(self):
        self.calls = 0

    def open_session(self, app, request):
        self.calls += 1
        raise redis.exceptions.ConnectionError(OUTAGE)

    def save_session(self, app, session, response):
        self.calls += 1
        raise redis.exceptions.ConnectionError(OUTAGE)


@pytest.fixture
def managed_identity(monkeypatch):
    """Stand in for the managed identity; nothing may ask IMDS for a token in tests."""
    import redis_entraid.cred_provider as cred_provider

    calls = []

    def create_from_managed_identity(**kwargs):
        calls.append(kwargs)
        return redis.credentials.UsernamePasswordCredentialProvider("portal-object-id", "entra-token")

    monkeypatch.setattr(cred_provider, "create_from_managed_identity", create_from_managed_identity)
    return calls


@pytest.fixture
def fake_redis(monkeypatch):
    server = FakeRedisServer()
    server.install(monkeypatch)
    return server


def _answer_like_production(app, monkeypatch):
    # TESTING propagates exceptions into the test; production hands them to the
    # error handlers, which is what these tests are about.
    monkeypatch.setitem(app.config, "PROPAGATE_EXCEPTIONS", False)


@pytest.fixture
def store_down(app, monkeypatch):
    backend = UnreachableStore()
    monkeypatch.setattr(app, "session_interface",
                        session_store.PortalSessionInterface(backend, (redis.exceptions.RedisError,)))
    _answer_like_production(app, monkeypatch)
    return backend


@pytest.fixture
def redis_backed(app, monkeypatch, managed_identity, fake_redis):
    """Run the portal on Flask-Session's real Redis store, talking to the fake server."""
    client = session_store.build_redis_client(session_store.read_settings(REDIS_ENV))
    interface = session_store.PortalSessionInterface(RedisSessionInterface(app, client=client),
                                                     session_store.redis_store_errors())
    monkeypatch.setattr(app, "session_interface", interface)
    _answer_like_production(app, monkeypatch)
    return fake_redis


def make_instance(environ):
    """A bare app with the portal's session setup, standing in for one web app instance."""
    instance = Flask(__name__)
    instance.config.update(SECRET_KEY="test-secret-key", TESTING=True)
    session_store.configure_sessions(instance, environ)

    @instance.route(f"{API}/remember", methods=["POST"])
    def remember():
        session["user"] = {"name": "Test Operator"}
        return jsonify(ok=True)

    @instance.route(f"{API}/recall")
    def recall():
        return jsonify(user=session.get("user"))

    return instance


def session_cookie(response):
    return next(header for header in response.headers.getlist("Set-Cookie")
                if header.startswith("session="))


# ================================================================ settings


def test_local_runs_default_to_the_disk_store():
    settings = session_store.read_settings({})

    assert settings.backend == "filesystem"
    assert settings.lifetime_hours == 12
    assert settings.cookie_secure is True
    assert settings.redis_host is None
    assert settings.redis_port == 10000
    assert settings.redis_entra_resource == "https://redis.azure.com"


def test_redis_settings_come_from_the_environment():
    settings = session_store.read_settings({
        "SESSION_BACKEND": " Redis ",
        "REDIS_HOST": "portal.redis.cache.usgovcloudapi.net",
        "REDIS_PORT": "6380",
        "REDIS_ENTRA_RESOURCE": "acca5fbb-b7e4-4009-81f1-37e38fd66d78",
        "SESSION_LIFETIME_HOURS": "8",
        "SESSION_COOKIE_SECURE": "false",
    })

    assert settings.backend == "redis"
    assert settings.redis_host == "portal.redis.cache.usgovcloudapi.net"
    assert settings.redis_port == 6380
    assert settings.redis_entra_resource == "acca5fbb-b7e4-4009-81f1-37e38fd66d78"
    assert settings.lifetime_hours == 8
    assert settings.cookie_secure is False


@pytest.mark.parametrize("environ, named", [
    ({"SESSION_BACKEND": "memcached"}, "SESSION_BACKEND"),
    ({"SESSION_BACKEND": "redis"}, "REDIS_HOST"),
    ({"SESSION_LIFETIME_HOURS": "0"}, "SESSION_LIFETIME_HOURS"),
    ({"SESSION_LIFETIME_HOURS": "721"}, "SESSION_LIFETIME_HOURS"),
    ({"SESSION_LIFETIME_HOURS": "twelve"}, "SESSION_LIFETIME_HOURS"),
    ({"SESSION_COOKIE_SECURE": "sometimes"}, "SESSION_COOKIE_SECURE"),
    ({**REDIS_ENV, "REDIS_PORT": "70000"}, "REDIS_PORT"),
])
def test_a_bad_setting_stops_the_portal_with_a_message_naming_it(environ, named):
    with pytest.raises(RuntimeError, match=named):
        session_store.read_settings(environ)


@pytest.mark.parametrize("path, expected", [
    ("/api/ui/session", True),
    ("/api/ui/vms/1/start", True),
    ("/api/ui", True),
    ("/login", True),
    ("/getAToken", True),
    ("/logout", True),
    ("/", False),
    ("/vms", False),
    ("/health", False),
    ("/favicon.ico", False),
    ("/static/dist/assets/index.js", False),
    ("/api/uiother", False),
    ("/login/again", False),
])
def test_only_the_api_and_sign_in_routes_use_the_session(path, expected):
    assert session_store.uses_session(path) is expected


# ============================================================ Redis client


def test_the_redis_client_signs_in_as_the_managed_identity_over_tls(managed_identity):
    from redis_entraid.identity_provider import ManagedIdentityType

    settings = session_store.read_settings(
        {**REDIS_ENV, "REDIS_ENTRA_RESOURCE": "acca5fbb-b7e4-4009-81f1-37e38fd66d78"})
    client = session_store.build_redis_client(settings)

    assert managed_identity == [{"identity_type": ManagedIdentityType.SYSTEM_ASSIGNED,
                                 "resource": "acca5fbb-b7e4-4009-81f1-37e38fd66d78"}]

    pool = client.connection_pool
    connection = pool.connection_kwargs
    assert issubclass(pool.connection_class, redis.SSLConnection)
    assert connection["host"] == "portal.eastus.redis.azure.net"
    assert connection["port"] == 10000
    assert connection["protocol"] == 2
    assert connection["credential_provider"].get_credentials() == ("portal-object-id", "entra-token")
    assert connection["socket_connect_timeout"] == 2
    assert connection["socket_timeout"] == 2
    assert client.get_retry().get_retries() == 2


def test_configuring_redis_wraps_flask_sessions_store(managed_identity):
    instance = Flask(__name__)
    instance.config["SECRET_KEY"] = "test-secret-key"

    settings = session_store.configure_sessions(instance, REDIS_ENV)

    interface = instance.session_interface
    assert settings.backend == "redis"
    assert isinstance(interface, session_store.PortalSessionInterface)
    assert isinstance(interface.backend, RedisSessionInterface)
    assert interface.backend.client.connection_pool.connection_kwargs["host"] == REDIS_ENV["REDIS_HOST"]
    assert redis.exceptions.RedisError in interface.store_errors
    assert instance.permanent_session_lifetime == timedelta(hours=12)


def test_the_portal_runs_locally_on_the_wrapped_disk_store(app):
    from flask_session.filesystem import FileSystemSessionInterface

    assert isinstance(app.session_interface, session_store.PortalSessionInterface)
    assert isinstance(app.session_interface.backend, FileSystemSessionInterface)
    assert app.session_interface.store_errors == ()


def test_a_sign_in_on_one_instance_is_honoured_by_another(managed_identity, fake_redis):
    first, second = make_instance(REDIS_ENV).test_client(), make_instance(REDIS_ENV).test_client()

    assert first.post(f"{API}/remember").status_code == 200
    session_id = first.get_cookie("session").value

    second.set_cookie("session", session_id)
    assert second.get(f"{API}/recall").get_json() == {"user": {"name": "Test Operator"}}
    # Redis forgets the session when its cookie would expire.
    assert fake_redis.sets[0] == (f"session:{session_id}", 12 * 3600)


# =========================================================== cookie policy


def test_the_session_cookie_is_secure_http_only_and_same_site_lax(client):
    attributes = [part.strip().lower() for part in session_cookie(client.get(UI_SESSION_PATH)).split(";")]

    assert "secure" in attributes
    assert "httponly" in attributes
    assert "samesite=lax" in attributes
    assert any(attribute.startswith("expires=") for attribute in attributes)


def test_an_idle_session_lasts_twelve_hours_by_default(app):
    assert app.permanent_session_lifetime == timedelta(hours=12)


# ============================================== routes without a session


@pytest.mark.parametrize("path", ["/health", "/", "/vms/1/update", "/favicon.ico",
                                  "/static/dist/index.html"])
def test_routes_that_do_not_use_the_session_work_while_the_store_is_down(client, store_down,
                                                                         spa_bundle, path):
    client.set_cookie("session", "an-existing-session-id")

    response = client.get(path)

    assert response.status_code == 200
    assert store_down.calls == 0
    assert "Set-Cookie" not in response.headers


def test_writing_the_session_on_a_route_that_does_not_load_it_fails_loudly(app):
    with app.test_request_context("/vms"):
        with pytest.raises(RuntimeError, match="/vms does not load the session"):
            session["user"] = {"name": "Test Operator"}


# ========================================================== store outage


def test_an_unreachable_store_answers_503_json_on_the_api(client, store_down):
    client.set_cookie("session", "an-existing-session-id")

    response = client.get(UI_SESSION_PATH)

    assert response.status_code == 503
    assert response.headers["Retry-After"] == "30"
    assert "session store" in response.get_json()["error"]


def test_an_unreachable_store_answers_503_on_the_sign_in_routes(client, store_down):
    response = client.get("/logout")

    assert response.status_code == 503
    assert response.mimetype == "text/plain"
    assert "session store" in response.get_data(as_text=True)


def test_a_signed_in_session_is_read_back_from_redis(client, redis_backed):
    sign_in(client)

    assert client.get(f"{API}/vms").status_code == 200
    assert [key for key in redis_backed.data if key.startswith("session:")]


def test_a_failed_read_from_redis_answers_503(client, redis_backed):
    sign_in(client)
    redis_backed.failing = {"get", "set"}

    response = client.get(f"{API}/vms")

    assert response.status_code == 503
    assert "session store" in response.get_json()["error"]


def test_an_outage_is_logged_with_its_cause_where_application_insights_collects_it(
        client, redis_backed, caplog):
    sign_in(client)
    redis_backed.failing = {"get", "set"}

    with caplog.at_level("ERROR", logger="linuxbroker.frontend"):
        client.get(f"{API}/vms")

    # Flask logs the traceback too, but under its own logger, which is not exported.
    exported = [record.getMessage() for record in caplog.records
                if record.name.startswith("linuxbroker.frontend")]
    assert exported == [f"The session store could not be reached (ConnectionError: {OUTAGE})."]


def test_a_failed_save_of_a_changed_session_answers_503_once(client, redis_backed):
    # With no cookie yet, the first store call is saving the new CSRF token.
    redis_backed.failing = {"set"}

    response = client.get(UI_SESSION_PATH)

    assert response.status_code == 503
    # Finalizing the error response must not wait on the store a second time.
    assert redis_backed.attempts["set"] == 1


def test_losing_only_the_expiry_refresh_keeps_the_views_answer(client, redis_backed, caplog):
    sign_in(client)
    redis_backed.failing = {"set"}

    with caplog.at_level("WARNING", logger="linuxbroker.frontend.sessions"):
        response = client.get(f"{API}/vms")

    assert response.status_code == 200
    assert "expiry" in caplog.text
