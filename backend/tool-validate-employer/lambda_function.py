"""Lambda: isolated executor of the external validate_employer tool (doc 5.2-bis).

The security boundary is one of PERMISSIONS, not code: this function
runs with a minimal IAM role — logs only, NO access to profile data,
the index, S3 or any pipeline table. A code path trying to touch them
would get AccessDenied: the isolation is provable, not declared.

The validation is REAL: a deterministic lookup against the bundled
company registry (registry.json, ~126 companies with aliases), which
is the source of truth of this deployment. When a contracted external
API replaces it, only this function changes — the agent-side contract,
the circuit breaker and the isolation stay identical."""

import json
import re
from pathlib import Path
from typing import Any


def _normalize(name: str) -> str:
    """Normalize an employer name for the registry lookup.

    Args:
        name: The raw name.

    Returns:
        str: Lowercased name with punctuation stripped.
    """
    return re.sub(r"[^a-z0-9 ]+", "", name.lower()).strip()


##demo registry shipped in the deploy zip (registry.json): lookup by
##normalized alias or registry name
_REGISTRY_DATA = json.loads((Path(__file__).parent / "registry.json").read_text())
REGISTRY: dict[str, dict[str, Any]] = {}
for company in _REGISTRY_DATA["companies"]:
    entry = {"registry_name": company["registry_name"], "country": company["country"]}
    for variant in [company["registry_name"], *company["aliases"]]:
        REGISTRY[_normalize(variant)] = entry


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    """Validate the existence of one declared employer.

    Args:
        event: {"employer_name": <string>} from the agent tool.
        context: Lambda runtime context (unused).

    Returns:
        dict[str, Any]: {"employer": <input>, "exists": <bool>,
            "registry_name": <str|None>, "country": <str|None>,
            "source": "company-registry"}.

    Raises:
        ValueError: If employer_name is missing or blank.
    """
    employer_name = event.get("employer_name")
    if not isinstance(employer_name, str) or not employer_name.strip():
        raise ValueError("employer_name is required")

    hit = REGISTRY.get(_normalize(employer_name))

    return {
        "employer": employer_name,
        "exists": hit is not None,
        "registry_name": hit["registry_name"] if hit else None,
        "country": hit["country"] if hit else None,
        "source": "company-registry",
    }
