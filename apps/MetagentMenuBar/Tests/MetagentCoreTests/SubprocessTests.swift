import Darwin
import Foundation
import XCTest
@testable import MetagentCore

final class SubprocessTests: XCTestCase {
    func testExitEventQueueCreationFailureRetainsPolling() {
        let waiter = SubprocessExitWaiter(processID: getpid(), queueFactory: { -1 })
        XCTAssertFalse(waiter.usesEventWaiting)
        XCTAssertFalse(waiter.wait(upTo: 0.001))
    }

    func testExitEventRegistrationFailureClosesDescriptorAndRetainsPolling() throws {
        // A regular file is a valid descriptor but cannot register kqueue
        // events. This exercises the error path without exhausting resources.
        let descriptor = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let waiter = SubprocessExitWaiter(processID: getpid(), queueFactory: { descriptor })
        let descriptorResult = fcntl(descriptor, F_GETFD)
        let descriptorError = errno
        XCTAssertFalse(waiter.usesEventWaiting)
        XCTAssertEqual(descriptorResult, -1)
        XCTAssertEqual(descriptorError, EBADF)
        XCTAssertFalse(waiter.wait(upTo: 0.001))
    }

    func testTimerExpirationDoesNotReportProcessExitAndCanRearm() throws {
        let waiter = SubprocessExitWaiter(processID: getpid())
        _ = waiter.wait(upTo: 0.001)
        try XCTSkipUnless(waiter.usesEventWaiting, "Process/timer events unavailable on this host.")
        let started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        XCTAssertFalse(waiter.wait(upTo: 0.015))
        XCTAssertTrue(waiter.usesEventWaiting)
        XCTAssertFalse(waiter.wait(upTo: 0.02))
        XCTAssertTrue(waiter.usesEventWaiting)
        XCTAssertGreaterThanOrEqual(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - started, 30_000_000)
    }

    func testTimerRegistrationFailureClosesDescriptorAndRetainsPolling() throws {
        let descriptor = kqueue()
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        // Mutually exclusive time units make this a rejected timer change.
        let waiter = SubprocessExitWaiter(
            processID: getpid(), queueFactory: { descriptor },
            timerFlags: UInt32(NOTE_SECONDS | NOTE_NSECONDS | NOTE_MACH_CONTINUOUS_TIME)
        )
        try XCTSkipUnless(waiter.usesEventWaiting, "Process events unavailable on this host.")
        XCTAssertFalse(waiter.wait(upTo: 0.001))
        let descriptorResult = fcntl(descriptor, F_GETFD)
        let descriptorError = errno
        XCTAssertFalse(waiter.usesEventWaiting)
        XCTAssertEqual(descriptorResult, -1)
        XCTAssertEqual(descriptorError, EBADF)
        XCTAssertFalse(waiter.wait(upTo: 0.001))
    }

