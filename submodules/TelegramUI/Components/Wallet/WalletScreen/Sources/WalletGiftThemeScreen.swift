import Foundation
import UIKit
import Display
import AccountContext
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ComponentFlow
import ViewControllerComponent
import GiftItemComponent

private final class WalletGiftThemeDefaultRow: UIControl {
    private let preview = UIView()
    private let gradient = CAGradientLayer()
    private let previewLine = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let checkView = UIImageView()

    var pressed: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.layer.cornerRadius = 16.0
        self.preview.layer.cornerRadius = 8.0
        self.preview.clipsToBounds = true
        self.gradient.colors = [UIColor(rgb: 0x055ac4).cgColor, UIColor(rgb: 0x25bafa).cgColor]
        self.gradient.startPoint = CGPoint(x: 0.0, y: 1.0)
        self.gradient.endPoint = CGPoint(x: 1.0, y: 0.0)
        self.preview.layer.addSublayer(self.gradient)
        self.preview.isUserInteractionEnabled = false
        self.addSubview(self.preview)
        self.previewLine.backgroundColor = UIColor.white.withAlphaComponent(0.8)
        self.previewLine.layer.cornerRadius = 1.0
        self.preview.addSubview(self.previewLine)

        self.titleLabel.numberOfLines = 1
        self.subtitleLabel.numberOfLines = 2
        self.titleLabel.isUserInteractionEnabled = false
        self.subtitleLabel.isUserInteractionEnabled = false
        self.addSubview(self.titleLabel)
        self.addSubview(self.subtitleLabel)
        self.checkView.contentMode = .center
        self.checkView.isUserInteractionEnabled = false
        self.addSubview(self.checkView)

        self.isAccessibilityElement = true
        self.accessibilityIdentifier = "Wallet.GiftThemes.Default"
        self.addTarget(self, action: #selector(self.buttonPressed), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            self.alpha = self.isHighlighted ? 0.6 : 1.0
        }
    }

    @objc private func buttonPressed() {
        self.pressed?()
    }

    override func accessibilityActivate() -> Bool {
        self.buttonPressed()
        return true
    }

    func update(theme: PresentationTheme, isRussian: Bool, isSelected: Bool, width: CGFloat) -> CGFloat {
        self.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.titleLabel.text = isRussian ? "Стандартная тема" : "Default Theme"
        self.titleLabel.font = Font.medium(17.0)
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.subtitleLabel.text = isRussian ? "Оригинальная синяя карта" : "The original blue card"
        self.subtitleLabel.font = Font.regular(13.0)
        self.subtitleLabel.textColor = theme.list.itemSecondaryTextColor
        self.checkView.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18.0, weight: .semibold))?.withTintColor(theme.list.itemAccentColor, renderingMode: .alwaysOriginal)
        self.checkView.isHidden = !isSelected
        self.accessibilityLabel = self.titleLabel.text
        self.accessibilityValue = isSelected ? "Selected" : "NotSelected"
        self.accessibilityTraits = isSelected ? [.button, .selected] : .button

        let textWidth = max(0.0, width - 90.0 - 48.0)
        let titleSize = self.titleLabel.sizeThatFits(CGSize(width: textWidth, height: 100.0))
        let subtitleSize = self.subtitleLabel.sizeThatFits(CGSize(width: textWidth, height: 100.0))
        let height = max(80.0, titleSize.height + subtitleSize.height + 34.0)
        self.preview.frame = CGRect(x: 16.0, y: floor((height - 38.0) / 2.0), width: 58.0, height: 38.0)
        self.gradient.frame = self.preview.bounds
        self.previewLine.frame = CGRect(x: 8.0, y: 25.0, width: 20.0, height: 3.0)
        self.titleLabel.frame = CGRect(x: 90.0, y: floor((height - titleSize.height - subtitleSize.height - 4.0) / 2.0), width: textWidth, height: titleSize.height)
        self.subtitleLabel.frame = CGRect(x: 90.0, y: self.titleLabel.frame.maxY + 4.0, width: textWidth, height: subtitleSize.height)
        self.checkView.frame = CGRect(x: width - 40.0, y: floor((height - 24.0) / 2.0), width: 24.0, height: 24.0)
        return height
    }
}

private final class WalletGiftThemeTile: UIView {
    private let gift = ComponentView<Empty>()
    private let button = UIButton(type: .custom)
    private let checkView = UIImageView()
    private let titleLabel = UILabel()
    private let numberLabel = UILabel()

