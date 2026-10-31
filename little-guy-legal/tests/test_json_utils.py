import pytest

from app.inference.json_utils import StructuredOutputError, extract_json_object, parse_model
from app.models.stages import ArgumentOutput


def test_extracts_from_fence_and_think_blocks():
    text = "<think>reasoning...</think>Here you go:\n```json\n{\"a\": 1, \"b\": [1,2,]}\n```"
    assert extract_json_object(text) == {"a": 1, "b": [1, 2]}


def test_extracts_balanced_object_with_prose():
    text = 'Sure. {"position": "customer", "x": "}"} trailing'
    assert extract_json_object(text)["position"] == "customer"


def test_schema_errors_are_reported():
    with pytest.raises(StructuredOutputError) as exc:
        parse_model('{"position": "customer"}', ArgumentOutput)
    assert any("style" in e["loc"] for e in exc.value.errors)
