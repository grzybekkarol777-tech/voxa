# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS menu bar dictation app in one file, `dictate.py` (rumps). Option+Space starts and stops recording, and Esc cancels. The audio goes to OpenAI `gpt-4o-transcribe`. Then `gpt-4.1-mini` lightly cleans up the text. The result is copied to the clipboard with `pbcopy`. Local whisper.cpp (`pywhispercpp`, model `base.en`) is used when there is no key, when OpenAI fails, or when "Use OpenAI" is unticked in the menu. The app is English only: every step has the language fixed to English.

This folder is not a git repo. There are no tests and no linter.

## Commands

- Install deps: `uv sync` (uv is the package manager; `uv.lock` is committed state).
- Run in the foreground, logs on stdout: `.venv/bin/python dictate.py`
- Run in the background: the `dictate` alias in `~/.zshrc`. It logs to `~/Library/Logs/dictate.log`.
- Syntax check without launching: `.venv/bin/python -m py_compile dictate.py`
- Restart after a code change: Quit from the menu bar icon first. A second copy exits at once because of the lock file `~/Library/Caches/dictate.lock`.
- Hear what was recorded last: `afplay ~/Library/Caches/dictate-last.wav`. Each transcription also logs one line with the raw and the copied text.

## How it works

- A pynput `GlobalHotKeys` thread calls `toggle()`. `busy` blocks the hotkey while a transcription runs.
- `start()` opens a `sounddevice` stream at 16 kHz mono. Its callback appends chunks to `self.chunks`.
- `stop()` hands off to a `transcribe` thread. It keeps recording for `TAIL` seconds, closes the stream, saves the WAV, transcribes, cleans up, copies and notifies.
- Speed matters most. `clean_up()` calls the Responses API, not chat/completions: with the same model it answered in 0.9 s instead of 3.7 s. A shared `requests.Session` lets the clean-up reuse the transcription's connection.
- `clean_up()` must never raise. On any error, or when the answer fails the word-overlap and length checks, it returns the raw transcript. The checks catch the model answering, translating or cutting the dictation. Keep this contract.
- `Overlay` copies SuperWhisper's recording window, at the top of the screen. It shows a live waveform (`WaveView`, fed by a 30 fps timer that reads the latest `chunks`), or the words so far from the live API's delta events. Below is a strip with Stop (⌥Space) and Cancel (esc), which can also be clicked (`ClickView`). After the stop it shows a spinner and "Transcribing…", and it hides once the text is copied. It is a borderless non-activating panel, so a click never takes focus from the app the user will paste into. The hotkey and transcription run off the main thread, so all AppKit calls go through `AppHelper.callAfter`.
- Esc cancels: nothing is transcribed. Over 30 s the window asks "Discard?" first, and a second esc within 3 s confirms. Esc is not swallowed, so the front app gets it too.
- The start and stop sounds are timed on purpose. The start sound plays after the mic is live. The stop sound plays after the tail, so it is not recorded.

## Setup gotchas

- The OpenAI key lives in the Keychain item `dictate-openai`. The comment above `KEYCHAIN_ITEM` gives the exact command. A bare `-w` prompt cuts the key at 128 characters.
- `.venv/bin/Info.plist` (with `CFBundleIdentifier` set to `rumps`) makes rumps notifications work. Recreating the venv deletes it. Restore it with `/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string rumps' .venv/bin/Info.plist`.
- `Quartz` is not a direct dependency. It comes from pynput's `pyobjc-framework-quartz` on macOS.
- The hotkey needs Input Monitoring for the app that started Python (Terminal). The app checks this at launch and notifies if it is missing.
- Whisper models download on first use to `~/Library/Application Support/pywhispercpp/models`. The local `models/` folder is empty and the code does not use it.

## Voxa: the Swift app in `mac/`

`mac/Sources/Voxa/main.swift` is a native port of `dictate.py` under the brand Voxa (indigo-to-magenta circle with a white waveform). It installs to `~/Applications/Voxa.app` (`com.karol.voxa`), and both the `voxa` and `dictate` aliases open it. The Python app still runs with `dictate-py`. The two share `dictate.lock`, so only one runs at a time. Keep both in step: the constants, the clean-up prompt and the guards are copied 1:1.

- Build and install: `mac/build.sh` (swiftc, no SwiftPM, no Xcode). `mac/make-cert.sh` was run once. It made the self-signed "Voxa Self-Signed" identity in `mac/signing/voxa-signing.keychain-db`, which is on the user's keychain search list. The stable signature keeps the microphone permission across rebuilds.
- `mac/toolchain-fix/overlay.yaml` hides the Command Line Tools' duplicate `SwiftBridging` module map. Without it, every AppKit build fails with "could not build module 'Foundation'".
- Differences from the Python app:
  - The hotkeys are Carbon `RegisterEventHotKey`. That needs no Input Monitoring, and it swallows the keys: Option+Space no longer types a hidden space, and esc is taken only while recording.
  - The key is read through `/usr/bin/security`, so the Keychain never asks.
  - It logs to `~/Library/Logs/voxa.log`.
  - It can paste for you (`dictate.py` stays copy-only). With "Paste into the front app" on (the default), it copies the text, then posts Cmd+V with `CGEvent` to whatever has focus, for example Claude Code in Terminal. "Press Return after pasting" (off by default) also sends Return. Both are saved in `UserDefaults` (`com.karol.voxa`). Posting keys needs Accessibility, whose switch asks for an admin password, and the user's account is standard. So without it, when Terminal is the front app, `typeIntoTerminal` uses Terminal's AppleScript `do script … in selected tab of front window`, which types into the running program (Claude Code included) and always presses Return. That needs only Automation consent (`NSAppleEventsUsageDescription` in `Info.plist`), which needs no admin. In other apps without Accessibility, it prompts once per launch and stays copy-only. The stable signature keeps both grants across rebuilds.
  - Offline, it runs `local_transcribe.py` with the venv's Python.
  - The recording window is in the Voxa gradient (white text, translucent strip and key caps), not SuperWhisper's gray. `GradientView.animate` makes the colors drift while listening (1.6 s) and faster while transcribing (0.8 s).
- `mac/Sources/Voxa/Dashboard.swift` is the window that opens with the app: status, stats, recent dictations (`~/Library/Application Support/Voxa/history.json`) and settings. It's AppKit, because the CLT's SwiftUI module won't compile with this swiftc. While active, it shows a purple "Listening…/Transcribing…" card with a live waveform (`Store.level`, set in `start()`).
- Test without the mic: `~/Applications/Voxa.app/Contents/MacOS/Voxa --selftest clip.wav` (16-bit 24 kHz WAV, for example `say -o clip.wav --file-format=WAVE --data-format=LEI16@24000 "…"`). It feeds the clip at speaking speed and prints the live, upload, clean-up and local results. `--cleanup "text"` tests the light fix alone. `VOXA_DEBUG=1` prints every live event.
- The icon is drawn by `mac/icon.swift`. Delete `mac/build/Voxa.icns` (or edit `icon.swift`) and `build.sh` redraws it.

## Style

Comments explain why, often with the real failure that caused the choice (for example, the 22 s dictation behind `chunking_strategy`). Keep that habit and the short, flat function style.
