import AsyncDisplayKit
import UIKit
import Display
import ComponentFlow
import TelegramCore
import SwiftSignalKit
import TelegramPresentationData
import PresentationDataUtils
import AccountContext
import ContextUI
import PhotoResources
import TelegramUIPreferences
import TelegramStringFormatting
import ItemListPeerItem
import ItemListPeerActionItem
import MergeLists
import ItemListUI
import ChatControllerInteraction
import MultilineTextComponent
import BalancedTextComponent
import Markdown
import PeerInfoPaneNode
import GiftItemComponent
import PlainButtonComponent
import GiftViewScreen
import GiftUnpinScreen
import ButtonComponent
import UndoUI
import CheckComponent
import LottieComponent
import ContextUI
import TabSelectorComponent
import BundleIconComponent
import EmojiTextAttachmentView
import TextFormat
import PromptUI
import CollectionTabItemComponent
import EdgeEffect
import OverlayStatusController

public final class PeerInfoGiftsPaneNode: ASDisplayNode, PeerInfoPaneNode, UIScrollViewDelegate {
    public enum GiftCollection: Equatable {
        case all
        case collection(Int32)
        case create
        
        init(rawValue: Int32) {
            switch rawValue {
            case 0:
                self = .all
            case -1:
                self = .create
            default:
                self = .collection(rawValue)
            }
        }
        
        public var rawValue: Int32 {
            switch self {
            case .all:
                return 0
            case .create:
                return -1
            case let .collection(id):
                return id
            }
        }
    }
    
    private let context: AccountContext
    private let peerId: EnginePeer.Id
    private let profileGiftsCollections: ProfileGiftsCollectionsContext
    private let profileGifts: ProfileGiftsContext
    private let canManage: Bool
    private let canGift: Bool
    private var peer: EnginePeer?
    private let initialGiftCollectionId: Int64?
    
    private var resultsAreEmpty = false
    
    private let chatControllerInteraction: ChatControllerInteraction
    
    public weak var parentController: ViewController? {
        didSet {
            self.giftsListView.parentController = self.parentController
        }
    }
    
    private let backgroundNode: ASDisplayNode
    private let scrollNode: ASScrollNode
    private var giftsListView: GiftsListView
    
    private let tabSelector = ComponentView<Empty>()
    public private(set) var currentCollection: GiftCollection = .all
    
    private var panelEdgeEffectView: EdgeEffectView?
    private var panelContentContainer: UIView?
    private var panelButton: ComponentView<Empty>?
    private var panelCheck: ComponentView<Empty>?
    private let bulkGiftDisposable = MetaDisposable()
    private var bulkGiftBusy = false
    private var bulkGiftExecuting = false
    private var bulkGiftGeneration = 0
    private var bulkGiftProgress: (completed: Int, total: Int)?
    private var bulkGiftLoadingController: ViewController?
        
    private var currentParams: (size: CGSize, topInset: CGFloat, sideInset: CGFloat, bottomInset: CGFloat, deviceMetrics: DeviceMetrics, visibleHeight: CGFloat, isScrollingLockedAtTop: Bool, expandProgress: CGFloat, navigationHeight: CGFloat, presentationData: PresentationData)?
    
    private var theme: PresentationTheme?
    private let presentationDataPromise = Promise<PresentationData>()
    
    private var collectionsDisposable: Disposable?
    private var collections: [StarGiftCollection]?
    private var reorderedCollectionIds: [Int32]?
    private var isReordering = false
    
    private let ready = Promise<Bool>()
    private var didSetReady: Bool = false
    public var isReady: Signal<Bool, NoError> {
        return self.ready.get()
    }

    private let statusPromise = Promise<PeerInfoStatusData?>(nil)
    public var status: Signal<PeerInfoStatusData?, NoError> {
        self.statusPromise.get()
    }
    
    public var tabBarOffsetUpdated: ((ContainedViewLayoutTransition) -> Void)?
    public var tabBarOffset: CGFloat {
        return 0.0
    }
    
    public var giftsContext: ProfileGiftsContext {
        return self.giftsListView.profileGifts
    }
    
    public var openShareLink: ((String) -> Void)?
    
    private let collectionsMaxCount: Int
    
    public init(context: AccountContext, peerId: EnginePeer.Id, chatControllerInteraction: ChatControllerInteraction, profileGiftsCollections: ProfileGiftsCollectionsContext, profileGifts: ProfileGiftsContext, canManage: Bool, canGift: Bool, initialGiftCollectionId: Int64?) {
        self.context = context
        self.peerId = peerId
        self.chatControllerInteraction = chatControllerInteraction
        self.profileGiftsCollections = profileGiftsCollections
        self.profileGifts = profileGifts
        self.canManage = canManage
        self.canGift = canGift
        self.initialGiftCollectionId = initialGiftCollectionId
        
        if let value = context.currentAppConfiguration.with({ $0 }).data?["stargifts_collections_limit"] as? Double {
            self.collectionsMaxCount = Int(value)
        } else {
            self.collectionsMaxCount = 6
        }
        
        self.backgroundNode = ASDisplayNode()
        self.scrollNode = ASScrollNode()
        self.giftsListView = GiftsListView(context: context, peerId: peerId, profileGifts: profileGifts, giftsCollections: profileGiftsCollections, canSelect: false)
                
        super.init()
                
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.scrollNode)
        
        self.statusPromise.set(self.giftsListView.status)
        self.ready.set(self.giftsListView.isReady)
        
        self.giftsListView.onContentUpdated = { [weak self] in
            guard let self else {
                return
            }
            if let params = self.currentParams {
                self.update(size: params.size, topInset: params.topInset, sideInset: params.sideInset, bottomInset: params.bottomInset, deviceMetrics: params.deviceMetrics, visibleHeight: params.visibleHeight, isScrollingLockedAtTop: params.isScrollingLockedAtTop, expandProgress: params.expandProgress, navigationHeight: params.navigationHeight, presentationData: params.presentationData, synchronous: true, transition: .immediate)
            }
        }
        self.giftsListView.contextAction = { [weak self] gift, view, gesture in
            guard let self else {
                return
            }
            self.contextAction(gift: gift, view: view, gesture: gesture)
        }
        self.giftsListView.sizeEditingUpdated = { [weak self] in
            self?.updateScrolling(transition: UIAccessibility.isReduceMotionEnabled ? .immediate : .easeInOut(duration: 0.2))
        }
        self.giftsListView.bulkSelectionUpdated = { [weak self] in
            self?.updateScrolling(transition: UIAccessibility.isReduceMotionEnabled ? .immediate : .easeInOut(duration: 0.2))
        }
        self.giftsListView.bulkSelectionUnavailable = { [weak self] gift, mode in
            self?.explainBulkGiftRestriction(gift: gift, mode: mode)
        }
        self.giftsListView.displayUnpinScreen = { [weak self] gift, completion in
            guard let self else {
                return
            }
            self.displayUnpinScreen(gift: gift, completion: completion)
        }
        
        self.collectionsDisposable = (profileGiftsCollections.state
        |> deliverOnMainQueue).start(next: { [weak self] state in
            guard let self else {
                return
            }
            self.collections = state.collections
            self.updateScrolling(transition: .easeInOut(duration: 0.2))
        })
        
        if let initialGiftCollectionId {
            self.setCurrentCollection(collection: .collection(Int32(initialGiftCollectionId)))
        }
        
