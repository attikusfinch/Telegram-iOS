// Test-only contract models. They replace Telegram account/network modules in
// the standalone test binary, so exercising production orchestration cannot
// submit a real payment, upgrade, transfer, or any network request.
import Foundation
import SwiftSignalKit

#if GIFT_BULK_TEST_CORE
public enum EnginePeer {
    public typealias Id = Int64
}

public enum StarGiftReference: Hashable {
    case test(Int)
}

public enum StarGift {
    public struct UniqueGift {
        public struct Flags: OptionSet {
            public let rawValue: Int32
            public init(rawValue: Int32) { self.rawValue = rawValue }
            public static let isBurned = Flags(rawValue: 2)
        }
        public let hostPeerId: EnginePeer.Id?
        public let flags: Flags
        public init(hostPeerId: EnginePeer.Id? = nil, flags: Flags = []) {
            self.hostPeerId = hostPeerId
            self.flags = flags
        }
    }
    case generic
    case unique(UniqueGift)
}

public enum TransferStarGiftError {
    case generic
    case disallowedStarGift
}

public enum UpgradeStarGiftError {
    case generic
    case alreadyUpgraded
}

public enum BotPaymentFormRequestError {
    case generic
    case alreadyActive
    case noPaymentNeeded
    case disallowedStarGift
    case starGiftResellTooEarly(Int32)
    case starGiftUserLimit
}

public enum SendBotPaymentFormError {
    case generic
    case disallowedStarGift
}

public enum SendBotPaymentResult {
    case done(receiptMessageId: Int?, subscriptionPeerId: EnginePeer.Id?, uniqueStarGift: ProfileGiftsContext.State.StarGift?)
    case externalVerificationRequired(url: String)
}

public enum BotPaymentInvoiceSource: Equatable {
    case starGiftUpgrade(keepOriginalInfo: Bool, reference: StarGiftReference)
    case starGiftTransfer(reference: StarGiftReference, toPeerId: EnginePeer.Id)
}

public struct BotPaymentPrice {
    public let amount: Int64
}

public struct BotPaymentInvoice {
    public let currency: String
    public let prices: [BotPaymentPrice]
}

public struct BotPaymentForm {
    public let id: Int64
    public let invoice: BotPaymentInvoice
    public init(id: Int64, currency: String = "XTR", amounts: [Int64]) {
        self.id = id
        self.invoice = BotPaymentInvoice(currency: currency, prices: amounts.map { BotPaymentPrice(amount: $0) })
    }
}

public struct StarsAmount: Equatable, Comparable {
    public let value: Int64
    public let nanos: Int32
    public init(value: Int64, nanos: Int32) { self.value = value; self.nanos = nanos }
    public static func <(lhs: Self, rhs: Self) -> Bool {
        return lhs.value == rhs.value ? lhs.nanos < rhs.nanos : lhs.value < rhs.value
    }
}

public final class StarsContext {
    public struct State {
        public let balance: StarsAmount
    }
    public var currentState: State?
    public init(balance: Int64) { self.currentState = State(balance: StarsAmount(value: balance, nanos: 0)) }
}

public final class ProfileGiftsContext {
    public struct State {
        public struct StarGift {
            public let gift: TelegramCore.StarGift
            public let reference: StarGiftReference?
            public let isRefunded: Bool
            public let canTransferDate: Int32?
            public let canUpgrade: Bool
            public let transferStars: Int64?
            public let upgradeStars: Int64?
            public let nameHidden: Bool
            public let upgradeSeparate: Bool
            public init(gift: TelegramCore.StarGift, reference: StarGiftReference?, isRefunded: Bool = false, canTransferDate: Int32? = nil, canUpgrade: Bool = false, transferStars: Int64? = nil, upgradeStars: Int64? = nil, nameHidden: Bool = false, upgradeSeparate: Bool = false) {
                self.gift = gift; self.reference = reference; self.isRefunded = isRefunded
                self.canTransferDate = canTransferDate; self.canUpgrade = canUpgrade
                self.transferStars = transferStars; self.upgradeStars = upgradeStars
                self.nameHidden = nameHidden; self.upgradeSeparate = upgradeSeparate
            }
        }
    }
    public var upgradeCalls: [(Int64?, StarGiftReference, Bool)] = []
    public var upgrade: (Int64?, StarGiftReference, Bool) -> Signal<State.StarGift, UpgradeStarGiftError> = { _, reference, _ in
        return .single(State.StarGift(gift: .unique(.init()), reference: reference))
    }
    public init() {}
    public func upgradeStarGift(formId: Int64?, reference: StarGiftReference, keepOriginalInfo: Bool) -> Signal<State.StarGift, UpgradeStarGiftError> {
        self.upgradeCalls.append((formId, reference, keepOriginalInfo))
        return self.upgrade(formId, reference, keepOriginalInfo)
    }
}

public final class TelegramEngine {
    public final class Payments {
        public var quotedSources: [BotPaymentInvoiceSource] = []
        public var paidCalls: [(Int64, BotPaymentInvoiceSource)] = []
        public var freeTransferCalls: [(Bool, StarGiftReference, EnginePeer.Id)] = []
        public var fetch: (BotPaymentInvoiceSource) -> Signal<BotPaymentForm, BotPaymentFormRequestError> = { _ in .fail(.generic) }
        public var send: (Int64, BotPaymentInvoiceSource) -> Signal<SendBotPaymentResult, SendBotPaymentFormError> = { _, _ in .single(.done(receiptMessageId: nil, subscriptionPeerId: nil, uniqueStarGift: nil)) }
        public var transfer: (Bool, StarGiftReference, EnginePeer.Id) -> Signal<Never, TransferStarGiftError> = { _, _, _ in .complete() }
        public init() {}
        public func fetchBotPaymentForm(source: BotPaymentInvoiceSource, themeParams: [String: Any]?) -> Signal<BotPaymentForm, BotPaymentFormRequestError> {
            self.quotedSources.append(source)
            return self.fetch(source)
        }
        public func sendStarsPaymentForm(formId: Int64, source: BotPaymentInvoiceSource) -> Signal<SendBotPaymentResult, SendBotPaymentFormError> {
            self.paidCalls.append((formId, source))
            return self.send(formId, source)
        }
        public func transferStarGift(prepaid: Bool, reference: StarGiftReference, peerId: EnginePeer.Id) -> Signal<Never, TransferStarGiftError> {
            self.freeTransferCalls.append((prepaid, reference, peerId))
            return self.transfer(prepaid, reference, peerId)
        }
    }
    public let payments = Payments()
    public init() {}
}
#endif

#if GIFT_BULK_TEST_CONTEXT
import TelegramCore
public final class Account {
    public let peerId: EnginePeer.Id = 1
    public init() {}
}
public final class AccountContext {
    public let account = Account()
    public let engine = TelegramEngine()
    public var starsContext: StarsContext? = StarsContext(balance: 100_000)
    public init() {}
}
#endif
