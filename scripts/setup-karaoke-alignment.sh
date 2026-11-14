#!/bin/zsh
# Optional local Demucs runtime. The model is not bundled in VMM.
set -euo pipefail
TASK_ROOT="${1:-$HOME/Library/Application Support/VMM/KaraokeAlignment}"
TASK_PYTHON="${VMM_KARAOKE_PYTHON:-$(command -v python3.10 || true)}"
if [[ -z "$TASK_PYTHON" || ! -x "$TASK_PYTHON" ]]; then
  print -u2 'Python 3.10が見つかりません。VMM_KARAOKE_PYTHONにPython 3.10のパスを指定してください。'; exit 1
fi
if ! command -v ffmpeg >/dev/null; then print -u2 'FFmpegを先にインストールしてください。'; exit 1; fi
if [[ -e "$TASK_ROOT/venv" || -e "$TASK_ROOT/models" ]]; then
  print -u2 '既存のvenvまたはmodelsを保護するため中止します。別の空のフォルダを指定してください。'; exit 1
fi
print '歌声分離に必要なPythonライブラリとDemucsのモデルをダウンロードします。'
mkdir -p -m 700 "$TASK_ROOT"
"$TASK_PYTHON" -m venv "$TASK_ROOT/venv"
"$TASK_ROOT/venv/bin/python" -m pip install 'numpy<2' 'torch==2.2.2' 'torchaudio==2.2.2' 'demucs==4.0.1' soundfile
export TORCH_HOME="$TASK_ROOT/models/torch"
"$TASK_ROOT/venv/bin/python" -c 'from demucs.pretrained import get_model; get_model("htdemucs")'
print '設定完了。VMMの歌詞演出で以下を選択してください。'
print "Python: $TASK_ROOT/venv/bin/python"
print "モデルフォルダ: $TASK_ROOT/models"
