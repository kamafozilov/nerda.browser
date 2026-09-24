# Nerda

- **Changelog**: a change people would notice gets its line in `CHANGELOG.md` under `## [Unreleased]`, in the same commit. How to write it: [docs/releasing.md](docs/releasing.md).
- **Versions** stay 0.0.x, one patch step per release (`./release.sh` with no argument), until the owner announces the public 1.0.0. Choose another version only when the owner asks for it.
- **Nerda Dev** (`./watch.sh`, `./build.sh debug`) is the app to build and run while working. `build/Nerda.app` is the release app and shares the owner's real data.
- **Decisions** and their reasons: [docs/decisions.md](docs/decisions.md).