        let _ = (context.engine.data.subscribe(TelegramEngine.EngineData.Item.Peer.Peer(id: peerId))
        |> deliverOnMainQueue).start(next: { [weak self] peer in
            guard let self else {
                return
            }
            self.peer = peer
            self.updateScrolling(transition: .immediate)
        })
    }
    
    deinit {
        self.collectionsDisposable?.dispose()
        self.bulkGiftDisposable.dispose()
        self.bulkGiftLoadingController?.dismiss()
    }
        
    public override func didLoad() {
        super.didLoad()
        
        self.scrollNode.view.contentInsetAdjustmentBehavior = .never
        self.scrollNode.view.delegate = self
        self.scrollNode.view.scrollsToTop = false
        
        if let tabSelectorView = self.tabSelector.view {
            self.scrollNode.view.insertSubview(self.giftsListView, aboveSubview: tabSelectorView)
        } else {
            self.scrollNode.view.insertSubview(self.giftsListView, at: 0)
        }
    }
    
    private func item(at point: CGPoint) -> (AnyHashable, ComponentView<Empty>)? {
        return self.giftsListView.item(at: self.giftsListView.convert(point, from: self.view))
    }
    
    public func createCollection(gifts: [ProfileGiftsContext.State.StarGift] = []) {
        guard let params = self.currentParams else {
            return
        }
        if let collections = self.collections, collections.count >= self.collectionsMaxCount {
            let alertController = textAlertController(context: self.context, title: params.presentationData.strings.PeerInfo_Gifts_CollectionLimitReached_Title, text: params.presentationData.strings.PeerInfo_Gifts_CollectionLimitReached_Text, actions: [TextAlertAction(type: .defaultAction, title: params.presentationData.strings.Common_OK, action: {})])
            self.parentController?.present(alertController, in: .window(.root))
            return
        }
        
        let promptController = promptController(context: self.context, updatedPresentationData: nil, text: params.presentationData.strings.PeerInfo_Gifts_CreateCollection_Title, titleFont: .bold, subtitle: params.presentationData.strings.PeerInfo_Gifts_CreateCollection_Text, value: "", placeholder: params.presentationData.strings.PeerInfo_Gifts_CreateCollection_Placeholder, characterLimit: 12, displayCharacterLimit: true, apply: { [weak self] value in
            guard let self, let value else {
                return
            }
            let _ = self.profileGiftsCollections.createCollection(title: value, starGifts: gifts).start(next: { [weak self] collection in
                guard let self else {
                    return
                }
                if let collection {
                    self.setCurrentCollection(collection: .collection(collection.id))
                    
                    if let tabSelectorView = self.tabSelector.view as? TabSelectorComponent.View {
                        tabSelectorView.scrollToEnd()
                    }
                }
            })
        })
        self.parentController?.present(promptController, in: .window(.root))
    }
    
    public func deleteCollection(id: Int32) {
        guard let params = self.currentParams else {
            return
        }
        let actionSheet = ActionSheetController(presentationData: params.presentationData)
        actionSheet.setItemGroups([
            ActionSheetItemGroup(items: [
                ActionSheetTextItem(title: params.presentationData.strings.PeerInfo_Gifts_RemoveCollectionConfirmation),
                ActionSheetButtonItem(title: params.presentationData.strings.PeerInfo_Gifts_RemoveCollectionAction, color: .destructive, action: { [weak self, weak actionSheet] in
                    actionSheet?.dismissAnimated()
                    
                    self?.setCurrentCollection(collection: .all)
                    let _ = self?.profileGiftsCollections.deleteCollection(id: id).start()
                    
                    if let tabSelectorView = self?.tabSelector.view as? TabSelectorComponent.View {
                        tabSelectorView.scrollToStart()
                    }
                })
            ]),
            ActionSheetItemGroup(items: [
                ActionSheetButtonItem(title: params.presentationData.strings.Common_Cancel, color: .accent, font: .bold, action: { [weak actionSheet] in
                    actionSheet?.dismissAnimated()
                })
            ])
        ])
        self.parentController?.present(actionSheet, in: .window(.root))
    }
    
    public func addGiftsToCollection(id: Int32) {
        var collectionGiftsMaxCount: Int32 = 1000
        if let value = self.context.currentAppConfiguration.with({ $0 }).data?["stargifts_collection_gifts_limit"] as? Double {
            collectionGiftsMaxCount = Int32(value)
        }
        var remainingCount = collectionGiftsMaxCount
        if let currentCount = self.giftsListView.profileGifts.currentState?.count {
            remainingCount = max(0, collectionGiftsMaxCount - currentCount)
        }
        let screen = AddGiftsScreen(context: self.context, peerId: self.peerId, collectionId: id, remainingCount: remainingCount, completion: { [weak self] gifts in
            guard let self else {
                return
            }
            let _ = self.profileGiftsCollections.addGifts(id: id, gifts: gifts).start()
        })
        self.parentController?.push(screen)
    }
    
    public func renameCollection(id: Int32) {
        guard let params = self.currentParams, let collection = self.collections?.first(where: { $0.id == id }) else {
            return
        }
        
        let promptController = promptController(context: self.context, updatedPresentationData: nil, text: params.presentationData.strings.PeerInfo_Gifts_RenameCollection_Title, titleFont: .bold, value: collection.title, placeholder: params.presentationData.strings.PeerInfo_Gifts_CreateCollection_Placeholder, characterLimit: 12, displayCharacterLimit: true, apply: { [weak self] value in
            guard let self, let value else {
                return
            }
            let _ = self.profileGiftsCollections.renameCollection(id: id, title: value).start()
        })
        self.parentController?.present(promptController, in: .window(.root))
    }
    
    public func beginReordering() {
        guard !self.bulkGiftBusy else { return }
        self.cancelBulkGiftSelection()
        self.giftsListView.endSizeEditing(save: false)
        self.giftsListView.beginReordering()
    }

    public var resizeGiftsTitle: String {
        let languageCode = self.currentParams?.presentationData.strings.primaryComponent.languageCode ?? "en"
        return languageCode.hasPrefix("ru") ? "Изменить размеры подарков" : "Resize Gifts"
    }

    public var canResizeGifts: Bool {
        guard !self.bulkGiftBusy else { return false }
        return self.giftsListView.profileGifts.currentState?.filteredGifts.contains(where: { $0.reference != nil }) ?? false
    }

    public func beginSizeEditing() {
        guard !self.bulkGiftBusy else { return }
        self.giftsListView.beginSizeEditing()
    }

    private var bulkGiftRussian: Bool {
        return self.currentParams?.presentationData.strings.primaryComponent.languageCode.hasPrefix("ru") ?? false
    }

    public var canBulkManageGifts: Bool {
        return self.peerId == self.context.account.peerId && !self.bulkGiftBusy
    }

    public var isBulkSelectingGifts: Bool {
        return self.giftsListView.isBulkSelecting
    }

    public var isBulkGiftOperationInProgress: Bool {
        return self.bulkGiftBusy
    }

    public var bulkTransferGiftsTitle: String {
        return self.bulkGiftRussian ? "Отправить несколько подарков" : "Send Multiple Gifts"
    }

    public var bulkUpgradeGiftsTitle: String {
        return self.bulkGiftRussian ? "Улучшить несколько подарков" : "Upgrade Multiple Gifts"
    }

    public var cancelBulkGiftsTitle: String {
        return self.bulkGiftRussian ? "Отменить выбор" : "Cancel Selection"
    }

    public func beginBulkGiftTransfer() {
        self.beginBulkGiftSelection(mode: .transfer)
    }

    public func beginBulkGiftUpgrade() {
        self.beginBulkGiftSelection(mode: .upgrade)
    }

    private func beginBulkGiftSelection(mode: GiftBulkActionMode, initialGift: ProfileGiftsContext.State.StarGift? = nil) {
        guard self.canBulkManageGifts else { return }
        self.bulkGiftGeneration += 1
        self.context.starsContext?.load(force: true)
        self.giftsListView.beginBulkSelection(mode: mode, eligibility: { gift, mode in
            return GiftBulkActions.isEligible(gift: gift, mode: mode, now: Int32(clamping: Int64(Date().timeIntervalSince1970)))
        })
        if let initialGift {
            self.giftsListView.selectBulkGift(initialGift)
        }
        if let state = self.giftsListView.profileGifts.currentState,
           case .ready(false, _) = state.dataState,
           !state.filteredGifts.contains(where: { GiftBulkActions.isEligible(gift: $0, mode: mode, now: Int32(clamping: Int64(Date().timeIntervalSince1970))) }) {
            let text: String
            if mode == .transfer {
                text = self.bulkGiftRussian ? "Нет доступных для отправки коллекционных подарков. Нажмите на подарок с замком, чтобы узнать причину." : "No collectible gifts are available to send. Tap a locked gift to see why."
            } else {
                text = self.bulkGiftRussian ? "Нет обычных подарков, доступных для улучшения. Нажмите на подарок с замком, чтобы узнать причину." : "No regular gifts are available to upgrade. Tap a locked gift to see why."
            }
            self.presentBulkGiftMessage(title: self.bulkGiftRussian ? "Нет доступных подарков" : "No Available Gifts", text: text)
        }
    }

    public func cancelBulkGiftSelection() {
        guard !self.bulkGiftExecuting else { return }
        self.bulkGiftGeneration += 1
        self.bulkGiftDisposable.set(nil)
        self.dismissBulkGiftLoading()
        self.setBulkGiftBusy(false)
        self.giftsListView.endBulkSelection()
    }

    private func setBulkGiftBusy(_ value: Bool) {
        self.bulkGiftBusy = value
        self.giftsListView.isUserInteractionEnabled = !value
        self.tabSelector.view?.isUserInteractionEnabled = !value
        self.updateScrolling(transition: .easeInOut(duration: 0.2))
    }

    private func dismissBulkGiftLoading() {
        self.bulkGiftLoadingController?.dismiss()
        self.bulkGiftLoadingController = nil
    }

    private func presentBulkGiftMessage(title: String, text: String) {
        let strings = self.currentParams?.presentationData.strings ?? self.context.sharedContext.currentPresentationData.with { $0 }.strings
        let controller = textAlertController(context: self.context, title: title, text: text, actions: [
            TextAlertAction(type: .defaultAction, title: strings.Common_OK, action: {})
        ])
        self.parentController?.present(controller, in: .window(.root))
    }

    private func explainBulkGiftRestriction(gift: ProfileGiftsContext.State.StarGift, mode: GiftBulkActionMode) {
        guard !self.bulkGiftBusy, self.giftsListView.bulkSelectionMode == mode,
              let reason = GiftBulkActions.selectionRestriction(gift: gift, mode: mode, now: Int32(clamping: Int64(Date().timeIntervalSince1970))) else { return }
        let text: String
        switch reason {
        case .requiresCollectible:
            text = self.bulkGiftRussian ? "Передавать можно коллекционные подарки. Если этот подарок поддерживает улучшение, сначала улучшите его." : "Only collectible gifts can be transferred. If this gift supports upgrading, upgrade it first."
        case .alreadyUpgraded:
            text = self.bulkGiftRussian ? "Этот подарок уже коллекционный и не требует улучшения." : "This gift is already collectible and cannot be upgraded again."
        case .upgradeUnavailable:
            text = self.bulkGiftRussian ? "Telegram не разрешает улучшение этого подарка." : "Telegram does not support upgrading this gift."
        case .hostedGift:
            text = self.bulkGiftRussian ? "Этот подарок размещён в профиле из TON. Его передача выполняется через кошелёк владельца." : "This gift is linked to the profile from TON. Transfer it from the owner's wallet."
        case .burnedGift:
            text = self.bulkGiftRussian ? "Этот подарок уничтожен и больше недоступен для передачи." : "This gift was burned and can no longer be transferred."
        case .refunded:
            text = self.bulkGiftRussian ? "Улучшение этого подарка было возвращено. Действие недоступно." : "The upgrade of this gift was refunded. This action is unavailable."
        case let .transferCooldown(until):
            let data = self.currentParams?.presentationData ?? self.context.sharedContext.currentPresentationData.with { $0 }
            let date = stringForFullDate(timestamp: until, strings: data.strings, dateTimeFormat: data.dateTimeFormat)
            text = self.bulkGiftRussian ? "Telegram временно ограничил передачу этого подарка. Он будет доступен после \(date)." : "Telegram has temporarily restricted this gift. It can be transferred after \(date)."
        case .missingReference:
            let strings = self.currentParams?.presentationData.strings ?? self.context.sharedContext.currentPresentationData.with { $0 }.strings
            let controller = textAlertController(context: self.context,
                title: self.bulkGiftRussian ? "Обновите подарок" : "Refresh Gift Details",
                text: self.bulkGiftRussian ? "В данных подарка пока нет идентификатора для этого действия. Обновите список подарков и попробуйте снова." : "This gift's details do not yet contain an identifier for this action. Refresh the gift list and try again.",
                actions: [
                    TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: {}),
                    TextAlertAction(type: .defaultAction, title: self.bulkGiftRussian ? "Обновить" : "Refresh", action: { [weak self] in
                        self?.giftsListView.profileGifts.reload()
                    })
                ])
            self.parentController?.present(controller, in: .window(.root))
            return
        }
        self.presentBulkGiftMessage(title: mode == .transfer
            ? (self.bulkGiftRussian ? "Подарок нельзя отправить" : "Gift Cannot Be Sent")
            : (self.bulkGiftRussian ? "Подарок нельзя улучшить" : "Gift Cannot Be Upgraded"), text: text)
    }

    private func bulkGiftErrorText(_ error: GiftBulkActionError) -> String {
        switch error {
        case let .insufficientBalance(required):
            return self.bulkGiftRussian ? "Недостаточно звёзд. Требуется \(required) ⭐." : "Not enough Stars. \(required) ⭐ is required."
        case .balanceUnavailable:
            return self.bulkGiftRussian ? "Не удалось получить баланс звёзд. Обновите баланс и попробуйте снова." : "Your Stars balance could not be loaded. Refresh your balance and try again."
        case .recipientDisallowed:
            return self.bulkGiftRussian ? "Получатель не принимает эти подарки." : "This recipient does not accept these gifts."
        case .unavailableGift, .invalidSelection:
            return self.bulkGiftRussian ? "Один из выбранных подарков больше недоступен. Обновите список и выберите подарки заново." : "A selected gift is no longer available. Refresh the list and select the gifts again."
        case .invalidRecipient:
            return self.bulkGiftRussian ? "Выберите другого получателя." : "Choose another recipient."
        case .invalidPrice:
            return self.bulkGiftRussian ? "Не удалось подтвердить стоимость. Действия с подарками не запущены." : "The price could not be verified. Gift actions have not started."
        case .timedOut, .generic:
            return self.bulkGiftRussian ? "Не удалось подтвердить результат последнего действия. Проверьте подарок и историю операций перед повторной попыткой." : "The last action could not be confirmed. Check the gift and transaction history before trying again."
        case .verificationRequired:
            return self.bulkGiftRussian ? "Для платежа требуется дополнительное подтверждение. Очередь остановлена." : "The payment requires additional verification. The queue has stopped."
        }
    }

    private func bulkGiftActionPressed() {
        guard !self.bulkGiftBusy, let mode = self.giftsListView.bulkSelectionMode else { return }
        let gifts = self.giftsListView.selectedBulkGifts
        guard !gifts.isEmpty else { return }
        if mode == .upgrade {
            self.prepareBulkGifts(gifts: gifts, mode: mode, recipient: nil)
        } else {
            let generation = self.bulkGiftGeneration
            let controller = self.context.sharedContext.makePeerSelectionController(PeerSelectionControllerParams(
                context: self.context,
                filter: [.excludeSecretChats, .excludeSavedMessages, .excludeBots, .excludeGroups, .excludeChannels, .doNotSearchMessages],
                requestPeerType: [.user(.init(isBot: false, isPremium: nil))],
                title: self.bulkGiftRussian ? "Кому отправить подарки?" : "Send Gifts To",
                multipleSelection: false,
                hasCreation: false,
                excludedPeerIds: [self.context.account.peerId]
            ))
            controller.peerSelected = { [weak self, weak controller] recipient, _ in
                guard let self, self.bulkGiftGeneration == generation, !self.bulkGiftBusy, self.giftsListView.bulkSelectionMode == .transfer else { return }
                controller?.dismiss()
                Queue.mainQueue().after(0.2, { [weak self] in
                    guard let self, self.bulkGiftGeneration == generation, self.giftsListView.bulkSelectionMode == .transfer else { return }
                    self.prepareBulkGifts(gifts: self.giftsListView.selectedBulkGifts, mode: .transfer, recipient: recipient)
                })
            }
            self.parentController?.present(controller, in: .window(.root))
        }
    }

    private func prepareBulkGifts(gifts: [ProfileGiftsContext.State.StarGift], mode: GiftBulkActionMode, recipient: EnginePeer?) {
        guard !self.bulkGiftBusy, !gifts.isEmpty, self.giftsListView.bulkSelectionMode == mode else { return }
        self.bulkGiftGeneration += 1
        let generation = self.bulkGiftGeneration
        self.bulkGiftProgress = nil
        self.setBulkGiftBusy(true)
        let theme = self.context.sharedContext.currentPresentationData.with { $0 }.theme
        let loading = OverlayStatusController(style: theme.actionSheet.backgroundType == .light ? .light : .dark, type: .loading(cancelled: { [weak self] in
            guard let self, !self.bulkGiftExecuting, self.bulkGiftGeneration == generation else { return }
            self.bulkGiftGeneration += 1
            self.bulkGiftDisposable.set(nil)
            self.dismissBulkGiftLoading()
            self.setBulkGiftBusy(false)
        }))
        loading.blocksBackgroundWhenInOverlay = true
        self.bulkGiftLoadingController = loading
        self.parentController?.present(loading, in: .window(.root))
        self.bulkGiftDisposable.set((GiftBulkActions.prepare(context: self.context, gifts: gifts, mode: mode, recipientId: recipient?.id, keepOriginalInfo: true)
        |> deliverOnMainQueue).start(next: { [weak self] quote in
            guard let self, self.bulkGiftGeneration == generation else { return }
            self.dismissBulkGiftLoading()
            Queue.mainQueue().after(0.2, { [weak self] in
                guard let self, self.bulkGiftGeneration == generation, self.bulkGiftBusy else { return }
                self.confirmBulkGifts(quote: quote, recipientName: recipient?.debugDisplayTitle, generation: generation)
            })
        }, error: { [weak self] error in
            guard let self, self.bulkGiftGeneration == generation else { return }
            self.dismissBulkGiftLoading()
            self.setBulkGiftBusy(false)
            Queue.mainQueue().after(0.2, { [weak self] in
                guard let self, self.bulkGiftGeneration == generation else { return }
                let text: String
                if error == .generic || error == .timedOut {
                    text = self.bulkGiftRussian ? "Не удалось получить стоимость. Действия с подарками не запущены. Попробуйте снова." : "The price could not be loaded. Gift actions have not started. Try again."
                } else {
                    text = self.bulkGiftErrorText(error)
                }
                self.presentBulkGiftMessage(title: self.bulkGiftRussian ? "Не удалось подготовить подарки" : "Could Not Prepare Gifts", text: text)
            })
        }))
    }

    private func confirmBulkGifts(quote: GiftBulkQuote, recipientName: String?, generation: Int) {
        let count = quote.items.count
        let title: String
        let text: String
        let actionTitle: String
        if quote.mode == .transfer {
            title = self.bulkGiftRussian ? (count == 1 ? "Отправить подарок?" : "Отправить подарки (\(count))?") : "Send \(count) \(count == 1 ? "Gift" : "Gifts")?"
            text = self.bulkGiftRussian ? "Получатель: \(recipientName ?? "").\nОбщая комиссия: \(quote.totalCost) ⭐.\n\nВсе выбранные подарки будут переданы получателю и исчезнут из вашего профиля." : "Recipient: \(recipientName ?? "").\nTotal fee: \(quote.totalCost) ⭐.\n\nAll selected gifts will be transferred to this recipient and removed from your profile."
            actionTitle = self.bulkGiftRussian ? "Отправить" : "Send"
        } else {
            title = self.bulkGiftRussian ? (count == 1 ? "Улучшить подарок?" : "Улучшить подарки (\(count))?") : "Upgrade \(count) \(count == 1 ? "Gift" : "Gifts")?"
            text = self.bulkGiftRussian ? "Общая стоимость: \(quote.totalCost) ⭐.\nУже оплаченные улучшения учтены бесплатно.\n\nСохраним доступные данные отправителей и сообщения. Скрытые сведения не сохраняются." : "Total cost: \(quote.totalCost) ⭐.\nPrepaid upgrades are included at no extra cost.\n\nAvailable sender details and messages will be kept. Hidden details are not retained."
            actionTitle = self.bulkGiftRussian ? "Улучшить" : "Upgrade"
        }
        let strings = self.currentParams?.presentationData.strings ?? self.context.sharedContext.currentPresentationData.with { $0 }.strings
        let controller = textAlertController(context: self.context, title: title, text: text, actions: [
            TextAlertAction(type: .genericAction, title: strings.Common_Cancel, action: { [weak self] in
                guard let self, self.bulkGiftGeneration == generation else { return }
                self.bulkGiftGeneration += 1
                self.setBulkGiftBusy(false)
            }),
            TextAlertAction(type: .defaultAction, title: actionTitle, action: { [weak self] in
                guard let self, self.bulkGiftGeneration == generation, self.bulkGiftBusy, !self.bulkGiftExecuting else { return }
                self.executeBulkGifts(quote: quote)
            })
        ], actionLayout: .vertical, dismissOnOutsideTap: false)
        self.parentController?.present(controller, in: .window(.root))
    }

    private func executeBulkGifts(quote: GiftBulkQuote) {
        let selected = Set(self.giftsListView.selectedBulkGifts.compactMap(\.reference))
        guard quote.items.allSatisfy({ selected.contains($0.reference) }) else {
            self.setBulkGiftBusy(false)
            self.presentBulkGiftMessage(title: self.bulkGiftRussian ? "Подарки изменились" : "Gifts Changed", text: self.bulkGiftErrorText(.unavailableGift))
            return
        }
        self.bulkGiftExecuting = true
        self.bulkGiftProgress = (0, quote.items.count)
        self.updateScrolling(transition: .immediate)
        let activeContext = self.giftsListView.profileGifts
        let theme = self.context.sharedContext.currentPresentationData.with { $0 }.theme
        let loading = OverlayStatusController(style: theme.actionSheet.backgroundType == .light ? .light : .dark, type: .loading(cancelled: nil))
        loading.blocksBackgroundWhenInOverlay = true
        self.bulkGiftLoadingController = loading
        self.parentController?.present(loading, in: .window(.root))
        var removedCount = 0
        // Keep the confirmed queue alive until its final result, including navigation changes.
        self.bulkGiftDisposable.set((GiftBulkActions.execute(context: self.context, profileGifts: activeContext, quote: quote)
        |> deliverOnMainQueue).start(next: { [self] progress in
            if quote.mode == .transfer, progress.completed > removedCount {
                let references = quote.items[removedCount ..< progress.completed].map(\.reference)
                activeContext.removeStarGifts(references: references)
                if activeContext !== self.profileGifts {
                    self.profileGifts.removeStarGifts(references: references)
                }
                removedCount = progress.completed
            }
            self.bulkGiftProgress = (progress.completed, progress.total)
            self.updateScrolling(transition: .immediate)
            guard progress.isFinished else { return }
            self.bulkGiftExecuting = false
            self.bulkGiftProgress = nil
            self.dismissBulkGiftLoading()
            self.setBulkGiftBusy(false)
            self.giftsListView.endBulkSelection()
            self.context.starsContext?.load(force: true)
            activeContext.reload()
            if activeContext !== self.profileGifts {
                self.profileGifts.reload()
            }
            Queue.mainQueue().after(0.2, { [weak self] in
                guard let self else { return }
                if let error = progress.error {
                    let summary = self.bulkGiftRussian ? "Подтверждено: \(progress.completed) из \(progress.total).\nОстальные действия остановлены.\n\n" : "Confirmed: \(progress.completed) of \(progress.total).\nThe remaining actions have stopped.\n\n"
                    self.presentBulkGiftMessage(title: self.bulkGiftRussian ? "Очередь остановлена" : "Queue Stopped", text: summary + self.bulkGiftErrorText(error))
                } else {
                    let text = quote.mode == .transfer
                        ? (self.bulkGiftRussian ? "Подарков отправлено: \(progress.completed)." : "Gifts sent: \(progress.completed).")
                        : (self.bulkGiftRussian ? "Подарков улучшено: \(progress.completed)." : "Gifts upgraded: \(progress.completed).")
                    self.presentBulkGiftMessage(title: self.bulkGiftRussian ? "Готово" : "Done", text: text)
                }
            })
        }))
    }
    
    public func endReordering() {
        self.giftsListView.endReordering()
    }
    
    public func updateIsReordering(isReordering: Bool, animated: Bool) {
        if self.isReordering != isReordering {
            self.isReordering = isReordering
            
            if let collections = self.collections {
                if isReordering {
                    var collectionIds: [Int32] = []
                    for collection in collections {
                        collectionIds.append(collection.id)
                    }
                    self.reorderedCollectionIds = collectionIds
                } else if let reorderedCollectionIds = self.reorderedCollectionIds {
                    let _ = self.profileGiftsCollections.reorderCollections(order: reorderedCollectionIds).start()
                    Queue.mainQueue().after(1.0, {
                        self.reorderedCollectionIds = nil
                    })
                }
            }
         
            self.giftsListView.updateIsReordering(isReordering: isReordering, animated: animated)
            self.updateScrolling(transition: .easeInOut(duration: 0.2))
        }
    }
    
    public func ensureMessageIsVisible(id: EngineMessage.Id) {
    }
    
    public func scrollToTop() -> Bool {
        self.scrollNode.view.setContentOffset(.zero, animated: true)
        return true
    }
    
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        self.updateScrolling(interactive: true, transition: .immediate)
    }
    
    public func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelContextGestures(view: scrollView)
    }
    
    private func displayUnpinScreen(gift: ProfileGiftsContext.State.StarGift, completion: (() -> Void)? = nil) {
        guard let pinnedGifts = self.profileGifts.currentState?.gifts.filter({ $0.pinnedToTop }), let presentationData = self.currentParams?.presentationData else {
            return
        }
        let controller = GiftUnpinScreen(
            context: self.context,
            gift: gift,
            pinnedGifts: pinnedGifts,
            completion: { [weak self] unpinnedReference in
                guard let self else {
                    return
                }
                completion?()
                
                var replacingTitle = ""
                for gift in pinnedGifts {
                    if gift.reference == unpinnedReference, case let .unique(uniqueGift) = gift.gift {
                        replacingTitle = "\(uniqueGift.title) #\(formatCollectibleNumber(uniqueGift.number, dateTimeFormat: presentationData.dateTimeFormat))"
                    }
                }
                
                var updatedPinnedGifts = self.giftsListView.pinnedReferences
                if let index = updatedPinnedGifts.firstIndex(of: unpinnedReference), let reference = gift.reference {
                    updatedPinnedGifts[index] = reference
                }
                self.profileGifts.updatePinnedToTopStarGifts(references: updatedPinnedGifts)
                
                var title = ""
                if case let .unique(uniqueGift) = gift.gift {
                    title = "\(uniqueGift.title) #\(formatCollectibleNumber(uniqueGift.number, dateTimeFormat: presentationData.dateTimeFormat))"
                }
                                                       
                let _ = self.scrollToTop()
                Queue.mainQueue().after(0.35) {
                    let toastTitle = presentationData.strings.PeerInfo_Gifts_ToastPinned_TitleNew(title).string
                    let toastText = presentationData.strings.PeerInfo_Gifts_ToastPinned_ReplacingText(replacingTitle).string
                    self.parentController?.present(UndoOverlayController(presentationData: presentationData, content: .universal(animation: "anim_toastpin", scale: 0.06, colors: [:], title: toastTitle, text: toastText, customUndoText: nil, timeout: 5), elevatedLayout: true, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
                }
            }
        )
        self.parentController?.push(controller)
    }
    
    func setCurrentCollection(collection: GiftCollection) {
        guard !self.bulkGiftBusy, self.currentCollection != collection else {
            return
        }
        var animateRight = false
        if case let .collection(currentId) = self.currentCollection {
            if case let .collection(nextId) = collection {
                if let currentIndex = self.collections?.firstIndex(where: { $0.id == currentId }), let nextIndex = self.collections?.firstIndex(where: { $0.id == nextId }) {
                    animateRight = nextIndex > currentIndex
                }
            }
        } else {
            animateRight = true
        }

        let previousGiftsListView = self.giftsListView
        previousGiftsListView.endSizeEditing(save: false)
        previousGiftsListView.endBulkSelection()
        
        let profileGifts: ProfileGiftsContext
        switch collection {
        case let .collection(id):
            profileGifts = self.profileGiftsCollections.giftsContextForCollection(id: id)
        default:
            profileGifts = self.profileGifts
        }
        if case .ready = profileGifts.currentState?.dataState {
            profileGifts.reload()
        }

        self.giftsListView = GiftsListView(context: self.context, peerId: self.peerId, profileGifts: profileGifts, giftsCollections: self.profileGiftsCollections, canSelect: false)
        self.giftsListView.addToCollection = { [weak self] in
            guard let self else {
                return
            }
            if case let .collection(id) = collection {
                self.addGiftsToCollection(id: id)
            }
        }
        self.giftsListView.onContentUpdated = { [weak self] in
            guard let self else {
                return
            }
            if case .collection = collection {
                self.resultsAreEmpty = self.giftsListView.resultsAreEmpty
            } else {
                self.resultsAreEmpty = false
            }
            if let params = self.currentParams {
                self.update(size: params.size, topInset: params.topInset, sideInset: params.sideInset, bottomInset: params.bottomInset, deviceMetrics: params.deviceMetrics, visibleHeight: params.visibleHeight, isScrollingLockedAtTop: params.isScrollingLockedAtTop, expandProgress: params.expandProgress, navigationHeight: params.navigationHeight, presentationData: params.presentationData, synchronous: true, transition: .immediate)
            }
        }
        self.giftsListView.displayUnpinScreen = { [weak self] gift, completion in
            guard let self else {
                return
            }
            self.displayUnpinScreen(gift: gift, completion: completion)
        }
        self.giftsListView.contextAction = { [weak self] gift, view, gesture in
            guard let self else {
                return
            }
            self.contextAction(gift: gift, view: view, gesture: gesture)
        }
        self.giftsListView.sizeEditingUpdated = { [weak self] in
            self?.updateScrolling(transition: UIAccessibility.isReduceMotionEnabled ? .immediate : .easeInOut(duration: 0.2))
        }
        self.giftsListView.bulkSelectionUpdated = { [weak self] in
            self?.updateScrolling(transition: UIAccessibility.isReduceMotionEnabled ? .immediate : .easeInOut(duration: 0.2))
        }
        self.giftsListView.bulkSelectionUnavailable = { [weak self] gift, mode in
            self?.explainBulkGiftRestriction(gift: gift, mode: mode)
        }
        self.giftsListView.parentController = self.parentController
        self.giftsListView.frame = previousGiftsListView.frame
                                        
        self.scrollNode.view.insertSubview(self.giftsListView, aboveSubview: previousGiftsListView)
        
        let multiplier = animateRight ? 1.0 : -1.0
        
        previousGiftsListView.layer.animatePosition(from: .zero, to: CGPoint(x: previousGiftsListView.frame.width * multiplier * -1.0, y: 0.0), duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring, removeOnCompletion: false, additive: true, completion: { _ in
            previousGiftsListView.removeFromSuperview()
        })
        self.giftsListView.layer.animatePosition(from: CGPoint(x: previousGiftsListView.frame.width * multiplier, y: 0.0), to: .zero, duration: 0.4, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
        
        self.currentCollection = collection
        self.updateScrolling(transition: .spring(duration: 0.25))
        
        if let params = self.currentParams {
            let visibleBounds = self.scrollNode.bounds.insetBy(dx: 0.0, dy: -10.0)
            let _ = self.giftsListView.update(size: params.size, sideInset: params.sideInset, bottomInset: params.bottomInset, deviceMetrics: params.deviceMetrics, visibleHeight: params.visibleHeight, isScrollingLockedAtTop: params.isScrollingLockedAtTop, expandProgress: params.expandProgress, presentationData: params.presentationData, synchronous: true, visibleBounds: visibleBounds, transition: .immediate)
        }
    }
    
    func openCollectionContextMenu(id: Int32, sourceNode: ASDisplayNode, gesture: ContextGesture?) {
        guard let params = self.currentParams, let sourceNode = sourceNode as? ContextExtractedContentContainingNode else {
            return
        }
        
        var canEditCollections = false
        if self.peerId == self.context.account.peerId || self.canManage {
            canEditCollections = true
        }
        
        var items: [ContextMenuItem] = []
        
        if canEditCollections {
            items.append(.action(ContextMenuActionItem(text: params.presentationData.strings.PeerInfo_Gifts_AddGifts, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Peer Info/Gifts/AddGift"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] _, f in
                guard let self else {
                    return
                }
                f(.default)
                
                self.setCurrentCollection(collection: .collection(id))
                self.addGiftsToCollection(id: id)
            })))
            
            items.append(.action(ContextMenuActionItem(text: params.presentationData.strings.PeerInfo_Gifts_RenameCollection, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Edit"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] _, f in
                guard let self else {
                    return
                }
                f(.default)
                
                Queue.mainQueue().after(0.15) {
                    self.renameCollection(id: id)
                }
            })))
        }

        if let peer = self.peer, let addressName = peer.addressName, !addressName.isEmpty {
            items.append(.action(ContextMenuActionItem(text: params.presentationData.strings.PeerInfo_Gifts_ShareCollection, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] _, f in
                guard let self else {
                    return
                }
                f(.default)
                
                self.openShareLink?("https://t.me/\(addressName)/c/\(id)")
            })))
        }
        
        if canEditCollections {
            items.append(.action(ContextMenuActionItem(text: params.presentationData.strings.PeerInfo_Gifts_Reorder, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/ReorderItems"), color: theme.actionSheet.primaryTextColor)
            }, action: { [weak self] c, f in
                c?.dismiss(completion: { [weak self] in
                    guard let self else {
                        return
                    }
                    self.beginReordering()
                })
            })))
            
            items.append(.action(ContextMenuActionItem(text: params.presentationData.strings.PeerInfo_Gifts_DeleteCollection, textColor: .destructive, icon: { theme in
                return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.contextMenu.destructiveColor)
            }, action: { [weak self] _, f in
                guard let self else {
                    return
                }
                f(.default)
                
                Queue.mainQueue().after(0.15) {
                    self.deleteCollection(id: id)
                }
            })))
        }
        
        let contextController = makeContextController(
            presentationData: params.presentationData,
            source: .extracted(GiftsExtractedContentSource(sourceNode: sourceNode)),
            items: .single(ContextController.Items(content: .list(items))),
            recognizer: nil,
            gesture: gesture
        )
        self.parentController?.presentInGlobalOverlay(contextController)
    }
    
    func updateScrolling(interactive: Bool = false, transition: ComponentTransition) {
        if let params = self.currentParams {
            let visibleBounds = self.scrollNode.bounds.insetBy(dx: 0.0, dy: -10.0)
                
            var topInset: CGFloat = params.topInset
            
            var canEditCollections = false
            if self.peerId == self.context.account.peerId || self.canManage {
                canEditCollections = true
            }
            var canShare = false
            if let peer = self.peer, let addressName = peer.addressName, !addressName.isEmpty {
                canShare = true
            }
            
            let hasNonEmptyCollections = self.collections?.contains(where: { $0.count > 0 }) ?? false
            if let collections = self.collections, !collections.isEmpty && (hasNonEmptyCollections || canEditCollections) {
                var tabSelectorItems: [TabSelectorComponent.Item] = []
                tabSelectorItems.append(TabSelectorComponent.Item(
                    id: AnyHashable(GiftCollection.all.rawValue),
                    title: params.presentationData.strings.PeerInfo_Gifts_Collections_All
                ))
                                
                var effectiveCollections: [StarGiftCollection] = collections
                if let reorderedCollectionIds = self.reorderedCollectionIds {
                    var collectionMap: [Int32: StarGiftCollection] = [:]
                    for collection in collections {
                        collectionMap[collection.id] = collection
                    }
                    var reorderedCollections: [StarGiftCollection] = []
                    for id in reorderedCollectionIds {
                        if let collection = collectionMap[id] {
                            reorderedCollections.append(collection)
                        }
                    }
                    effectiveCollections = reorderedCollections
                }
                
                for collection in effectiveCollections {
                    if !canEditCollections && collection.count == 0 {
                        continue
                    }
                    tabSelectorItems.append(TabSelectorComponent.Item(
                        id: AnyHashable(GiftCollection.collection(collection.id).rawValue),
                        content: .component(AnyComponent(
                            CollectionTabItemComponent(
                                context: self.context,
                                icon: collection.icon.flatMap { .collection($0) },
                                title: collection.title,
                                theme: params.presentationData.theme
                            )
                        )),
                        isReorderable: collections.count > 1,
                        contextAction: canEditCollections || canShare ? { [weak self] sourceNode, gesture in
                            guard let self else {
                                return
                            }
                            self.openCollectionContextMenu(id: collection.id, sourceNode: sourceNode, gesture: gesture)
                        } : nil
                    ))
                }
                        
                if canEditCollections {
                    tabSelectorItems.append(TabSelectorComponent.Item(
                        id: AnyHashable(GiftCollection.create.rawValue),
                        content: .component(AnyComponent(
                            CollectionTabItemComponent(
                                context: self.context,
                                icon: .add,
                                title: params.presentationData.strings.PeerInfo_Gifts_Collections_Add,
                                theme: params.presentationData.theme
                            )
                        )),
                        isReorderable: false
                    ))
                }
                
                let tabSelectorSize = self.tabSelector.update(
                    transition: transition,
                    component: AnyComponent(TabSelectorComponent(
                        context: self.context,
                        colors: TabSelectorComponent.Colors(
                            foreground: params.presentationData.theme.list.itemPrimaryTextColor,
                            selection: params.presentationData.theme.list.itemSecondaryTextColor.withMultipliedAlpha(0.15),
                            simple: true
                        ),
                        theme: params.presentationData.theme,
                        customLayout: TabSelectorComponent.CustomLayout(
                            font: Font.medium(15.0),
                            spacing: 2.0,
                            height: 44.0 - 5.0 * 2.0
                        ),
                        items: tabSelectorItems,
                        selectedId: AnyHashable(self.currentCollection.rawValue),
                        reorderItem: self.isReordering ? { [weak self] fromId, toId in
                            guard let self, var reorderedCollectionIds = self.reorderedCollectionIds else {
                                return
                            }
                            guard let sourceId = fromId.base as? Int32 else {
                                return
                            }
                            guard let targetId = toId.base as? Int32 else {
                                return
                            }
                            guard let sourceIndex = reorderedCollectionIds.firstIndex(of: sourceId), let targetIndex = reorderedCollectionIds.firstIndex(of: targetId) else {
                                return
                            }
                            reorderedCollectionIds[sourceIndex] = targetId
                            reorderedCollectionIds[targetIndex] = sourceId
                            self.reorderedCollectionIds = reorderedCollectionIds
                                
                            self.updateScrolling(transition: .easeInOut(duration: 0.2))
                        } : nil,
                        setSelectedId: { [weak self] id in
                            guard let self, let idValue = id.base as? Int32 else {
                                return
                            }
                            
                            let giftCollection = GiftCollection(rawValue: idValue)
                            if case .create = giftCollection {
                                self.createCollection()
                            } else {
                                self.setCurrentCollection(collection: giftCollection)
                            }
                        }
                    )),
                    environment: {},
                    containerSize: CGSize(width: params.size.width - 14.0 * 2.0, height: 44.0)
                )
                if let tabSelectorView = self.tabSelector.view {
                    if tabSelectorView.superview == nil {
                        tabSelectorView.alpha = 1.0
                        self.scrollNode.view.insertSubview(tabSelectorView, at: 0)
                        
                        if !transition.animation.isImmediate {
                            tabSelectorView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.25)
                        }
                    }
                    transition.setFrame(view: tabSelectorView, frame: CGRect(origin: CGPoint(x: floor((params.size.width - tabSelectorSize.width) / 2.0), y: topInset), size: tabSelectorSize))
                    
                    topInset += tabSelectorSize.height + 15.0
                }
            } else if let tabSelectorView = self.tabSelector.view {
                tabSelectorView.alpha = 0.0
                tabSelectorView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.25, completion: { _ in
                    tabSelectorView.removeFromSuperview()
                })
            }
            
            var contentHeight = self.giftsListView.updateScrolling(topInset: topInset, visibleBounds: visibleBounds, transition: transition)
            
            var bottomScrollInset: CGFloat = 0.0
            let size = params.size
            let sideInset = params.sideInset
            let bottomInset = params.bottomInset
            let presentationData = params.presentationData
          
            self.theme = presentationData.theme
            
            let panelEdgeEffectView: EdgeEffectView
            let panelContentContainer: UIView
            let isSizeEditing = self.giftsListView.isSizeEditing
            let isBulkSelecting = self.giftsListView.isBulkSelecting
            let isEditingTool = isSizeEditing || isBulkSelecting
            let selectedBulkCount = self.giftsListView.selectedBulkGifts.count
            let panelButtonEnabled = !self.bulkGiftBusy && (!isBulkSelecting || selectedBulkCount > 0)
            
            var panelVisibility: CGFloat = isEditingTool || params.expandProgress >= 1.0 ? 1.0 : 0.0
            if !isEditingTool && (!self.canGift || self.resultsAreEmpty) {
                panelVisibility = 0.0
            }
            
            if let current = self.panelContentContainer {
                panelContentContainer = current
            } else {
                panelContentContainer = UIView()
                self.view.addSubview(panelContentContainer)
                self.panelContentContainer = panelContentContainer
            }
            self.view.bringSubviewToFront(panelContentContainer)
            panelContentContainer.isUserInteractionEnabled = panelVisibility > 0.0
            
            let panelTransition: ComponentTransition = .immediate
            if let current = self.panelEdgeEffectView {
                panelEdgeEffectView = current
            } else {
                panelEdgeEffectView = EdgeEffectView()
                panelContentContainer.addSubview(panelEdgeEffectView)
                self.panelEdgeEffectView = panelEdgeEffectView
            }
                    
            let panelButton: ComponentView<Empty>
            if let current = self.panelButton {
                panelButton = current
            } else {
                panelButton = ComponentView<Empty>()
                self.panelButton = panelButton
            }
            
            let buttonInsets = ContainerViewLayout.concentricInsets(bottomInset: params.bottomInset, innerDiameter: 52.0 * 0.5, sideInset: sideInset + 30.0)
            
            let buttonTitle: String
            var buttonIconName: String?
            if isBulkSelecting {
                if let progress = self.bulkGiftProgress {
                    buttonTitle = self.bulkGiftRussian ? "Готово \(progress.completed) из \(progress.total)" : "Completed \(progress.completed) of \(progress.total)"
                } else if self.bulkGiftBusy {
                    buttonTitle = self.bulkGiftRussian ? "Проверяем стоимость…" : "Checking Prices…"
                } else if selectedBulkCount == 0 {
                    buttonTitle = self.giftsListView.bulkSelectionMode == .transfer
                        ? (self.bulkGiftRussian ? "Выберите подарки для отправки" : "Select Gifts to Send")
                        : (self.bulkGiftRussian ? "Выберите подарки для улучшения" : "Select Gifts to Upgrade")
                } else if self.giftsListView.bulkSelectionMode == .transfer {
                    buttonTitle = self.bulkGiftRussian ? "Отправить (\(selectedBulkCount))" : "Send Gifts (\(selectedBulkCount))"
                } else {
                    buttonTitle = self.bulkGiftRussian ? "Улучшить (\(selectedBulkCount))" : "Upgrade Gifts (\(selectedBulkCount))"
                }
            } else if isSizeEditing {
                buttonTitle = "Save Grid"
            } else if self.peerId == self.context.account.peerId {
                if case .all = self.currentCollection {
                    buttonTitle = params.presentationData.strings.PeerInfo_Gifts_Send
                } else {
                    buttonTitle = params.presentationData.strings.PeerInfo_Gifts_AddGiftsButton
                    buttonIconName = "Item List/AddItemIcon"
                }
            } else {
                buttonTitle = params.presentationData.strings.PeerInfo_Gifts_SendGift
            }
            
            let buttonAttributedString = NSAttributedString(string: buttonTitle, font: Font.semibold(17.0), textColor: presentationData.theme.list.itemCheckColors.foregroundColor, paragraphAlignment: .center)
            var buttonTitleContent: AnyComponent<Empty> = AnyComponent(MultilineTextComponent(text: .plain(buttonAttributedString)))
            if let buttonIconName {
                buttonTitleContent = AnyComponent(HStack([
                    AnyComponentWithIdentity(id: "_icon", component: AnyComponent(BundleIconComponent(
                        name: buttonIconName,
                        tintColor: presentationData.theme.list.itemCheckColors.foregroundColor,
                        maxSize: CGSize(width: 18.0, height: 18.0)
                    ))),
                    AnyComponentWithIdentity(id: "_title", component: buttonTitleContent)
                ], spacing: 7.0))
            }
            
            let panelButtonSize = panelButton.update(
                transition: transition,
                component: AnyComponent(
                    ButtonComponent(
                        background: ButtonComponent.Background(
                            style: .glass,
                            color: presentationData.theme.list.itemCheckColors.fillColor,
                            foreground: presentationData.theme.list.itemCheckColors.foregroundColor,
                            pressedColor: presentationData.theme.list.itemCheckColors.fillColor.withMultipliedAlpha(0.8)
                        ),
                        content: AnyComponentWithIdentity(
                            id: AnyHashable(buttonTitle),
                            component: buttonTitleContent
                        ),
                        isEnabled: panelButtonEnabled,
                        action: { [weak self] in
                            guard let self, !self.bulkGiftBusy else {
                                return
                            }
                            if self.giftsListView.isBulkSelecting {
                                self.bulkGiftActionPressed()
                            } else if self.giftsListView.isSizeEditing {
                                self.giftsListView.endSizeEditing(save: true)
                            } else {
                                self.buttonPressed()
                            }
                        }
                    )
                ),
                environment: {},
                containerSize: CGSize(width: size.width - buttonInsets.left * 2.0, height: 52.0)
            )
            
            var scrollOffset: CGFloat = max(0.0, size.height - params.visibleHeight)
            
            let effectiveBottomInset = max(buttonInsets.bottom, bottomInset)
            let bottomPanelHeight = effectiveBottomInset + panelButtonSize.height + 8.0
            if params.visibleHeight < 110.0 {
                scrollOffset -= bottomPanelHeight
            }
            
            if let panelButtonView = panelButton.view {
                if panelButtonView.superview == nil {
                    panelContentContainer.addSubview(panelButtonView)
                }
                panelButtonView.frame = CGRect(origin: CGPoint(x: buttonInsets.left, y: 8.0), size: panelButtonSize)
                panelButtonView.isHidden = false
                panelButtonView.isAccessibilityElement = false
                if let button = panelButtonView.subviews.first(where: { $0 is UIButton }) as? UIButton {
                    button.isAccessibilityElement = true
                    button.accessibilityTraits = panelButtonEnabled ? [.button] : [.button, .notEnabled]
                    button.accessibilityLabel = buttonTitle
                    button.accessibilityIdentifier = isBulkSelecting ? "ProfileGifts.BulkAction" : (isSizeEditing ? "ProfileGifts.SaveGrid" : "ProfileGifts.SendGift")
                }
            }
            
            let panelBottom: CGFloat
            if isEditingTool, let parentController = self.parentController {
                // Keep Save reachable while the profile header is still visible.
                panelBottom = max(0.0, min(size.height, self.view.convert(parentController.view.bounds, from: parentController.view).maxY))
            } else {
                panelBottom = size.height
            }
            panelTransition.setFrame(view: panelContentContainer, frame: CGRect(origin: CGPoint(x: 0.0, y: panelBottom - bottomPanelHeight), size: CGSize(width: size.width, height: bottomPanelHeight)))
            
            if self.canManage && !isEditingTool {
                let panelCheck: ComponentView<Empty>
                if let current = self.panelCheck {
                    panelCheck = current
                } else {
                    panelCheck = ComponentView<Empty>()
                    self.panelCheck = panelCheck
                }
                let checkTheme = CheckComponent.Theme(
                    backgroundColor: presentationData.theme.list.itemCheckColors.fillColor,
                    strokeColor: presentationData.theme.list.itemCheckColors.foregroundColor,
                    borderColor: presentationData.theme.list.itemCheckColors.strokeColor,
                    overlayBorder: false,
                    hasInset: false,
                    hasShadow: false
                )
                
                let panelCheckSize = panelCheck.update(
                    transition: .immediate,
                    component: AnyComponent(
                        PlainButtonComponent(
                            content: AnyComponent(HStack([
                                AnyComponentWithIdentity(id: AnyHashable(0), component: AnyComponent(CheckComponent(
                                    theme: checkTheme,
                                    size: CGSize(width: 22.0, height: 22.0),
                                    selected: self.profileGifts.currentState?.notificationsEnabled ?? false
                                ))),
                                AnyComponentWithIdentity(id: AnyHashable(1), component: AnyComponent(MultilineTextComponent(
                                    text: .plain(NSAttributedString(string: presentationData.strings.PeerInfo_Gifts_ChannelNotify, font: Font.regular(17.0), textColor: presentationData.theme.list.itemPrimaryTextColor))
                                )))
                            ],
                            spacing: 16.0
                            )),
                            effectAlignment: .center,
                            action: { [weak self] in
                                guard let self, let currentState = self.profileGifts.currentState else {
                                    return
                                }
                                let enabled = !(currentState.notificationsEnabled ?? false)
                                self.profileGifts.toggleStarGiftsNotifications(enabled: enabled)
                                
                                let animation = enabled ? "anim_profileunmute" : "anim_profilemute"
                                let text = enabled ? presentationData.strings.PeerInfo_Gifts_ChannelNotifyTooltip : presentationData.strings.PeerInfo_Gifts_ChannelNotifyDisabledTooltip
                                
                                let controller = UndoOverlayController(
                                    presentationData: presentationData,
                                    content: .universal(animation: animation, scale: 0.075, colors: ["__allcolors__": UIColor.white], title: nil, text: text, customUndoText: nil, timeout: nil),
                                    appearance: UndoOverlayController.Appearance(bottomInset: 53.0),
                                    action: { _ in return true }
                                )
                                self.chatControllerInteraction.presentController(controller, nil)
                              
                                self.updateScrolling(transition: .immediate)
                            },
                            animateAlpha: false,
                            animateScale: false
                        )
                    ),
                    environment: {},
                    containerSize: panelButtonSize
                )
                if let panelCheckView = panelCheck.view {
                    if panelCheckView.superview == nil {
                        panelContentContainer.addSubview(panelCheckView)
                    }
                    panelCheckView.frame = CGRect(origin: CGPoint(x: floor((size.width - panelCheckSize.width) / 2.0), y: 16.0 + 16.0), size: panelCheckSize)
                    panelCheckView.isHidden = false
                }
                if let panelButtonView = panelButton.view {
                    panelButtonView.isHidden = true
                }
            } else if let panelCheckView = self.panelCheck?.view {
                panelCheckView.isHidden = true
            }
            
            let edgeEffectFrame = CGRect(x: 0.0, y: 0.0, width: size.width, height: bottomPanelHeight)
            panelTransition.setFrame(view: panelEdgeEffectView, frame: edgeEffectFrame)
            panelEdgeEffectView.update(content: presentationData.theme.list.blocksBackgroundColor, blur: false, rect: edgeEffectFrame, edge: .bottom, edgeSize: 40.0, transition: panelTransition)
            
            ComponentTransition.spring(duration: 0.4).setSublayerTransform(view: panelContentContainer, transform: CATransform3DMakeTranslation(0.0, bottomPanelHeight * (1.0 - panelVisibility), 0.0))
            
            contentHeight += bottomPanelHeight
            bottomScrollInset = bottomPanelHeight - 40.0
            contentHeight += params.bottomInset
            
            self.scrollNode.view.scrollIndicatorInsets = UIEdgeInsets(top: 50.0, left: 0.0, bottom: bottomScrollInset, right: 0.0)
            
            let contentSize = CGSize(width: params.size.width, height: contentHeight)
            if self.scrollNode.view.contentSize != contentSize {
                self.scrollNode.view.contentSize = contentSize
            }
        }
        
        let bottomContentOffset = max(0.0, self.scrollNode.view.contentSize.height - self.scrollNode.view.contentOffset.y - self.scrollNode.view.frame.height)
        if bottomContentOffset < 200.0 {
            Queue.mainQueue().justDispatch {
                self.giftsListView.loadMore()
            }
        }
    }
        
    @objc private func buttonPressed() {
        if self.peerId == self.context.account.peerId || self.canManage {
            if case let .collection(id) = self.currentCollection {
                self.addGiftsToCollection(id: id)
            } else {
                let _ = (self.context.account.stateManager.contactBirthdays
                         |> take(1)
                         |> deliverOnMainQueue).start(next: { [weak self] birthdays in
                    guard let self else {
                        return
                    }
                    let controller = self.context.sharedContext.makePremiumGiftController(context: self.context, source: .settings(birthdays), completion: nil)
                    controller.navigationPresentation = .modal
                    self.chatControllerInteraction.navigationController()?.pushViewController(controller)
                })
            }
        } else {
            self.chatControllerInteraction.sendGift(self.peerId)
        }
    }
    
    private func contextAction(gift: ProfileGiftsContext.State.StarGift, view: UIView, gesture: ContextGesture) {
        guard let currentParams = self.currentParams else {
            return
        }
        let presentationData = currentParams.presentationData
        let strings = presentationData.strings
        
        let canManage = self.peerId == self.context.account.peerId || self.canManage
        var canReorder = false
        if case .all = self.currentCollection, let currentState = self.profileGifts.currentState {
            if case .All = currentState.filter {
                for gift in currentState.gifts {
                    if gift.pinnedToTop {
                        canReorder = true
                        break
                    }
                }
            }
        } else {
            canReorder = true
        }
        
        let profileGifts: ProfileGiftsContext
        switch self.currentCollection {
        case let .collection(id):
            profileGifts = self.profileGiftsCollections.giftsContextForCollection(id: id)
        default:
            profileGifts = self.profileGifts
        }
        
        var items: [ContextMenuItem] = []
        if gift.reference != nil {
            if self.canBulkManageGifts {
                let now = Int32(clamping: Int64(Date().timeIntervalSince1970))
                if GiftBulkActions.isEligible(gift: gift, mode: .transfer, now: now) {
                    items.append(.action(ContextMenuActionItem(text: self.bulkTransferGiftsTitle, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Peer Info/TransferIcon"), color: theme.contextMenu.primaryColor)
                    }, action: { [weak self] controller, _ in
                        controller?.dismiss(completion: { [weak self] in
                            self?.beginBulkGiftSelection(mode: .transfer, initialGift: gift)
                        })
                    })))
                }
                if GiftBulkActions.isEligible(gift: gift, mode: .upgrade, now: now) {
                    items.append(.action(ContextMenuActionItem(text: self.bulkUpgradeGiftsTitle, icon: { theme in
                        return generateTintedImage(image: UIImage(bundleImageName: "Premium/GiftUpgrade"), color: theme.contextMenu.primaryColor)
                    }, action: { [weak self] controller, _ in
                        controller?.dismiss(completion: { [weak self] in
                            self?.beginBulkGiftSelection(mode: .upgrade, initialGift: gift)
                        })
                    })))
                }
            }
            items.append(.action(ContextMenuActionItem(text: self.resizeGiftsTitle, icon: { _ in
                return generateTintedImage(image: UIImage(bundleImageName: "Peer Info/Gifts/Resize"), color: .white)
            }, action: { [weak self] controller, _ in
                controller?.dismiss(completion: { [weak self] in
                    self?.beginSizeEditing()
                })
            })))
        }
        if canManage {
            items.append(.action(ContextMenuActionItem(text: strings.PeerInfo_Gifts_Context_AddToCollection, textLayout: .twoLinesMax, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Peer Info/Gifts/AddToCollection"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, f in
                var subItems: [ContextMenuItem] = []
                
                subItems.append(.action(ContextMenuActionItem(text: strings.Common_Back, textColor: .primary, icon: { theme in
                    return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Back"), color: theme.actionSheet.primaryTextColor)
                }, iconSource: nil, iconPosition: .left, action: { c, _ in
                    c?.popItems()
                })))
                
                subItems.append(.separator)
                
                subItems.append(.action(ContextMenuActionItem(text: strings.PeerInfo_Gifts_Context_NewCollection, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Peer Info/Gifts/AddCollection"), color: theme.contextMenu.primaryColor) }, iconPosition: .left, action: { [weak self] c, f in
                    f(.default)
                    
                    self?.createCollection(gifts: [gift])
                })))
                
                var entityFiles: [Int64: TelegramMediaFile] = [:]
                
                if let collections = self?.collections {
                    for collection in collections {
                        if let file = collection.icon {
                            entityFiles[file.fileId.id] = file
                        }
                    }
                    
                    for collection in collections {
                        let title: String
                        var entities: [MessageTextEntity] = []
                        if let icon = collection.icon {
                            title = "#   \(collection.title)"
                            entities = [
                                MessageTextEntity(
                                    range: 0..<1,
                                    type: .CustomEmoji(stickerPack: nil, fileId: icon.fileId.id)
                                )
                            ]
                        } else {
                            title = collection.title
                        }
                        
                        let isAdded = gift.collectionIds?.contains(collection.id) ?? false
                        
                        subItems.append(.action(ContextMenuActionItem(text: title, entities: entities, entityFiles: entityFiles, enableEntityAnimations: false, icon: { theme in
                            return entities.isEmpty ? generateTintedImage(image: UIImage(bundleImageName: "Peer Info/Gifts/Collection"), color: theme.contextMenu.primaryColor) : (isAdded ? generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Check"), color: theme.contextMenu.primaryColor) : UIImage())
                        }, iconPosition: collection.icon == nil ? .left : .right, action: { [weak self] _, f in
                            f(.default)
                            
                            guard let self else {
                                return
                            }
                            
                            if isAdded, let giftReference = gift.reference {
                                let _ = self.profileGiftsCollections.removeGifts(id: collection.id, gifts: [giftReference]).start()
                            } else {
                                let _ = self.profileGiftsCollections.addGifts(id: collection.id, gifts: [gift]).start()
                            }
                            
                            var giftFile: TelegramMediaFile?
                            var giftTitle: String?
                            switch gift.gift {
                            case let .generic(gift):
                                giftFile = gift.file
                            case let .unique(uniqueGift):
                                giftTitle = uniqueGift.title + " #\(formatCollectibleNumber(uniqueGift.number, dateTimeFormat: currentParams.presentationData.dateTimeFormat))"
                                for attribute in uniqueGift.attributes {
                                    if case let .model(_, file, _, _) = attribute {
                                        giftFile = file
                                    }
                                }
                            }
                            
                            if let giftFile {
                                let text: String
                                if let giftTitle {
                                    if isAdded {
                                        text = currentParams.presentationData.strings.PeerInfo_Gifts_RemovedFromCollectionUnique(giftTitle, collection.title).string
                                    } else {
                                        text = currentParams.presentationData.strings.PeerInfo_Gifts_AddedToCollectionUnique(giftTitle, collection.title).string
                                    }
                                } else {
                                    if isAdded {
                                        text = currentParams.presentationData.strings.PeerInfo_Gifts_RemovedFromCollection(collection.title).string
                                    } else {
                                        text = currentParams.presentationData.strings.PeerInfo_Gifts_AddedToCollection(collection.title).string
                                    }
                                }
                                
                                let undoController = UndoOverlayController(
                                    presentationData: currentParams.presentationData,
                                    content: .sticker(context: self.context, file: giftFile, loop: false, title: nil, text: text, undoText: nil, customAction: nil),
                                    elevatedLayout: true,
                                    action: { _ in return true }
                                )
                                self.parentController?.present(undoController, in: .current)
                            }
                        })))
                    }
                }
                
                c?.pushItems(items: .single(ContextController.Items(content: .list(subItems))))
            })))
            items.append(.separator)
        }
        
        if canManage {
            if case .unique = gift.gift, case .all = self.currentCollection {
                items.append(.action(ContextMenuActionItem(text: gift.pinnedToTop ? strings.PeerInfo_Gifts_Context_Unpin : strings.PeerInfo_Gifts_Context_Pin, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: gift.pinnedToTop ? "Chat/Context Menu/Unpin" : "Chat/Context Menu/Pin"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, f in
                    c?.dismiss(completion: { [weak self] in
                        guard let self else {
                            return
                        }
                        let pinnedToTop = !gift.pinnedToTop
                        guard let reference = gift.reference else {
                            return
                        }
                        
                        if pinnedToTop && self.giftsListView.pinnedReferences.count >= self.giftsListView.maxPinnedCount {
                            self.displayUnpinScreen(gift: gift)
                            return
                        }
                        
                        profileGifts.updateStarGiftPinnedToTop(reference: reference, pinnedToTop: pinnedToTop)
                        
                        let toastTitle: String?
                        let toastText: String
                        if !pinnedToTop {
                            toastTitle = nil
                            toastText = strings.PeerInfo_Gifts_ToastUnpinned_Text
                        } else {
                            var title = ""
                            if case let .unique(uniqueGift) = gift.gift {
                                title = "\(uniqueGift.title) #\(formatCollectibleNumber(uniqueGift.number, dateTimeFormat: presentationData.dateTimeFormat))"
                            }
                            toastTitle = strings.PeerInfo_Gifts_ToastPinned_TitleNew(title).string
                            toastText = strings.PeerInfo_Gifts_ToastPinned_Text
                        }
                        self.parentController?.present(UndoOverlayController(presentationData: presentationData, content: .universal(animation: !pinnedToTop ? "anim_toastunpin" : "anim_toastpin", scale: 0.06, colors: [:], title: toastTitle, text: toastText, customUndoText: nil, timeout: 5), elevatedLayout: true, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
                    })
                })))
            }
            
            var isReorderableGift = false
            if case .unique = gift.gift {
                isReorderableGift = true
            } else if case .collection = self.currentCollection {
                isReorderableGift = true
            }
            
            if isReorderableGift && canManage && canReorder {
                items.append(.action(ContextMenuActionItem(text: strings.PeerInfo_Gifts_Context_Reorder, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/ReorderItems"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, f in
                    c?.dismiss(completion: { [weak self] in
                        guard let self else {
                            return
                        }
                        self.beginReordering()
                    })
                })))
            }
            
            if case let .unique(uniqueGift) = gift.gift, self.peerId == self.context.account.peerId {
                items.append(.action(ContextMenuActionItem(text: strings.PeerInfo_Gifts_Context_Wear, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Peer Info/WearIcon"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, f in
                    c?.dismiss(completion: { [weak self] in
                        guard let self else {
                            return
                        }
                        if self.context.isPremium {
                            let _ = self.context.engine.accountData.setStarGiftStatus(starGift: uniqueGift, expirationDate: nil).startStandalone()
                        } else {
                            let text = strings.Gift_View_TooltipPremiumWearing
                            let tooltipController = UndoOverlayController(
                                presentationData: presentationData,
                                content: .premiumPaywall(title: nil, text: text, customUndoText: nil, timeout: nil, linkAction: nil),
                                position: .bottom,
                                animateInAsReplacement: false,
                                appearance: UndoOverlayController.Appearance(sideInset: 16.0, bottomInset: 62.0),
                                action: { [weak self] action in
                                    if let self, case .info = action {
                                        let premiumController = self.context.sharedContext.makePremiumIntroController(context: self.context, source: .messageEffects, forceDark: false, dismissed: nil)
                                        self.parentController?.push(premiumController)
                                    }
                                    return false
                                }
                            )
                            self.parentController?.present(tooltipController, in: .current)
                        }
                    })
                })))
            }
        }
        
        if case let .unique(gift) = gift.gift {
            let link = "https://t.me/nft/\(gift.slug)"
            
            items.append(.action(ContextMenuActionItem(text: strings.PeerInfo_Gifts_Context_CopyLink, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Link"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, f in
                c?.dismiss(completion: { [weak self] in
                    guard let self else {
                        return
                    }
                    UIPasteboard.general.string = link
                    
                    self.parentController?.present(UndoOverlayController(presentationData: currentParams.presentationData, content: .linkCopied(title: nil, text: currentParams.presentationData.strings.Conversation_LinkCopied), elevatedLayout: true, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                })
            })))
            
            items.append(.action(ContextMenuActionItem(text: strings.PeerInfo_Gifts_Context_Share, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Forward"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, f in
                c?.dismiss(completion: { [weak self] in
                    guard let self else {
                        return
                    }
                    let context = self.context
                    let shareController = context.sharedContext.makeShareController(
                        context: context,
                        params: ShareControllerParams(
                            subject: .url(link),
                            externalShare: false,
                            actionCompleted: { [weak self] in
                                self?.parentController?.present(UndoOverlayController(presentationData: presentationData, content: .linkCopied(title: nil, text: presentationData.strings.Conversation_LinkCopied), elevatedLayout: true, animateInAsReplacement: false, action: { _ in return false }), in: .current)
                            },
                            enqueued: { [weak self] peerIds, _ in
                                let _ = (context.engine.data.get(
                                    EngineDataList(
                                        peerIds.map(TelegramEngine.EngineData.Item.Peer.Peer.init)
                                    )
                                )
                                |> deliverOnMainQueue).startStandalone(next: { [weak self] peerList in
                                    guard let self, let parentController = self.parentController else {
                                        return
                                    }

                                    let peers = peerList.compactMap { $0 }
                                    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                                    let text: String
                                    var savedMessages = false
                                    if peerIds.count == 1, let peerId = peerIds.first, peerId == context.account.peerId {
                                        text = presentationData.strings.Conversation_ForwardTooltip_SavedMessages_One
                                        savedMessages = true
                                    } else {
                                        if peers.count == 1, let peer = peers.first {
                                            var peerName = peer.id == context.account.peerId ? presentationData.strings.DialogList_SavedMessages : peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                            peerName = peerName.replacingOccurrences(of: "**", with: "")
                                            text = presentationData.strings.Conversation_ForwardTooltip_Chat_One(peerName).string
                                        } else if peers.count == 2, let firstPeer = peers.first, let secondPeer = peers.last {
                                            var firstPeerName = firstPeer.id == context.account.peerId ? presentationData.strings.DialogList_SavedMessages : firstPeer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                            firstPeerName = firstPeerName.replacingOccurrences(of: "**", with: "")
                                            var secondPeerName = secondPeer.id == context.account.peerId ? presentationData.strings.DialogList_SavedMessages : secondPeer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                            secondPeerName = secondPeerName.replacingOccurrences(of: "**", with: "")
                                            text = presentationData.strings.Conversation_ForwardTooltip_TwoChats_One(firstPeerName, secondPeerName).string
                                        } else if let peer = peers.first {
                                            var peerName = peer.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
                                            peerName = peerName.replacingOccurrences(of: "**", with: "")
                                            text = presentationData.strings.Conversation_ForwardTooltip_ManyChats_One(peerName, "\(peers.count - 1)").string
                                        } else {
                                            text = ""
                                        }
                                    }

                                    parentController.present(UndoOverlayController(presentationData: presentationData, content: .forward(savedMessages: savedMessages, text: text), elevatedLayout: true, animateInAsReplacement: false, action: { [weak self] action in
                                        if savedMessages, action == .info {
                                            let _ = (context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))
                                            |> deliverOnMainQueue).start(next: { [weak self] peer in
                                                guard let peer, let navigationController = self?.parentController?.navigationController as? NavigationController else {
                                                    return
                                                }
                                                context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, chatController: nil, context: context, chatLocation: .peer(peer), subject: nil, botStart: nil, updateTextInputState: nil, keepStack: .always, useExisting: true, purposefulAction: nil, scrollToEndIfExists: false, activateMessageSearch: nil, animated: true))
                                            })
                                        }
                                        return false
                                    }, additionalView: nil), in: .current)
                                })
                            },
                            shareStory: { [weak self] in
                                guard let self, let parentController = self.parentController else {
                                    return
                                }
                                Queue.mainQueue().after(0.15) {
                                    let controller = self.context.sharedContext.makeStorySharingScreen(context: self.context, subject: .gift(gift), parentController: parentController)
                                    parentController.push(controller)
                                }
                            }
                        )
                    )
                    self.parentController?.present(shareController, in: .window(.root))
                })
            })))
        }
        
        if canManage {
            items.append(.action(ContextMenuActionItem(text: gift.savedToProfile ? strings.PeerInfo_Gifts_Context_Hide : strings.PeerInfo_Gifts_Context_Show, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: gift.savedToProfile ? "Peer Info/HideIcon" : "Peer Info/ShowIcon"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, f in
                c?.dismiss(completion: { [weak self] in
                    guard let self else {
                        return
                    }
                    if let reference = gift.reference {
                        let added = !gift.savedToProfile
                        profileGifts.updateStarGiftAddedToProfile(reference: reference, added: added)
                        
                        var animationFile: TelegramMediaFile?
                        switch gift.gift {
                        case let .generic(gift):
                            animationFile = gift.file
                        case let .unique(gift):
                            for attribute in gift.attributes {
                                if case let .model(_, file, _, _) = attribute {
                                    animationFile = file
                                    break
                                }
                            }
                        }
                                                
                        let text: String
                        if self.peerId.namespace == Namespaces.Peer.CloudChannel {
                            text = added ? presentationData.strings.Gift_Displayed_ChannelText : presentationData.strings.Gift_Hidden_ChannelText
                        } else {
                            text = added ? presentationData.strings.Gift_Displayed_NewText : presentationData.strings.Gift_Hidden_NewText
                        }
                        
                        if let animationFile {
                            let resultController = UndoOverlayController(
                                presentationData: presentationData,
                                content: .sticker(context: context, file: animationFile, loop: false, title: nil, text: text, undoText: nil, customAction: nil),
                                elevatedLayout: true,
                                action: { _ in
                                    return true
                                }
                            )
                            self.parentController?.present(resultController, in: .window(.root))
                        }
                    }
                })
            })))
            
            if case let .unique(uniqueGift) = gift.gift {
                items.append(.action(ContextMenuActionItem(text: strings.PeerInfo_Gifts_Context_Transfer, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Peer Info/TransferIcon"), color: theme.contextMenu.primaryColor) }, action: { [weak self] c, f in
                    c?.dismiss(completion: { [weak self] in
                        guard let self else {
                            return
                        }
                        let context = self.context
                        
                        guard uniqueGift.hostPeerId == nil else {
                            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
                            let alertController = textAlertController(
                                context: context,
                                title: presentationData.strings.Gift_UnavailableAction_Title,
                                text: presentationData.strings.Gift_UnavailableAction_Text,
                                actions: [
                                    TextAlertAction(type: .defaultAction, title: presentationData.strings.Gift_UnavailableAction_OpenFragment, action: {
                                        context.sharedContext.openExternalUrl(context: context, urlContext: .generic, url: "https://fragment.com/gift/\(uniqueGift.slug)", forceExternal: true, presentationData: presentationData, navigationController: nil, dismissInput: {})
                                    }),
                                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {})
                                ],
                                actionLayout: .vertical
                            )
                            self.parentController?.present(alertController, in: .window(.root))
                            return
                        }
                        
                        let _ = (context.account.stateManager.contactBirthdays
                        |> take(1)
                        |> deliverOnMainQueue).start(next: { [weak self] birthdays in
                            guard let self, let reference = gift.reference else {
                                return
                            }
                            var showSelf = false
                            if self.peerId.namespace == Namespaces.Peer.CloudChannel {
                                showSelf = true
                            }
                            let transferStars = gift.transferStars ?? 0
                            let controller = context.sharedContext.makePremiumGiftController(context: context, source: .starGiftTransfer(birthdays, reference, uniqueGift, transferStars, gift.canExportDate, showSelf), completion: { peerIds in
                                guard let peerId = peerIds.first else {
                                    return .complete()
                                }
                                Queue.mainQueue().after(1.5, {
                                    if transferStars > 0 {
                                        context.starsContext?.load(force: true)
                                    }
                                })
                                return profileGifts.transferStarGift(prepaid: transferStars == 0, reference: reference, peerId: peerId)
                            })
                            self.parentController?.push(controller)
                        })
                    })
                })))
            }
        }
        
        if canManage, case let .collection(id) = self.currentCollection {
            items.append(.action(ContextMenuActionItem(text: strings.PeerInfo_Gifts_Context_RemoveFromCollection, textColor: .destructive, textLayout: .twoLinesMax, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Peer Info/Gifts/RemoveFromCollection"), color: theme.contextMenu.destructiveColor) }, action: { [weak self] c, f in
                f(.default)
                
                guard let self else {
                    return
                }
                
                if let reference = gift.reference {
                    let _ = self.profileGiftsCollections.removeGifts(id: id, gifts: [reference]).start()
                }
                
                var giftFile: TelegramMediaFile?
                var giftTitle: String?
                switch gift.gift {
                case let .generic(gift):
                    giftFile = gift.file
                case let .unique(uniqueGift):
                    giftTitle = uniqueGift.title + " #\(formatCollectibleNumber(uniqueGift.number, dateTimeFormat: currentParams.presentationData.dateTimeFormat))"
                    for attribute in uniqueGift.attributes {
                        if case let .model(_, file, _, _) = attribute {
                            giftFile = file
                        }
                    }
                }
                
                if let giftFile, let collection = self.collections?.first(where: { $0.id == id }) {
                    let text: String
                    if let giftTitle {
                        text = currentParams.presentationData.strings.PeerInfo_Gifts_RemovedFromCollectionUnique(giftTitle, collection.title).string
                    } else {
                        text = currentParams.presentationData.strings.PeerInfo_Gifts_RemovedFromCollection(collection.title).string
                    }
                    
                    let undoController = UndoOverlayController(
                        presentationData: currentParams.presentationData,
                        content: .sticker(context: self.context, file: giftFile, loop: false, title: nil, text: text, undoText: nil, customAction: nil),
                        elevatedLayout: true,
                        action: { _ in return true }
                    )
                    self.parentController?.present(undoController, in: .current)
                }
            })))
        }
        
        guard !items.isEmpty else {
            return
        }
        
        let previewController = GiftContextPreviewController(context: self.context, gift: gift)
        let contextController = makeContextController(
            context: self.context,
            presentationData: currentParams.presentationData,
            source: .controller(ContextControllerContentSourceImpl(controller: previewController, sourceView: view)),
            items: .single(ContextController.Items(content: .list(items))), gesture: gesture
        )
        self.parentController?.presentInGlobalOverlay(contextController)
    }
    
    public func update(size: CGSize, topInset: CGFloat, sideInset: CGFloat, bottomInset: CGFloat, deviceMetrics: DeviceMetrics, visibleHeight: CGFloat, isScrollingLockedAtTop: Bool, expandProgress: CGFloat, navigationHeight: CGFloat, presentationData: PresentationData, synchronous: Bool, transition: ContainedViewLayoutTransition) {
        self.currentParams = (size, topInset, sideInset, bottomInset, deviceMetrics, visibleHeight, isScrollingLockedAtTop, expandProgress, navigationHeight, presentationData)
        self.presentationDataPromise.set(.single(presentationData))
        
        self.backgroundNode.backgroundColor = presentationData.theme.list.blocksBackgroundColor
        transition.updateFrame(node: self.backgroundNode, frame: CGRect(origin: CGPoint(x: 0.0, y: topInset), size: CGSize(width: size.width, height: size.height - topInset)))
        transition.updateFrame(node: self.scrollNode, frame: CGRect(origin: CGPoint(), size: size))
        
        let visibleBounds = self.scrollNode.bounds.insetBy(dx: 0.0, dy: -10.0)
        
        let contentHeight = self.giftsListView.update(size: size, sideInset: sideInset, bottomInset: bottomInset, deviceMetrics: deviceMetrics, visibleHeight: visibleHeight, isScrollingLockedAtTop: isScrollingLockedAtTop, expandProgress: expandProgress, presentationData: presentationData, synchronous: synchronous, visibleBounds: visibleBounds, transition: transition)
        transition.updateFrame(view: self.giftsListView, frame: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: max(size.height, contentHeight))))
        
        if isScrollingLockedAtTop {
            self.scrollNode.view.contentOffset = .zero
        }
        self.scrollNode.view.isScrollEnabled = !isScrollingLockedAtTop && !self.giftsListView.isResizingGift && !self.bulkGiftBusy
        
        self.updateScrolling(transition: ComponentTransition(transition))
    }
    
    public func findLoadedMessage(id: EngineMessage.Id) -> EngineMessage? {
        return nil
    }
    
    public func updateHiddenMedia() {
    }
    
    public func transferVelocity(_ velocity: CGFloat) {
        if velocity > 0.0 {
//            self.scrollNode.transferVelocity(velocity)
        }
    }
    
    public func cancelPreviewGestures() {
    }
    
    public func transitionNodeForGallery(messageId: EngineMessage.Id, media: EngineMedia) -> (ASDisplayNode, CGRect, () -> (UIView?, UIView?))? {
        return nil
    }
    
    public func addToTransitionSurface(view: UIView) {
    }
    
    public func updateSelectedMessages(animated: Bool) {
    }
}

