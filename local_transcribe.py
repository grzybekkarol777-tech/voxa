"""Voxa's offline fallback: prints local Whisper's text for a WAV recorded at dictate.RATE. whisper.cpp logs go to
stderr, so stdout carries only the text."""
import sys
import wave

import numpy as np

from dictate import local_text

with wave.open(sys.argv[1]) as w:
    audio = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
print(" ".join(local_text(audio).split()))
