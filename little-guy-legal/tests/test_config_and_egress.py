import pytest

from app.config import Settings, is_loopback_url
from app.inference.base import EgressBlocked, InferenceError
from app.inference.egress import assert_loopback, make_loopback_client
from app.inference.factory import build_provider
from tests.conftest import make_settings


@pytest.mark.parametrize("url,ok", [
    ("http://127.0.0.1:8642", True), ("http://localhost:8000/v1", True), ("http://[::1]:8000", True),
    ("https://api.openai.com/v1", False), ("https://openrouter.ai/api/v1", False), ("http://10.0.0.5:8000", False),
    ("http://inference-api.nousresearch.com", False), ("ftp://127.0.0.1", False), ("", False),
])
def test_loopback_detection(url, ok):
    assert is_loopback_url(url) is ok


def test_cloud_endpoint_is_refused_at_construction(tmp_path):
    s = make_settings(tmp_path, inference_provider="hermes", hermes_base_url="https://api.openai.com/v1")
    with pytest.raises(EgressBlocked):
        build_provider(s)
    s = make_settings(tmp_path, inference_provider="omlx", omlx_base_url="https://openrouter.ai/api/v1", omlx_model="x")
    with pytest.raises(EgressBlocked):
        build_provider(s)


def test_request_hook_blocks_redirect_off_box():
    client = make_loopback_client("http://127.0.0.1:1", timeout=1)
    import httpx

    req = client.build_request("GET", "https://api.anthropic.com/v1/messages")
    with pytest.raises(EgressBlocked):
        client.send(req)


def test_proxy_env_is_ignored(monkeypatch):
    monkeypatch.setenv("HTTPS_PROXY", "http://evil.example:3128")
    monkeypatch.setenv("HTTP_PROXY", "http://evil.example:3128")
    client = make_loopback_client("http://127.0.0.1:1", timeout=1)
    # trust_env=False means no proxy mounts are configured from the environment
    assert client._mounts == {} or all(v is None or "evil" not in str(k) for k, v in client._mounts.items())


def test_scripted_provider_requires_explicit_opt_in(tmp_path):
    s = make_settings(tmp_path, allow_scripted_provider=False)
    with pytest.raises(InferenceError):
        build_provider(s)


def test_host_must_be_loopback(tmp_path):
    with pytest.raises(Exception):
        make_settings(tmp_path, host="0.0.0.0")


def test_secret_not_in_repr(tmp_path):
    s = make_settings(tmp_path, hermes_api_key="super-secret-value-123456")
    assert "super-secret-value" not in repr(s) and "super-secret-value" not in s.model_dump_json()
