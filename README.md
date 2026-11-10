# OpenVision — Ray-Ban Meta × Gemini homework solver

> **Russian build.** This branch localises the app to Russian: Russian speech recognition and voice, wake word «Клод», formulas read aloud in Russian words, Russian UI. Everything else is the upstream fork.

Bấm nút chụp trên kính, nói **"Ok Vision"** và hỏi bất cứ điều gì bằng tiếng Việt hoặc tiếng Anh.
Kính đọc câu trả lời bằng đúng ngôn ngữ bạn hỏi; điện thoại hiện lời giải từng bước với công thức.

Press the capture button on the glasses, say **"Ok Vision"** and ask anything in Vietnamese or
English. The glasses speak the answer in the language you asked in; the phone shows the full
step-by-step solution with rendered formulas.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![iOS 18+](https://img.shields.io/badge/iOS-18+-blue.svg)](https://developer.apple.com/ios/)

> Fork of [rayl15/OpenVision](https://github.com/rayl15/OpenVision), narrowed to one workflow.
> Why: [ADR-001](docs/architecture/ADR-001-solver-pipeline.md). How it fits together:
> [docs/architecture.md](docs/architecture.md).

## What it does

- **Photo straight from the glasses.** The capture button is routed to the app (Meta DAT 1.0)
  and the photo is taken at full sensor resolution — no waiting for the Meta AI app to import it
  into Camera Roll. Short press: photo for your next question. Hold: photo and solve now.
  Double press: hear the last answer again. (All configurable.)
- **Ask freely.** No fixed commands: "giải câu 3", "what does this say?", "hướng dẫn mình làm
  câu này", or a question that has nothing to do with the photo.
- **Answer in your language, pronounced right.** Vietnamese question → Vietnamese answer in a
  Vietnamese voice; English → English. Math is read as words ("x bình phương bằng 4").
- **Two channels.** A short spoken answer (answer first) on the glasses; the full derivation in
  Markdown + LaTeX on the phone, rendered offline with KaTeX.
- **Asks for a photo when it needs one.** If you ask about something and there is no photo, the
  app takes one and asks Gemini again.
- **Doesn't hang.** Streaming replies, retries by failure type, a second model when quota runs
  out, several API keys, and a hard 120 s limit — then it tells you, out loud.
- **Modes from your words:** solve (default), tutor ("gợi ý", "teach me"), whole page
  ("tất cả các câu"), read / translate.

## Requirements

- iPhone with iOS 18+ (built for iPhone 15 Pro / Pro Max), Ray-Ban Meta glasses
- The Meta AI app with **Developer Mode** on (needed for the capture button and full-resolution
  photos, which are experimental in the Meta SDK — without them the app falls back to Camera Roll)
- A [Gemini API key](https://aistudio.google.com/app/apikey) — pasted in **Settings → Gemini**.
  Several keys (from different Google Cloud projects) can be entered, separated by commas.
  **Never put a key in the source code: this repository is public.**

## Install

Unsigned IPA: run the **Build Unsigned IPA** workflow (Actions tab) and sideload the artifact
(e.g. with AltStore or Sideloadly). To build yourself:

```bash
git clone https://github.com/darwnlinz1/OpenVision.git
cd OpenVision
cp Config.xcconfig.example Config.xcconfig
cp OpenVision/Config/Config.swift.example OpenVision/Config/Config.swift
open OpenVision.xcodeproj
```

`Config.xcconfig` holds your Apple Team ID, bundle id and (optionally) Meta App ID / Client Token
from the [Meta developer console](https://developer.meta.com). In Developer Mode the App ID may be
`0`. Both config files are gitignored. More: [SETUP.md](SETUP.md).

First run:
1. Settings → **Kính Ray-Ban Meta** → **Đăng ký app** (opens Meta AI to grant access).
2. Settings → **Gemini** → paste your key.
3. Settings → **Giọng nói** → choose the listening language and download an Enhanced/Premium
   Vietnamese voice in iOS Settings for the most natural pronunciation.
4. Kính → **Chụp thử** to check the button link and photo transfer.

## Tests

```bash
python3 scripts/blueprint/verify_blueprint.py      # static workflow + security guard
xcodebuild test -project OpenVision.xcodeproj -scheme OpenVision \
  -destination "platform=iOS Simulator,name=iPhone 16 Pro"
```

See [docs/testing](docs/testing) for the end-to-end plan.

## License & acknowledgments

MIT — see [LICENSE](LICENSE).

- [Meta Wearables DAT SDK](https://github.com/facebook/meta-wearables-dat-ios) — glasses
- [Google Gemini API](https://ai.google.dev) — the solver
- [KaTeX](https://katex.org) and [marked](https://marked.js.org) (MIT) — offline solution rendering
- [rayl15/OpenVision](https://github.com/rayl15/OpenVision) — the original app
- [Visor](https://github.com/macedonga/visor) — ideas for the glasses workflow (no code copied)
