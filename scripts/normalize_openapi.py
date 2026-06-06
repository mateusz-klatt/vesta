#!/usr/bin/env python3
"""Normalize a pydantic-emitted OpenAPI 3.1 document for swift-openapi-generator.

Pydantic encodes `Optional[T]` as `anyOf: [{...T...}, {"type": "null"}]`. The Swift
generator drops properties shaped that way (it does not treat anyOf-null as a
nullable), so e.g. WhoAmI/DeviceInfo come out missing every optional field.

This rewrites that pattern into the canonical OpenAPI 3.1 nullable the generator
understands:
  - scalar/array/object branch -> merge it up and set `type: [<t>, "null"]`
  - `$ref` branch              -> the bare `$ref`, and drop the property from the
                                  enclosing `required` so it generates as optional

Usage: normalize_openapi.py <in.json> <out.json>
"""
import json
import sys


def _is_null(s):
    return isinstance(s, dict) and s.get("type") == "null"


def _collapse(schema):
    """Return (new_schema, was_nullable) for an anyOf-null property schema."""
    ao = schema.get("anyOf")
    if not isinstance(ao, list) or not any(_is_null(x) for x in ao):
        return schema, False
    rest = [x for x in ao if not _is_null(x)]
    if len(rest) != 1:
        return schema, False
    branch = rest[0]
    carried = {k: v for k, v in schema.items() if k not in ("anyOf",)}
    if "$ref" in branch:
        # nullable $ref -> bare ref (optionality comes from `required` removal)
        return {"$ref": branch["$ref"]}, True
    if "type" in branch:
        merged = dict(branch)
        merged.update({k: v for k, v in carried.items() if k not in merged})
        t = branch["type"]
        merged["type"] = ([t, "null"] if isinstance(t, str) else list(dict.fromkeys(list(t) + ["null"])))
        return merged, True
    return schema, False


def transform(node):
    if isinstance(node, dict):
        props = node.get("properties")
        if isinstance(props, dict):
            required = list(node.get("required", []))
            for name, pschema in list(props.items()):
                new, nullable = _collapse(pschema)
                if nullable:
                    props[name] = new
                    if name in required:
                        required.remove(name)
            if "required" in node:
                if required:
                    node["required"] = required
                else:
                    del node["required"]
        # also collapse any stray anyOf-null not sitting under properties (scalars only)
        if "anyOf" in node:
            new, nullable = _collapse(node)
            if nullable and "$ref" not in new:
                node.clear()
                node.update(new)
        for v in node.values():
            transform(v)
    elif isinstance(node, list):
        for v in node:
            transform(v)


def main():
    src, dst = sys.argv[1], sys.argv[2]
    doc = json.load(open(src))
    transform(doc)
    with open(dst, "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    print(f"normalized {src} -> {dst}")


if __name__ == "__main__":
    main()
