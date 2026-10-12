import Foundation
import SwiftSignalKit

@main
enum GiftBulkActionsSupportTests {
    enum TestError: Equatable {
        case failed
        case missingResult
    }

    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        self.assertions += 1
        precondition(condition(), message)
    }

    static func wait(_ semaphore: DispatchSemaphore) {
        check(semaphore.wait(timeout: .now() + 5.0) == .success, "Timed out waiting for fake operations")
    }

    static func main() {
        self.priceTests()
        self.synchronousQueueTests()
        self.errorTests()
        self.cancellationTests()
        print("Gift bulk action support: \(self.assertions) assertions passed")
    }

    static func priceTests() {
        check(GiftBulkPrice.total(currency: "XTR", amounts: [100, 25, 0]) == 125, "Sum every invoice price")
        check(GiftBulkPrice.total(currency: "XTR", amounts: [0]) == 0, "Zero-cost Stars invoice is valid")
        check(GiftBulkPrice.total(currency: "USD", amounts: [100]) == nil, "Reject other currencies")
        check(GiftBulkPrice.total(currency: "TON", amounts: [100]) == nil, "Reject TON invoice")
        check(GiftBulkPrice.total(currency: "XTR", amounts: []) == nil, "Missing invoice price is not free")
        check(GiftBulkPrice.total(currency: "XTR", amounts: [-1, 2]) == nil, "Reject negative price even with positive total")
        check(GiftBulkPrice.total(currency: "XTR", amounts: [Int64.max, 1]) == nil, "Invoice overflow is rejected")
        check(GiftBulkPrice.sum([Int64.max, 0]) == Int64.max, "Largest representable total is valid")
        check(GiftBulkPrice.sum([Int64.max, 1]) == nil, "Batch overflow is rejected")
        check(GiftBulkPrice.sum([0, -1]) == nil, "Reject negative batch cost")
        check(GiftBulkPrice.sum([]) == 0, "Empty sum is zero; selection validation handles empty batches")
    }

    static func synchronousQueueTests() {
        let queue = Queue(name: "GiftBulkActionsTests.synchronous")
        let done = DispatchSemaphore(value: 0)
        let items = Array(0 ..< 1000)
        var started: [Int] = []
        var values: [Int] = []
        var active = 0
        var maximumActive = 0
        var terminalCompleted: Int?
        var terminalError: TestError?
        let disposable = giftBulkSequential(items: items, queue: queue, missingResultError: TestError.missingResult, operation: { item in
            return Signal<Int, TestError> { subscriber in
                started.append(item)
                active += 1
                maximumActive = max(maximumActive, active)
                subscriber.putNext(item)
                subscriber.putCompletion()
                return ActionDisposable {
                    active -= 1
                }
            }
        }).start(next: { event in
            switch event {
            case let .value(index, value):
                check(index == value, "Preserve item index")
                values.append(value)
            case let .finished(completed, error):
                terminalCompleted = completed
                terminalError = error
            }
        }, completed: {
            done.signal()
        })
        wait(done)
        disposable.dispose()
        queue.sync {
            check(started == items, "Synchronous operations all start in order")
            check(values == items, "Synchronous completions never skip or cancel the next operation")
            check(terminalCompleted == items.count && terminalError == nil, "Report complete batch")
            check(maximumActive == 1 && active == 0, "Only one operation remains active at a time")
        }

        let emptyDone = DispatchSemaphore(value: 0)
        var emptyFactoryCalled = false
        let emptyDisposable = giftBulkSequential(items: [Int](), queue: queue, missingResultError: TestError.missingResult, operation: { _ -> Signal<Int, TestError> in
            emptyFactoryCalled = true
            return .single(0)
        }).start(next: { event in
            if case let .finished(completed, error) = event {
                check(completed == 0 && error == nil, "Empty queue terminates without work")
            }
        }, completed: { emptyDone.signal() })
        wait(emptyDone)
        emptyDisposable.dispose()
        check(!emptyFactoryCalled, "Empty queue starts no operation")
    }

    static func errorTests() {
        let queue = Queue(name: "GiftBulkActionsTests.error")
        let done = DispatchSemaphore(value: 0)
        var started: [Int] = []
        var received: [Int] = []
        var result: (Int, TestError?)?
        let disposable = giftBulkSequential(items: [0, 1, 2, 3], queue: queue, missingResultError: TestError.missingResult, operation: { item -> Signal<Int, TestError> in
            started.append(item)
            return item == 2 ? .fail(.failed) : .single(item)
        }).start(next: { event in
            switch event {
            case let .value(_, value): received.append(value)
            case let .finished(completed, error): result = (completed, error)
            }
        }, completed: { done.signal() })
        wait(done)
        disposable.dispose()
        check(started == [0, 1, 2], "Stop before the operation after a failure")
        check(received == [0, 1], "Only confirmed operations are reported")
        check(result?.0 == 2 && result?.1 == .failed, "Keep partial progress and first error")

        let missingDone = DispatchSemaphore(value: 0)
        var missingStarted = 0
        var missingResult: (Int, TestError?)?
        let missingDisposable = giftBulkSequential(items: [0, 1], queue: queue, missingResultError: TestError.missingResult, operation: { _ -> Signal<Int, TestError> in
            missingStarted += 1
            return .complete()
        }).start(next: { event in
            if case let .finished(completed, error) = event { missingResult = (completed, error) }
        }, completed: { missingDone.signal() })
        wait(missingDone)
        missingDisposable.dispose()
        check(missingStarted == 1, "No-result completion stops the queue")
        check(missingResult?.0 == 0 && missingResult?.1 == .missingResult, "No-result completion is not a successful operation")

        let duplicateDone = DispatchSemaphore(value: 0)
        var duplicateValues = 0
        let duplicateDisposable = giftBulkSequential(items: [0], queue: queue, missingResultError: TestError.missingResult, operation: { _ in
            return Signal<Int, TestError> { subscriber in
                subscriber.putNext(0)
                subscriber.putNext(0)
                subscriber.putCompletion()
                return EmptyDisposable
            }
        }).start(next: { event in
            if case .value = event { duplicateValues += 1 }
        }, completed: { duplicateDone.signal() })
        wait(duplicateDone)
        duplicateDisposable.dispose()
        check(duplicateValues == 1, "Duplicate result emission never counts a gift twice")
    }

    static func cancellationTests() {
        let queue = Queue(name: "GiftBulkActionsTests.cancel")
        let gate = DispatchSemaphore(value: 0)
        queue.justDispatch { gate.wait() }
        var beforeStartCalled = false
        let beforeStart = giftBulkSequential(items: [0], queue: queue, missingResultError: TestError.missingResult, operation: { _ -> Signal<Int, TestError> in
            beforeStartCalled = true
            return .single(0)
        }).start()
        beforeStart.dispose()
        gate.signal()
        queue.sync {
            check(!beforeStartCalled, "Cancellation before dispatch prevents all work")
        }

        let started = DispatchSemaphore(value: 0)
        var calls = 0
        var cancelledOperation = false
        var reportedFinish = false
        let duringOperation = giftBulkSequential(items: [0, 1], queue: queue, missingResultError: TestError.missingResult, operation: { _ in
            return Signal<Int, TestError> { _ in
                calls += 1
                started.signal()
                return ActionDisposable { cancelledOperation = true }
            }
        }).start(next: { event in
            if case .finished = event { reportedFinish = true }
        })
        wait(started)
        duringOperation.dispose()
        queue.sync {
            check(calls == 1 && cancelledOperation, "Cancellation disposes active work and starts no next operation")
            check(!reportedFinish, "Cancelled subscriber receives no false success")
        }

        let progressGate = DispatchSemaphore(value: 0)
        let progress = DispatchSemaphore(value: 0)
        queue.justDispatch { progressGate.wait() }
        var progressCalls = 0
        var afterProgress: Disposable?
        afterProgress = giftBulkSequential(items: [0, 1, 2], queue: queue, missingResultError: TestError.missingResult, operation: { item -> Signal<Int, TestError> in
            progressCalls += 1
            return .single(item)
        }).start(next: { event in
            if case .value = event {
                afterProgress?.dispose()
                progress.signal()
            }
        })
        progressGate.signal()
        wait(progress)
        queue.sync {
            check(progressCalls == 1, "Cancellation from progress callback stops the synchronous chain")
        }
    }
}