    func testInterruptedExitEventWaitCanResumeWithoutLosingQueue() throws {
        let waiter = SubprocessExitWaiter(processID: getpid())
        _ = waiter.wait(upTo: 0.001)
        try XCTSkipUnless(waiter.usesEventWaiting, "Process/timer events unavailable on this host.")
        var action = sigaction()
        var original = sigaction()
        sigemptyset(&action.sa_mask)
        action.__sigaction_u.__sa_handler = { _ in }
        // No SA_RESTART: interrupt this exact waiting thread, not an arbitrary
        // test runner thread. Restore the process-wide handler before return.
        guard sigaction(SIGUSR1, &action, &original) == 0 else {
            throw NSError(domain: "SubprocessTests", code: Int(errno))
        }
        let signal = SubprocessTestSignalDelivery(thread: pthread_self())
        defer {
            // Cancel under the same lock used to send, before restoring the
            // handler. A delayed callback must never signal after test return.
            signal.cancel()
            sigaction(SIGUSR1, &original, nil)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            signal.send()
        }
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertFalse(waiter.wait(upTo: 0.5))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.4)
        XCTAssertTrue(waiter.usesEventWaiting)
        XCTAssertFalse(waiter.wait(upTo: 0.001))
    }

    func testCapturesImmediateBinaryOutputAndNonzeroStatus() throws {
        let result = try runSubprocess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '\\000\\001\\377'; printf 'failure' >&2; exit 7"],
            timeout: 2
        )
        XCTAssertEqual(result.standardOutput, Data([0, 1, 255]))
        XCTAssertEqual(result.standardError, Data("failure".utf8))
        XCTAssertEqual(result.status, 7)
        XCTAssertFalse(result.timedOut)
    }

    func testExtremeTimeoutsDoNotTrapOrChangeSuccessfulExit() throws {
        for timeout in [TimeInterval.infinity, TimeInterval.greatestFiniteMagnitude] {
            let result = try runSubprocess(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["0.02"], timeout: timeout
            )
            XCTAssertEqual(result.status, 0)
            XCTAssertFalse(result.timedOut)
        }
    }

    func testAlreadyExitedChildrenAreReapedWithoutMissingOutput() throws {
        for index in 0..<40 {
            let result = try runSubprocess(
                executable: URL(fileURLWithPath: "/usr/bin/printf"),
                arguments: ["%s", String(index)],
                timeout: 2
            )
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.standardOutput, Data(String(index).utf8))
            XCTAssertFalse(result.timedOut)
        }
    }

    func testFileBackedInputAndLargeOutputDoNotDeadlock() throws {
        let input = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0) })
        let result = try runSubprocess(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [], standardInput: input, timeout: 3
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput, input)
        XCTAssertTrue(result.standardError.isEmpty)
        XCTAssertFalse(result.timedOut)
    }

    func testObserverReceivesOutputWhileProcessIsStillRunningAndFinalBytes() throws {
        var observations: [Data] = []
        let result = try runSubprocess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf early; sleep 0.4; printf late"],
            outputObserver: { output, _ in observations.append(output) }, timeout: 2
        )
        XCTAssertEqual(result.standardOutput, Data("earlylate".utf8))
        XCTAssertTrue(observations.contains(Data("early".utf8)))
        XCTAssertEqual(observations.last, result.standardOutput)
        XCTAssertFalse(result.timedOut)
    }

    func testTimeoutKillsTermResistantProcessGroup() throws {
        let started = ProcessInfo.processInfo.systemUptime
        let result = try runSubprocess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; sleep 30 & child=$!; printf '%s' \"$child\"; wait"],
            timeout: 0.15
        )
        XCTAssertTrue(result.timedOut)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 4)
        let child = try XCTUnwrap(Int32(String(decoding: result.standardOutput, as: UTF8.self)))
        // The owned group has received SIGKILL. Give the OS a short interval to
        // reap an orphaned child, rather than confusing its zombie with a leak.
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while kill(child, 0) == 0 && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let childResult = kill(child, 0)
        let childError = errno
        XCTAssertEqual(childResult, -1)
        XCTAssertEqual(childError, ESRCH)
    }

    func testCancellationBeforeStartAndWhileRunningRemainsPrompt() throws {
        for beforeStart in [true, false] {
            let cancellation = MCPAuthenticationCancellation()
            if beforeStart {
                cancellation.cancel()
            } else {
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                    cancellation.cancel()
                }
            }
            let started = ProcessInfo.processInfo.systemUptime
            let result = try runSubprocess(
                executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"],
                cancellation: cancellation, timeout: 3
            )
            XCTAssertFalse(result.timedOut)
            XCTAssertNotEqual(result.status, 0)
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 1)
        }
    }

    func testPerformanceImmediateSubprocesses() throws {
        guard ProcessInfo.processInfo.environment["METAGENT_RUN_SUBPROCESS_PERFORMANCE_TESTS"] == "1" else {
            return
        }
        let availability = SubprocessExitWaiter(processID: getpid())
        _ = availability.wait(upTo: 0.001)
        try XCTSkipUnless(availability.usesEventWaiting,
            "Kernel process/timer events unavailable; the correctness fallback retains polling.")
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<40 {
            let result = try runSubprocess(
                executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: 2
            )
            XCTAssertEqual(result.status, 0)
            XCTAssertFalse(result.timedOut)
        }
        let seconds = ProcessInfo.processInfo.systemUptime - started
        print("METAGENT_SUBPROCESS_TIMING {\"commands\":40,\"seconds\":\(seconds)}")
        // This opt-in rail specifically catches the old artificial 50 ms
        // completion tick. It is not a universal host performance guarantee.
        let configuredMultiplier = Double(
            ProcessInfo.processInfo.environment["METAGENT_PERFORMANCE_BUDGET_MULTIPLIER"] ?? ""
        ) ?? 1
        let multiplier = configuredMultiplier.isFinite ? min(max(configuredMultiplier, 0.5), 10) : 1
        XCTAssertLessThan(seconds, 1.6 * multiplier)
    }
}

private final class SubprocessTestSignalDelivery: @unchecked Sendable {
    private let thread: pthread_t
    private let lock = NSLock()
    private var active = true

    init(thread: pthread_t) { self.thread = thread }

    func send() {
        lock.lock()
        defer { lock.unlock() }
        if active { pthread_kill(thread, SIGUSR1) }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        active = false
    }
}
