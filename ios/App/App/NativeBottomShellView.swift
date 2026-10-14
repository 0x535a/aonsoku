import UIKit

/// One transparent overlay. Only its controls participate in hit testing.
/// This view never creates a WebView, queue, player or audio session.
final class NativeBottomShellView: UIView, UITabBarDelegate {
    var onEvent: (([String: Any]) -> Void)?
    var onInsetsChanged: ((CGFloat, CGFloat, Bool) -> Void)?
    var enabled = false { didSet { setNeedsLayout() } }
    var obscured = false { didSet { setNeedsLayout() } }
    var keyboardVisible = false { didSet { setNeedsLayout() } }
    private let tabBar = UITabBar()
    private let topMaterial = UIVisualEffectView()
    private let topTabs = UISegmentedControl(items: ["", "", ""])
    private let backButton = UIButton(type: .system)
    private let playerMaterial = UIVisualEffectView()
    private let infoButton = UIButton(type: .system)
    private let artwork = UIImageView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let progress = UIProgressView(progressViewStyle: .bar)
    private var hasContent = false
    private var trackId = ""
    private var lastCover: String?
    private var lastLabels: [String] = []
    private var lastInsets: [CGFloat] = []
    private(set) var compact = true

    override init(frame: CGRect) { super.init(frame: frame); build() }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let target = super.hitTest(point, with: event)
        return target === self ? nil : target
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        compact = traitCollection.userInterfaceIdiom != .pad || bounds.width < 768
        let safe = safeAreaInsets
        let rowHeight: CGFloat = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 88 : 68
        let tabHeight = max(72, tabBar.sizeThatFits(CGSize(width: bounds.width, height: 100)).height)
        let topInset: CGFloat = compact ? 0 : safe.top + 64
        let bottomInset = compact
            ? safe.bottom + tabHeight + (hasContent ? rowHeight + 16 : 0)
            : (hasContent ? safe.bottom + rowHeight + 24 : 0)
        topMaterial.isHidden = !enabled || obscured || compact
        tabBar.isHidden = !enabled || obscured || keyboardVisible || !compact
        playerMaterial.isHidden = !enabled || obscured || keyboardVisible || !hasContent
        let availableWidth = bounds.width - safe.left - safe.right
        let topWidth = min(availableWidth - 24, 620)
        topMaterial.frame = CGRect(x: safe.left + (availableWidth - topWidth) / 2,
                                   y: safe.top + 6, width: topWidth, height: 52)
        backButton.frame = CGRect(x: 4, y: 4, width: 44, height: 44)
        topTabs.frame = CGRect(x: 52, y: 6, width: topWidth - 64, height: 40)
        tabBar.frame = CGRect(x: safe.left, y: bounds.height - safe.bottom - tabHeight,
                              width: availableWidth, height: tabHeight)
        let playerWidth = min(availableWidth - 24, compact ? availableWidth - 24 : 640)
        let playerBottom = compact ? safe.bottom + tabHeight + 8 : safe.bottom + 12
        playerMaterial.frame = CGRect(x: safe.left + (availableWidth - playerWidth) / 2,
                                      y: bounds.height - playerBottom - rowHeight,
                                      width: playerWidth, height: rowHeight)
        infoButton.frame = CGRect(x: 10, y: 6, width: max(0, playerWidth - 110), height: rowHeight - 14)
        artwork.frame = CGRect(x: 0, y: (infoButton.bounds.height - 48) / 2, width: 48, height: 48)
        let textWidth = max(0, infoButton.bounds.width - 60)
        title.frame = CGRect(x: 60, y: infoButton.bounds.height / 2 - 22, width: textWidth, height: 24)
        subtitle.frame = CGRect(x: 60, y: infoButton.bounds.height / 2 + 2, width: textWidth, height: 20)
        playButton.frame = CGRect(x: playerWidth - 98, y: (rowHeight - 48) / 2, width: 48, height: 48)
        nextButton.frame = CGRect(x: playerWidth - 50, y: (rowHeight - 48) / 2, width: 48, height: 48)
        progress.frame = CGRect(x: 16, y: rowHeight - 3, width: max(0, playerWidth - 32), height: 2)
        let insets: [CGFloat] = [enabled ? topInset : 0, enabled ? bottomInset : 0, compact ? 1 : 0]
        if insets != lastInsets {
            lastInsets = insets
            onInsetsChanged?(insets[0], insets[1], compact)
        }
    }

    func update(_ state: [String: Any]) {
        enabled = state["enabled"] as? Bool ?? false
        obscured = state["obscured"] as? Bool ?? false
        hasContent = state["hasContent"] as? Bool ?? false
        infoButton.isEnabled = state["canOpenPlayer"] as? Bool ?? false
        let newTrackId = state["trackId"] as? String ?? ""
        if trackId != newTrackId {
            trackId = newTrackId
            lastCover = nil
            artwork.image = UIImage(systemName: "music.note")
        }
        let playing = state["isPlaying"] as? Bool ?? false
        playButton.isEnabled = hasContent
        nextButton.isEnabled = hasContent && (state["hasNext"] as? Bool ?? false)
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
        playButton.accessibilityLabel = state[playing ? "pauseLabel" : "playLabel"] as? String
        nextButton.accessibilityLabel = state["nextLabel"] as? String
        infoButton.accessibilityLabel = state["openPlayerLabel"] as? String
        infoButton.accessibilityValue = state["trackLabel"] as? String
        backButton.accessibilityLabel = state["backLabel"] as? String
        title.text = state["title"] as? String
        subtitle.text = state["artist"] as? String
        progress.progress = Float(state["progressFraction"] as? Double ?? 0)
        infoButton.accessibilityHint = state["progressLabel"] as? String
        if let labels = state["labels"] as? [String], labels.count == 3, labels != lastLabels {
            lastLabels = labels
            let symbols = ["house", "square.grid.2x2", "magnifyingglass"]
            tabBar.items = labels.enumerated().map { index, label in
                topTabs.setTitle(label, forSegmentAt: index)
                return UITabBarItem(title: label, image: UIImage(systemName: symbols[index]), tag: index)
            }
        }
        let selection = min(2, max(0, state["activeIndex"] as? Int ?? 0))
        topTabs.selectedSegmentIndex = selection
        tabBar.selectedItem = tabBar.items?[selection]
        setNeedsLayout()
    }

    func updateArtwork(_ state: [String: Any]) {
        guard state["trackId"] as? String == trackId else { return }
        let cover = state["coverData"] as? String
        if cover != lastCover {
            lastCover = cover
            artwork.image = cover.flatMap { encoded in
                guard let comma = encoded.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])),
                      data.count <= 100_000 else { return nil }
                return UIImage(data: data)
            } ?? UIImage(systemName: "music.note")
        }
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
        onEvent?(["type": "tab", "index": item.tag])
    }

    private func build() {
        backgroundColor = .clear
        for material in [topMaterial, playerMaterial] { material.clipsToBounds = true }
        topMaterial.layer.cornerRadius = 26
        playerMaterial.layer.cornerRadius = 24
        addSubview(topMaterial); addSubview(tabBar); addSubview(playerMaterial)
        topMaterial.contentView.addSubview(backButton); topMaterial.contentView.addSubview(topTabs)
        for control in [infoButton, playButton, nextButton, progress] { playerMaterial.contentView.addSubview(control) }
        for child in [artwork, title, subtitle] {
            infoButton.addSubview(child)
            child.isUserInteractionEnabled = false
            child.isAccessibilityElement = false
        }
        infoButton.accessibilityTraits = .button
        infoButton.isAccessibilityElement = true
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 8
        artwork.tintColor = .secondaryLabel
        artwork.backgroundColor = .tertiarySystemFill
        artwork.image = UIImage(systemName: "music.note")
        title.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 15, weight: .semibold), maximumPointSize: 22)
        subtitle.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12), maximumPointSize: 18)
        title.adjustsFontForContentSizeCategory = true; subtitle.adjustsFontForContentSizeCategory = true
        title.textColor = .label; subtitle.textColor = .secondaryLabel
        title.lineBreakMode = .byTruncatingTail; subtitle.lineBreakMode = .byTruncatingTail
        progress.isAccessibilityElement = false
        progress.tintColor = .systemBlue
        topTabs.addTarget(self, action: #selector(selectTopTab), for: .valueChanged)
        tabBar.delegate = self; tabBar.tintColor = .systemBlue
        backButton.setImage(UIImage(systemName: "chevron.backward"), for: .normal)
        nextButton.setImage(UIImage(systemName: "forward.end.fill"), for: .normal)
        for button in [backButton, playButton, nextButton, infoButton] {
            button.addInteraction(UIPointerInteraction(delegate: nil))
        }
        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        infoButton.addTarget(self, action: #selector(openPlayer), for: .touchUpInside)
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        nextButton.addTarget(self, action: #selector(nextTrack), for: .touchUpInside)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMaterial),
            name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMaterial),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        updateMaterial()
    }

    @objc private func updateMaterial() {
        for view in [topMaterial, playerMaterial] {
            if UIAccessibility.isReduceTransparencyEnabled {
                view.effect = nil; view.backgroundColor = .secondarySystemBackground
            } else {
                view.backgroundColor = .clear
                if #available(iOS 26.0, *) {
                    let glass = UIGlassEffect(style: .regular)
                    glass.isInteractive = !UIAccessibility.isReduceMotionEnabled
                    view.effect = glass
                } else { view.effect = UIBlurEffect(style: .systemMaterial) }
            }
        }
    }

    @objc private func selectTopTab() { onEvent?(["type": "tab", "index": topTabs.selectedSegmentIndex]) }
    @objc private func goBack() { onEvent?(["type": "back"]) }
    @objc private func openPlayer() { onEvent?(["type": "openPlayer"]) }
    @objc private func togglePlayback() { onEvent?(["type": "control", "action": "togglePlayPause"]) }
    @objc private func nextTrack() { onEvent?(["type": "control", "action": "playNextSong"]) }
}
