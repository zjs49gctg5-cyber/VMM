#!/usr/bin/env python3
"""Offline optional Demucs adapter. Inputs and output remain local."""
import argparse
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--audio', required=True)
    parser.add_argument('--models', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    root = Path(args.models).expanduser().resolve()
    checkpoint = root / 'torch' / 'hub' / 'checkpoints' / '955717e8-8726e21a.th'
    if not checkpoint.is_file():
        raise ValueError('Demucsのモデルが見つかりません。セットアップ手順を確認してください。')
    ffmpeg = shutil.which('ffmpeg')
    if not ffmpeg:
        raise ValueError('FFmpegが見つかりません。')
    os.environ['TORCH_HOME'] = str(root / 'torch')
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ.setdefault('OMP_NUM_THREADS', '4')
    with tempfile.TemporaryDirectory(prefix='vmm-vocals-worker-') as scratch:
        decoded = str(Path(scratch) / 'source.wav')
        subprocess.run([ffmpeg, '-v', 'error', '-i', args.audio, '-ac', '2', '-ar', '44100', '-c:a', 'pcm_s16le', decoded], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        command = [sys.executable, '-m', 'demucs', '--two-stems', 'vocals', '-n', 'htdemucs', '--device', 'cpu', '-o', scratch, decoded]
        child = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        def stop_child(_signum, _frame):
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            raise SystemExit(130)
        old_handler = signal.signal(signal.SIGTERM, stop_child)
        try:
            if child.wait() != 0:
                raise ValueError('歌声分離に失敗しました。Demucsと音声バックエンドを確認してください。')
        finally:
            signal.signal(signal.SIGTERM, old_handler)
        files = list(Path(scratch).glob('htdemucs/*/vocals.wav'))
        if len(files) != 1:
            raise ValueError('分離した歌声を取得できません。')
        if Path(args.output).exists():
            raise ValueError('出力先が既に存在します。')
        shutil.copyfile(files[0], args.output)


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        print('歌声分離に失敗しました: ' + str(error), file=sys.stderr)
        sys.exit(1)
