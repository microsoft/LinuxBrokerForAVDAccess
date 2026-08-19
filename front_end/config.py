import os

# Endpoints that differ per Azure cloud. AzureCustom has no built-in profile, so a
# custom or sovereign cloud must supply every endpoint through its own variable.
_CLOUD_PROFILES = {
    'AzurePublic': {
        'AZURE_AUTHORITY_HOST': 'https://login.microsoftonline.com',
    },
    'AzureUSGovernment': {
        'AZURE_AUTHORITY_HOST': 'https://login.microsoftonline.us',
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

CLIENT_ID = os.environ.get('CLIENT_ID')
TENANT_ID = os.environ.get('TENANT_ID')
API_CLIENT_ID = os.environ.get('API_CLIENT_ID')
API_URL = os.environ.get('API_URL')
CLIENT_SECRET = os.environ.get("MICROSOFT_PROVIDER_AUTHENTICATION_SECRET")
AUTHORITY = f"{AUTHORITY_HOST}/{TENANT_ID}/"
API_APP_URI = f"api://{API_CLIENT_ID}"
API_SCOPE = [f"{API_APP_URI}/access_as_user"]