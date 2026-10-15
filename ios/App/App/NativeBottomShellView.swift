import UIKit

/// Presentation and interaction only. UITabAccessory owns its glass, placement,
/// safe area and regular-to-inline transition.
final class NativeBottomShellView: UIView {
    var onEvent: (([String: Any]) -> Void)?
    var onLayoutChanged: (() -> Void)?
    var keyboardVisible = false { didSet { updateVisibility() } }
    var enabled = false { didSet { updateVisibility() } }
    var obscured = false { didSet { updateVisibility() } }
    private var hasContent = false { didSet { updateVisibility() } }

    private let artwork = UIImageView()
    private let title = UILabel()
    private let subtitle = UILabel()
    private let playButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let textStack = UIStackView()
    private let row = UIStackView()
    private var artworkWidth: NSLayoutConstraint!
    private var artworkHeight: NSLayoutConstraint!
    private(set) var inline = false
    private var trackId = ""
    private var lastCover: String?
    private var canOpenPlayer = false

    var accessoryPresentation: (inline: Bool, artistVisible: Bool, nextVisible: Bool) {
        (inline, !subtitle.isHidden, !nextButton.isHidden)
    }
    var controlButtons: [UIButton] { [playButton, nextButton] }

    private func updateVisibility() {
        isHidden = !enabled || obscured || keyboardVisible || !hasContent
        setNeedsLayout()
        onLayoutChanged?()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        build()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: inline ? 44 : 64)
    }

    @available(iOS 26.0, *)
    override func updateProperties() {
        super.updateProperties()
        let nextInline = traitCollection.tabAccessoryEnvironment == .inline
        guard inline != nextInline else { return }
        inline = nextInline
        subtitle.isHidden = inline || !enabled
        nextButton.isHidden = inline
        artworkWidth.constant = inline ? 30 : 46
        artworkHeight.constant = inline ? 30 : 46
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        onLayoutChanged?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let regular = !inline
        subtitle.isHidden = !regular || !enabled
        nextButton.isHidden = !regular
        row.spacing = inline ? 8 : 10
        let size: CGFloat = inline ? 30 : 46
        artworkWidth.constant = size
        artworkHeight.constant = size
        onLayoutChanged?()
    }

    func update(_ state: [String: Any]) {
        enabled = state["enabled"] as? Bool ?? false
        hasContent = state["hasContent"] as? Bool ?? false
        let newTrackId = state["trackId"] as? String ?? ""
        if trackId != newTrackId {
            trackId = newTrackId
            lastCover = nil
            artwork.image = UIImage(systemName: "music.note")
        }
        playButton.isEnabled = hasContent
        nextButton.isEnabled = hasContent && (state["hasNext"] as? Bool ?? false)
        let playing = state["isPlaying"] as? Bool ?? false
        playButton.setImage(UIImage(systemName: playing ? "pause.fill" : "play.fill"), for: .normal)
        playButton.accessibilityLabel = state[playing ? "pauseLabel" : "playLabel"] as? String
        nextButton.accessibilityLabel = state["nextLabel"] as? String
        canOpenPlayer = state["canOpenPlayer"] as? Bool ?? false
        textStack.accessibilityTraits = canOpenPlayer ? .button : .staticText
        textStack.accessibilityLabel = state["openPlayerLabel"] as? String
        textStack.accessibilityValue = state["trackLabel"] as? String
        textStack.accessibilityHint = state["progressLabel"] as? String
        title.text = state["title"] as? String
        subtitle.text = state["artist"] as? String
        setNeedsLayout()
    }


    func updateArtwork(_ state: [String: Any]) {
        guard state["trackId"] as? String == trackId else { return }
        let cover = state["coverData"] as? String
        guard cover != lastCover else { return }
        lastCover = cover
        artwork.image = cover.flatMap { encoded in
            guard let comma = encoded.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])),
                  data.count <= 100_000 else { return nil }
            return UIImage(data: data)
        } ?? UIImage(systemName: "music.note")
    }

    private func build() {
        backgroundColor = .clear
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = 7
        artwork.tintColor = .secondaryLabel
        artwork.backgroundColor = .tertiarySystemFill
        artwork.image = UIImage(systemName: "music.note")
        artwork.isAccessibilityElement = false

        title.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 15, weight: .semibold), maximumPointSize: 22)
        title.adjustsFontForContentSizeCategory = true
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.isAccessibilityElement = false

        subtitle.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 12), maximumPointSize: 18)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = .secondaryLabel
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.isAccessibilityElement = false

        textStack.isAccessibilityElement = true
        textStack.accessibilityTraits = .button
        textStack.axis = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(subtitle)

        isHidden = true
        artworkWidth = artwork.widthAnchor.constraint(equalToConstant: 46)
        artworkHeight = artwork.heightAnchor.constraint(equalToConstant: 46)
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
        playButton.tintColor = .label
        playButton.accessibilityLabel = "Play or pause"
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        nextButton.setImage(UIImage(systemName: "forward.end.fill"), for: .normal)
        nextButton.tintColor = .label
        nextButton.accessibilityLabel = "Next track"
        nextButton.addTarget(self, action: #selector(nextTrack), for: .touchUpInside)
        for button in [playButton, nextButton] {
            let width = button.widthAnchor.constraint(equalToConstant: 44)
            width.priority = .defaultHigh
            width.isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addInteraction(UIPointerInteraction(delegate: nil))
        }

        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = .zero
        row.addArrangedSubview(artwork)
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(playButton)
        row.addArrangedSubview(nextButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            artworkWidth, artworkHeight,
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for target in [artwork, textStack] {
            target.isUserInteractionEnabled = true
            let open = UITapGestureRecognizer(target: self, action: #selector(openPlayer))
            open.cancelsTouchesInView = false
            target.addGestureRecognizer(open)
        }
    }

    @objc private func togglePlayback() { onEvent?(["type": "control", "action": "togglePlayPause"]) }
    @objc private func nextTrack() { onEvent?(["type": "control", "action": "playNextSong"]) }
    @objc private func openPlayer() { if canOpenPlayer { onEvent?(["type": "openPlayer"]) } }
}
