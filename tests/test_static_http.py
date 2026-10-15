# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

"""Exercise the HTTP oracle: correct page, wrong HTTP-200 body, failure and retry."""
import http.server
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


HELPER = Path(__file__).with_name("static-http-check.sh")
CONTENT = b"<!doctype html><title>Current synthetic landing page</title>\n"


class StaticHttpTests(unittest.TestCase):
    def probe(self, replies, attempts=1):
        calls = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                status, body = replies[min(len(calls), len(replies)-1)]
                calls.append(status)
                self.send_response(status); self.end_headers(); self.wfile.write(body)
            def log_message(self, *_):
                pass
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever); thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                expected = Path(directory, "reference.html"); expected.write_bytes(CONTENT)
                result = subprocess.run(["bash", str(HELPER), f"http://127.0.0.1:{server.server_port}/", str(expected), str(attempts), "0"], capture_output=True, text=True, timeout=10)
                self.assertNotIn(CONTENT.decode(), result.stdout + result.stderr)
                return result.returncode, calls
        finally:
            server.shutdown(); server.server_close(); thread.join()
    def test_current_content_passes_without_the_obsolete_phrase(self):
        self.assertEqual(self.probe([(200, CONTENT)])[0], 0)
    def test_wrong_html_with_http_200_is_rejected(self):
        self.assertEqual(self.probe([(200, b"<html>unrelated login page</html>")])[0], 1)
    def test_http_error_is_rejected_even_if_the_body_matches(self):
        self.assertEqual(self.probe([(503, CONTENT)])[0], 1)
    def test_transient_mismatch_retries_then_checks_exact_content(self):
        code, calls = self.probe([(200, b"wrong"), (200, CONTENT)], attempts=2)
        self.assertEqual(code, 0); self.assertEqual(len(calls), 2)
    def test_empty_reference_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory, "empty"); path.touch()
            result = subprocess.run(["bash", str(HELPER), "http://127.0.0.1:1/", str(path), "1", "0"], capture_output=True)
            self.assertEqual(result.returncode, 2)


if __name__ == "__main__": unittest.main()