    var pressed: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        self.checkView.contentMode = .center
        self.checkView.layer.cornerRadius = 12.0
        self.checkView.isUserInteractionEnabled = false
        self.button.addSubview(self.checkView)
        self.button.layer.cornerRadius = 16.0
        self.button.addTarget(self, action: #selector(self.buttonPressed), for: .touchUpInside)
        self.button.addTarget(self, action: #selector(self.highlightChanged), for: [.touchDown, .touchDragEnter, .touchDragExit, .touchUpInside, .touchUpOutside, .touchCancel])
        self.button.isAccessibilityElement = true
        self.addSubview(self.button)
        self.titleLabel.numberOfLines = 1
        self.titleLabel.textAlignment = .center
        self.numberLabel.numberOfLines = 1
        self.numberLabel.textAlignment = .center
        self.titleLabel.isAccessibilityElement = false
        self.numberLabel.isAccessibilityElement = false
        self.addSubview(self.titleLabel)
        self.addSubview(self.numberLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func buttonPressed() {
        self.pressed?()
    }

    @objc private func highlightChanged() {
        self.alpha = self.button.isHighlighted ? 0.6 : 1.0
    }

    func update(context: AccountContext, theme: PresentationTheme, strings: PresentationStrings, uniqueGift: StarGift.UniqueGift, isSelected: Bool, allowAnimations: Bool, width: CGFloat, transition: ComponentTransition) -> CGSize {
        let giftSize = self.gift.update(
            transition: transition,
            component: AnyComponent(GiftItemComponent(
                context: context,
                style: .glass,
                theme: theme,
                strings: strings,
                subject: .uniqueGift(gift: uniqueGift, price: nil),
                isSelected: false,
                mode: .grid,
                cornerRadius: 16.0,
                allowAnimations: allowAnimations,
                action: nil
            )),
            environment: {},
            containerSize: CGSize(width: width, height: width)
        )
        if let giftView = self.gift.view {
            if giftView.superview == nil {
                giftView.isUserInteractionEnabled = false
                giftView.isAccessibilityElement = false
                giftView.accessibilityElementsHidden = true
                self.insertSubview(giftView, at: 0)
            }
            transition.setFrame(view: giftView, frame: CGRect(origin: .zero, size: giftSize))
        }

        self.button.layer.borderWidth = isSelected ? 2.0 : 0.0
        self.button.layer.borderColor = theme.list.itemAccentColor.cgColor
        self.checkView.backgroundColor = theme.list.itemAccentColor
        self.checkView.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12.0, weight: .bold))?.withTintColor(.white, renderingMode: .alwaysOriginal)
        self.checkView.isHidden = !isSelected
        self.checkView.frame = CGRect(x: width - 30.0, y: 6.0, width: 24.0, height: 24.0)
        self.button.accessibilityLabel = "\(uniqueGift.title), #\(uniqueGift.number)"
        self.button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        self.button.accessibilityValue = isSelected ? "Selected" : "NotSelected"
        self.button.accessibilityIdentifier = "Wallet.GiftThemes.Gift.\(uniqueGift.id)"

        self.titleLabel.text = uniqueGift.title
        self.titleLabel.font = Font.medium(13.0)
        self.titleLabel.textColor = theme.list.itemPrimaryTextColor
        self.numberLabel.text = "#\(uniqueGift.number)"
        self.numberLabel.font = Font.regular(11.0)
        self.numberLabel.textColor = theme.list.itemSecondaryTextColor
        self.titleLabel.frame = CGRect(x: 0.0, y: width + 8.0, width: width, height: 18.0)
        self.numberLabel.frame = CGRect(x: 0.0, y: width + 27.0, width: width, height: 16.0)
        let size = CGSize(width: width, height: width + 44.0)
        transition.setFrame(view: self.button, frame: CGRect(origin: .zero, size: size))
        return size
    }
}

private final class WalletGiftThemeScreenComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment

    let context: AccountContext
    let selectedGift: StarGift.UniqueGift?
    let completion: (StarGift.UniqueGift?) -> Void

    init(context: AccountContext, selectedGift: StarGift.UniqueGift?, completion: @escaping (StarGift.UniqueGift?) -> Void) {
        self.context = context
        self.selectedGift = selectedGift
        self.completion = completion
    }

