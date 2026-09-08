"""Local dev HTTP server for the backend-api lambda.

Dev-only: converts HTTP requests into API Gateway v2 events, invokes
lambda_handler and adds the CORS headers (API Gateway does it in
AWS). Excluded from the deploy zip.

Run (from the backend/ folder):
    BUCKET_NAME=... JOBS_TABLE=... AWS_PROFILE=... \
        AWS_DEFAULT_REGION=eu-central-1 \
        poetry run python backend-api/local_server.py
"""

import json
import os
import re
from http.server import BaseHTTPRequestHandler, HTTPServer

from lambda_function import lambda_handler

PORT = int(os.environ.get("PORT", "8080"))
# vite dev server origin
ALLOWED_ORIGIN = "http://localhost:5173"

GET_JOB_PATH = re.compile(r"^/jobs/([^/]+)$")


class DevHandler(BaseHTTPRequestHandler):
    def _send_cors(self) -> None:
        """Add the CORS headers that API Gateway adds in AWS.

        Returns:
            None
        """
        self.send_header("access-control-allow-origin", ALLOWED_ORIGIN)
        self.send_header("access-control-allow-methods", "GET, POST, OPTIONS")
        self.send_header("access-control-allow-headers", "content-type")

    def _reply(self, event: dict) -> None:
        """Invoke the lambda handler and write its response.

        Args:
            event: The API Gateway v2 event to pass to the handler.

        Returns:
            None
        """
        try:
            result = lambda_handler(event, None)
        except Exception as exc:  # noqa: BLE001 - dev server: the error goes
            # to the browser with CORS headers, not as a fake CORS error
            result = {
                "statusCode": 500,
                "headers": {"content-type": "application/json"},
                "body": json.dumps({"message": f"{type(exc).__name__}: {exc}"}),
            }
        self.send_response(result["statusCode"])
        self._send_cors()
        for name, value in result.get("headers", {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(result["body"].encode())

    def do_OPTIONS(self) -> None:
        """Answer the browser CORS preflight.

        Returns:
            None
        """
        self.send_response(204)
        self._send_cors()
        self.end_headers()

    def do_POST(self) -> None:
        """Route POST /jobs to the lambda handler.

        Returns:
            None
        """
        if self.path.rstrip("/") != "/jobs":
            self._reply({"routeKey": ""})
            return
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length).decode() if length else None
        self._reply({"routeKey": "POST /jobs", "body": body})

    def do_GET(self) -> None:
        """Route GET /jobs/{jobId} to the lambda handler.

        Returns:
            None
        """
        match = GET_JOB_PATH.match(self.path)
        if not match:
            self._reply({"routeKey": ""})
            return
        self._reply(
            {"routeKey": "GET /jobs/{jobId}", "pathParameters": {"jobId": match.group(1)}}
        )


if __name__ == "__main__":
    print(f"backend-api in ascolto su http://localhost:{PORT}")
    HTTPServer(("localhost", PORT), DevHandler).serve_forever()
