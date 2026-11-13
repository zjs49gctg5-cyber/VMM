import importlib.util
import json
import socket
import threading
import time
import unittest
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError

spec = importlib.util.spec_from_file_location('qwen_bridge', Path(__file__).parents[1] / 'qwen3_tts_bridge.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

class Backend:
    def speakers(self):
        return ['Ryan', 'Ono_Anna']
    def synthesize(self, **values):
        self.last = values
        return b'RIFF0000WAVEtest'

class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.backend = Backend()
        self.server = bridge.make_server(self.backend, 0)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f'http://127.0.0.1:{self.server.server_port}'
    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
    def send(self, path, values=None, headers=None):
        return urlopen(Request(self.url + path, data=json.dumps(values).encode() if values is not None else None, headers=headers or {}), timeout=5)
    def test_speakers_and_synthesis(self):
        with self.send('/speakers') as response:
            self.assertEqual(json.load(response), {'speakers':['Ryan', 'Ono_Anna']})
        values = dict(text='Hello', speaker='Ryan', language='English', instruct='Speak softly')
        with self.send('/synthesis', values) as response:
            self.assertEqual(response.headers['Content-Type'], 'audio/wav')
            self.assertTrue(response.read().startswith(b'RIFF'))
        self.assertEqual(self.backend.last, values)
    def test_invalid_voice_language_text(self):
        for values in [dict(text='x', speaker='Unknown'), dict(text='x', speaker='Ryan', language='wrong'), dict(text='', speaker='Ryan'), dict(text=5, speaker='Ryan'), {}]:
            with self.assertRaises(HTTPError) as error:
                self.send('/synthesis', values)
            self.assertEqual(error.exception.code, 400)
            error.exception.close()
    def test_origins_host_and_routes(self):
        for headers in [{'Origin':'https://example.com'}, {'Host':'evil.com'}]:
            with self.assertRaises(HTTPError) as error:
                self.send('/speakers', headers=headers)
            self.assertEqual(error.exception.code, 403)
            error.exception.close()
        with self.assertRaises(HTTPError) as error:
            self.send('/unknown')
        self.assertEqual(error.exception.code, 404)
        error.exception.close()
    def test_incomplete_connections_are_bounded_and_time_out(self):
        self.server.request_timeout = 0.5
        clients = []
        try:
            for _ in range(self.server.max_requests):
                client = socket.create_connection(('127.0.0.1', self.server.server_port), timeout=2)
                client.sendall(b'GET /speakers HTTP/1.1\r\n')
                clients.append(client)
            deadline = time.monotonic() + 2
            while self.server._request_slots._value and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(self.server._request_slots._value, 0)
            extra = socket.create_connection(('127.0.0.1', self.server.server_port), timeout=2)
            try:
                extra.settimeout(2)
                extra.sendall(b'GET /speakers HTTP/1.1\r\nHost: localhost\r\n\r\n')
                try:
                    response = extra.recv(1024)
                except ConnectionResetError:
                    response = b''
                self.assertEqual(response, b'')
            finally:
                extra.close()
            for client in clients:
                client.settimeout(2)
                self.assertEqual(client.recv(1024), b'')
            with self.send('/speakers') as response:
                self.assertEqual(response.status, 200)
        finally:
            for client in clients:
                client.close()
    def test_backend_errors_do_not_expose_private_details(self):
        def fail(**_):
            raise RuntimeError('private prompt and local model path')
        self.backend.synthesize = fail
        with self.assertRaises(HTTPError) as error:
            self.send('/synthesis', dict(text='x', speaker='Ryan'))
        self.assertEqual(error.exception.code, 500)
        body = error.exception.read()
        error.exception.close()
        self.assertNotIn(b'private', body)
        self.assertIn(b'inference failed', body)

if __name__ == '__main__':
    unittest.main()
