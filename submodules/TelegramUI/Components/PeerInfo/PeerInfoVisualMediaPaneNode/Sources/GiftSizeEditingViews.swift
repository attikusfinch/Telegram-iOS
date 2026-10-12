import UIKit
import Display

final class GiftResizeHandle: UIView, UIGestureRecognizerDelegate {
    private let cornerLayer = CAShapeLayer()
    var pan: ((UIPanGestureRecognizer) -> Void)?
    var changeSize: ((GiftTileSize) -> Void)?
    var growsInward: Bool = false {
        didSet {
            self.accessibilityHint = self.growsInward ? "Drag left to make wider, or down to make taller. Swipe up or down to choose a size." : "Drag the corner to resize. Swipe up or down to choose a size."
        }
    }
    var tileSize: GiftTileSize = .standard {
        didSet {
            self.accessibilityValue = "\(self.tileSize.width) × \(self.tileSize.height)"
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.disablesInteractiveTransitionGestureRecognizerNow = { true }
        self.isAccessibilityElement = true
        self.accessibilityLabel = "Gift size"
        self.accessibilityHint = "Drag the corner to resize. Swipe up or down to choose a size."
        self.accessibilityTraits = .adjustable
        self.accessibilityValue = "1 × 1"

        self.cornerLayer.fillColor = nil
        self.cornerLayer.strokeColor = UIColor.white.cgColor
        self.cornerLayer.lineWidth = 4.5
        self.cornerLayer.lineCap = .round
        self.cornerLayer.lineJoin = .round
        self.cornerLayer.shadowColor = UIColor.black.cgColor
        self.cornerLayer.shadowOpacity = 0.28
        self.cornerLayer.shadowRadius = 2.0
        self.cornerLayer.shadowOffset = CGSize(width: 0.0, height: 1.0)
        self.layer.addSublayer(self.cornerLayer)

        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(self.panned(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = self
        self.addGestureRecognizer(recognizer)

        self.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Increase width", actionHandler: { [weak self] _ in
                guard let self, self.tileSize.width < (self.tileSize.height == 1 ? 3 : 2) else { return false }
                self.changeSize?(GiftTileSize(width: self.tileSize.width + 1, height: self.tileSize.height))
                return true
            }),
            UIAccessibilityCustomAction(name: "Decrease width", actionHandler: { [weak self] _ in
                guard let self, self.tileSize.width > 1 else { return false }
                self.changeSize?(GiftTileSize(width: self.tileSize.width - 1, height: self.tileSize.height))
                return true
            }),
            UIAccessibilityCustomAction(name: "Increase height", actionHandler: { [weak self] _ in
                guard let self, self.tileSize.height < 2 else { return false }
                self.changeSize?(GiftTileSize(width: min(2, self.tileSize.width), height: 2))
                return true
            }),
            UIAccessibilityCustomAction(name: "Decrease height", actionHandler: { [weak self] _ in
                guard let self, self.tileSize.height > 1 else { return false }
                self.changeSize?(GiftTileSize(width: self.tileSize.width, height: 1))
                return true
            })
        ]
    }

    required init?(coder: NSCoder) {
        preconditionFailure()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        self.cornerLayer.frame = self.bounds
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 17.0, y: 34.0))
        path.addLine(to: CGPoint(x: 27.0, y: 34.0))
        path.addQuadCurve(to: CGPoint(x: 34.0, y: 27.0), controlPoint: CGPoint(x: 34.0, y: 34.0))
        path.addLine(to: CGPoint(x: 34.0, y: 17.0))
        self.cornerLayer.path = path.cgPath
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        self.pan?(recognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // The corner takes priority over the surrounding vertical and tab swipes.
        if otherGestureRecognizer is InteractiveTransitionGestureRecognizer {
            return false
        }
        return otherGestureRecognizer is UIPanGestureRecognizer
    }

    override func accessibilityIncrement() {
        self.stepSize(forward: true)
    }

    override func accessibilityDecrement() {
        self.stepSize(forward: false)
    }

    private func stepSize(forward: Bool) {
        let sizes = GiftTileSize.supportedSizes
        let index = sizes.firstIndex(of: self.tileSize) ?? 0
        let nextIndex = min(sizes.count - 1, max(0, index + (forward ? 1 : -1)))
        if index != nextIndex {
            self.changeSize?(sizes[nextIndex])
        }
    }
}
