import Foundation
import TelegramCore
import AccountContext
import SwiftSignalKit

enum GiftBulkActionError: Equatable {
    case invalidSelection
    case invalidRecipient
    case unavailableGift
    case invalidPrice
    case insufficientBalance(required: Int64)
    case balanceUnavailable
    case recipientDisallowed
    case timedOut
    case verificationRequired
    case generic
}

enum GiftBulkSelectionRestriction: Equatable {
    case missingReference
    case refunded
    case requiresCollectible
    case alreadyUpgraded
    case upgradeUnavailable
    case hostedGift
    case burnedGift
    case transferCooldown(until: Int32)
}

struct GiftBulkQuotedGift {
    let reference: StarGiftReference
    let formId: Int64?
    let cost: Int64
    let keepOriginalInfo: Bool
}

struct GiftBulkQuote {
    let mode: GiftBulkActionMode
    let items: [GiftBulkQuotedGift]
    let recipientId: EnginePeer.Id?
    let totalCost: Int64
}

struct GiftBulkProgress {
    let completed: Int
    let total: Int
    let isFinished: Bool
    let error: GiftBulkActionError?
}

enum GiftBulkActions {
    static func isEligible(gift: ProfileGiftsContext.State.StarGift, mode: GiftBulkActionMode, now: Int32) -> Bool {
        return self.selectionRestriction(gift: gift, mode: mode, now: now) == nil
    }

    static func selectionRestriction(gift: ProfileGiftsContext.State.StarGift, mode: GiftBulkActionMode, now: Int32) -> GiftBulkSelectionRestriction? {
        switch (mode, gift.gift) {
        case let (.transfer, .unique(uniqueGift)):
            if uniqueGift.hostPeerId != nil {
                return .hostedGift
            }
            if uniqueGift.flags.contains(.isBurned) {
                return .burnedGift
            }
            if gift.isRefunded {
                return .refunded
            }
            if gift.reference == nil {
                return .missingReference
            }
            if let canTransferDate = gift.canTransferDate, now < canTransferDate {
                return .transferCooldown(until: canTransferDate)
            }
            return nil
        case (.transfer, .generic):
            return .requiresCollectible
        case (.upgrade, .generic):
            if gift.isRefunded {
                return .refunded
            }
            if !gift.canUpgrade {
                return .upgradeUnavailable
            }
            if gift.reference == nil {
                return .missingReference
            }
            return nil
        case (.upgrade, .unique):
            return .alreadyUpgraded
        }
    }

    static func prepare(
        context: AccountContext,
        gifts: [ProfileGiftsContext.State.StarGift],
        mode: GiftBulkActionMode,
        recipientId: EnginePeer.Id?,
        keepOriginalInfo: Bool
    ) -> Signal<GiftBulkQuote, GiftBulkActionError> {
        return Signal { subscriber in
            guard !gifts.isEmpty else {
                subscriber.putError(.invalidSelection)
                return EmptyDisposable
            }
            if mode == .transfer, recipientId == nil || recipientId == context.account.peerId {
                subscriber.putError(.invalidRecipient)
                return EmptyDisposable
            }

            let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
            var references = Set<StarGiftReference>()
            var snapshot: [ProfileGiftsContext.State.StarGift] = []
            for gift in gifts {
                guard self.isEligible(gift: gift, mode: mode, now: now), let reference = gift.reference else {
                    subscriber.putError(.unavailableGift)
                    return EmptyDisposable
                }
                if references.insert(reference).inserted {
                    snapshot.append(gift)
                }
            }

            var quotedItems: [GiftBulkQuotedGift] = []
            return giftBulkSequential(
                items: snapshot,
                queue: Queue.mainQueue(),
                missingResultError: GiftBulkActionError.generic,
                operation: { gift in
                    return self.quoteGift(context: context, gift: gift, mode: mode, recipientId: recipientId, keepOriginalInfo: keepOriginalInfo)
                    |> take(1)
                    |> timeout(30.0, queue: Queue.mainQueue(), alternate: .fail(.timedOut))
                }
            ).start(next: { event in
                switch event {
                case let .value(_, value):
                    quotedItems.append(value)
                case let .finished(_, error):
                    if let error {
                        subscriber.putError(error)
                    } else if let totalCost = GiftBulkPrice.sum(quotedItems.map(\.cost)) {
                        subscriber.putNext(GiftBulkQuote(mode: mode, items: quotedItems, recipientId: recipientId, totalCost: totalCost))
                        subscriber.putCompletion()
                    } else {
                        subscriber.putError(.invalidPrice)
                    }
                }
            })
        }
    }

