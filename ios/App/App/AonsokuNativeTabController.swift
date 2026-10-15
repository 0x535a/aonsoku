import UIKit
import Capacitor

/// System-owned navigation and accessory around the existing single Capacitor
/// bridge. A container hosts the same bridge controller as tabs change; no tab
/// creates another WKWebView or audio service.
@available(iOS 26.0, *)
final class AonsokuNativeTabController: UITabBarController, UITabBarControllerDelegate {
    let miniPlayer = NativeBottomShellView()
    private let bridgeController = AonsokuViewController()
    private var containers: [Int: AonsokuTabContainerController] = [:]
    private var lastReportedInsets: [CGFloat] = []
    private var tabLabels = ["Home", "Library", "Search"]
    private var hasPlayerContent = false
    private var accessoryObscured = false
    private var shellEnabled = false
    private var bridgeConstraints: [NSLayoutConstraint] = []
    private var syncingSelection = false

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        mode = .tabBar
        // React's existing portrait-layout hook decides when this shell is used.
        // The active native navigation always uses bottom tabs, including iPad.
        traitOverrides.horizontalSizeClass = .compact
        tabBarMinimizeBehavior = .onScrollDown
        bridgeController.nativeTabController = self
        tabs = makeTabs()
        miniPlayer.onEvent = { [weak self] in self?.handleAccessoryEvent($0) }
        miniPlayer.onLayoutChanged = { [weak self] in
            self?.sendCurrentLayout()
        }
        setTabBarHidden(true, animated: false)
        view.backgroundColor = .systemBackground
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep the navigation-only override out of Web content and presentations.
        if let sizeClass = view.window?.traitCollection.horizontalSizeClass {
            for container in containers.values {
                container.traitOverrides.horizontalSizeClass = sizeClass
            }
        }
        updateAccessoryVisibility()
    }

    private func makeTabs() -> [UITab] {
        let symbols = ["house", "books.vertical", "magnifyingglass"]
        return tabLabels.indices.map { index in
            UITab(title: tabLabels[index], image: UIImage(systemName: symbols[index]), identifier: "aonsoku-\(index)") { [weak self] _ in
                guard let self else { return UIViewController() }
                if let existing = containers[index] { return existing }
                let container = AonsokuTabContainerController(index: index) { [weak self] selected in
                    self?.hostBridge(in: selected)
                }
                containers[index] = container
                return container
            }
        }
    }

    private func hostBridge(in container: AonsokuTabContainerController) {
        if let sizeClass = view.window?.traitCollection.horizontalSizeClass {
            container.traitOverrides.horizontalSizeClass = sizeClass
        }
        guard bridgeController.parent !== container else { return }
        NSLayoutConstraint.deactivate(bridgeConstraints)
        if bridgeController.parent != nil {
            bridgeController.parent?.setContentScrollView(nil, for: .all)
            bridgeController.willMove(toParent: nil)
            bridgeController.view.removeFromSuperview()
            bridgeController.removeFromParent()
        }
        container.addChild(bridgeController)
        let bridgeView = bridgeController.view!
        bridgeView.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(bridgeView)
        bridgeConstraints = [
            bridgeView.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            bridgeView.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            bridgeView.topAnchor.constraint(equalTo: container.view.topAnchor),
            bridgeView.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
        ]
        NSLayoutConstraint.activate(bridgeConstraints)
        container.setContentScrollView(bridgeController.webView?.scrollView, for: .all)
        bridgeController.setContentScrollView(bridgeController.webView?.scrollView, for: .all)
        bridgeController.didMove(toParent: container)
    }

    func tabBarController(_ tabBarController: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
        // User intent is separate from selection completion: route updates also
        // change selectedTab and must never navigate back to a tab's root.
        guard !syncingSelection,
              let index = tabs.firstIndex(where: { $0 === tab }) else { return true }
        bridgeController.dispatchShellEvent(["type": "tab", "index": index])
        return true
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelectTab tab: UITab, previousTab: UITab?) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        selectTab(index, notifyWeb: false)
    }

    func selectTab(_ index: Int, notifyWeb: Bool) {
        guard tabs.indices.contains(index) else { return }
        if selectedTab !== tabs[index] {
            syncingSelection = true
            selectedTab = tabs[index]
            syncingSelection = false
        }
        let container = tabs[index].viewController as? AonsokuTabContainerController
        if let container { hostBridge(in: container) }
        if notifyWeb { bridgeController.dispatchShellEvent(["type": "tab", "index": index]) }
    }

    func updateShellState(_ state: [String: Any]) {
        if let labels = state["labels"] as? [String], labels.count == 3, labels != tabLabels {
            tabLabels = labels
            for (index, title) in labels.enumerated() { tabs[index].title = title }
        }
        shellEnabled = state["enabled"] as? Bool ?? false
        hasPlayerContent = state["hasContent"] as? Bool ?? false
        accessoryObscured = state["obscured"] as? Bool ?? false
        miniPlayer.obscured = accessoryObscured
        if let index = state["activeIndex"] as? Int { selectTab(index, notifyWeb: false) }
        miniPlayer.layoutIfNeeded()
        updateAccessoryVisibility()
        sendCurrentLayout()
    }

    func updateAccessoryVisibility() {
        let hideNavigation = !shellEnabled || accessoryObscured || miniPlayer.keyboardVisible
        // Web fullscreen/dialogs share the registered WK scroll view. Hiding
        // native chrome alone leaves UIKit's edge scrim over the Web overlay.
        // Restore normal edge effects when native navigation returns.
        if let scrollView = bridgeController.webView?.scrollView {
            scrollView.topEdgeEffect.isHidden = hideNavigation
            scrollView.bottomEdgeEffect.isHidden = hideNavigation
        }
        if isTabBarHidden != hideNavigation { setTabBarHidden(hideNavigation, animated: false) }
        if hideNavigation && !sidebar.isHidden { sidebar.isHidden = true }
        let shouldShow = shellEnabled && hasPlayerContent && !accessoryObscured && !miniPlayer.keyboardVisible
        if shouldShow, bottomAccessory == nil {
            bottomAccessory = UITabAccessory(contentView: miniPlayer)
        } else if !shouldShow, bottomAccessory != nil {
            bottomAccessory = nil
        }
        sendCurrentLayout()
    }

    func setAccessoryObscured(_ value: Bool) {
        accessoryObscured = value
        miniPlayer.obscured = value
        updateAccessoryVisibility()
    }

    private func sendCurrentLayout() {
        guard let bridgeView = bridgeController.viewIfLoaded else { return }
        let active = shellEnabled
        // Preserve the page geometry while a keyboard/modal/fullscreen player is over it.
        // A window-mode change must still restore/hide Web chrome immediately.
        if active && lastReportedInsets.last == 1 && (accessoryObscured || miniPlayer.keyboardVisible) { return }
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var frames: [CGRect] = []
        if !isTabBarHidden { frames.append(tabBar.convert(tabBar.bounds, to: bridgeView)) }
        if bottomAccessory != nil, !miniPlayer.isHidden {
            frames.append(miniPlayer.convert(miniPlayer.bounds, to: bridgeView))
        }
        for frame in frames where frame.width > 0 && frame.height > 0 {
            let overlap = bridgeView.bounds.intersection(frame)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            if frame.midY > bridgeView.bounds.midY {
                bottom = max(bottom, bridgeView.bounds.maxY - overlap.minY)
            } else {
                top = max(top, overlap.maxY - bridgeView.bounds.minY)
            }
        }
        sendLayout(top: active ? top : 0, bottom: active ? bottom : 0, compact: active, active: active)
    }

    func reportCurrentLayout() {
        // React may mount after UIKit's first layout (or after a Web reload).
        lastReportedInsets = []
        sendCurrentLayout()
    }

    #if DEBUG
    func verifySingleBridgeAcrossTabs() -> Bool {
        let original = bridgeController.webView
        let originalTab = selectedIndex
        guard original != nil else { return false }
        // Selection completion alone must not turn a route update into a tap.
        let previousTab = selectedTab
        let sentBefore = bridgeController.shellTabEventCount
        selectTab(2, notifyWeb: false)
        tabBarController(self, didSelectTab: tabs[2], previousTab: previousTab)
        guard bridgeController.shellTabEventCount == sentBefore else { return false }
        // A real user intent, including reselecting the current tab, sends once.
        guard tabBarController(self, shouldSelectTab: tabs[2]) else { return false }
        tabBarController(self, didSelectTab: tabs[2], previousTab: tabs[2])
        guard bridgeController.shellTabEventCount == sentBefore + 1 else { return false }
        for index in [2, 0, 1, 2, originalTab] {
            selectTab(index, notifyWeb: false)
            guard bridgeController.webView === original,
                  bridgeController.parent === tabs[index].viewController,
                  containers.values.reduce(0, { $0 + $1.children.count }) == 1 else { return false }
        }
        return true
    }
    #endif

    private func sendLayout(top: CGFloat, bottom: CGFloat, compact: Bool, active: Bool) {
        let values: [CGFloat] = [top, bottom, compact ? 1 : 0, active ? 1 : 0]
        guard values != lastReportedInsets else { return }
        lastReportedInsets = values
        bridgeController.dispatchShellEvent([
            "type": "layout", "top": top, "bottom": bottom, "compact": compact, "active": active,
        ])
    }

    private func handleAccessoryEvent(_ event: [String: Any]) {
        switch event["type"] as? String {
        case "control", "openPlayer": bridgeController.dispatchShellEvent(event)
        default: break
        }
    }
}

@available(iOS 26.0, *)
private final class AonsokuTabContainerController: UIViewController {
    let index: Int
    private let activate: (AonsokuTabContainerController) -> Void

    init(index: Int, activate: @escaping (AonsokuTabContainerController) -> Void) {
        self.index = index
        self.activate = activate
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = .systemBackground
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        activate(self)
    }
}