private func cancelContextGestures(view: UIView) {
    if let gestureRecognizers = view.gestureRecognizers {
        for gesture in gestureRecognizers {
            if let gesture = gesture as? ContextGesture {
                gesture.cancel()
            }
        }
    }
    for subview in view.subviews {
        cancelContextGestures(view: subview)
    }
}

private final class ContextControllerContentSourceImpl: ContextControllerContentSource {
    let controller: ViewController
    weak var sourceView: UIView?
    
    let navigationController: NavigationController? = nil
    
    let passthroughTouches: Bool = false
    
    init(controller: ViewController, sourceView: UIView?) {
        self.controller = controller
        self.sourceView = sourceView
    }
    
    func transitionInfo() -> ContextControllerTakeControllerInfo? {
        let sourceView = self.sourceView
        
        return ContextControllerTakeControllerInfo(contentAreaInScreenSpace: CGRect(origin: CGPoint(), size: CGSize(width: 10.0, height: 10.0)), sourceNode: { [weak sourceView] in
            if let sourceView {
                return (sourceView, sourceView.bounds)
            } else {
                return nil
            }
        })
    }
    
    func animatedIn() {
        self.controller.didAppearInContextPreview()
    }
}

private final class GiftsExtractedContentSource: ContextExtractedContentSource {
    let keepInPlace: Bool = false
    let ignoreContentTouches: Bool = false
    let blurBackground: Bool = true
    
    private let sourceNode: ContextExtractedContentContainingNode
    
    init(sourceNode: ContextExtractedContentContainingNode) {
        self.sourceNode = sourceNode
    }
    
    func takeView() -> ContextControllerTakeViewInfo? {
        return ContextControllerTakeViewInfo(containingItem: .node(self.sourceNode), contentAreaInScreenSpace: UIScreen.main.bounds)
    }
    
    func putBack() -> ContextControllerPutBackViewInfo? {
        return ContextControllerPutBackViewInfo(contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}
