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

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        mode = .tabSidebar
        sidebar.preferredLayout = .tile
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

    func tabBarController(_ tabBarController: UITabBarController, didSelectTab tab: UITab, previousTab: UITab?) {
        guard let index = tabs.firstIndex(where: { $0 === tab }) else { return }
        selectTab(index, notifyWeb: true)
    }

    func selectTab(_ index: Int, notifyWeb: Bool) {
        guard tabs.indices.contains(index) else { return }
        if selectedTab !== tabs[index] { selectedTab = tabs[index] }
        let container = tabs[index].viewController as? AonsokuTabContainerController
        if let container { hostBridge(in: container) }
        // UIKit updates selectedTab before invoking its delegate.
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
        let compact = traitCollection.userInterfaceIdiom != .pad || bridgeView.bounds.width < 768
        // Preserve the page geometry while a keyboard/modal/fullscreen player is over it.
        if shellEnabled && (accessoryObscured || miniPlayer.keyboardVisible) { return }
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
        sendLayout(top: shellEnabled ? top : 0, bottom: shellEnabled ? bottom : 0, compact: compact)
    }

    #if DEBUG
    func verifySingleBridgeAcrossTabs() -> Bool {
        let original = bridgeController.webView
        let originalTab = selectedIndex
        guard original != nil else { return false }
        // Model UIKit's ordering: selectedTab is already updated at delegate entry.
        let previousTab = selectedTab
        selectedTab = tabs[2]
        let sentBefore = bridgeController.shellTabEventCount
        tabBarController(self, didSelectTab: tabs[2], previousTab: previousTab)
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

    private func sendLayout(top: CGFloat, bottom: CGFloat, compact: Bool) {
        let values: [CGFloat] = [top, bottom, compact ? 1 : 0]
        guard values != lastReportedInsets else { return }
        lastReportedInsets = values
        bridgeController.dispatchShellEvent([
            "type": "layout", "top": top, "bottom": bottom, "compact": compact,
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
