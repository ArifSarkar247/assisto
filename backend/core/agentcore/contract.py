"""Versioned tool contract + a small, strict JSON-Schema validator.

A tool declares name@version, labels, input/output schema, risk, credits,
rate limit, owning feature flag, topics and which output fields can carry
PII. The validator supports the subset the registry uses (object with
properties/required/additionalProperties=false, string with maxLength/enum/
pattern-free, integer/number with minimum/maximum, boolean, array with items/
maxItems, nullable via a type list) — enough to reject every malformed plan.
"""
from dataclasses import dataclass, field

RISKS = ("read", "write_low", "external", "money", "delete")
# risk levels that ALWAYS need a one-tap approval, whatever the autonomy level
APPROVAL_RISKS = ("external", "money", "delete")


class ToolError(Exception):
    """A tool failed in an expected way (code is stable, shown in audit)."""
    def __init__(self, code, detail=""):
        self.code = code
        self.detail = (detail or "")[:200]
        super().__init__(code)


class SchemaError(ValueError):
    pass


@dataclass(frozen=True)
class Tool:
    name: str
    version: int
    label_bn: str
    label_en: str
    desc: str                      # planner-facing description (English)
    risk: str
    input_schema: dict
    output_schema: dict
    run: object                    # fn(ctx, args) -> dict
    summarize: object              # fn(out, lang) -> one human line (template answer)
    credits: int = 0
    rate_per_hour: int = 60
    feature: str = ""              # owning feature flag ("" = none)
    topics: tuple = ()
    pii_out: tuple = ()            # output keys that may carry phone/account numbers
    approval_title: object = None  # fn(args, lang) -> title for an approval card
    tests: tuple = field(default=("schema", "ownership", "empty", "flag_off"))

    @property
    def ref(self):
        return "%s@%d" % (self.name, self.version)

    @property
    def needs_approval(self):
        return self.risk in APPROVAL_RISKS

    def spec(self):
        """The planner-facing / API-facing contract (no callables)."""
        return {"name": self.name, "version": self.version, "risk": self.risk,
                "label_bn": self.label_bn, "label_en": self.label_en,
                "description": self.desc, "credits": self.credits,
                "rate_per_hour": self.rate_per_hour, "feature": self.feature,
                "topics": list(self.topics), "needs_approval": self.needs_approval,
                "input_schema": self.input_schema, "output_schema": self.output_schema}


def _type_ok(v, t):
    if t == "object":
        return isinstance(v, dict)
    if t == "array":
        return isinstance(v, list)
    if t == "string":
        return isinstance(v, str)
    if t == "integer":
        return isinstance(v, int) and not isinstance(v, bool)
    if t == "number":
        return isinstance(v, (int, float)) and not isinstance(v, bool)
    if t == "boolean":
        return isinstance(v, bool)
    if t == "null":
        return v is None
    raise SchemaError("unknown type %s" % t)


def validate(value, schema, path="$"):
    """Raise SchemaError on the first violation; return value unchanged."""
    types = schema.get("type")
    if types is not None:
        tl = types if isinstance(types, list) else [types]
        if not any(_type_ok(value, t) for t in tl):
            raise SchemaError("%s: expected %s" % (path, "|".join(tl)))
    if value is None:
        return value
    if "enum" in schema and value not in schema["enum"]:
        raise SchemaError("%s: not one of %s" % (path, schema["enum"]))
    if isinstance(value, str):
        if len(value) > schema.get("maxLength", 10 ** 6):
            raise SchemaError("%s: too long" % path)
        if len(value) < schema.get("minLength", 0):
            raise SchemaError("%s: too short" % path)
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            raise SchemaError("%s: below minimum" % path)
        if "maximum" in schema and value > schema["maximum"]:
            raise SchemaError("%s: above maximum" % path)
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for k in schema.get("required", ()):
            if k not in value:
                raise SchemaError("%s.%s: required" % (path, k))
        if schema.get("additionalProperties") is False:
            extra = set(value) - set(props)
            if extra:
                raise SchemaError("%s: unexpected %s" % (path, sorted(extra)[0]))
        for k, v in value.items():
            if k in props:
                validate(v, props[k], "%s.%s" % (path, k))
    if isinstance(value, list):
        if len(value) > schema.get("maxItems", 10 ** 6):
            raise SchemaError("%s: too many items" % path)
        items = schema.get("items")
        if items:
            for i, v in enumerate(value):
                validate(v, items, "%s[%d]" % (path, i))
    return value


def obj(props=None, required=(), extra=False):
    """Schema helper: a closed object."""
    return {"type": "object", "properties": props or {}, "required": list(required),
            "additionalProperties": extra}
