# Nerda

- **Changelog**: a change people would notice gets its line in `CHANGELOG.md` under `## [Unreleased]`, in the same commit. How to write it: [docs/releasing.md](docs/releasing.md).
- **Versions** stay 0.0.x, one patch step per release (`./release.sh` with no argument), until the owner announces the public 1.0.0. Choose another version only when the owner asks for it.
- **Nerda Dev** (`./watch.sh`, `./build.sh debug`) is the app to build and run while working. After a change, `./watch.sh once` puts the new build in the owner's Nerda Dev for them to try: behind the window in use, and not while they are using it. Never open it here any other way. `build/Nerda.app` is the release app and shares the owner's real data.
- **Trying things on screen** (clicks, keys, drags, windows, screenshots) happens in the test VM, `./vm.sh`, never on this Mac: its mouse, keyboard and front window are the owner's, so nothing here clicks, types or brings a window forward. A test program that opens a window runs there too (`./vm.sh put`, then `./vm.sh ssh`). `./vm.sh down` when done. What the VM can't do (trackpad swipes, Touch ID, camera) goes to the owner.
- **Decisions** and their reasons: [docs/decisions.md](docs/decisions.md).
- **Performance**: time a change that could cost speed or memory with `./bench.sh` before and after it, and compare the numbers.