    static func ==(lhs: WalletGiftThemeScreenComponent, rhs: WalletGiftThemeScreenComponent) -> Bool {
        return lhs.context === rhs.context && lhs.selectedGift == rhs.selectedGift
    }

    private final class ScrollView: UIScrollView {
        override func touchesShouldCancel(in view: UIView) -> Bool {
            return true
        }
    }

    final class View: UIView, UIScrollViewDelegate {
        private let scrollView = ScrollView()
        private let refreshControl = UIRefreshControl()
        private let defaultRow = WalletGiftThemeDefaultRow()
        private let introduction = UILabel()
        private let sectionTitle = UILabel()
        private let emptyLabel = UILabel()
        private let reloadButton = UIButton(type: .system)
        private let loadingView = UIActivityIndicatorView(style: .medium)
        private var tiles: [Int64: WalletGiftThemeTile] = [:]

        private var giftsContext: ProfileGiftsContext?
        private var giftsDisposable: Disposable?
        private var giftsState: ProfileGiftsContext.State?
        private var gifts: [StarGift.UniqueGift] = []
        private var giftFrames: [(StarGift.UniqueGift, CGRect)] = []
        private var didChooseTheme = false
        private var isUpdating = false
        private var availableSize: CGSize?
        private var component: WalletGiftThemeScreenComponent?
        private weak var state: EmptyComponentState?
        private var environment: EnvironmentType?

