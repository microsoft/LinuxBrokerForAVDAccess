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