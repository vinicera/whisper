import base64
from dataclasses import replace

import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.llm import FakeProvider
from app.main import create_app
from app.sanitizer import find_forbidden

# PNG 1x1 valido; o FakeProvider nao olha a imagem.
PNG = base64.b64encode(
    bytes.fromhex(
        "89504e470d0a1a0a0000000d4948445200000001000000010806000000"
        "1f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082"
    )
).decode()


def make_client(tmp_path, provider, token="segredo"):
    settings = replace(Settings.from_env(), bridge_token=token, history_db=tmp_path / "h.db",
                       verify_timeout_seconds=30)
    return TestClient(create_app(settings, provider=provider, warm_sympy=False))


def payload(mode="tutor", **opts):
    return {
        "request_id": "req-1",
        "client": {"app_version": "test"},
        "image": {"mime": "image/png", "base64": PNG, "source": "upload"},
        "options": {"mode": mode, **opts},
    }


AUTH = {"Authorization": "Bearer segredo"}


def test_health(tmp_path):
    with make_client(tmp_path, FakeProvider()) as c:
        r = c.get("/v1/health")
        assert r.status_code == 200
        assert r.json()["llm_provider"] == "fake"


def test_auth_required(tmp_path):
    with make_client(tmp_path, FakeProvider()) as c:
        assert c.post("/v1/solve", json=payload()).status_code == 401
        assert c.post("/v1/solve", json=payload(), headers={"Authorization": "Bearer x"}).status_code == 401


def test_solve_ok_tutor(tmp_path):
    with make_client(tmp_path, FakeProvider()) as c:
        r = c.post("/v1/solve", json=payload(), headers=AUTH)
        assert r.status_code == 200, r.text
        body = r.json()
        assert body["status"] == "ok"
        assert body["verification"] == {**body["verification"], "performed": True, "passed": True}
        kinds = [s["kind"] for s in body["speech"]["segments"]]
        assert kinds[0] == "enunciado" and kinds[-1] == "resposta" and "passo" in kinds
        assert find_forbidden(body["speech"]["full_text"]) == []
        assert body["speech"]["full_text"].count("A resposta final é") == 1
        # Historico gravado
        hist = c.get("/v1/history", headers=AUTH).json()
        assert hist[0]["request_id"] == "req-1"


def test_retry_after_failed_verification(tmp_path):
    provider = FakeProvider(wrong_first=True)
    with make_client(tmp_path, provider) as c:
        body = c.post("/v1/solve", json=payload(), headers=AUTH).json()
    assert provider.calls == 2
    assert body["status"] == "ok"
    assert body["debug"]["attempts"] == 2


def test_ditado_mode_only_statement(tmp_path):
    with make_client(tmp_path, FakeProvider()) as c:
        body = c.post("/v1/solve", json=payload(mode="ditado"), headers=AUTH).json()
    assert [s["kind"] for s in body["speech"]["segments"]] == ["enunciado"]
    assert body["verification"]["performed"] is False


def test_unreadable(tmp_path):
    with make_client(tmp_path, FakeProvider(unreadable=True)) as c:
        r = c.post("/v1/solve", json=payload(), headers=AUTH)
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "unreadable"
    assert body["error"]["code"] == "IMAGE_UNREADABLE"
    assert "Aproxime" in body["speech"]["full_text"]


def test_bad_base64(tmp_path):
    p = payload()
    p["image"]["base64"] = "não é base64 !!!!!!!!!!"
    with make_client(tmp_path, FakeProvider()) as c:
        r = c.post("/v1/solve", json=p, headers=AUTH)
    assert r.status_code == 502
    assert r.json()["error"]["code"] == "BAD_IMAGE"


def test_validation_error_is_spoken(tmp_path):
    with make_client(tmp_path, FakeProvider()) as c:
        r = c.post("/v1/solve", json={"oops": 1}, headers=AUTH)
    assert r.status_code == 422
    assert r.json()["speech"]["full_text"]


@pytest.mark.parametrize("mode", ["tutor", "resposta"])
def test_dirty_model_answer_falls_back_to_sympy_speech(tmp_path, mode):
    class Dirty(FakeProvider):
        def analyze(self, *a, **k):
            ans = super().analyze(*a, **k)
            ans.resposta_falada = "{}"  # sobra nada util apos sanitizar
            return ans

    with make_client(tmp_path, Dirty()) as c:
        body = c.post("/v1/solve", json=payload(mode=mode), headers=AUTH).json()
    final = body["speech"]["segments"][-1]["text"]
    assert final.startswith("A resposta final é")
    assert "cosseno de x" in final
