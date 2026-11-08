# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.3.2] - 2026-11-08

The engine could be left half-installed when Piper was still running.

### Fixed

- Installing or repairing the voices failed with "Access denied" on
  `espeak-ng.dll` when a `piper.exe` was still alive (a child of the resident
  process, or an orphan from an earlier install): Windows does not let you
  overwrite a DLL that a process has loaded, and the engine was left without
  `espeak-ng-data`. Found from the `setup.log` of a real install.
  - `setup.ps1` closes the `piper.exe` of its own folder, extracts the engine to a
    temporary folder and only then replaces `bin/piper` in one move, putting the
    old one back if that fails. It never leaves a half-installed engine.
  - The installer and the uninstaller close the resident process, the voice
    server and any `piper.exe` of the installation folder before replacing or
    deleting files (new `parar_read_aloud.ps1`; it only touches processes of that
    folder, never another copy or another program that uses Piper).
  - The uninstaller retries and warns if some file was still in use.

## [1.3.1] - 2026-11-07

Installations that end without a voice, and updates that keep what is yours.

### Fixed

- A fresh install could end with no voice engine and no voice models when the
  download of `setup.ps1` failed (the window closed by itself and the installer
  went on as if nothing had happened). Now each download is retried three times
  with the system proxy, the error says which file failed and what to check,
  the installer warns you and explains how to retry, everything is written to
  `read_aloud_piper/runtime/setup.log`, and Read Aloud itself offers to
  download the missing engine or voice when it opens.
- Piper needs the Microsoft Visual C++ Redistributable: `setup.ps1` checks for
  it and, if missing, downloads Microsoft's installer, verifies its signature
  and runs it.

### Added

- "Tell me when there is a new version" (on by default, in Settings > About):
  one query to GitHub a day (and when Read Aloud opens), only a notice in the
  tray; it installs nothing without your confirmation and sends none of your
  data.

### Changed

- Updating keeps `config/settings.psd1` (it is edited by hand) and leaves a copy
  of the replaced factory dictionaries in `copia_de_config_anterior`. Settings,
  your dictionary and `settings.local.psd1` were already untouched.
- Uninstalling also removes the configuration copy, and the settings
  and dictionary if you choose not to keep them.

## [1.3.0] - 2026-11-07

Fixes found while testing 1.2 and new screenshots.

### Fixed

- The volume fader follows the mouse when you press on the track and keep
  dragging (before, only dragging the knob itself worked).
- Shortcuts with `[` or `]` (or any key that needs Shift or AltGr to type on
  your keyboard layout) are registered with the modifiers that layout needs, so
  they match what you press on Latin American and other non-US keyboards.
- The SHA-256 check of an update no longer depends on `Get-FileHash`, which
  fails in a process started from a PowerShell 7 terminal ("Download and
  install" in the settings). Checked end to end against the real release.
- The release workflow uses the Inno Setup that the Windows runner already has
  (1.2.0 first failed trying to downgrade it).

### Changed

- New screenshots of the player, the text panel and the settings (appearance,
  pronunciation, shortcuts and About), and an updated README: the tray icon,
  the installer and the desktop shortcut, shortcuts recorded from the settings
  and settings that no longer need a restart.

## [1.2.0] - 2026-11-07

Read Aloud for anyone: no AutoHotkey, an installer, and everything adjustable
from the settings panel.

### Added

- Keyboard shortcuts handled by the resident process itself (no AutoHotkey),
  with a tray icon ("Quit Read Aloud", settings). Reading is now `Ctrl+Alt+V`
  (it keeps the feel of pasting and leaves `Ctrl+Shift+V`, paste without
  formatting, alone). Shortcuts are recorded from the settings panel (click one
  and press the new combination), checked for duplicates, reserved
  combinations and other programs, and applied at once.
- Windows installer (`ReadAloud-Setup-<version>.exe`, Inno Setup), per user and
  without administrator rights, built by CI on every release together with its
  `.sha256`. Start menu shortcuts (settings, close, install or repair the
  voices, uninstall), an optional desktop shortcut that opens the settings
  without reading anything, and optional start with Windows. Uninstalling asks
  whether to keep your settings and dictionary.
- Settings panel: theme (like Windows, dark, light) and eight accent colors
  applied instantly; interface in English and Spanish (`Language`); a
  pronunciation section listing the whole dictionary, by text language and by
  voice (Piper or the own voice), with search, test, save and remove; keyboard
  shortcuts; "About" with version and contact, "Copy diagnostics" and "Check for
  updates" (queries GitHub only when pressed, verifies the SHA-256 of the
  installer and opens it only if you confirm); choice between reading with
  Piper or waiting while the own voice is still loading.
