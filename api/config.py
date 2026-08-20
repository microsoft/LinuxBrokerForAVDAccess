import os

# Endpoints that differ per Azure cloud. AzureCustom has no built-in profile, so a
# custom or sovereign cloud must supply every endpoint through its own variable.
_CLOUD_PROFILES = {
    'AzurePublic': {
        'AZURE_AUTHORITY_HOST': 'https://login.microsoftonline.com',
        'GRAPH_ENDPOINT': 'https://graph.microsoft.com',
        'STS_ISSUER_HOST': 'https://sts.windows.net',
    },
    'AzureUSGovernment': {
        'AZURE_AUTHORITY_HOST': 'https://login.microsoftonline.us',
        'GRAPH_ENDPOINT': 'https://graph.microsoft.us',
        'STS_ISSUER_HOST': 'https://sts.windows.net',
    },
}

AZURE_CLOUD_NAME = os.environ.get('AZURE_CLOUD_NAME') or 'AzurePublic'

def resolve_cloud_endpoint(name):
    value = os.environ.get(name)
    if value:
        return value.rstrip('/')

    profile = _CLOUD_PROFILES.get(AZURE_CLOUD_NAME)
    if not profile:
        raise RuntimeError(
            f"AZURE_CLOUD_NAME '{AZURE_CLOUD_NAME}' has no built-in endpoints, so {name} must be set explicitly."
        )

    return profile[name]

AUTHORITY_HOST = resolve_cloud_endpoint('AZURE_AUTHORITY_HOST')
GRAPH_ENDPOINT = resolve_cloud_endpoint('GRAPH_ENDPOINT')
STS_ISSUER_HOST = resolve_cloud_endpoint('STS_ISSUER_HOST')

TENANT_ID = os.environ.get("TENANT_ID")
AUTHORITY = f"{AUTHORITY_HOST}/{TENANT_ID}"
VM_SUBSCRIPTION_ID = os.environ.get("VM_SUBSCRIPTION_ID")
VM_RESOURCE_GROUP = os.environ.get("VM_RESOURCE_GROUP")
CLIENT_ID = os.environ.get("CLIENT_ID")
MICROSOFT_PROVIDER_AUTHENTICATION_SECRET = os.environ.get("MICROSOFT_PROVIDER_AUTHENTICATION_SECRET")
APP_URI = f"api://{CLIENT_ID}"
AVD_HOST_GROUP_ID = os.environ.get('AVD_HOST_GROUP_ID')
LINUX_HOST_GROUP_ID = os.environ.get('LINUX_HOST_GROUP_ID')
LINUX_HOST_ADMIN_LOGIN_NAME = os.environ.get('LINUX_HOST_ADMIN_LOGIN_NAME')
GRAPH_API_ENDPOINT = os.environ.get('GRAPH_API_ENDPOINT') or f"{GRAPH_ENDPOINT}/.default"
DOMAIN_NAME = os.environ.get('DOMAIN_NAME')
VAULT_URL = os.environ.get('VAULT_URL')
KEY_NAME = os.environ.get('KEY_NAME')
DB_SERVER = os.environ.get('DB_SERVER')
DB_DATABASE = os.environ.get('DB_DATABASE')
DB_USERNAME = os.environ.get('DB_USERNAME')
DB_PASSWORD_NAME = os.environ.get('DB_PASSWORD_NAME')
NFS_SHARE = os.environ.get("NFS_SHARE")

db_password = None

# ===============================
# Linux host settings
#
# Bounds for the fleet-wide host settings profile, as (minimum, maximum, default).
# These deliberately duplicate the CHECK constraints in
# sql_queries/028_create_table-linux_host_settings.sql and the clamps in
# linux_host/apply-host-settings.sh. A value that reaches a host controls session
# reclamation, so it is validated at every layer rather than trusted from the one above.
# All three definitions must be kept in agreement.
LINUX_HOST_SETTING_BOUNDS = {
    'GracePeriodSeconds': (60, 86400, 1200),
    'ReconcileIntervalSeconds': (30, 900, 60),
    'WatcherDebounceSeconds': (1, 300, 10),
    'WatcherSettleSeconds': (0, 60, 2),
    'IdleTimeoutSeconds': (0, 86400, 0),
    'IdleWarningSeconds': (0, 900, 120),
    'ScreenIdleDelaySeconds': (0, 86400, 0),
    'ScreenLockDelaySeconds': (0, 86400, 0),
}

LINUX_HOST_SETTING_BOOLEANS = {
    # Defaults disable the lock screen. A locked GNOME greeter inside an xrdp/xpra session
    # frequently cannot be unlocked after a reconnect, which strands the host's lease.
    # DisableLockScreen also removes the Super+L shortcut and the Lock menu entry, so a user
    # cannot lock manually either.
    'ScreenLockEnabled': False,
    'DisableLockScreen': True,
    'ScreenLockSettingsLocked': True,
}

# IdleTimeoutSeconds is the one field where 0 is meaningful rather than out of range: it
# disables idle enforcement entirely. Any non-zero value must clear this floor so a typo
# cannot start disconnecting active users almost immediately.
IDLE_TIMEOUT_MINIMUM_SECONDS = 300