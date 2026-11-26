#include <stdlib.h>
#include "TestRun.h"

// How many tests run at once. Left to itself, Swift Testing starts every
// test at the same moment, and with each test opening its pages that is
// some 200 WebKit page processes launched within three seconds: macOS
// leaves them all waiting for seconds, and a page that loads in a fraction
// of a second alone takes longer than a test waits for it (`waitFor`).
// 16 at a time leaves room for a second run beside this one: at 32, two
// runs together kept some 140 processes going and the main thread of each
// late by seconds, and tests timed out waiting; at 16, a run takes no
// longer, its length being the tests that run one after another. Set
// before Swift Testing reads its settings, as the test bundle loads; a
// value given to `swift test` in the environment wins.
__attribute__((constructor))
static void limitTestsAtOnce(void) {
    setenv("SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH", "16", 0);
}

// Pages without the fonts installed on the Mac beyond its own
// (`UserInstalledFonts`). With them, a page started in a process already
// running (the one kept ready, a spare) has WebKit issue two sandbox
// extensions for its fonts on the main thread, each "with user intent",
// which the kernel has sandboxd approve, asking TCC. Some 420 asks a run,
// and now and then one goes unanswered for 5 s, the main thread held all
// the while and every test's wait with it. Set once for the whole run,
// before any page is made, so no test flips it under another.
__attribute__((constructor))
static void leaveUserInstalledFontsOut(void) {
    setenv("NERDA_USER_INSTALLED_FONTS", "0", 0);
}

// Not the Mac's memory pressure (`MemoryPressure.hearsSystem`): every
// browser joins the shared sleep coordinator, and every last frame and the
// new tab's picture listen too, so the Mac short of memory, two runs side
// by side on 16 GB included, would put tests' hidden tabs to sleep and drop
// their frames under them. The tests that need pressure hand their own to
// what they test.
__attribute__((constructor))
static void leaveTheMacsMemoryPressureOut(void) {
    setenv("NERDA_SYSTEM_MEMORY_PRESSURE", "0", 0);
}
