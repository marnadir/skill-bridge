"""Pipeline metrics via CloudWatch Embedded Metric Format (EMF).

EMF is a structured-log convention: a JSON blob printed to stdout that
CloudWatch turns into custom metrics — no API calls, no SDK, no
latency in the hot path. Namespace: SkillBridge/Pipeline, dimension:
Step. The job_id travels as a log property (searchable in Logs
Insights) but NOT as a dimension: per-job dimensions would explode
metric cardinality.

Cost is a first-class metric from day one (doc sez. 9): every Bedrock
call is priced with the USD table below and reported in EUR
(StepCostEur) via the static EUR_PER_USD rate. Cost is also an
anomaly signal: a sudden +30% flags a grown prompt or a loop before
any human complaint.

The emitter is deliberately defensive: metrics must NEVER fail a job.
"""

import json
import os
import time
from typing import Any

##USD per 1M tokens (eu-central-1, checked 2026-09). Keep in sync
##when switching models. Bedrock bills in USD: the EUR metric is a
##conversion with the static rate below.
_PRICES_PER_MTOK: dict[str, tuple[float, float]] = {
    ##model id substring -> (input, output)
    "claude-haiku-4-5": (1.00, 5.00),
    "embed-multilingual": (0.10, 0.0),
}

##static FX rate, overridable via env without a code change; update
##periodically (it is a reporting convenience, not accounting)
EUR_PER_USD = float(os.environ.get("EUR_PER_USD", "0.86"))


def _price_for(model_id: str) -> tuple[float, float]:
    """Return the (input, output) USD price per 1M tokens for a model.

    Args:
        model_id: The Bedrock model or inference profile id.

    Returns:
        tuple[float, float]: Prices per 1M tokens; (0, 0) if unknown.
    """
    for key, prices in _PRICES_PER_MTOK.items():
        if key in model_id:
            return prices
    return (0.0, 0.0)


class Metrics:
    """Accumulates metrics for one lambda invocation and emits one EMF blob."""

    def __init__(self, step: str, namespace: str = "SkillBridge/Pipeline") -> None:
        """Initialize the emitter.

        Args:
            step: The pipeline step name (EMF dimension).
            namespace: The CloudWatch namespace.
        """
        self.step = step
        self.namespace = namespace
        self._values: dict[str, tuple[float, str]] = {}

    def add(self, name: str, value: float, unit: str = "Count") -> None:
        """Add (accumulate) a metric value.

        Args:
            name: Metric name.
            value: Value to add to the current one.
            unit: CloudWatch unit.

        Returns:
            None
        """
        current = self._values.get(name, (0.0, unit))[0]
        self._values[name] = (current + value, unit)

    def add_converse_usage(self, response: dict[str, Any], model_id: str) -> None:
        """Record tokens and cost of a bedrock converse response.

        Args:
            response: The raw converse response (with "usage").
            model_id: The model the call was made with.

        Returns:
            None
        """
        usage = response.get("usage", {})
        tokens_in = int(usage.get("inputTokens", 0))
        tokens_out = int(usage.get("outputTokens", 0))
        self._record_tokens(tokens_in, tokens_out, model_id)

    def add_invoke_usage(self, response: dict[str, Any], model_id: str) -> None:
        """Record tokens and cost of a bedrock invoke_model response.

        invoke_model has no usage in the body: the token count comes
        from the x-amzn-bedrock-* response headers.

        Args:
            response: The raw invoke_model response.
            model_id: The model the call was made with.

        Returns:
            None
        """
        headers = response.get("ResponseMetadata", {}).get("HTTPHeaders", {})
        tokens_in = int(headers.get("x-amzn-bedrock-input-token-count", 0) or 0)
        tokens_out = int(headers.get("x-amzn-bedrock-output-token-count", 0) or 0)
        self._record_tokens(tokens_in, tokens_out, model_id)

    def add_usage_dict(self, usage: dict[str, Any], model_id: str) -> None:
        """Record tokens and cost from an accumulated usage dict.

        Args:
            usage: {"inputTokens": n, "outputTokens": n} (strands shape).
            model_id: The model the calls were made with.

        Returns:
            None
        """
        self._record_tokens(
            int(usage.get("inputTokens", 0)), int(usage.get("outputTokens", 0)), model_id
        )

    def _record_tokens(self, tokens_in: int, tokens_out: int, model_id: str) -> None:
        """Accumulate token counts and their USD cost.

        Args:
            tokens_in: Input tokens.
            tokens_out: Output tokens.
            model_id: The model id (for pricing).

        Returns:
            None
        """
        price_in, price_out = _price_for(model_id)
        usd = tokens_in / 1e6 * price_in + tokens_out / 1e6 * price_out
        self.add("TokensIn", tokens_in)
        self.add("TokensOut", tokens_out)
        self.add("StepCostEur", usd * EUR_PER_USD, "None")

    def flush(self, job_id: str | None = None) -> None:
        """Print the EMF blob. Never raises: metrics must not fail a job.

        Args:
            job_id: Optional job id, attached as a log property.

        Returns:
            None
        """
        try:
            if not self._values:
                return
            blob: dict[str, Any] = {
                "_aws": {
                    "Timestamp": int(time.time() * 1000),
                    "CloudWatchMetrics": [
                        {
                            "Namespace": self.namespace,
                            ##both per-step and aggregate (no-dimension)
                            ##series: alarms on totals need the latter
                            "Dimensions": [["Step"], []],
                            "Metrics": [
                                {"Name": name, "Unit": unit}
                                for name, (_, unit) in self._values.items()
                            ],
                        }
                    ],
                },
                "Step": self.step,
            }
            if job_id:
                blob["JobId"] = job_id
            for name, (value, _) in self._values.items():
                blob[name] = value
            print(json.dumps(blob))
        except Exception as exc:  # noqa: BLE001 - observability must never
            # break the pipeline
            print(f"[metrics] emit failed: {type(exc).__name__}: {exc}")
