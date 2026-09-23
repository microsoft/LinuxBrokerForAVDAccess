"""Verified Entra principals. Scopes, user roles and application roles are not interchangeable."""

from dataclasses import dataclass
from enum import Enum
import uuid

import jwt
import requests

import config


class AuthenticationError(Exception):
    pass


class AuthenticationUnavailable(Exception):
    pass


class PrincipalKind(Enum):
    USER = "user"
    WORKLOAD = "workload"


class Policy(Enum):
    CAPABILITIES = "capabilities"
    MANAGE = "manage"
    CONNECT = "connect"
    INVENTORY = "inventory"
    MAINTENANCE = "maintenance"
    HOST_SETTINGS = "host_settings"
    HOST = "host"


@dataclass(frozen=True)
class Principal:
    tenant_id: str
    object_id: str
    client_id: str
    kind: PrincipalKind
    scopes: frozenset[str]
    roles: frozenset[str]

    @property
    def can_manage(self) -> bool:
        return (
            self.kind is PrincipalKind.USER
            and self.client_id == config.PORTAL_CLIENT_ID
            and "access_as_user" in self.scopes
            and "FullAccess" in self.roles
        )

    @property
    def can_connect(self) -> bool:
        return (
            self.kind is PrincipalKind.USER
            and self.client_id == config.BROKER_LAUNCHER_CLIENT_ID
            and "connect_as_user" in self.scopes
            and "WorkspaceUser" in self.roles
        )

    def is_workload(self, role: str) -> bool:
        return self.kind is PrincipalKind.WORKLOAD and role in self.roles

    def allows(self, policy: Policy) -> bool:
        if policy is Policy.CAPABILITIES:
            return self.kind is PrincipalKind.USER and self.client_id in {
                config.PORTAL_CLIENT_ID, config.BROKER_LAUNCHER_CLIENT_ID,
            }
        if policy is Policy.MANAGE:
            return self.can_manage
        if policy is Policy.CONNECT:
            return self.can_connect
        if policy in (Policy.INVENTORY, Policy.MAINTENANCE):
            return self.can_manage or self.is_workload("ScheduledTask")
        if policy is Policy.HOST_SETTINGS:
            return self.can_manage or self.is_workload("LinuxHost")
        if policy is Policy.HOST:
            return self.is_workload("LinuxHost")
        return False


def claim_uuid(value) -> str:
    if not isinstance(value, str):
        raise AuthenticationError("Identity claims must be UUID strings.")
    try:
        parsed = uuid.UUID(value)
    except ValueError as exc:
        raise AuthenticationError("Invalid identity claim.") from exc
    if parsed.int == 0 or str(parsed) != value.lower():
        raise AuthenticationError("Invalid identity claim.")
    return str(parsed)


def _principal(payload: dict) -> Principal:
    tenant = claim_uuid(payload.get("tid"))
    if tenant != config.TENANT_ID:
        raise AuthenticationError("Unexpected tenant.")
    object_id = claim_uuid(payload.get("oid"))
    if not isinstance(payload.get("sub"), str) or not payload["sub"].strip():
        raise AuthenticationError("Invalid subject.")
    if not isinstance(payload.get("aud"), str) or not isinstance(payload.get("iss"), str):
        raise AuthenticationError("Invalid audience or issuer type.")
    for name in ("iat", "nbf", "exp"):
        if type(payload.get(name)) is not int:
            raise AuthenticationError("Invalid token lifetime.")
    if payload["exp"] <= max(payload["iat"], payload["nbf"]):
        raise AuthenticationError("Invalid token lifetime.")

    version = payload.get("ver")
    if version not in ("1.0", "2.0"):
        raise AuthenticationError("Unsupported token version.")
    client_id = claim_uuid(payload.get("azp" if version == "2.0" else "appid"))
    for name in ("appid", "azp"):
        if name in payload and claim_uuid(payload[name]) != client_id:
            raise AuthenticationError("Conflicting client claims.")

    roles = payload.get("roles", [])
    if not isinstance(roles, list) or any(not isinstance(role, str) or not role.strip() for role in roles):
        raise AuthenticationError("Invalid role claims.")
    identity_type = payload.get("idtyp")
    if "scp" in payload:
        scopes = payload["scp"]
        if not isinstance(scopes, str) or not scopes.strip() or identity_type not in (None, "user"):
            raise AuthenticationError("Invalid delegated principal.")
        kind = PrincipalKind.USER
        scopes = frozenset(scopes.split())
    else:
        # An unscoped user token must never become a workload just because it has roles.
        if identity_type != "app":
            raise AuthenticationError("An application principal requires idtyp=app.")
        kind = PrincipalKind.WORKLOAD
        scopes = frozenset()
    return Principal(tenant, object_id, client_id, kind, scopes, frozenset(roles))


def authenticate(authorization_header: str | None) -> Principal:
    parts = (authorization_header or "").split()
    if len(parts) != 2 or parts[0].lower() != "bearer":
        raise AuthenticationError("A bearer token is required.")
    token = parts[1]
    try:
        claim_uuid(config.TENANT_ID)
        claim_uuid(config.CLIENT_ID)
    except AuthenticationError as exc:
        raise AuthenticationUnavailable("Broker authentication is not configured.") from exc

    try:
        header = jwt.get_unverified_header(token)
    except (jwt.InvalidTokenError, ValueError) as exc:
        raise AuthenticationError("Invalid token header.") from exc
    if header.get("alg") != "RS256" or not isinstance(header.get("kid"), str) or not header["kid"]:
        raise AuthenticationError("Invalid signing algorithm or key identifier.")

    try:
        response = requests.get(
            f"{config.AUTHORITY_HOST}/{config.TENANT_ID}/discovery/v2.0/keys", timeout=10,
        )
        response.raise_for_status()
        document = response.json()
    except requests.RequestException as exc:
        raise AuthenticationUnavailable("Signing keys are unavailable.") from exc
    except ValueError as exc:
        raise AuthenticationUnavailable("Invalid signing key document.") from exc

    if not isinstance(document, dict) or not isinstance(document.get("keys"), list):
        raise AuthenticationUnavailable("Invalid signing key document.")
    keys = [
        key for key in document["keys"]
        if isinstance(key, dict) and key.get("kid") == header["kid"]
        and key.get("kty") == "RSA" and key.get("use") == "sig"
        and key.get("alg", "RS256") == "RS256"
    ]
    if len(keys) != 1:
        raise AuthenticationError("Unknown signing key.")
    try:
        signing_key = jwt.algorithms.RSAAlgorithm.from_jwk(keys[0])
    except (jwt.InvalidKeyError, ValueError, TypeError, KeyError) as exc:
        raise AuthenticationUnavailable("Invalid signing key document.") from exc
    try:
        payload = jwt.decode(
            token,
            key=signing_key,
            algorithms=["RS256"],
            audience=[config.CLIENT_ID, config.APP_URI],
            issuer=[
                f"{config.AUTHORITY_HOST}/{config.TENANT_ID}/v2.0",
                f"{config.AUTHORITY_HOST}/{config.TENANT_ID}/",
                f"{config.STS_ISSUER_HOST}/{config.TENANT_ID}/",
            ],
            options={"require": ["exp", "nbf", "iat", "iss", "aud", "sub", "tid", "oid", "ver"]},
        )
        return _principal(payload)
    except (jwt.InvalidTokenError, ValueError, TypeError, KeyError) as exc:
        raise AuthenticationError("Invalid token.") from exc
