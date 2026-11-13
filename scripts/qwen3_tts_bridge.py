#!/usr/bin/env python3
"""Local VMM adapter for the official qwen-tts CustomVoice Python API.
No models or Python packages are installed by this script.
"""
import argparse
import io
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class BoundedHTTPServer(ThreadingHTTPServer):
    # An unauthenticated loopback client must not be able to create an
    # unbounded number of threads or hold idle connections indefinitely.
    request_queue_size = 8
    request_timeout = 10
    max_requests = 8

    def __init__(self, *args, **kwargs):
        self._request_slots = threading.BoundedSemaphore(self.max_requests)
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if not self._request_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            request.settimeout(self.request_timeout)
            super().process_request(request, client_address)
        except BaseException:
            self._request_slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()


class QwenBackend:
    def __init__(self, model_path, device):
        import torch
        from qwen_tts import Qwen3TTSModel
        self.model = Qwen3TTSModel.from_pretrained(
            model_path, device_map=device, dtype=torch.float32,
            attn_implementation="eager",
        )
        if not self.model.get_supported_speakers():
            raise ValueError("A CustomVoice model with built-in speakers is required")

    def speakers(self):
        return self.model.get_supported_speakers()

    def synthesize(self, text, speaker, language, instruct):
        import soundfile
        wavs, rate = self.model.generate_custom_voice(
            text=text, speaker=speaker, language=language,
            instruct=instruct or None, max_new_tokens=4096,
        )
        output = io.BytesIO()
        soundfile.write(output, wavs[0], rate, format="WAV", subtype="PCM_16")
        return output.getvalue()


def make_server(backend, port=8001):
    lock = threading.Lock()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # Do not put dialogue text into logs.

        def send(self, code, data, content_type="application/json"):
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def failure(self, code, message):
            self.send(code, json.dumps({"error": message}).encode())

        def allowed(self):
            if self.headers.get("Origin"):
                self.failure(403, "Browser origins are not supported")
                return False
            if self.headers.get("Host", "").split(":")[0] not in ("127.0.0.1", "localhost"):
                self.failure(403, "Loopback host required")
                return False
            return True

        def do_GET(self):
            if not self.allowed():
                return
            if self.path != "/speakers":
                self.failure(404, "Unknown route")
                return
            with lock:
                voices = backend.speakers()
            self.send(200, json.dumps({"speakers": voices}).encode())

        def do_POST(self):
            if not self.allowed():
                return
            if self.path != "/synthesis":
                self.failure(404, "Unknown route")
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 100_000:
                    self.failure(413, "Request size limit exceeded")
                    return
                data = json.loads(self.rfile.read(length))
                text, speaker = data["text"], data["speaker"]
                language, instruct = data.get("language", "Japanese"), data.get("instruct", "")
                if not all(isinstance(v, str) for v in (text, speaker, language, instruct)) or not 0 < len(text) <= 12000 or len(instruct) > 4000:
                    raise ValueError("Invalid text or instruction")
                if language not in ("Japanese", "English", "Auto"):
                    raise ValueError("Unsupported language")
                with lock:
                    if speaker not in backend.speakers():
                        raise ValueError("Unknown speaker")
                    audio = backend.synthesize(text=text, speaker=speaker, language=language, instruct=instruct)
                self.send(200, audio, "audio/wav")
            except (ValueError, KeyError, TypeError):
                self.failure(400, "Invalid synthesis request")
            except Exception:
                # Backend errors can contain local model paths or prompt text.
                self.failure(500, "Qwen3-TTS inference failed")

    server = BoundedHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="Local CustomVoice model directory")
    parser.add_argument("--device", default="cpu", choices=("cpu", "mps", "cuda:0"))
    parser.add_argument("--port", type=int, default=8001)
    args = parser.parse_args()
    if not Path(args.model).is_dir():
        parser.error("--model must be a downloaded local CustomVoice model directory")
    if not 1 <= args.port <= 65535:
        parser.error("Invalid port")
    backend = QwenBackend(args.model, args.device)
    server = make_server(backend, args.port)
    print(f"VMM Qwen3-TTS bridge: http://127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
