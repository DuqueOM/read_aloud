# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-11-03

First public version.

### Added

#### Reading with shortcuts

- `Ctrl+Shift+V` reads the selected text in any program; `Ctrl+Shift+Q`
  stops, `Ctrl+Shift+Space` pauses or resumes, `Ctrl+Shift+,` and `.` skip
  back and forward, and `Ctrl+Shift+]` and `[` change the speed
  (AutoHotkey v2).
- The same from the console with `read_aloud.ps1`: `-InputText`, `-Stop`,
  `-Toggle`, `-Language`, `-ListVoices`, `-Diagnose`, `-Direct` (without the
  resident process) and `-ShowPlan`, which shows how the text will be split
  and with which voice, without playing it.
- `setup.ps1` downloads Piper and the voices into the repository folder, and
  `install_startup.ps1` starts the shortcuts and the engine at sign-in. No
  administrator rights needed.
- Windows SAPI voices as a fallback when Piper or its voice is missing.

#### Language per sentence and pronunciation dictionary

- Each sentence picks Spanish or English from its stop words, spelling and
  morphology, with scores normalized by length; adjacent sentences in the
  same language are read together, and a voice switch needs a clear sentence
  of at least five words.
- A dictionary of 250 terms (`config/terms_es.tsv`) rewrites English words
  inside Spanish text with Spanish spelling, longest terms first and in a
  single pass.
- Units read in full, in singular or plural (`45 s`, `8 GB`, `los MB`),
  `ML` as "machine learning" or as letters, arrows and path slashes spoken.
- The text is read as headings, paragraphs, table rows and bullets, and each
  kind of block gets its own pause.

#### Floating player with text panel and settings

- A small bar that stays on top while reading, with pause, skip, a speed
  menu from 0.5x to 2x (also with the mouse wheel), a seek bar and position;
  translucent when idle and closed when the reading ends.
- A text panel with the current sentence highlighted and what was already
  read dimmed: clicking a sentence jumps to it, the text can be copied, and
  the window resizes from any side and moves with its tab.
- A settings panel for opacity, size, font, the panel on show, the engine,
  the Piper voices, performance (voice always loaded or freed when idle),
  skip seconds, fallback language and the pause between sentences.
  Settings layer as defaults, `config/settings.psd1`,
  `config/settings.local.psd1` (ignored by Git) and the panel.

#### Resident process

- `read_aloud_daemon.ps1` stays in the background with one `piper.exe` per
  language and its model already loaded; the shortcut writes to a one-way
  named pipe instead of starting PowerShell. A command is accepted in 20 to
  80 ms and the first sentence is synthesized in 60 to 200 ms.
- Sentence-by-sentence streaming: the first sentence plays as soon as it is
  ready, the next ones are generated meanwhile, and two players hand over
  without a gap; block pauses are appended to the audio as silence.
- A named mutex keeps a single instance. When idle it waits for events, and
  the window timer slows down: about 16 ms of CPU every 20 s.

#### Custom voice (optional)

- A documented pipeline (`voz_personalizada/`, `docs/voz-personalizada.md`)
  that extracts one speaker from recordings where several people talk:
  voice separation, transcription with Whisper large-v3 and Qwen3-ASR, word
  alignment, speaker recognition with WavLM, quality scoring, review pages
  and the final selection. `voz.toml` adapts it to any voice.
- LoRA fine-tuning of Qwen3-TTS 12Hz 1.7B Base, with three bugs of the
  official recipe fixed, and a blind vote to choose between candidates.
- Real-time reading on an 8 GB card: LoRA merged into the weights, the code
  predictor replayed as a CUDA graph and sentences generated in batches,
  from 3.76 to 0.34 times the audio length.
- The `auto` engine uses the custom voice when it is installed and the
  NVIDIA card has at least 7 GB, falls back to Piper while another job uses
  the card, and reloads the voice when the card is free.
- Locked Python environments (`pyproject.toml` and `uv.lock`), and 15
  architecture decision records in `docs/adr/`.

#### Tests and CI

- 157 Pester tests for the text logic, the settings layers, the engine
  choice, WAV handling and file encodings, plus reference reading plans for
  sample texts and a smoke test of `-ShowPlan`. They run on Windows
  PowerShell 5.1 and PowerShell 7.
- pre-commit with gitleaks, ruff, PSScriptAnalyzer and a check for terms
  that must not be published.
- GitHub Actions running Pester, PSScriptAnalyzer, ruff and gitleaks over the
  whole history, with every action pinned to a commit.

[Unreleased]: https://github.com/DuqueOM/read_aloud/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/DuqueOM/read_aloud/releases/tag/v1.0.0
