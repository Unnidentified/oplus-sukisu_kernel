#!/usr/bin/env python3
"""Validate every build profile under configs/.

Two layers:

1. Schema - configs/schema.json, checked with a small built-in validator so this
   script has no third-party dependencies and cannot break because a runner
   image changed.
2. Cross-file invariants that a per-file schema cannot express:
   - model is unique within one OS directory (the same device legitimately
     appears under a14/a15/a16, but two profiles in the same directory sharing
     a model produce the same zip name and one silently overwrites the other)
   - the file stem matches model (the matrix and the zip name both use model)
   - the referenced manifest exists
   - the containing directory matches os_version
   - a profile is not both blocked and tested (a blocked profile cannot have
     been flashed)
   - the README's known-unbuildable table lists exactly the blocked profiles,
     so the prose cannot drift away from the configs

Exit code 0 when everything passes, 1 otherwise.
"""

from __future__ import annotations

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIGS = os.path.join(ROOT, "configs")
SCHEMA = os.path.join(CONFIGS, "schema.json")
README = os.path.join(ROOT, "README.md")
BLOCKED_HEADING = "### Known-unbuildable profiles"

TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
    "number": (int, float),
    "integer": int,
}


def check_type(value, expected):
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    py = TYPES.get(expected)
    return py is not None and isinstance(value, py)


def validate(value, schema, path, errors):
    """Validate against the JSON Schema subset used by configs/schema.json."""
    expected = schema.get("type")
    if expected and not check_type(value, expected):
        errors.append(f"{path}: expected {expected}, got {type(value).__name__}")
        return

    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} not in {schema['enum']}")

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{path}: shorter than {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            errors.append(f"{path}: longer than {schema['maxLength']} ({len(value)})")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append(f"{path}: {value!r} does not match {schema['pattern']}")

    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required key {key!r}")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    errors.append(f"{path}: unknown key {key!r}")
        for key, sub in props.items():
            if key in value:
                validate(value[key], sub, f"{path}.{key}", errors)


def readme_blocked_configs() -> set[str] | None:
    """Config paths listed in the README's known-unbuildable section.

    Returns None when the section is missing, so a rename of the heading is
    reported instead of silently disabling the cross-check.
    """
    try:
        with open(README, encoding="utf-8") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return None

    try:
        start = lines.index(BLOCKED_HEADING)
    except ValueError:
        return None

    paths: set[str] = set()
    for line in lines[start + 1:]:
        if line.startswith("## ") or line.startswith("### ") or line.strip() == "---":
            break
        for token in re.findall(r"`([^`]+)`", line):
            if token.startswith("configs/") and token.endswith(".json"):
                paths.add(token)
    return paths


def main() -> int:
    with open(SCHEMA, encoding="utf-8") as fh:
        schema = json.load(fh)

    errors: list[str] = []
    seen_models: dict[tuple[str, str], str] = {}
    blocked_configs: set[str] = set()
    tested_models: set[str] = set()
    checked = 0

    for dirpath, _dirnames, filenames in os.walk(CONFIGS):
        for name in sorted(filenames):
            if not name.endswith(".json") or name == "schema.json":
                continue
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, ROOT)
            checked += 1

            try:
                with open(full, encoding="utf-8") as fh:
                    cfg = json.load(fh)
            except json.JSONDecodeError as exc:
                errors.append(f"{rel}: invalid JSON: {exc}")
                continue

            validate(cfg, schema, rel, errors)
            if not isinstance(cfg, dict):
                continue

            model = cfg.get("model")
            stem = name[: -len(".json")]
            if isinstance(model, str):
                if stem != model:
                    errors.append(f"{rel}: file stem {stem!r} != model {model!r}")
                scope = (os.path.basename(dirpath), model)
                if scope in seen_models:
                    errors.append(
                        f"{rel}: duplicate model {model!r} in "
                        f"{scope[0]}/ (also {seen_models[scope]})"
                    )
                else:
                    seen_models[scope] = rel

            manifest = cfg.get("manifest")
            if isinstance(manifest, str):
                candidate = os.path.join(dirpath, "..", "..", "manifests",
                                         os.path.basename(dirpath), manifest)
                if not os.path.exists(os.path.normpath(candidate)):
                    errors.append(f"{rel}: manifest {manifest!r} not found")

            os_version = cfg.get("os_version")
            if isinstance(os_version, str):
                if os.path.basename(dirpath) != os_version.lower():
                    errors.append(
                        f"{rel}: directory {os.path.basename(dirpath)!r} != "
                        f"os_version {os_version!r}"
                    )

            blocked = cfg.get("blocked")
            tested = cfg.get("tested")
            if isinstance(blocked, str) and isinstance(tested, str):
                errors.append(
                    f"{rel}: both 'blocked' and 'tested' are set. A profile that "
                    f"cannot be built cannot have been flashed."
                )
            # Both fields are rendered into markdown table cells: the build
            # summary for 'blocked', the release notes for 'tested'. A pipe
            # would split the row, and a newline would break the table.
            for field, value in (("blocked", blocked), ("tested", tested)):
                if isinstance(value, str) and "|" in value:
                    errors.append(f"{rel}: {field!r} must not contain '|'")
                if isinstance(value, str) and "\n" in value:
                    errors.append(f"{rel}: {field!r} must be a single line")
            if isinstance(blocked, str):
                blocked_configs.add(rel)
            if isinstance(tested, str) and isinstance(model, str):
                tested_models.add(model)

    documented = readme_blocked_configs()
    if documented is None:
        errors.append(
            f"README.md: no '{BLOCKED_HEADING}' section, so the blocked profiles "
            f"cannot be cross-checked against the prose"
        )
    else:
        for path in sorted(blocked_configs - documented):
            errors.append(
                f"README.md: {path!r} is blocked in its config but missing from "
                f"the known-unbuildable list"
            )
        for path in sorted(documented - blocked_configs):
            errors.append(
                f"README.md: {path!r} is listed as unbuildable but its config has "
                f"no 'blocked' field"
            )

    if errors:
        print(f"config validation failed ({len(errors)} problem(s)):", file=sys.stderr)
        for err in errors:
            print(f"  {err}", file=sys.stderr)
        return 1

    print(f"config validation passed ({checked} profiles)")
    if blocked_configs:
        print(f"  blocked: {len(blocked_configs)} profile(s)")
    if tested_models:
        print(f"  tested on hardware: {', '.join(sorted(tested_models))}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
