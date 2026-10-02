import SwiftUI
import UIKit

/// 在窗口上安装一个「双指滑动」手势识别器。
///
/// SwiftUI 没有多指手势 API，这里退回 UIKit：把一个双指平移手势挂到窗口上，
/// 纵向滑动超过阈值时触发回调（用于进入多选状态）。手势不吞掉触摸，
/// 所以不会影响列表滚动和按钮点击。
struct TwoFingerPanCatcher: UIViewRepresentable {
    let onTrigger: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onTrigger = onTrigger
        DispatchQueue.main.async {
            context.coordinator.attachIfNeeded(to: uiView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTrigger: onTrigger)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTrigger: () -> Void
        private var installed = false
        private weak var window: UIWindow?
        private weak var pan: UIPanGestureRecognizer?

        init(onTrigger: @escaping () -> Void) {
            self.onTrigger = onTrigger
        }

        func attachIfNeeded(to view: UIView) {
            guard !installed, let window = view.window else { return }
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.cancelsTouchesInView = false
            pan.delegate = self
            window.addGestureRecognizer(pan)
            self.window = window
            self.pan = pan
            installed = true
        }

        @objc private func handle(_ gesture: UIPanGestureRecognizer) {
            switch gesture.state {
            case .began:
                // 双指手势期间锁住列表滚动，避免页面跟着滑。
                lockScrollViews(at: gesture.location(in: nil))
            case .ended:
                unlockScrollViews()
                let translation = gesture.translation(in: gesture.view)
                guard abs(translation.y) > 40, abs(translation.y) > abs(translation.x) else { return }
                onTrigger()
            case .cancelled, .failed:
                unlockScrollViews()
            default:
                break
            }
        }

        private var lockedScrollViews: [UIScrollView] = []

        private func lockScrollViews(at point: CGPoint) {
            guard let window else { return }
            var view = window.hitTest(point, with: nil)
            while let current = view {
                if let scrollView = current as? UIScrollView, scrollView.isScrollEnabled {
                    scrollView.isScrollEnabled = false
                    lockedScrollViews.append(scrollView)
                }
                view = current.superview
            }
        }

        private func unlockScrollViews() {
            for scrollView in lockedScrollViews {
                scrollView.isScrollEnabled = true
            }
            lockedScrollViews.removeAll()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        deinit {
            if let pan, let window {
                window.removeGestureRecognizer(pan)
            }
        }
    }
}