        override init(frame: CGRect) {
            super.init(frame: frame)

            self.scrollView.delegate = self
            self.scrollView.alwaysBounceVertical = true
            self.scrollView.delaysContentTouches = false
            self.scrollView.canCancelContentTouches = true
            self.scrollView.contentInsetAdjustmentBehavior = .never
            self.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
            self.scrollView.refreshControl = self.refreshControl
            self.refreshControl.addTarget(self, action: #selector(self.reloadPressed), for: .valueChanged)
            self.addSubview(self.scrollView)
            self.scrollView.addSubview(self.defaultRow)
            self.introduction.numberOfLines = 0
            self.scrollView.addSubview(self.introduction)
            self.scrollView.addSubview(self.sectionTitle)
            self.emptyLabel.numberOfLines = 0
            self.emptyLabel.textAlignment = .center
            self.scrollView.addSubview(self.emptyLabel)
            self.reloadButton.addTarget(self, action: #selector(self.reloadPressed), for: .touchUpInside)
            self.reloadButton.accessibilityIdentifier = "Wallet.GiftThemes.Reload"
            self.scrollView.addSubview(self.reloadButton)
            self.scrollView.addSubview(self.loadingView)
            self.defaultRow.pressed = { [weak self] in
                self?.chooseTheme(nil)
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        deinit {
            self.giftsDisposable?.dispose()
        }

        @objc private func reloadPressed() {
            guard let component = self.component else {
                return
            }
            // A fresh context also resets pagination for the unique-only filter.
            self.updateGiftsContext(component: component, previousContext: nil)
            self.state?.updated(transition: .immediate)
        }

        private func chooseTheme(_ gift: StarGift.UniqueGift?) {
            guard let component = self.component, let controller = self.environment?.controller(), !self.didChooseTheme else {
                return
            }
            if let gift, !self.gifts.contains(where: { $0.id == gift.id }) {
                return
            }
            self.didChooseTheme = true
            HapticFeedback().impact(.light)
            component.completion(gift)
            if let navigationController = controller.navigationController, navigationController.topViewController === controller, navigationController.viewControllers.count > 1 {
                let _ = navigationController.popViewController(animated: true)
            } else {
                controller.dismiss()
            }
        }

        private func updateGiftsContext(component: WalletGiftThemeScreenComponent, previousContext: AccountContext?) {
            guard previousContext !== component.context else {
                return
            }
            self.giftsDisposable?.dispose()
            self.giftsState = nil
            self.gifts = []
            self.didChooseTheme = false
            let giftsContext = ProfileGiftsContext(account: component.context.account, peerId: component.context.account.peerId, filter: [.unique, .displayed, .hidden], limit: 36)
            self.giftsContext = giftsContext
            self.giftsDisposable = (giftsContext.state
            |> deliverOnMainQueue).start(next: { [weak self, weak giftsContext] giftsState in
                guard let self, let giftsContext, self.giftsContext === giftsContext else {
                    return
                }
                self.giftsState = giftsState
                var giftIds = Set<Int64>()
                self.gifts = giftsState.filteredGifts.compactMap { profileGift in
                    guard !profileGift.isRefunded, case let .unique(gift) = profileGift.gift, !gift.flags.contains(.isBurned), giftIds.insert(gift.id).inserted else {
                        return nil
                    }
                    return gift
                }
                if case .ready = giftsState.dataState {
                    self.refreshControl.endRefreshing()
                }
                Queue.mainQueue().justDispatch { [weak self, weak giftsContext] in
                    guard let self, let giftsContext, self.giftsContext === giftsContext else {
                        return
                    }
                    self.state?.updated(transition: .immediate)
                }
            })
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if !self.isUpdating {
                self.updateVisibleGifts(transition: .immediate)
            }
        }

        private func updateVisibleGifts(transition: ComponentTransition) {
            guard let component = self.component, let environment = self.environment, let availableSize = self.availableSize else {
                return
            }
            let visibleBounds = self.scrollView.bounds.insetBy(dx: 0.0, dy: -120.0)
            let allowAnimations = environment.isVisible && !UIAccessibility.isReduceMotionEnabled
            var validIds = Set<Int64>()
            for (gift, frame) in self.giftFrames where visibleBounds.intersects(frame) {
                validIds.insert(gift.id)
                let tile: WalletGiftThemeTile
                let itemTransition: ComponentTransition
                if let current = self.tiles[gift.id] {
                    tile = current
                    itemTransition = transition
                } else {
                    tile = WalletGiftThemeTile()
                    self.tiles[gift.id] = tile
                    self.scrollView.addSubview(tile)
                    itemTransition = .immediate
                }
                let _ = tile.update(context: component.context, theme: environment.theme, strings: environment.strings, uniqueGift: gift, isSelected: component.selectedGift?.id == gift.id, allowAnimations: allowAnimations, width: frame.width, transition: itemTransition)
                tile.pressed = { [weak self] in
                    self?.chooseTheme(gift)
                }
                itemTransition.setFrame(view: tile, frame: frame)
            }
            for id in self.tiles.keys.filter({ !validIds.contains($0) }) {
                self.tiles.removeValue(forKey: id)?.removeFromSuperview()
            }
            if environment.isVisible, case .ready(canLoadMore: true, nextOffset: _) = self.giftsState?.dataState, self.scrollView.contentOffset.y + availableSize.height + 400.0 >= self.scrollView.contentSize.height {
                self.giftsContext?.loadMore()
            }
        }

        func update(component: WalletGiftThemeScreenComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
            self.isUpdating = true
            defer {
                self.isUpdating = false
            }
            let previousContext = self.component?.context
            self.component = component
            self.state = state
            let environment = environment[EnvironmentType.self].value
            self.environment = environment
            self.availableSize = availableSize
            self.updateGiftsContext(component: component, previousContext: previousContext)

            let isRussian = environment.strings.primaryComponent.languageCode.lowercased().hasPrefix("ru")
            environment.controller()?.title = isRussian ? "Темы подарков" : "Gift Themes"
            self.backgroundColor = environment.theme.list.blocksBackgroundColor
            self.introduction.font = Font.regular(14.0)
            self.introduction.textColor = environment.theme.list.itemSecondaryTextColor
            self.introduction.text = isRussian ? "Выберите подарок — его цвета, узор и модель украсят вашу карту." : "Choose a gift to bring its colors, pattern and artwork to your card."
            self.sectionTitle.font = Font.semibold(13.0)
            self.sectionTitle.textColor = environment.theme.list.itemSecondaryTextColor
            self.sectionTitle.text = isRussian ? "ВАШИ ПОДАРКИ" : "YOUR GIFTS"
            self.emptyLabel.font = Font.regular(15.0)
            self.emptyLabel.textColor = environment.theme.list.itemSecondaryTextColor
            self.emptyLabel.text = isRussian ? "Ваши коллекционные подарки появятся здесь.\nЕсли список не загрузился, попробуйте обновить его." : "Your collectible gifts will appear here.\nIf the list did not load, try refreshing it."
            self.reloadButton.setTitle(isRussian ? "Обновить" : "Refresh", for: .normal)
            self.reloadButton.titleLabel?.font = Font.medium(15.0)
            self.reloadButton.tintColor = environment.theme.list.itemAccentColor
            self.loadingView.color = environment.theme.list.itemAccentColor
            self.refreshControl.tintColor = environment.theme.list.itemAccentColor

            let sideInset = 16.0 + environment.safeInsets.left
            let rightInset = 16.0 + environment.safeInsets.right
            let width = max(0.0, availableSize.width - sideInset - rightInset)
            var contentHeight = environment.navigationHeight + 16.0
            let rowHeight = self.defaultRow.update(theme: environment.theme, isRussian: isRussian, isSelected: component.selectedGift == nil, width: width)
            transition.setFrame(view: self.defaultRow, frame: CGRect(x: sideInset, y: contentHeight, width: width, height: rowHeight))
            contentHeight += rowHeight + 12.0
            let introductionSize = self.introduction.sizeThatFits(CGSize(width: max(0.0, width - 8.0), height: 1000.0))
            transition.setFrame(view: self.introduction, frame: CGRect(x: sideInset + 4.0, y: contentHeight, width: width - 8.0, height: introductionSize.height))
            contentHeight += introductionSize.height + 30.0
            transition.setFrame(view: self.sectionTitle, frame: CGRect(x: sideInset + 4.0, y: contentHeight, width: width - 8.0, height: 20.0))
            contentHeight += 30.0

            let spacing: CGFloat = 10.0
            let columns = max(2, min(5, Int(floor((width + spacing) / 118.0))))
            let itemWidth = floorToScreenPixels((width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            let itemHeight = itemWidth + 44.0
            self.giftFrames = self.gifts.enumerated().map { index, gift in
                return (gift, CGRect(x: sideInset + CGFloat(index % columns) * (itemWidth + spacing), y: contentHeight + CGFloat(index / columns) * (itemHeight + 16.0), width: itemWidth, height: itemHeight))
            }
            if !self.gifts.isEmpty {
                contentHeight += CGFloat((self.gifts.count + columns - 1) / columns) * (itemHeight + 16.0)
            }

            let isLoading: Bool
            switch self.giftsState?.dataState {
            case .loading, nil:
                isLoading = true
            case .ready:
                isLoading = false
            }
            self.emptyLabel.isHidden = isLoading || !self.gifts.isEmpty
            self.reloadButton.isHidden = isLoading || !self.gifts.isEmpty
            if !self.emptyLabel.isHidden {
                let emptySize = self.emptyLabel.sizeThatFits(CGSize(width: max(0.0, width - 24.0), height: 1000.0))
                transition.setFrame(view: self.emptyLabel, frame: CGRect(x: sideInset + 12.0, y: contentHeight + 36.0, width: width - 24.0, height: emptySize.height))
                transition.setFrame(view: self.reloadButton, frame: CGRect(x: sideInset, y: self.emptyLabel.frame.maxY + 12.0, width: width, height: 44.0))
                contentHeight += emptySize.height + 112.0
            }
            self.loadingView.isHidden = !isLoading
            if isLoading {
                self.loadingView.startAnimating()
                transition.setFrame(view: self.loadingView, frame: CGRect(x: floor((availableSize.width - 24.0) / 2.0), y: contentHeight + 24.0, width: 24.0, height: 24.0))
                contentHeight += 72.0
            } else {
                self.loadingView.stopAnimating()
            }
            contentHeight += environment.safeInsets.bottom + 24.0

            transition.setFrame(view: self.scrollView, frame: CGRect(origin: .zero, size: availableSize))
            self.scrollView.contentSize = CGSize(width: availableSize.width, height: max(contentHeight, availableSize.height))
            self.scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: environment.navigationHeight, left: 0.0, bottom: environment.safeInsets.bottom, right: 0.0)
            self.updateVisibleGifts(transition: transition)
            return availableSize
        }
    }

    func makeView() -> View {
        return View()
    }

    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<EnvironmentType>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

final class WalletGiftThemeScreen: ViewControllerComponentContainer {
    init(context: AccountContext, selectedGift: StarGift.UniqueGift?, completion: @escaping (StarGift.UniqueGift?) -> Void) {
        super.init(context: context, component: WalletGiftThemeScreenComponent(context: context, selectedGift: selectedGift, completion: completion), navigationBarAppearance: .default)

        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        self.title = presentationData.strings.primaryComponent.languageCode.lowercased().hasPrefix("ru") ? "Темы подарков" : "Gift Themes"
        self.navigationItem.backBarButtonItem = UIBarButtonItem(title: presentationData.strings.Common_Back, style: .plain, target: nil, action: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
