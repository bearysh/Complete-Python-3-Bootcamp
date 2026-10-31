"""Extract and validate JSON objects from model output."""
from __future__ import annotations

import json
import re
from typing import Any, TypeVar

from pydantic import BaseModel, ValidationError

T = TypeVar("T", bound=BaseModel)

FENCE_RE = re.compile(r"```(?:json)?\s*(.*?)```", re.S | re.I)
THINK_RE = re.compile(r"<think>.*?</think>", re.S | re.I)


class StructuredOutputError(ValueError):
    def __init__(self, message: str, errors: list[dict[str, Any]] | None = None):
        super().__init__(message)
        self.errors = errors or []


def extract_json_object(text: str) -> dict[str, Any]:
    text = THINK_RE.sub("", text).strip()
    candidates: list[str] = []
    for m in FENCE_RE.finditer(text):
        candidates.append(m.group(1).strip())
    candidates.append(text)
    start = text.find("{")
    if start != -1:
        candidates.append(_balanced(text, start))
    last_error: Exception | None = None
    for cand in candidates:
        if not cand:
            continue
        try:
            obj = json.loads(cand)
        except json.JSONDecodeError as exc:
            last_error = exc
            # Try common repairs: trailing commas.
            try:
                obj = json.loads(re.sub(r",\s*([}\]])", r"\1", cand))
            except json.JSONDecodeError:
                continue
        if isinstance(obj, dict):
            return obj
    raise StructuredOutputError(f"No JSON object found in model output ({type(last_error).__name__ if last_error else 'empty'}).")


def _balanced(text: str, start: int) -> str:
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    return text[start:]


def parse_model(text: str, schema: type[T]) -> T:
    obj = extract_json_object(text)
    try:
        return schema.model_validate(obj)
    except ValidationError as exc:
        errors = [{"loc": ".".join(str(p) for p in e["loc"]), "msg": e["msg"]} for e in exc.errors()[:25]]
        raise StructuredOutputError("Output did not match the required schema.", errors) from exc
