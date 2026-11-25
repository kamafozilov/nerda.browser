#include <stdlib.h>
#include "TestRun.h"

// How many tests run at once. Left to itself, Swift Testing starts every
// test at the same moment, and with each test opening its pages that is
// some 200 WebKit page processes launched within three seconds: macOS
// leaves them all waiting for seconds, and a page that loads in a fraction
// of a second alone takes longer than a test waits for it (`waitFor`).
// 32 at a time keeps it near 70 processes, and the run as quick: its
// length is the tests that run one after another. Set before Swift Testing
// reads its settings, as the test bundle loads; a value given to
// `swift test` in the environment wins.
__attribute__((constructor))
static void limitTestsAtOnce(void) {
    setenv("SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH", "32", 0);
}