    static func execute(
        context: AccountContext,
        profileGifts: ProfileGiftsContext,
        quote: GiftBulkQuote
    ) -> Signal<GiftBulkProgress, NoError> {
        return Signal { subscriber in
            let finish: (GiftBulkActionError) -> Disposable = { error in
                subscriber.putNext(GiftBulkProgress(completed: 0, total: quote.items.count, isFinished: true, error: error))
                subscriber.putCompletion()
                return EmptyDisposable
            }
            guard !quote.items.isEmpty, Set(quote.items.map(\.reference)).count == quote.items.count else {
                return finish(.invalidSelection)
            }
            guard let cost = GiftBulkPrice.sum(quote.items.map(\.cost)), cost == quote.totalCost else {
                return finish(.invalidPrice)
            }
            if quote.mode == .transfer, quote.recipientId == nil || quote.recipientId == context.account.peerId {
                return finish(.invalidRecipient)
            }
            if cost > 0 {
                guard let starsState = context.starsContext?.currentState else {
                    return finish(.balanceUnavailable)
                }
                guard starsState.balance >= StarsAmount(value: cost, nanos: 0) else {
                    return finish(.insufficientBalance(required: cost))
                }
            }

            subscriber.putNext(GiftBulkProgress(completed: 0, total: quote.items.count, isFinished: false, error: nil))
            return giftBulkSequential(
                items: quote.items,
                queue: Queue.mainQueue(),
                missingResultError: GiftBulkActionError.generic,
                operation: { gift in
                    return self.perform(context: context, profileGifts: profileGifts, mode: quote.mode, recipientId: quote.recipientId, gift: gift)
                    |> take(1)
                    |> timeout(60.0, queue: Queue.mainQueue(), alternate: .fail(.timedOut))
                }
            ).start(next: { event in
                switch event {
                case let .value(index, _):
                    subscriber.putNext(GiftBulkProgress(completed: index + 1, total: quote.items.count, isFinished: false, error: nil))
                case let .finished(completed, error):
                    subscriber.putNext(GiftBulkProgress(completed: completed, total: quote.items.count, isFinished: true, error: error))
                    subscriber.putCompletion()
                }
            })
        }
    }

    private static func quoteGift(
        context: AccountContext,
        gift: ProfileGiftsContext.State.StarGift,
        mode: GiftBulkActionMode,
        recipientId: EnginePeer.Id?,
        keepOriginalInfo: Bool
    ) -> Signal<GiftBulkQuotedGift, GiftBulkActionError> {
        guard let reference = gift.reference else {
            return .fail(.unavailableGift)
        }
        let effectiveKeepOriginalInfo = keepOriginalInfo && !gift.nameHidden && !gift.upgradeSeparate
        let source: BotPaymentInvoiceSource
        switch mode {
        case .transfer:
            guard let recipientId else {
                return .fail(.invalidRecipient)
            }
            guard (gift.transferStars ?? 0) >= 0 else {
                return .fail(.invalidPrice)
            }
            if (gift.transferStars ?? 0) == 0 {
                return .single(GiftBulkQuotedGift(reference: reference, formId: nil, cost: 0, keepOriginalInfo: effectiveKeepOriginalInfo))
            }
            source = .starGiftTransfer(reference: reference, toPeerId: recipientId)
        case .upgrade:
            if let upgradeStars = gift.upgradeStars, upgradeStars > 0 {
                return .single(GiftBulkQuotedGift(reference: reference, formId: nil, cost: 0, keepOriginalInfo: effectiveKeepOriginalInfo))
            }
            source = .starGiftUpgrade(keepOriginalInfo: effectiveKeepOriginalInfo, reference: reference)
        }

        return context.engine.payments.fetchBotPaymentForm(source: source, themeParams: nil)
        |> map(Optional.init)
        |> `catch` { error -> Signal<BotPaymentForm?, GiftBulkActionError> in
            switch error {
            case .noPaymentNeeded:
                return .single(nil)
            case .disallowedStarGift:
                return .fail(.recipientDisallowed)
            default:
                return .fail(.generic)
            }
        }
        |> mapToSignal { form -> Signal<GiftBulkQuotedGift, GiftBulkActionError> in
            guard let form else {
                return .single(GiftBulkQuotedGift(reference: reference, formId: nil, cost: 0, keepOriginalInfo: effectiveKeepOriginalInfo))
            }
            guard let cost = GiftBulkPrice.total(currency: form.invoice.currency, amounts: form.invoice.prices.map(\.amount)) else {
                return .fail(.invalidPrice)
            }
            return .single(GiftBulkQuotedGift(reference: reference, formId: form.id, cost: cost, keepOriginalInfo: effectiveKeepOriginalInfo))
        }
    }

    private static func perform(
        context: AccountContext,
        profileGifts: ProfileGiftsContext,
        mode: GiftBulkActionMode,
        recipientId: EnginePeer.Id?,
        gift: GiftBulkQuotedGift
    ) -> Signal<Void, GiftBulkActionError> {
        switch mode {
        case .transfer:
            guard let recipientId else {
                return .fail(.invalidRecipient)
            }
            if let formId = gift.formId {
                return context.engine.payments.sendStarsPaymentForm(
                    formId: formId,
                    source: .starGiftTransfer(reference: gift.reference, toPeerId: recipientId)
                )
                |> mapError { error -> GiftBulkActionError in
                    if case .disallowedStarGift = error {
                        return .recipientDisallowed
                    }
                    return .generic
                }
                |> mapToSignal { result -> Signal<Void, GiftBulkActionError> in
                    guard case .done = result else {
                        return .fail(.verificationRequired)
                    }
                    return .single(())
                }
            } else {
                guard gift.cost == 0 else {
                    return .fail(.invalidPrice)
                }
                return Signal { subscriber in
                    return context.engine.payments.transferStarGift(prepaid: true, reference: gift.reference, peerId: recipientId).start(error: { error in
                        if case .disallowedStarGift = error {
                            subscriber.putError(.recipientDisallowed)
                        } else {
                            subscriber.putError(.generic)
                        }
                    }, completed: {
                        subscriber.putNext(())
                        subscriber.putCompletion()
                    })
                }
            }
        case .upgrade:
            guard gift.formId != nil || gift.cost == 0 else {
                return .fail(.invalidPrice)
            }
            return profileGifts.upgradeStarGift(formId: gift.formId, reference: gift.reference, keepOriginalInfo: gift.keepOriginalInfo)
            |> mapError { _ -> GiftBulkActionError in
                return .generic
            }
            |> map { _ in () }
        }
    }
}
