from fixture import Fixture
import os, subprocess, threading
from http.server import ThreadingHTTPServer
Fixture.calls = []
server = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
try:
    env = dict(os.environ, TRANSCRIPTDOCK_TEST_BASE_URL=f'http://127.0.0.1:{server.server_port}')
    subprocess.run(['swift', 'run', 'ClientCheck'], env=env, check=True, timeout=120)
    assert not any('/credential-leak' in path for _, path in Fixture.calls), 'redirect leaked a request'
    assert sum(path == '/v1/rate-limit' for _, path in Fixture.calls) == 1, 'unexpected automatic retry'
    print(f'{len(Fixture.calls)} local fixture requests checked')
finally:
    server.shutdown()
    server.server_close()
    thread.join()