- English pronunciation dictionary (`config/terms_en.tsv`) and a user
  dictionary per language that updates do not touch.
- Accessibility: names for screen readers on every control and a visible
  keyboard focus.
- Issue templates, `-Quit` and `-ShowSettings` options in `read_aloud.ps1`, and
  log rotation (`daemon.log`, `qwen.log`).

### Changed

- No setting asks for a restart any more: voice, engine, performance and
  sentence pause reload the voice processes in place, and shortcuts and colors
  apply instantly. Only changing the interface language restarts the reader.
- An error in a window handler no longer closes the resident process silently:
  it is written to `daemon.log`.

### Removed

- `read_aloud_hotkey.ahk` and the AutoHotkey requirement. `install_startup.ps1`
  removes the old shortcut and script if it finds them.

### Fixed

- The dictionary merge dropped almost every word when a term was called
  `keys` or `values` (they shadowed the hashtable properties).

## [1.1.0] - 2026-11-07

Fluidity and control of the player.

### Added

- Seek to any point of the reading, even one that is not generated yet: the
  target chunk is generated first. Previous and next sentence (`prev`,
  `next` commands). The remaining time is estimated from the speech rate
  measured so far.
- Volume control: a vertical fader above the volume button (drag, click on
  the track, or mouse wheel in 5 % steps; `louder` and `quieter` commands).
  The level is remembered and only affects Read Aloud, not Windows.
- Per-engine pronunciation dictionary: `config/terms_es.tsv` accepts an
  optional third column with the spelling for the custom voice. GitHub is
  read as "Guit jab" by Piper and "Guit jap" by the custom voice.
- Setting `QwenLoadWaitSeconds`: if a reading arrives while the custom voice
  is still loading (15 to 50 s), it starts with Piper and switches to the
  custom voice as soon as it is ready, instead of staying silent.
- `FirstChunkChars`, `MaxChunkChars` and `QwenBatchChars` settings, and
  tests for the player logic (`lib/ReadAloud.Player.ps1`).
- README: "Support the project" and "Feedback and contact" sections.

### Changed

- Folder trees, bullet lists, tables and long sentences are split into
  chunks that grow progressively, equal for Piper and the custom voice. The
  voice no longer reads tree lines, code quotes or table bars.
  Measured with the custom voice: no long waits in the middle of a folder
  tree (25.2 s before), and 4.4 s to the first audio on long bullets (9.5 s
  before).
- A single high-quality English voice: the panel and `setup.ps1` no longer
  offer the medium one.

### Fixed

- The clock showed one extra minute from the second 30 of each minute (0:45
  as 1:45).
- The custom voice server ignores a BOM at the start of a line.

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

[Unreleased]: https://github.com/DuqueOM/read_aloud/compare/v1.3.2...HEAD
[1.3.2]: https://github.com/DuqueOM/read_aloud/releases/tag/v1.3.2
[1.3.1]: https://github.com/DuqueOM/read_aloud/releases/tag/v1.3.1
[1.3.0]: https://github.com/DuqueOM/read_aloud/releases/tag/v1.3.0
[1.2.0]: https://github.com/DuqueOM/read_aloud/releases/tag/v1.2.0
[1.1.0]: https://github.com/DuqueOM/read_aloud/releases/tag/v1.1.0
[1.0.0]: https://github.com/DuqueOM/read_aloud/releases/tag/v1.0.0
