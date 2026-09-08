"""Server HTTP di sviluppo locale per la lambda presign-cv.

Solo per il locale: converte le richieste nel formato evento della
Function URL, invoca lambda_handler e aggiunge gli header CORS (in
AWS li gestisce la Function URL). Escluso dallo zip di deploy.

Avvio (dalla cartella backend/):
    BUCKET_NAME=... AWS_PROFILE=... AWS_DEFAULT_REGION=eu-central-1 \
        poetry run python presign-cv/local_server.py
"""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

from lambda_function import lambda_handler

PORT = int(os.environ.get("PORT", "8080"))
# origin del dev server vite
ALLOWED_ORIGIN = "http://localhost:5173"


class DevHandler(BaseHTTPRequestHandler):
    def _send_cors(self) -> None:
        """Add the CORS headers that the Function URL adds in AWS.

        Returns:
            None
        """
        self.send_header("access-control-allow-origin", ALLOWED_ORIGIN)
        self.send_header("access-control-allow-methods", "POST, OPTIONS")
        self.send_header("access-control-allow-headers", "content-type")

    def do_OPTIONS(self) -> None:
        """Answer the browser CORS preflight.

        Returns:
            None
        """
        self.send_response(204)
        self._send_cors()
        self.end_headers()

    def do_POST(self) -> None:
        """Convert the HTTP request to a Function URL event and reply.

        Returns:
            None
        """
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length).decode() if length else None

        event = {"requestContext": {"http": {"method": "POST"}}, "body": body}
        try:
            result = lambda_handler(event, None)
        except Exception as exc:  # noqa: BLE001 - dev server: l'errore va al browser
            # con gli header CORS, altrimenti appare come (falso) errore CORS
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


if __name__ == "__main__":
    print(f"presign-cv in ascolto su http://localhost:{PORT} (bucket: {os.environ['BUCKET_NAME']})")
    HTTPServer(("localhost", PORT), DevHandler).serve_forever()
