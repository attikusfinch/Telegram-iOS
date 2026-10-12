import Foundation
import SwiftSignalKit

enum GiftBulkPrice {
    static func total(currency: String, amounts: [Int64]) -> Int64? {
        guard currency == "XTR", !amounts.isEmpty else {
            return nil
        }
        return self.sum(amounts)
    }

    static func sum(_ amounts: [Int64]) -> Int64? {
        var result: Int64 = 0
        for amount in amounts {
            guard amount >= 0 else {
                return nil
            }
            let (updated, overflow) = result.addingReportingOverflow(amount)
            guard !overflow else {
                return nil
            }
            result = updated
        }
        return result
    }
}

enum GiftBulkSequentialEvent<Value, Failure> {
    case value(index: Int, value: Value)
    case finished(completed: Int, error: Failure?)
}

/// Starts one operation at a time. Advancing is always dispatched so a synchronous
/// completion cannot replace a newer operation's disposable with an older one.
func giftBulkSequential<Item, Value, Failure>(
    items: [Item],
    queue: Queue,
    missingResultError: Failure,
    operation: @escaping (Item) -> Signal<Value, Failure>
) -> Signal<GiftBulkSequentialEvent<Value, Failure>, NoError> {
    return Signal { subscriber in
        let runner = GiftBulkSequentialRunner(
            items: items,
            queue: queue,
            missingResultError: missingResultError,
            operation: operation,
            subscriber: subscriber
        )
        runner.start()
        return ActionDisposable {
            runner.cancel()
        }
    }
}

private final class GiftBulkSequentialRunner<Item, Value, Failure> {
    private let items: [Item]
    private let queue: Queue
    private let missingResultError: Failure
    private let operation: (Item) -> Signal<Value, Failure>
    private let subscriber: Subscriber<GiftBulkSequentialEvent<Value, Failure>, NoError>
    private let disposable = MetaDisposable()
    private let isCancelled = Atomic<Bool>(value: false)
    private var index = 0
    private var isFinished = false

    init(
        items: [Item],
        queue: Queue,
        missingResultError: Failure,
        operation: @escaping (Item) -> Signal<Value, Failure>,
        subscriber: Subscriber<GiftBulkSequentialEvent<Value, Failure>, NoError>
    ) {
        self.items = items
        self.queue = queue
        self.missingResultError = missingResultError
        self.operation = operation
        self.subscriber = subscriber
    }

    func start() {
        self.queue.justDispatch { [weak self] in
            self?.advance()
        }
    }

    func cancel() {
        let _ = self.isCancelled.swap(true)
        self.disposable.dispose()
    }

    private func advance() {
        guard !self.isCancelled.with({ $0 }), !self.isFinished else {
            return
        }
        guard self.index < self.items.count else {
            self.finish(error: nil)
            return
        }

        let operationIndex = self.index
        var receivedResult = false
        self.disposable.set((self.operation(self.items[operationIndex])
        |> deliverOn(self.queue)).start(next: { [weak self] value in
            guard let self, !self.isCancelled.with({ $0 }), !self.isFinished, !receivedResult else {
                return
            }
            receivedResult = true
            self.subscriber.putNext(.value(index: operationIndex, value: value))
        }, error: { [weak self] error in
            self?.finish(error: error)
        }, completed: { [weak self] in
            guard let self, !self.isCancelled.with({ $0 }), !self.isFinished else {
                return
            }
            guard receivedResult else {
                self.finish(error: self.missingResultError)
                return
            }
            self.index += 1
            self.queue.justDispatch { [weak self] in
                self?.advance()
            }
        }))
    }

    private func finish(error: Failure?) {
        guard !self.isCancelled.with({ $0 }), !self.isFinished else {
            return
        }
        self.isFinished = true
        self.subscriber.putNext(.finished(completed: self.index, error: error))
        self.subscriber.putCompletion()
    }
}
