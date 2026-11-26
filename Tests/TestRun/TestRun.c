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
