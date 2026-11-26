# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring, read these

- **`GLOSSARY.md`** at the repo root.
- **`docs/decisions.md`**: one numbered row per decision, referred to as `#22`. Read the rows that touch the area you're about to work in. A new decision is a new row, added in the pull request that carries the change; this repo has no `docs/adr/`.

## File structure

Single-context repo:

```
/
├── GLOSSARY.md
├── docs/
│   └── decisions.md
└── Sources/
```

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal: either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag decision conflicts

If your output contradicts an existing decision, surface it explicitly rather than silently overriding:

> _Contradicts decision #23 (frame rate), but worth reopening because…_
