import os
import sys
import types
from pathlib import Path


TASK_ROOT = Path(__file__).resolve().parents[1]
if str(TASK_ROOT) not in sys.path:
    sys.path.insert(0, str(TASK_ROOT))

os.environ.setdefault("API_URL", "https://broker.example/api")
os.environ.setdefault("API_CLIENT_ID", "fake-client-id")


azure_module = types.ModuleType("azure")
functions_module = types.ModuleType("azure.functions")
identity_module = types.ModuleType("azure.identity")


class FunctionApp:
    def function_name(self, **_kwargs):
        def decorator(function):
            return function

        return decorator

    def timer_trigger(self, **_kwargs):
        def decorator(function):
            return function

        return decorator


class TimerRequest:
    def __init__(self, past_due=False):
        self.past_due = past_due


class FakeToken:
    token = "fake-token"


class ManagedIdentityCredential:
    def get_token(self, *_args, **_kwargs):
        return FakeToken()


functions_module.FunctionApp = FunctionApp
functions_module.TimerRequest = TimerRequest
identity_module.ManagedIdentityCredential = ManagedIdentityCredential
azure_module.functions = functions_module
azure_module.identity = identity_module

sys.modules["azure"] = azure_module
sys.modules["azure.functions"] = functions_module
sys.modules["azure.identity"] = identity_module
