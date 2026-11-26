import Testing
@testable import Nerda

/// The tests' run doesn't hear the Mac's memory pressure
/// (NERDA_SYSTEM_MEMORY_PRESSURE=0, set in TestRun.c): short of memory, the
/// Mac would put the tests' hidden tabs to sleep (`SleepCoordinator.shared`,
/// which every browser joins) and drop their last frames (`LastFrame`),
/// whatever the tests expect of them. A test hands its own level to what it
/// tests (`SleepCoordinator(watchingSystem: false)`).
@MainActor
@Test func theTestsDontHearTheMacsMemoryPressure() {
    #expect(!MemoryPressure.hearsSystem)
}
