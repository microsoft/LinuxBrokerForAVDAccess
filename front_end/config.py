import os

CLIENT_ID = os.environ.get('CLIENT_ID')
TENANT_ID = os.environ.get('TENANT_ID')
API_CLIENT_ID = os.environ.get('API_CLIENT_ID')
API_URL = os.environ.get('API_URL')
CLIENT_SECRET = os.environ.get("MICROSOFT_PROVIDER_AUTHENTICATION_SECRET")
AUTHORITY = f"https://login.microsoftonline.com/{TENANT_ID}/"
API_APP_URI = f"api://{API_CLIENT_ID}"
API_SCOPE = [f"{API_APP_URI}/access_as_user"]