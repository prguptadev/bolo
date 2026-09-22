# Bolo

Voice-driven Mac agent: hold right ⌥, speak (English/Hinglish), Bolo acts autonomously.
Design and decisions: `docs/DESIGN.md`. User-facing docs: `README.md`.

## Build and test

- `scripts/test.sh`: Swift Testing suite (BoloCore). Use this, not bare `swift test`; see below.
- `swift build && .build/debug/Bolo --say "<sentence>" --dry-run`: shows how a sentence is parsed without acting.
- `scripts/build-app.sh --install`: builds, signs, installs to ~/Applications and relaunches.

## This machine has only the Command Line Tools (no Xcode)

- `@Generable` / `@Guide` don't compile (macro plugin missing). Use `DynamicGenerationSchema`.
- `@Observable`, `#expect` / `@Test` macros do work.
- `swift test` needs the `-F`/rpath flags in `scripts/test.sh`.
- MLX Swift can't be built (Metal shaders need Xcode).

## Rules

- Bolo acts without confirmation. Never let it act on words the user didn't say: parser rules must
  not guess, and model output must pass `Grounding.filter`.
- Any new parser pattern gets a test in `Tests/BoloCoreTests`.
- Never run a non-dry-run `--say` that sends a message during development.
- Commits: no AI attribution lines.
