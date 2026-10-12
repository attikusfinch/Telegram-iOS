import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

enum GiftBulkActionMode: Equatable {
    case transfer
    case upgrade
}

extension GiftBulkActionError: Error {}

@main
enum GiftBulkActionsTests {
    static var assertions = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        precondition(value(), message)
    }
    static func pump(until finished: @autoclosure () -> Bool) {
        let deadline = Date().addingTimeInterval(5)
        while !finished(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        check(finished(), "Fake API test timed out")
    }
    static func prepare(_ context: AccountContext, _ gifts: [ProfileGiftsContext.State.StarGift], _ mode: GiftBulkActionMode, _ recipient: EnginePeer.Id? = nil, keep: Bool = true) -> Result<GiftBulkQuote, GiftBulkActionError> {
        var result: Result<GiftBulkQuote, GiftBulkActionError>?
        let disposable = GiftBulkActions.prepare(context: context, gifts: gifts, mode: mode, recipientId: recipient, keepOriginalInfo: keep).start(next: { result = .success($0) }, error: { result = .failure($0) })
        pump(until: result != nil)
        disposable.dispose()
        return result!
    }
    static func execute(_ context: AccountContext, _ profile: ProfileGiftsContext, _ quote: GiftBulkQuote) -> [GiftBulkProgress] {
        var progress: [GiftBulkProgress] = []
        var finished = false
        let disposable = GiftBulkActions.execute(context: context, profileGifts: profile, quote: quote).start(next: { progress.append($0) }, completed: { finished = true })
        pump(until: finished)
        disposable.dispose()
        return progress
    }
    static func gift(_ id: Int, unique: Bool = true, cost: Int64? = nil, prepaid: Int64? = nil, hidden: Bool = false, separate: Bool = false) -> ProfileGiftsContext.State.StarGift {
        return .init(gift: unique ? .unique(.init()) : .generic, reference: .test(id), canUpgrade: !unique, transferStars: cost, upgradeStars: prepaid, nameHidden: hidden, upgradeSeparate: separate)
    }
    static func quote(_ result: Result<GiftBulkQuote, GiftBulkActionError>) -> GiftBulkQuote {
        guard case let .success(quote) = result else { preconditionFailure("Expected a valid quote") }
        return quote
    }
    static func main() {
        eligibility()
        quotes()
        execution()
        print("Gift bulk API orchestration: \(assertions) assertions passed with test-only account/payment modules")
    }
    static func eligibility() {
        check(GiftBulkActions.isEligible(gift: gift(1), mode: .transfer, now: 100), "Nil transfer cost is free, not unavailable")
        check(!GiftBulkActions.isEligible(gift: gift(1), mode: .upgrade, now: 100), "Collectible is already upgraded")
        check(!GiftBulkActions.isEligible(gift: gift(1, unique: false), mode: .transfer, now: 100), "Regular gift cannot be transferred")
        check(GiftBulkActions.isEligible(gift: gift(1, unique: false), mode: .upgrade, now: 100), "Regular upgradable gift is eligible")
        check(!GiftBulkActions.isEligible(gift: .init(gift: .unique(.init(hostPeerId: 99)), reference: .test(1)), mode: .transfer, now: 100), "Hosted gift isn't owned")
        check(!GiftBulkActions.isEligible(gift: .init(gift: .unique(.init(flags: .isBurned)), reference: .test(1)), mode: .transfer, now: 100), "Burned gift unavailable")
        check(!GiftBulkActions.isEligible(gift: .init(gift: .unique(.init()), reference: .test(1), canTransferDate: 101), mode: .transfer, now: 100), "Cooldown blocks transfer")
        check(GiftBulkActions.isEligible(gift: .init(gift: .unique(.init()), reference: .test(1), canTransferDate: 100), mode: .transfer, now: 100), "Cooldown ends at exact timestamp")
        check(!GiftBulkActions.isEligible(gift: .init(gift: .generic, reference: .test(1), isRefunded: true, canUpgrade: true), mode: .upgrade, now: 100), "Refunded gift blocked")
        check(!GiftBulkActions.isEligible(gift: .init(gift: .generic, reference: nil, canUpgrade: true), mode: .upgrade, now: 100), "Reference is required")

        check(GiftBulkActions.selectionRestriction(gift: gift(1), mode: .transfer, now: 100) == nil, "Eligible collectible has no restriction")
        check(GiftBulkActions.selectionRestriction(gift: gift(1, unique: false), mode: .upgrade, now: 100) == nil, "Eligible regular gift has no restriction")
        check(GiftBulkActions.selectionRestriction(gift: gift(1, unique: false), mode: .transfer, now: 100) == .requiresCollectible, "Explain regular gifts cannot be transferred")
        check(GiftBulkActions.selectionRestriction(gift: gift(1), mode: .upgrade, now: 100) == .alreadyUpgraded, "Explain collectible is already upgraded")
        check(GiftBulkActions.selectionRestriction(gift: .init(gift: .generic, reference: .test(1)), mode: .upgrade, now: 100) == .upgradeUnavailable, "Explain unavailable regular-gift upgrade")
        check(GiftBulkActions.selectionRestriction(gift: .init(gift: .generic, reference: nil), mode: .upgrade, now: 100) == .upgradeUnavailable, "Unavailable upgrade precedes absent reference")
        check(GiftBulkActions.selectionRestriction(gift: .init(gift: .generic, reference: nil, canUpgrade: true), mode: .upgrade, now: 100) == .missingReference, "Upgradable gift without reference explains reload requirement")
        check(GiftBulkActions.selectionRestriction(gift: .init(gift: .unique(.init()), reference: nil), mode: .transfer, now: 100) == .missingReference, "Collectible without reference explains reload requirement")
        check(GiftBulkActions.selectionRestriction(gift: .init(gift: .unique(.init(hostPeerId: 99)), reference: nil), mode: .transfer, now: 100) == .hostedGift, "Hosting restriction precedes absent reference")
        check(GiftBulkActions.selectionRestriction(gift: .init(gift: .unique(.init(flags: .isBurned)), reference: nil), mode: .transfer, now: 100) == .burnedGift, "Burned restriction precedes absent reference")
        check(GiftBulkActions.selectionRestriction(gift: .init(gift: .generic, reference: nil, isRefunded: true, canUpgrade: true), mode: .upgrade, now: 100) == .refunded, "Refund explains unavailable upgrade before absent reference")
        check(GiftBulkActions.selectionRestriction(gift: .init(gift: .unique(.init()), reference: .test(1), isRefunded: true), mode: .transfer, now: 100) == .refunded, "Refund explains unavailable transfer")
        check(GiftBulkActions.selectionRestriction(gift: .init(gift: .unique(.init()), reference: .test(1), canTransferDate: 101), mode: .transfer, now: 100) == .transferCooldown(until: 101), "Cooldown reason retains exact server timestamp")
        check(GiftBulkActions.selectionRestriction(gift: .init(gift: .unique(.init()), reference: .test(1), canTransferDate: 100), mode: .transfer, now: 100) == nil, "Cooldown reason expires at the exact timestamp")

        let context = AccountContext()
        let blockedGift = ProfileGiftsContext.State.StarGift(gift: .unique(.init()), reference: .test(1), canTransferDate: Int32.max)
        if case let .failure(error) = prepare(context, [blockedGift], .transfer, 2) {
            check(error == .unavailableGift, "Reason-bearing selection still blocks execution preparation during cooldown")
        } else {
            preconditionFailure("Restricted gift unexpectedly prepared")
        }
        check(context.engine.payments.quotedSources.isEmpty && context.engine.payments.paidCalls.isEmpty && context.engine.payments.freeTransferCalls.isEmpty, "Blocked selection sends no quote, payment, or gift request")
    }
    static func quotes() {
        let context = AccountContext()
        context.engine.payments.fetch = { _ in .single(.init(id: 777, amounts: [100, 25])) }
        let transfer = quote(prepare(context, [gift(1, cost: 999), gift(2), gift(1, cost: 999)], .transfer, 2))
        check(transfer.items.count == 2, "Deduplicate references before spending")
        check(transfer.totalCost == 125, "Use server invoice total, not stale transfer metadata")
        check(transfer.items[0].formId == 777 && transfer.items[1].formId == nil, "Keep exact paid form and free path")
        check(context.engine.payments.paidCalls.isEmpty && context.engine.payments.freeTransferCalls.isEmpty, "Quote never sends anything")
        check(context.engine.payments.quotedSources == [.starGiftTransfer(reference: .test(1), toPeerId: 2)], "Only payable transfer needs a form")
        let upgrade = quote(prepare(context, [gift(3, unique: false), gift(4, unique: false, prepaid: 100), gift(5, unique: false, hidden: true), gift(6, unique: false, separate: true)], .upgrade))
        check(upgrade.totalCost == 375, "Prepaid upgrade contributes no new cost")
        check(upgrade.items.map(\.keepOriginalInfo) == [true, true, false, false], "Hidden/separately prepaid gift details stay excluded")
        check(upgrade.items[1].formId == nil, "Already-paid upgrade uses direct operation")
        check(context.engine.payments.quotedSources.suffix(3) == [.starGiftUpgrade(keepOriginalInfo: true, reference: .test(3)), .starGiftUpgrade(keepOriginalInfo: false, reference: .test(5)), .starGiftUpgrade(keepOriginalInfo: false, reference: .test(6))], "Quote uses exact effective information flags")
        context.engine.payments.fetch = { _ in .fail(.noPaymentNeeded) }
        check(quote(prepare(context, [gift(7, cost: 100)], .transfer, 2)).totalCost == 0, "NO_PAYMENT_NEEDED becomes free")
        context.engine.payments.fetch = { _ in .fail(.disallowedStarGift) }
        if case let .failure(error) = prepare(context, [gift(7, cost: 100)], .transfer, 2) { check(error == .recipientDisallowed, "Explain recipient restriction") } else { preconditionFailure() }
        context.engine.payments.fetch = { _ in .single(.init(id: 9, currency: "TON", amounts: [100])) }
        if case let .failure(error) = prepare(context, [gift(7, cost: 100)], .transfer, 2) { check(error == .invalidPrice, "Never silently accept different payment currency") } else { preconditionFailure() }
        if case let .failure(error) = prepare(context, [gift(7)], .transfer, 1) { check(error == .invalidRecipient, "Cannot transfer to owner") } else { preconditionFailure() }
    }
    static func execution() {
        let context = AccountContext()
        let profile = ProfileGiftsContext()
        context.engine.payments.fetch = { _ in .single(.init(id: 888, amounts: [100])) }
        let transfer = quote(prepare(context, [gift(1, cost: 100), gift(2), gift(3, cost: 100)], .transfer, 2))
        let progress = execute(context, profile, transfer)
        check(progress.last?.completed == 3 && progress.last?.error == nil, "Success requires all operations confirmed")
        check(context.engine.payments.paidCalls.map { $0.0 } == [888, 888], "Submit confirmed form ID without refetching")
        check(context.engine.payments.freeTransferCalls.count == 1 && context.engine.payments.freeTransferCalls[0].0, "Direct free transfer is prepaid")
        check(context.engine.payments.quotedSources.count == 2, "Execution never requotes silently")
        context.engine.payments.send = { _, _ in .single(.externalVerificationRequired(url: "https://example.invalid")) }
        let verification = execute(context, profile, transfer)
        check(verification.last?.completed == 0 && verification.last?.error == .verificationRequired, "Verification-required isn't success")
        check(context.engine.payments.freeTransferCalls.count == 1, "Failure doesn't advance to another gift")
        context.starsContext = StarsContext(balance: 1)
        let insufficient = execute(context, profile, transfer)
        check(insufficient.last?.error == .insufficientBalance(required: 200), "Check batch balance before any charge")
        check(context.engine.payments.paidCalls.count == 3, "Insufficient balance causes no new submission")
        context.starsContext = nil
        check(execute(context, profile, transfer).last?.error == .balanceUnavailable, "Unknown balance isn't treated as enough")
        context.starsContext = StarsContext(balance: 1000)
        let upgrade = quote(prepare(context, [gift(4, unique: false, prepaid: 100, hidden: true), gift(5, unique: false)], .upgrade))
        check(execute(context, profile, upgrade).last?.completed == 2, "Upgrade waits for actual resulting gifts")
        check(profile.upgradeCalls.count == 2 && profile.upgradeCalls[0].0 == nil && !profile.upgradeCalls[0].2, "Prepaid/hidden upgrade direct call respects privacy")
        check(profile.upgradeCalls[1].0 == 888 && profile.upgradeCalls[1].2, "Paid upgrade uses matching form and keep flag")
        let invalid = GiftBulkQuote(mode: .transfer, items: transfer.items + [transfer.items[0]], recipientId: 2, totalCost: 300)
        check(execute(context, profile, invalid).last?.error == .invalidSelection, "Execution rejects duplicate reference in malformed quote")
    }
}
