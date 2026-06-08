import AVFoundation
import CoreHaptics
import UIKit

private func bundledImage(named imageName: String) -> UIImage? {
    if let image = UIImage(named: imageName) {
        return image
    }

    let nsName = imageName as NSString
    let baseName = nsName.deletingPathExtension
    let providedExtension = nsName.pathExtension
    let localBaseNames = Array(Set([
        imageName,
        baseName,
        baseName.replacingOccurrences(of: "_left", with: " left"),
        baseName.replacingOccurrences(of: "_right", with: " right")
    ]))
    let extensions = providedExtension.isEmpty ? ["png", "jpg", "jpeg", "svg"] : [providedExtension]

    for localBaseName in localBaseNames {
        for fileExtension in extensions {
            if let url = Bundle.main.url(forResource: localBaseName, withExtension: fileExtension, subdirectory: "image") {
                if fileExtension.lowercased() == "svg" {
                    return UIImage(contentsOfFile: url.path)
                }
                if let data = try? Data(contentsOf: url),
                   let image = UIImage(data: data, scale: 3) {
                    return image
                }
            }
        }
    }

    return nil
}

@MainActor
private enum HapticFeedback {
    private static let touchGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static var engine: CHHapticEngine?

    static func prepareTouch() {
        prepareEngine()
        touchGenerator.prepare()
        selectionGenerator.prepare()
    }

    static func lightImpact() {
        playTransient(intensity: 0.42, sharpness: 0.38)
        touchGenerator.prepare()
        touchGenerator.impactOccurred(intensity: 0.55)
        touchGenerator.prepare()
    }

    static func touchDown() {
        lightImpact()
    }

    static func press() {
        lightImpact()
    }

    static func selection() {
        selectionGenerator.prepare()
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    private static func prepareEngine() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        if engine == nil {
            engine = try? CHHapticEngine()
            engine?.stoppedHandler = { _ in
                Task { @MainActor in
                    engine = nil
                }
            }
            engine?.resetHandler = {
                Task { @MainActor in
                    try? engine?.start()
                }
            }
        }
        try? engine?.start()
    }

    private static func playTransient(intensity: Float, sharpness: Float) {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        prepareEngine()
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
            ],
            relativeTime: 0
        )
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
              let player = try? engine?.makePlayer(with: pattern) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
    }
}

@MainActor
private func makeGlassEffect(tintColor: UIColor? = nil, interactive: Bool = false) -> UIVisualEffect {
    if #available(iOS 26.0, *) {
        let effect = UIGlassEffect(style: .regular)
        effect.tintColor = tintColor
        effect.isInteractive = interactive
        return effect
    }

    return UIBlurEffect(style: .systemUltraThinMaterialDark)
}

@MainActor
private func animateSystemTouchFeedback(on view: UIView, isPressed: Bool, scale: CGFloat = 0.96) {
    let targetTransform = isPressed ? CGAffineTransform(scaleX: scale, y: scale) : .identity

    guard !UIAccessibility.isReduceMotionEnabled else {
        view.transform = targetTransform
        return
    }

    UIView.animate(
        withDuration: isPressed ? 0.14 : 0.44,
        delay: 0,
        usingSpringWithDamping: isPressed ? 0.86 : 0.68,
        initialSpringVelocity: isPressed ? 0.1 : 0.75,
        options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
        animations: {
            view.transform = targetTransform
        }
    )
}

@MainActor
private func animateRevealLayout(for label: UILabel) {
    label.invalidateIntrinsicContentSize()
    label.superview?.invalidateIntrinsicContentSize()
    guard let layoutView = label.superview?.superview else { return }

    UIView.animate(
        withDuration: 0.12,
        delay: 0,
        options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
        animations: {
            layoutView.layoutIfNeeded()
        }
    )
}

@MainActor
private var hapticTouchFeedbackKey: UInt8 = 0

@MainActor
private extension UIControl {
    func enableSystemTouchFeedback(haptic: Bool = false) {
        objc_setAssociatedObject(self, &hapticTouchFeedbackKey, haptic, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        addTarget(self, action: #selector(systemTouchFeedbackDown), for: .touchDown)
        addTarget(self, action: #selector(systemTouchFeedbackUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }

    @objc func systemTouchFeedbackDown() {
        if (objc_getAssociatedObject(self, &hapticTouchFeedbackKey) as? Bool) == true {
            HapticFeedback.touchDown()
        }
        animateSystemTouchFeedback(on: self, isPressed: true)
    }

    @objc func systemTouchFeedbackUp() {
        animateSystemTouchFeedback(on: self, isPressed: false)
    }
}

private enum RecordingDragMode {
    case normal
    case cancel
    case action

    var promptText: String {
        switch self {
        case .normal:
            "Swipe up to cancel, down to add action or scene"
        case .cancel:
            "Release to cancel"
        case .action:
            "Adding action or scene..."
        }
    }
}

private let recordingCancelRed = UIColor(red: 0.957, green: 0.165, blue: 0.165, alpha: 1)

final class HomeViewController: UIViewController, UIScrollViewDelegate {
    private struct FeedItem {
        let name: String
        let mood: String
        let imageName: String
        let videoName: String
        let intro: String
        let message: CharacterMessage
    }

    private struct CharacterMessage {
        let firstScene: String
        let firstLine: String
        let secondScene: String
        let secondLine: String
    }

    private static let feedItems: [FeedItem] = [
        FeedItem(
            name: "Lucas",
            mood: "🍀 Feeling lucky today",
            imageName: "image1.jpg",
            videoName: "视频节点 3 (4).mp4",
            intro: "Damon Verlice.A name feared by everyone. A mafia boss with no mercy, no emotions... and no plans of ever falling in love... MoreIntro Damon Verlice.A name feared by everyone. A mafia boss with no mercy, no emotions... and no plans of ever falling in love. He is used to being obeyed, feared, and watched from a distance. But the moment you step into his world, every rule he has built around himself begins to crack.",
            message: CharacterMessage(
                firstScene: "Hearing that, he slightly raises a brow. His deep, icy gaze sweeps over you, carrying a hint of scrutiny and interest.",
                firstLine: "Moved?",
                secondScene: "He lets out a low chuckle, his voice deep, laced with faint disdain.",
                secondLine: "Are you moved by the ridiculous vows humans make to defy their own nature... or by the pathetic sight of Lucas, now betrayed by his own instincts?"
            )
        ),
        FeedItem(
            name: "Mira",
            mood: "🌙 Quiet but watching",
            imageName: "image2.png",
            videoName: "视频节点 4 (3).mp4",
            intro: "Mira Vale keeps her secrets like folded letters in a locked drawer. She was once the city oracle, hired to predict betrayals before they happened. Now she reads people by the tremor in their voice and the way they avoid looking at exits.",
            message: CharacterMessage(
                firstScene: "Mira tilts her head, the silver light catching in her eyes as if she has already heard your answer.",
                firstLine: "You came back.",
                secondScene: "Her smile is almost kind, but not quite. She steps closer, voice soft enough to feel dangerous.",
                secondLine: "Tell me the truth before I have to guess it."
            )
        ),
        FeedItem(
            name: "Rowan",
            mood: "🔥 Trouble feels fun",
            imageName: "image3.png",
            videoName: "视频节点 5 (2).mp4",
            intro: "Rowan Ash lives for impossible escapes and bad plans that somehow work. He jokes when he is scared, smiles when cornered, and has never met a locked door he did not immediately take personally.",
            message: CharacterMessage(
                firstScene: "Rowan lands beside you with a breathless laugh, dust on his coat and victory in his grin.",
                firstLine: "Miss me?",
                secondScene: "He glances over his shoulder at the chaos behind him, then offers you his hand.",
                secondLine: "No time for questions. Run first, be mad later."
            )
        ),
        FeedItem(
            name: "Seren",
            mood: "🕯️ Softly haunted",
            imageName: "image4.png",
            videoName: "视频节点 6 (2).mp4",
            intro: "Seren Blackwood was raised in a house where every portrait whispered and every hallway remembered grief. She learned to speak gently because the dead were always listening, and to trust slowly because the living lied more often.",
            message: CharacterMessage(
                firstScene: "Seren touches the edge of the old mirror, watching your reflection appear before you fully enter the room.",
                firstLine: "I knew you would find this place.",
                secondScene: "Her voice stays calm, but her fingers tighten around the candle.",
                secondLine: "Please do not ask what it cost me to wait."
            )
        ),
        FeedItem(
            name: "Nox",
            mood: "⚡ Restless tonight",
            imageName: "image5.png",
            videoName: "视频节点 7.mp4",
            intro: "Nox is a courier for messages too dangerous to send and too important to destroy. He knows every rooftop, every siren pattern, and every person who would sell him out for the right price.",
            message: CharacterMessage(
                firstScene: "Nox drops from the fire escape, breath sharp, eyes bright with the thrill of almost being caught.",
                firstLine: "You are late.",
                secondScene: "He tosses you a sealed envelope and looks away before you can read his worry.",
                secondLine: "If anyone asks, you never saw me."
            )
        ),
        FeedItem(
            name: "Iris",
            mood: "🌧️ Missing something",
            imageName: "image6.png",
            videoName: "视频节点 8 (3).mp4",
            intro: "Iris Lane restores damaged memories for people rich enough to forget on purpose. She is precise, patient, and quietly terrified of the one memory she cannot repair: the afternoon she first met you.",
            message: CharacterMessage(
                firstScene: "Iris studies the flickering recording, her face pale in the blue monitor light.",
                firstLine: "This part is missing.",
                secondScene: "She turns toward you, and for once the careful distance in her voice breaks.",
                secondLine: "Tell me you remember what happened here."
            )
        ),
        FeedItem(
            name: "Cassian",
            mood: "🩶 Guarded affection",
            imageName: "image7.png",
            videoName: "视频节点 3 (4).mp4",
            intro: "Cassian Noor is a royal guard who survived every battlefield by obeying orders and every heartbreak by pretending not to feel it. His loyalty is famous. His tenderness is a rumor he denies badly.",
            message: CharacterMessage(
                firstScene: "Cassian blocks the doorway before you can leave, armor catching the last light of the hall.",
                firstLine: "That is far enough.",
                secondScene: "His expression stays stern, but his voice lowers until only you can hear it.",
                secondLine: "I am not stopping you for the crown."
            )
        ),
        FeedItem(
            name: "Vera",
            mood: "✨ Almost honest",
            imageName: "image8.png",
            videoName: "视频节点 4 (3).mp4",
            intro: "Vera Saint writes scandal columns under three false names and knows which smiles are real by how quickly they vanish. She is charming, inconvenient, and always one secret away from danger.",
            message: CharacterMessage(
                firstScene: "Vera closes her notebook the moment you approach, but the ink on her fingers gives her away.",
                firstLine: "Do not look so betrayed.",
                secondScene: "She laughs softly, then softens before she can stop herself.",
                secondLine: "If I wanted to ruin you, darling, I would have used better adjectives."
            )
        )
    ]

    private static func feedImage(named fileName: String) -> UIImage? {
        let url = Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "image")
        if let url,
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }

        return UIImage(named: "HomeBackground")
    }

    private static func feedVideoURL(named fileName: String) -> URL? {
        Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "image")
    }

    private static func loopedFeedItems() -> [(logicalIndex: Int, item: FeedItem)] {
        guard let first = feedItems.first,
              let last = feedItems.last else {
            return []
        }

        return [(feedItems.count - 1, last)]
            + feedItems.enumerated().map { (logicalIndex: $0.offset, item: $0.element) }
            + [(0, first)]
    }

    private let heroContainer = UIView()
    private let feedScrollView = UIScrollView()
    private let topNavigationBar = UIView()
    private let chatContainer = UIView()
    private let inputBar = VoiceInputBar()
    private let tabBar = BottomNavigationBarView()
    private let recordingHintLabel = UILabel()
    private let introBubble = IntroBubbleView()
    private let incomingBubble = IncomingBubbleView()
    private let outgoingBubble = OutgoingBubbleView()
    private let titleNameLabel = UILabel()
    private let titleStateLabel = UILabel()
    private var feedPages: [FeedPageView] = []
    private var feedPageLogicalIndices: [Int] = []
    private var keyboardDismissGesture: UITapGestureRecognizer?
    private var feedPanGesture: UIPanGestureRecognizer?
    private var feedPanStartOffset: CGPoint = .zero
    private var feedSnapAnimator: UIViewPropertyAnimator?
    private var heroBottomConstraint: NSLayoutConstraint!
    private var inputBarBottomToHeroConstraint: NSLayoutConstraint!
    private var inputBarBottomToKeyboardConstraint: NSLayoutConstraint!
    private var hasPlayedInitialBubbleTypewriter = false
    private var isOpeningLucasDetails = false
    private var currentFeedIndex = 0
    private var currentRenderedFeedIndex = 1
    private var lastFeedLayoutSize: CGSize = .zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationController?.setNavigationBarHidden(true, animated: false)
        buildBackground()
        buildTopNavigation()
        buildChatContent()
        buildBottomControls()
        applyFeedItem(at: currentFeedIndex, animated: false)
        installFeedSwipeGesture()
        installKeyboardDismissGesture()
        observeKeyboard()
        observeAppActivation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        synchronizeFeedLayoutIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        HapticFeedback.prepareTouch()
        guard !hasPlayedInitialBubbleTypewriter else { return }
        hasPlayedInitialBubbleTypewriter = true
        incomingBubble.startTypewriter(delay: 0.12)
    }

    private func buildBackground() {
        heroContainer.layer.cornerRadius = 32
        heroContainer.layer.cornerCurve = .continuous
        heroContainer.clipsToBounds = true
        heroContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(heroContainer)

        feedScrollView.isPagingEnabled = true
        feedScrollView.showsVerticalScrollIndicator = false
        feedScrollView.showsHorizontalScrollIndicator = false
        feedScrollView.alwaysBounceVertical = true
        feedScrollView.decelerationRate = .fast
        feedScrollView.contentInsetAdjustmentBehavior = .never
        feedScrollView.delegate = self
        feedScrollView.translatesAutoresizingMaskIntoConstraints = false
        heroContainer.addSubview(feedScrollView)

        var previousPage: UIView?
        feedPages.removeAll()
        feedPageLogicalIndices.removeAll()
        let renderedFeedItems = Self.loopedFeedItems()
        renderedFeedItems.enumerated().forEach { renderedIndex, renderedItem in
            let item = renderedItem.item
            let page = FeedPageView(
                name: item.name,
                mood: item.mood,
                intro: item.intro,
                firstScene: item.message.firstScene,
                firstLine: item.message.firstLine,
                secondScene: item.message.secondScene,
                secondLine: item.message.secondLine,
                image: Self.feedImage(named: item.imageName),
                videoURL: Self.feedVideoURL(named: item.videoName)
            )
            page.onShowMoreTapped = { [weak self, weak page] in
                guard let self, let page else { return }
                self.presentScriptIntroSheet(text: page.fullIntroText)
            }
            page.translatesAutoresizingMaskIntoConstraints = false
            feedScrollView.addSubview(page)
            feedPages.append(page)
            feedPageLogicalIndices.append(renderedItem.logicalIndex)

            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: feedScrollView.contentLayoutGuide.leadingAnchor),
                page.trailingAnchor.constraint(equalTo: feedScrollView.contentLayoutGuide.trailingAnchor),
                page.widthAnchor.constraint(equalTo: feedScrollView.frameLayoutGuide.widthAnchor),
                page.heightAnchor.constraint(equalTo: feedScrollView.frameLayoutGuide.heightAnchor)
            ])

            if let previousPage {
                page.topAnchor.constraint(equalTo: previousPage.bottomAnchor).isActive = true
            } else {
                page.topAnchor.constraint(equalTo: feedScrollView.contentLayoutGuide.topAnchor).isActive = true
            }

            if renderedIndex == renderedFeedItems.count - 1 {
                page.bottomAnchor.constraint(equalTo: feedScrollView.contentLayoutGuide.bottomAnchor).isActive = true
            }
            previousPage = page
        }

        heroBottomConstraint = heroContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -46)

        NSLayoutConstraint.activate([
            heroContainer.topAnchor.constraint(equalTo: view.topAnchor),
            heroContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            heroContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heroBottomConstraint,

            feedScrollView.topAnchor.constraint(equalTo: heroContainer.topAnchor),
            feedScrollView.leadingAnchor.constraint(equalTo: heroContainer.leadingAnchor),
            feedScrollView.trailingAnchor.constraint(equalTo: heroContainer.trailingAnchor),
            feedScrollView.bottomAnchor.constraint(equalTo: heroContainer.bottomAnchor)
        ])
    }

    private func observeAppActivation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func handleAppDidBecomeActive() {
        guard view.window != nil else { return }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        updateFeedSelectionFromScrollView()
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        updateFeedSelectionFromScrollView()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate else { return }
        updateFeedSelectionFromScrollView()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === feedScrollView,
              feedScrollView.bounds.height > 0 else { return }
        let targetIndex = renderedFeedIndex(forProjectedY: targetContentOffset.pointee.y)
        targetContentOffset.pointee = CGPoint(
            x: 0,
            y: CGFloat(targetIndex) * feedScrollView.bounds.height
        )
    }

    private func updateFeedSelectionFromScrollView() {
        guard feedScrollView.bounds.height > 0 else { return }
        currentRenderedFeedIndex = renderedFeedIndex(forProjectedY: feedScrollView.contentOffset.y)
        applyFeedItem(at: logicalFeedIndex(forRenderedIndex: currentRenderedFeedIndex), animated: true)
        normalizeRenderedFeedPositionIfNeeded()
    }

    private func scrollToRenderedFeedItem(at index: Int, animated: Bool) {
        guard feedScrollView.bounds.height > 0 else {
            applyFeedItem(at: logicalFeedIndex(forRenderedIndex: index), animated: animated)
            return
        }
        let clampedIndex = min(max(index, 0), feedPages.count - 1)
        let targetOffset = CGPoint(x: 0, y: CGFloat(clampedIndex) * feedScrollView.bounds.height)
        snapFeed(to: targetOffset, renderedIndex: clampedIndex, animated: animated)
    }

    private func snapFeed(to targetOffset: CGPoint, renderedIndex: Int, animated: Bool) {
        feedSnapAnimator?.stopAnimation(true)
        let clampedIndex = min(max(renderedIndex, 0), feedPages.count - 1)
        let clampedOffset = clampedFeedOffset(targetOffset)
        currentRenderedFeedIndex = clampedIndex
        applyFeedItem(at: logicalFeedIndex(forRenderedIndex: clampedIndex), animated: animated)

        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            feedScrollView.setContentOffset(clampedOffset, animated: false)
            normalizeRenderedFeedPositionIfNeeded()
            return
        }

        let animator = UIViewPropertyAnimator(duration: 0.28, curve: .easeOut) {
            self.feedScrollView.setContentOffset(clampedOffset, animated: false)
        }
        animator.addCompletion { [weak self] _ in
            self?.feedSnapAnimator = nil
            self?.normalizeRenderedFeedPositionIfNeeded()
        }
        feedSnapAnimator = animator
        animator.startAnimation()
    }

    private func clampedFeedOffset(_ offset: CGPoint) -> CGPoint {
        let maxY = max(0, feedScrollView.contentSize.height - feedScrollView.bounds.height)
        return CGPoint(
            x: 0,
            y: min(max(offset.y, 0), maxY)
        )
    }

    private func projectedRenderedFeedIndex(for velocity: CGPoint) -> Int {
        guard feedScrollView.bounds.height > 0 else { return currentRenderedFeedIndex }
        let projectedY = feedScrollView.contentOffset.y - velocity.y * 0.28
        return renderedFeedIndex(forProjectedY: projectedY)
    }

    private func renderedFeedIndex(forProjectedY projectedY: CGFloat) -> Int {
        guard feedScrollView.bounds.height > 0 else { return currentRenderedFeedIndex }
        let pageHeight = feedScrollView.bounds.height
        let projectedIndex = Int((projectedY / pageHeight).rounded())
        return min(max(projectedIndex, 0), max(feedPages.count - 1, 0))
    }

    private func logicalFeedIndex(forRenderedIndex renderedIndex: Int) -> Int {
        feedPageLogicalIndices[safe: renderedIndex] ?? currentFeedIndex
    }

    private func normalizeRenderedFeedPositionIfNeeded() {
        guard feedScrollView.bounds.height > 0, feedPages.count > 2 else { return }
        let normalizedIndex: Int
        if currentRenderedFeedIndex == 0 {
            normalizedIndex = feedPages.count - 2
        } else if currentRenderedFeedIndex == feedPages.count - 1 {
            normalizedIndex = 1
        } else {
            return
        }

        feedPages[safe: currentRenderedFeedIndex]?.setVideoActive(false)
        currentRenderedFeedIndex = normalizedIndex
        feedScrollView.setContentOffset(
            CGPoint(x: 0, y: CGFloat(normalizedIndex) * feedScrollView.bounds.height),
            animated: false
        )
        feedPages[safe: currentRenderedFeedIndex]?.setVideoActive(true)
        feedPages[safe: currentRenderedFeedIndex]?.setStoryContentVisible(true, animated: false)
    }

    private func applyFeedItem(at index: Int, animated: Bool) {
        let clampedIndex = min(max(index, 0), Self.feedItems.count - 1)
        currentFeedIndex = clampedIndex
        let item = Self.feedItems[clampedIndex]
        titleNameLabel.text = item.name
        titleStateLabel.text = item.mood
        outgoingBubble.isHidden = true
        outgoingBubble.alpha = 0
        feedPages.enumerated().forEach { pageIndex, page in
            page.setVideoActive(pageIndex == currentRenderedFeedIndex)
        }
        feedPages[safe: currentRenderedFeedIndex]?.setStoryContentVisible(true, animated: false)

        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            feedPages[safe: currentRenderedFeedIndex]?.startMessageAnimation(delay: 0.04)
            return
        }

        HapticFeedback.selection()
        feedPages[safe: currentRenderedFeedIndex]?.startMessageAnimation(delay: 0.02)
    }

    private func buildTopNavigation() {
        topNavigationBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topNavigationBar)

        let profileButton = makeIconButton(symbolName: "person", label: "Profile")
        topNavigationBar.addSubview(profileButton)

        let titleButton = UIControl()
        titleButton.isAccessibilityElement = true
        titleButton.accessibilityLabel = "Lucas, feeling lucky today"
        titleButton.accessibilityHint = "Opens character details."
        titleButton.accessibilityTraits = [.button]
        titleButton.addTarget(self, action: #selector(openLucas), for: .touchUpInside)
        titleButton.enableSystemTouchFeedback()
        titleButton.translatesAutoresizingMaskIntoConstraints = false
        topNavigationBar.addSubview(titleButton)

        let titleStack = UIStackView()
        titleStack.axis = .vertical
        titleStack.alignment = .center
        titleStack.spacing = 1
        titleStack.isUserInteractionEnabled = false
        titleStack.alpha = 0
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        titleButton.addSubview(titleStack)

        titleNameLabel.text = Self.feedItems[currentFeedIndex].name
        titleNameLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: telkaFont(size: 17))
        titleNameLabel.adjustsFontForContentSizeCategory = true
        titleNameLabel.textColor = .white
        titleNameLabel.textAlignment = .center
        titleStack.addArrangedSubview(titleNameLabel)

        titleStateLabel.text = Self.feedItems[currentFeedIndex].mood
        titleStateLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14, weight: .regular))
        titleStateLabel.adjustsFontForContentSizeCategory = true
        titleStateLabel.textColor = UIColor.white.withAlphaComponent(0.80)
        titleStateLabel.textAlignment = .center
        titleStateLabel.lineBreakMode = .byTruncatingTail
        titleStack.addArrangedSubview(titleStateLabel)

        let voiceButton = makeIconButton(symbolName: "speaker.wave.2", label: "Voice")
        topNavigationBar.addSubview(voiceButton)

        NSLayoutConstraint.activate([
            topNavigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            topNavigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            topNavigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            topNavigationBar.heightAnchor.constraint(equalToConstant: 44),

            profileButton.leadingAnchor.constraint(equalTo: topNavigationBar.leadingAnchor),
            profileButton.centerYAnchor.constraint(equalTo: topNavigationBar.centerYAnchor),
            profileButton.widthAnchor.constraint(equalToConstant: 44),
            profileButton.heightAnchor.constraint(equalToConstant: 44),

            titleButton.centerXAnchor.constraint(equalTo: topNavigationBar.centerXAnchor),
            titleButton.centerYAnchor.constraint(equalTo: topNavigationBar.centerYAnchor),
            titleButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            titleButton.leadingAnchor.constraint(greaterThanOrEqualTo: profileButton.trailingAnchor, constant: 12),

            titleStack.topAnchor.constraint(greaterThanOrEqualTo: titleButton.topAnchor),
            titleStack.leadingAnchor.constraint(equalTo: titleButton.leadingAnchor),
            titleStack.trailingAnchor.constraint(equalTo: titleButton.trailingAnchor),
            titleStack.centerYAnchor.constraint(equalTo: titleButton.centerYAnchor),

            voiceButton.trailingAnchor.constraint(equalTo: topNavigationBar.trailingAnchor),
            voiceButton.centerYAnchor.constraint(equalTo: topNavigationBar.centerYAnchor),
            voiceButton.widthAnchor.constraint(equalToConstant: 44),
            voiceButton.heightAnchor.constraint(equalToConstant: 44),

            titleButton.trailingAnchor.constraint(lessThanOrEqualTo: voiceButton.leadingAnchor, constant: -12)
        ])
    }

    private func buildChatContent() {
        chatContainer.clipsToBounds = false
        chatContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(chatContainer)

        introBubble.translatesAutoresizingMaskIntoConstraints = false
        introBubble.isHidden = true
        introBubble.isUserInteractionEnabled = false
        introBubble.onShowMoreTapped = { [weak self] in
            self?.presentScriptIntroSheet(text: Self.feedItems[self?.currentFeedIndex ?? 0].intro)
        }
        introBubble.addInteraction(UIContextMenuInteraction(delegate: self))
        chatContainer.addSubview(introBubble)

        incomingBubble.translatesAutoresizingMaskIntoConstraints = false
        incomingBubble.isHidden = true
        incomingBubble.isUserInteractionEnabled = false
        incomingBubble.addInteraction(UIContextMenuInteraction(delegate: self))
        chatContainer.addSubview(incomingBubble)

        outgoingBubble.alpha = 0
        outgoingBubble.isHidden = true
        outgoingBubble.translatesAutoresizingMaskIntoConstraints = false
        chatContainer.addSubview(outgoingBubble)

        NSLayoutConstraint.activate([
            chatContainer.topAnchor.constraint(equalTo: topNavigationBar.bottomAnchor, constant: 12),
            chatContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chatContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            introBubble.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor, constant: 12),
            introBubble.trailingAnchor.constraint(lessThanOrEqualTo: chatContainer.trailingAnchor, constant: -64),
            introBubble.topAnchor.constraint(greaterThanOrEqualTo: chatContainer.topAnchor, constant: 12),

            incomingBubble.leadingAnchor.constraint(equalTo: chatContainer.leadingAnchor, constant: 12),
            incomingBubble.trailingAnchor.constraint(lessThanOrEqualTo: chatContainer.trailingAnchor, constant: -64),
            incomingBubble.topAnchor.constraint(equalTo: introBubble.bottomAnchor, constant: 8),
            incomingBubble.bottomAnchor.constraint(equalTo: chatContainer.bottomAnchor),

            outgoingBubble.trailingAnchor.constraint(equalTo: chatContainer.trailingAnchor, constant: -12),
            outgoingBubble.leadingAnchor.constraint(greaterThanOrEqualTo: chatContainer.leadingAnchor, constant: 64),
            outgoingBubble.bottomAnchor.constraint(equalTo: chatContainer.bottomAnchor)
        ])
    }

    private func buildBottomControls() {
        inputBar.onRecordingStateChanged = { [weak self] isRecording, mode in
            self?.setRecordingUIVisible(isRecording, mode: mode)
        }
        inputBar.onSendMessage = { [weak self] message in
            self?.sendMessage(message)
        }
        inputBar.onTuneTapped = { [weak self] in
            self?.presentTuneInspector()
        }
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(inputBar)

        tabBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabBar)

        recordingHintLabel.text = "Swipe up to cancel, down to add action or scene"
        recordingHintLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 14, weight: .regular)
        )
        recordingHintLabel.adjustsFontForContentSizeCategory = true
        recordingHintLabel.textColor = UIColor.white.withAlphaComponent(0.40)
        recordingHintLabel.textAlignment = .center
        recordingHintLabel.alpha = 0
        recordingHintLabel.isAccessibilityElement = false
        recordingHintLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(recordingHintLabel)

        inputBarBottomToHeroConstraint = inputBar.bottomAnchor.constraint(equalTo: heroContainer.bottomAnchor, constant: -12)
        inputBarBottomToKeyboardConstraint = inputBar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        inputBarBottomToKeyboardConstraint.isActive = false

        NSLayoutConstraint.activate([
            inputBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            inputBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            inputBarBottomToHeroConstraint,
            inputBar.heightAnchor.constraint(equalToConstant: 56),

            chatContainer.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -16),

            recordingHintLabel.topAnchor.constraint(equalTo: heroContainer.bottomAnchor, constant: 16),
            recordingHintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            recordingHintLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            recordingHintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 8),
            tabBar.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func sendMessage(_ message: String) {
        outgoingBubble.setText(message, animated: true)
        outgoingBubble.isHidden = false
        outgoingBubble.alpha = 0
        outgoingBubble.transform = .identity
        view.layoutIfNeeded()

        let launchRect = inputBar.messageLaunchSourceFrame(in: chatContainer)
        let targetCenter = CGPoint(x: outgoingBubble.frame.midX, y: outgoingBubble.frame.midY)
        let launchCenter = CGPoint(x: launchRect.midX, y: launchRect.midY)
        let initialTransform = CGAffineTransform(
            translationX: launchCenter.x - targetCenter.x,
            y: launchCenter.y - targetCenter.y
        )
        let midTransform = CGAffineTransform(
            translationX: (launchCenter.x - targetCenter.x) * 0.42,
            y: (launchCenter.y - targetCenter.y) * 0.58 - 10
        )
        outgoingBubble.transform = initialTransform
        feedPages[safe: currentRenderedFeedIndex]?.setStoryContentVisible(false, animated: true)

        let changes = {
            self.introBubble.alpha = 0
            self.incomingBubble.alpha = 0
            self.outgoingBubble.alpha = 1
            self.view.layoutIfNeeded()
        }

        guard !UIAccessibility.isReduceMotionEnabled else {
            changes()
            outgoingBubble.transform = .identity
            return
        }

        UIView.animateKeyframes(
            withDuration: 0.42,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .calculationModeCubic],
            animations: {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.55) {
                    self.outgoingBubble.transform = midTransform
                    self.outgoingBubble.alpha = 1
                    self.introBubble.alpha = 0
                    self.incomingBubble.alpha = 0
                }
                UIView.addKeyframe(withRelativeStartTime: 0.44, relativeDuration: 0.56) {
                    self.outgoingBubble.transform = .identity
                    self.view.layoutIfNeeded()
                }
            }
        )
    }

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    private func installKeyboardDismissGesture() {
        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboardFromBackgroundTap))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        keyboardDismissGesture = tapGesture
        view.addGestureRecognizer(tapGesture)
    }

    private func installFeedSwipeGesture() {
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleFeedPan(_:)))
        panGesture.cancelsTouchesInView = false
        panGesture.delegate = self
        feedPanGesture = panGesture
        view.addGestureRecognizer(panGesture)
    }

    @objc private func handleFeedPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            feedSnapAnimator?.stopAnimation(true)
            feedSnapAnimator = nil
            feedPanStartOffset = feedScrollView.contentOffset
        case .changed:
            let translation = gesture.translation(in: view)
            feedScrollView.setContentOffset(
                clampedFeedOffset(CGPoint(x: 0, y: feedPanStartOffset.y - translation.y)),
                animated: false
            )
        case .ended, .cancelled, .failed:
            let velocity = gesture.velocity(in: view)
            let translation = gesture.translation(in: view)
            let pageHeight = max(feedScrollView.bounds.height, 1)
            let progress = -translation.y / pageHeight
            let targetIndex: Int
            if abs(progress) > 0.08 {
                targetIndex = currentRenderedFeedIndex + (progress > 0 ? 1 : -1)
            } else {
                targetIndex = projectedRenderedFeedIndex(for: velocity)
            }
            scrollToRenderedFeedItem(at: targetIndex, animated: true)
        default:
            break
        }
    }

    @objc private func dismissKeyboardFromBackgroundTap() {
        inputBar.dismissKeyboardPreservingInputState()
    }

    @objc private func handleKeyboardFrameChange(_ notification: Notification) {
        guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboardFrameInView = view.convert(keyboardFrame, from: nil)
        let keyboardOverlap = max(0, view.bounds.maxY - keyboardFrameInView.minY)

        inputBarBottomToHeroConstraint.isActive = keyboardOverlap <= 0
        inputBarBottomToKeyboardConstraint.isActive = keyboardOverlap > 0
        inputBarBottomToKeyboardConstraint.constant = -(keyboardOverlap + 12)
        feedPages.forEach {
            $0.setKeyboardOverlap(keyboardOverlap, safeAreaBottom: view.safeAreaInsets.bottom)
        }
        if keyboardOverlap > 0 {
            inputBar.setKeyboardInputActive(true, animated: false)
        }
        inputBar.setKeyboardVisible(keyboardOverlap > 0, animated: false)
        animateKeyboardSyncedChanges(notification) {
            self.tabBar.alpha = keyboardOverlap > 0 ? 0 : 1
            self.recordingHintLabel.alpha = 0
            self.view.layoutIfNeeded()
        }
    }

    @objc private func handleKeyboardHide(_ notification: Notification) {
        inputBarBottomToKeyboardConstraint.isActive = false
        inputBarBottomToHeroConstraint.isActive = true
        feedPages.forEach { $0.setKeyboardOverlap(0, safeAreaBottom: view.safeAreaInsets.bottom) }
        inputBar.setKeyboardVisible(false, animated: false)
        animateKeyboardSyncedChanges(notification) {
            self.tabBar.alpha = 1
            self.view.layoutIfNeeded()
        }
    }

    private func synchronizeFeedLayoutIfNeeded() {
        let size = feedScrollView.bounds.size
        guard size.width > 0, size.height > 0, size != lastFeedLayoutSize else { return }
        lastFeedLayoutSize = size
        feedScrollView.setContentOffset(
            CGPoint(x: 0, y: CGFloat(currentRenderedFeedIndex) * size.height),
            animated: false
        )
    }

    private func animateKeyboardSyncedChanges(_ notification: Notification, changes: @escaping () -> Void) {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.32
        let curveRawValue = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        let options = UIView.AnimationOptions(rawValue: curveRawValue << 16).union([.beginFromCurrentState, .allowUserInteraction])

        UIView.animate(withDuration: duration, delay: 0, options: options, animations: changes)
    }

    private func setRecordingUIVisible(_ isVisible: Bool, mode: RecordingDragMode) {
        recordingHintLabel.text = mode.promptText

        let changes = {
            self.tabBar.alpha = isVisible ? 0 : 1
            self.recordingHintLabel.alpha = isVisible ? 1 : 0
        }

        guard !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }

        UIViewPropertyAnimator(duration: isVisible ? 0.22 : 0.28, dampingRatio: 0.86) {
            changes()
        }.startAnimation()
    }

    private func makeIconButton(symbolName: String, label: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbolName), for: .normal)
        button.tintColor = .white
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 25, weight: .medium),
            forImageIn: .normal
        )
        button.accessibilityLabel = label
        button.translatesAutoresizingMaskIntoConstraints = false
        button.enableSystemTouchFeedback()
        return button
    }

    private func telkaFont(size: CGFloat) -> UIFont {
        UIFont(name: "TelkaTRIAL-Wide-Medium", size: size) ?? .systemFont(ofSize: size, weight: .semibold)
    }

    @objc private func openLucas() {
        guard !isOpeningLucasDetails else { return }
        isOpeningLucasDetails = true

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard let self else { return }
            self.navigationController?.pushViewController(ViewController(), animated: true)
            self.isOpeningLucasDetails = false
        }
    }

    private func presentTuneInspector() {
        let inspector = TuneInspectorViewController()
        inspector.modalPresentationStyle = .pageSheet
        if let sheet = inspector.sheetPresentationController {
            let relaxedIdentifier = UISheetPresentationController.Detent.Identifier("relaxedTune")
            sheet.detents = [
                .custom(identifier: relaxedIdentifier) { context in
                    min(554, context.maximumDetentValue - 32)
                },
                .large()
            ]
            sheet.selectedDetentIdentifier = relaxedIdentifier
            sheet.prefersGrabberVisible = false
            sheet.preferredCornerRadius = 38
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
        }
        present(inspector, animated: true)
    }

    private func presentScriptIntroSheet(text: String) {
        let introSheet = ScriptIntroSheetViewController(text: text)
        introSheet.modalPresentationStyle = .pageSheet
        if let sheet = introSheet.sheetPresentationController {
            let relaxedIdentifier = UISheetPresentationController.Detent.Identifier("relaxedScriptIntro")
            sheet.detents = [
                .custom(identifier: relaxedIdentifier) { context in
                    min(554, context.maximumDetentValue - 32)
                },
                .large()
            ]
            sheet.selectedDetentIdentifier = relaxedIdentifier
            sheet.prefersGrabberVisible = false
            sheet.preferredCornerRadius = 38
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
            sheet.prefersEdgeAttachedInCompactHeight = true
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
        }
        present(introSheet, animated: true)
    }
}

extension HomeViewController: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [
                UIAction(title: "Like", image: UIImage(systemName: "hand.thumbsup")) { _ in },
                UIAction(title: "Dislike", image: UIImage(systemName: "hand.thumbsdown")) { _ in },
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in },
                UIMenu(options: .displayInline, children: [
                    UIAction(title: "Share", image: UIImage(systemName: "arrowshape.turn.up.right")) { _ in },
                    UIAction(title: "Rewind", image: UIImage(systemName: "clock.arrow.circlepath")) { _ in },
                    UIAction(title: "RePlay", image: UIImage(systemName: "arrow.clockwise")) { _ in }
                ])
            ])
        }
    }
}

extension HomeViewController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === feedPanGesture {
            guard let touchedView = touch.view else { return true }
            return !touchedView.isDescendant(of: inputBar)
                && !touchedView.isDescendant(of: feedScrollView)
        }

        if gestureRecognizer === keyboardDismissGesture {
            guard inputBar.isKeyboardInputModeActive else { return false }
            guard let touchedView = touch.view else { return true }
            return !touchedView.isDescendant(of: inputBar)
        }

        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === feedPanGesture,
              let panGesture = gestureRecognizer as? UIPanGestureRecognizer else {
            return true
        }
        let velocity = panGesture.velocity(in: view)
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === feedPanGesture || otherGestureRecognizer === feedPanGesture
    }
}

private final class FeedPageView: UIView {
    var onShowMoreTapped: (() -> Void)?

    private let backgroundImageView = UIImageView()
    private var videoPlayer: AVQueuePlayer?
    private var videoLooper: AVPlayerLooper?
    private var videoLayer: AVPlayerLayer?
    private let titleStack = UIStackView()
    private let nameLabel = UILabel()
    private let moodLabel = UILabel()
    private let introBubble = IntroBubbleView()
    private let incomingBubble = IncomingBubbleView()
    private var incomingBottomConstraint: NSLayoutConstraint!
    private let introText: String
    private let firstScene: String
    private let firstLine: String
    private let secondScene: String
    private let secondLine: String

    var fullIntroText: String {
        introText
    }

    init(
        name: String,
        mood: String,
        intro: String,
        firstScene: String,
        firstLine: String,
        secondScene: String,
        secondLine: String,
        image: UIImage?,
        videoURL: URL?
    ) {
        self.introText = intro
        self.firstScene = firstScene
        self.firstLine = firstLine
        self.secondScene = secondScene
        self.secondLine = secondLine
        super.init(frame: .zero)
        build(name: name, mood: mood, image: image, videoURL: videoURL)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = 32
        layer.cornerCurve = .continuous
        backgroundImageView.layer.cornerRadius = 32
        backgroundImageView.layer.cornerCurve = .continuous
        videoLayer?.cornerRadius = 32
        videoLayer?.cornerCurve = .continuous
        videoLayer?.masksToBounds = true
        videoLayer?.frame = bounds
    }

    func startMessageAnimation(delay: TimeInterval) {
        incomingBubble.configure(
            firstScene: firstScene,
            firstLine: firstLine,
            secondScene: secondScene,
            secondLine: secondLine
        )
        incomingBubble.startTypewriter(delay: delay)
    }

    func setKeyboardOverlap(_ overlap: CGFloat, safeAreaBottom: CGFloat) {
        guard overlap > 0 else {
            incomingBottomConstraint.constant = -84
            return
        }
        incomingBottomConstraint.constant = min(-84, safeAreaBottom + 46 - overlap - 84)
    }

    func setStoryContentVisible(_ visible: Bool, animated: Bool) {
        let changes = {
            self.introBubble.alpha = visible ? 1 : 0
            self.incomingBubble.alpha = visible ? 1 : 0
        }

        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }

        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: changes
        )
    }

    func setVideoActive(_ active: Bool) {
        guard let videoPlayer else { return }
        if active {
            videoPlayer.play()
        } else {
            videoPlayer.pause()
        }
    }

    private func build(name: String, mood: String, image: UIImage?, videoURL: URL?) {
        clipsToBounds = true
        layer.cornerRadius = 32
        layer.cornerCurve = .continuous

        backgroundImageView.image = image
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        backgroundImageView.layer.cornerRadius = 32
        backgroundImageView.layer.cornerCurve = .continuous
        backgroundImageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backgroundImageView)
        configureVideoBackground(url: videoURL)

        titleStack.axis = .vertical
        titleStack.alignment = .center
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleStack)

        nameLabel.text = name
        nameLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: UIFont(name: "TelkaTRIAL-Wide-Medium", size: 17) ?? .systemFont(ofSize: 17, weight: .semibold)
        )
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .white
        nameLabel.textAlignment = .center
        titleStack.addArrangedSubview(nameLabel)

        moodLabel.text = mood
        moodLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14, weight: .regular))
        moodLabel.adjustsFontForContentSizeCategory = true
        moodLabel.textColor = UIColor.white.withAlphaComponent(0.80)
        moodLabel.textAlignment = .center
        moodLabel.lineBreakMode = .byTruncatingTail
        titleStack.addArrangedSubview(moodLabel)

        introBubble.configure(text: introText)
        introBubble.onShowMoreTapped = { [weak self] in
            self?.onShowMoreTapped?()
        }
        introBubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(introBubble)

        incomingBubble.configure(
            firstScene: firstScene,
            firstLine: firstLine,
            secondScene: secondScene,
            secondLine: secondLine
        )
        incomingBubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(incomingBubble)

        incomingBottomConstraint = incomingBubble.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -84)

        NSLayoutConstraint.activate([
            backgroundImageView.topAnchor.constraint(equalTo: topAnchor),
            backgroundImageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundImageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundImageView.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleStack.topAnchor.constraint(equalTo: topAnchor, constant: 62),
            titleStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 112),
            titleStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -112),

            introBubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            introBubble.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -64),

            incomingBubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            incomingBubble.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -64),
            incomingBubble.topAnchor.constraint(equalTo: introBubble.bottomAnchor, constant: 8),
            incomingBottomConstraint
        ])
    }

    private func configureVideoBackground(url: URL?) {
        guard let url else { return }
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none
        player.preventsDisplaySleepDuringVideoPlayback = false

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.cornerRadius = 32
        playerLayer.cornerCurve = .continuous
        playerLayer.masksToBounds = true
        playerLayer.frame = bounds
        layer.insertSublayer(playerLayer, above: backgroundImageView.layer)

        videoPlayer = player
        videoLayer = playerLayer
        videoLooper = AVPlayerLooper(player: player, templateItem: item)
    }
}

private final class IntroBubbleView: UIView {
    var onShowMoreTapped: (() -> Void)?

    private let label = UILabel()
    private var introContent = ""
    private var lastRenderedWidth: CGFloat = 0

    var fullText: String {
        introContent
    }

    init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = maximumLabelWidth
        label.preferredMaxLayoutWidth = width
        guard abs(width - lastRenderedWidth) > 0.5 else { return }
        lastRenderedWidth = width
        label.attributedText = collapsedIntroText(for: width)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let labelSize = label.sizeThatFits(
            CGSize(width: maximumLabelWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: labelSize.width + 32, height: labelSize.height + 24)
    }

    private var maximumLabelWidth: CGFloat {
        let fallbackWidth = window?.windowScene?.screen.bounds.width ?? 393
        let containerWidth = superview?.bounds.width ?? 0
        return max(0, (containerWidth > 0 ? containerWidth : fallbackWidth) - 12 - 64 - 32)
    }

    func configure(text: String) {
        introContent = text
        lastRenderedWidth = 0
        label.attributedText = collapsedIntroText(for: maximumLabelWidth)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func build() {
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Character introduction"

        let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        let overlay = UIView()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.60)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)

        label.numberOfLines = 4
        label.attributedText = collapsedIntroText(for: maximumLabelWidth)
        label.adjustsFontForContentSizeCategory = true
        label.lineBreakMode = .byWordWrapping
        label.isUserInteractionEnabled = false
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(showMoreTapped))
        tapGesture.cancelsTouchesInView = false
        addGestureRecognizer(tapGesture)

        let pressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleShowMorePress(_:)))
        pressGesture.minimumPressDuration = 0
        pressGesture.cancelsTouchesInView = false
        addGestureRecognizer(pressGesture)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    @objc private func showMoreTapped() {
        HapticFeedback.selection()
        onShowMoreTapped?()
    }

    @objc private func handleShowMorePress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            HapticFeedback.touchDown()
            animateSystemTouchFeedback(on: self, isPressed: true, scale: 0.98)
        case .ended:
            animateSystemTouchFeedback(on: self, isPressed: false)
        case .cancelled, .failed:
            animateSystemTouchFeedback(on: self, isPressed: false)
        default:
            break
        }
    }

    private func collapsedIntroText(for width: CGFloat) -> NSAttributedString {
        guard width > 0 else { return introText(fullText) }
        let fullText = introContent
        guard !fullText.isEmpty else { return introText("") }
        let fullAttributedText = introText(fullText)
        guard measuredHeight(of: fullAttributedText, width: width) > fourLineHeight else {
            return fullAttributedText
        }

        var lowerBound = 0
        var upperBound = fullText.count
        var bestText = "... Show More"

        while lowerBound <= upperBound {
            let mid = (lowerBound + upperBound) / 2
            let prefix = String(fullText.prefix(mid)).trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = "\(prefix)... Show More"
            let candidateText = introText(candidate, showMoreRange: (candidate as NSString).range(of: "Show More", options: .backwards))

            if measuredHeight(of: candidateText, width: width) <= fourLineHeight {
                bestText = candidate
                lowerBound = mid + 1
            } else {
                upperBound = mid - 1
            }
        }

        let showMoreRange = (bestText as NSString).range(of: "Show More", options: .backwards)
        return introText(bestText, showMoreRange: showMoreRange)
    }

    private var fourLineHeight: CGFloat {
        ceil(introBodyFont.lineHeight * 4)
    }

    private var introBodyFont: UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 15, weight: .regular))
    }

    private func measuredHeight(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(
            with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
    }

    private func introText(_ text: String, showMoreRange: NSRange? = nil) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 0
        paragraph.lineBreakMode = .byWordWrapping

        let result = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: introBodyFont,
                .foregroundColor: UIColor.white.withAlphaComponent(0.40),
                .paragraphStyle: paragraph
            ]
        )
        if let showMoreRange,
           showMoreRange.location != NSNotFound,
           NSMaxRange(showMoreRange) <= result.length {
            result.addAttributes(
                [
                    .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 15, weight: .semibold)),
                    .foregroundColor: UIColor.white
                ],
                range: showMoreRange
            )
        }
        return result
    }
}

private final class ScriptIntroSheetViewController: UIViewController {
    private let text: String
    private let handleView = UIView()
    private let titleLabel = UILabel()
    private let scrollView = UIScrollView()
    private let contentLabel = UILabel()

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(white: 0.08, alpha: 0.34)
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        build()
    }

    private func build() {
        handleView.backgroundColor = UIColor.white.withAlphaComponent(0.20)
        handleView.layer.cornerRadius = 2.5
        handleView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(handleView)

        titleLabel.text = "Script Intro"
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: UIFont(name: "TelkaTRIAL-Wide-Medium", size: 17) ?? .systemFont(ofSize: 17, weight: .semibold)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleLabel)

        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byWordWrapping

        contentLabel.numberOfLines = 0
        contentLabel.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .regular)),
                .foregroundColor: UIColor.white.withAlphaComponent(0.76),
                .paragraphStyle: paragraph
            ]
        )
        contentLabel.adjustsFontForContentSizeCategory = true
        contentLabel.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentLabel)

        NSLayoutConstraint.activate([
            handleView.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            handleView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            handleView.widthAnchor.constraint(equalToConstant: 36),
            handleView.heightAnchor.constraint(equalToConstant: 5),

            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentLabel.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            contentLabel.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 24),
            contentLabel.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -24),
            contentLabel.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32)
        ])
    }
}

private struct TextRevealSegment {
    let text: NSAttributedString
    let isAnimated: Bool
}

private final class IncomingBubbleView: UIView {
    private enum Metrics {
        static let fontSize: CGFloat = 18
        static let lineHeight: CGFloat = 24
    }

    private let label = UILabel()
    private var revealDriver: SegmentedRevealDriver?
    private var fullText = NSAttributedString()
    private var revealSegments: [TextRevealSegment] = []
    private var lockedBubbleWidth: CGFloat?
    private var messageParts = (
        firstScene: "",
        firstLine: "",
        secondScene: "",
        secondLine: ""
    )

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.preferredMaxLayoutWidth = max(0, maximumLabelWidth)
    }

    override var intrinsicContentSize: CGSize {
        let labelSize = label.sizeThatFits(
            CGSize(width: maximumLabelWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(width: lockedBubbleWidth ?? max(40, labelSize.width + 32), height: labelSize.height + 24)
    }

    private var maximumLabelWidth: CGFloat {
        let fallbackWidth = window?.windowScene?.screen.bounds.width ?? 393
        let containerWidth = superview?.bounds.width ?? 0
        return max(0, (containerWidth > 0 ? containerWidth : fallbackWidth) - 12 - 64 - 32)
    }

    private func build() {
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = "Incoming message"
        widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true

        let blurView = BubbleBlurView(style: .light)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        let overlay = UIView()
        overlay.backgroundColor = BubbleBackgroundStyle.incomingFill
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)

        label.numberOfLines = 0
        revealSegments = messageSegments()
        fullText = revealSegments.joinedText
        label.attributedText = revealSegments.revealingAnimatedCharacters(progress: 0)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .left
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }

    func startTypewriter(delay: TimeInterval) {
        animateTypewriterText(revealSegments, on: label, after: delay)
    }

    func configure(firstScene: String, firstLine: String, secondScene: String, secondLine: String) {
        revealDriver?.stop()
        messageParts = (firstScene, firstLine, secondScene, secondLine)
        revealSegments = messageSegments()
        fullText = revealSegments.joinedText
        lockedBubbleWidth = targetBubbleWidth(for: fullText)
        label.attributedText = revealSegments.revealingAnimatedCharacters(progress: 0)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func targetBubbleWidth(for text: NSAttributedString) -> CGFloat {
        let labelWidth = maximumLabelWidth
        guard labelWidth > 0, text.length > 0 else { return 40 }
        let measuredWidth = ceil(text.boundingRect(
            with: CGSize(width: labelWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).width)
        return max(40, min(labelWidth + 32, measuredWidth + 32))
    }

    private func messageSegments() -> [TextRevealSegment] {
        func paragraph(spacingAfter: CGFloat) -> NSMutableParagraphStyle {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 0
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.minimumLineHeight = Metrics.lineHeight
            paragraph.maximumLineHeight = Metrics.lineHeight
            paragraph.paragraphSpacing = spacingAfter
            return paragraph
        }

        func attributes(font: UIFont, color: UIColor, spacingAfter: CGFloat) -> [NSAttributedString.Key: Any] {
            [
                .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: font),
                .foregroundColor: color,
                .paragraphStyle: paragraph(spacingAfter: spacingAfter),
                .kern: -0.43
            ]
        }

        let bodyColor = UIColor.black.withAlphaComponent(0.50)
        let emphasisColor = UIColor(red: 0.059, green: 0.090, blue: 0.165, alpha: 1)
        let bodyFont = UIFont.systemFont(ofSize: Metrics.fontSize, weight: .regular)
        let emphasisFont = UIFont.systemFont(ofSize: Metrics.fontSize, weight: .semibold)

        return [
            TextRevealSegment(
                text: NSAttributedString(
                    string: "\(messageParts.firstScene.removingWrappingParentheses())\n",
                    attributes: attributes(font: bodyFont, color: bodyColor, spacingAfter: 8)
                ),
                isAnimated: false
            ),
            TextRevealSegment(
                text: NSAttributedString(
                    string: "\(messageParts.firstLine)\n",
                    attributes: attributes(font: emphasisFont, color: emphasisColor, spacingAfter: 8)
                ),
                isAnimated: true
            ),
            TextRevealSegment(
                text: NSAttributedString(
                    string: "\(messageParts.secondScene.removingWrappingParentheses())\n",
                    attributes: attributes(font: bodyFont, color: bodyColor, spacingAfter: 8)
                ),
                isAnimated: false
            ),
            TextRevealSegment(
                text: NSAttributedString(
                    string: messageParts.secondLine,
                    attributes: attributes(font: emphasisFont, color: emphasisColor, spacingAfter: 0)
                ),
                isAnimated: true
            )
        ]
    }

    private func animateTypewriterText(_ segments: [TextRevealSegment], on label: UILabel, after delay: TimeInterval) {
        revealDriver?.stop()
        accessibilityValue = segments.joinedText.string

        guard !UIAccessibility.isReduceMotionEnabled, segments.animatedCharacterCount > 0 else {
            label.attributedText = segments.joinedText
            return
        }

        label.attributedText = segments.revealingAnimatedCharacters(progress: 0)
        let driver = SegmentedRevealDriver(label: label, segments: segments, delay: delay)
        revealDriver = driver
        driver.start()
    }
}

private final class OutgoingBubbleView: UIView {
    private enum Metrics {
        static let fontSize: CGFloat = 18
        static let lineHeight: CGFloat = 24
        static let horizontalPadding: CGFloat = 24
        static let verticalPadding: CGFloat = 12
        static let minimumWidth: CGFloat = 56
    }

    private let label = UILabel()
    private var lockedBubbleWidth: CGFloat?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.preferredMaxLayoutWidth = max(0, maximumLabelWidth)
    }

    override var intrinsicContentSize: CGSize {
        let labelSize = label.sizeThatFits(
            CGSize(width: maximumLabelWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        return CGSize(
            width: lockedBubbleWidth ?? max(Metrics.minimumWidth, labelSize.width + Metrics.horizontalPadding * 2),
            height: labelSize.height + Metrics.verticalPadding * 2
        )
    }

    private var maximumLabelWidth: CGFloat {
        let fallbackWidth = window?.windowScene?.screen.bounds.width ?? 393
        let containerWidth = superview?.bounds.width ?? 0
        return max(0, (containerWidth > 0 ? containerWidth : fallbackWidth) - 64 - 12 - 32)
    }

    func setText(_ text: String, animated: Bool) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 0
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.minimumLineHeight = Metrics.lineHeight
        paragraph.maximumLineHeight = Metrics.lineHeight
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: label.font as Any,
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph,
                .kern: -0.43
            ]
        )
        lockedBubbleWidth = targetBubbleWidth(for: attributedText)
        label.attributedText = attributedText
        invalidateIntrinsicContentSize()
        accessibilityLabel = "Sent message: \(text)"
    }

    private func targetBubbleWidth(for text: NSAttributedString) -> CGFloat {
        let labelWidth = maximumLabelWidth
        guard labelWidth > 0, text.length > 0 else { return 40 }
        let measuredWidth = ceil(text.boundingRect(
            with: CGSize(width: labelWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).width)
        return max(
            Metrics.minimumWidth,
            min(labelWidth + Metrics.horizontalPadding * 2, measuredWidth + Metrics.horizontalPadding * 2)
        )
    }

    private func build() {
        layer.cornerRadius = 24
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        widthAnchor.constraint(greaterThanOrEqualToConstant: Metrics.minimumWidth).isActive = true

        let blurView = BubbleBlurView(style: .dark)
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)

        let overlay = UIView()
        overlay.backgroundColor = BubbleBackgroundStyle.outgoingFill
        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)

        label.numberOfLines = 0
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: Metrics.fontSize, weight: .medium))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.textAlignment = .left
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        NSLayoutConstraint.activate([
            blurView.topAnchor.constraint(equalTo: topAnchor),
            blurView.leadingAnchor.constraint(equalTo: leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: trailingAnchor),
            blurView.bottomAnchor.constraint(equalTo: bottomAnchor),

            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),

            label.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.verticalPadding),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalPadding),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.horizontalPadding),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.verticalPadding)
        ])
    }
}

private enum BubbleBackgroundStyle {
    static let designBlurRadius: CGFloat = 40
    static let incomingBackgroundOpacity: CGFloat = 0.78
    static let outgoingBackgroundOpacity: CGFloat = 0.88
    static let incomingFill = UIColor.white.withAlphaComponent(incomingBackgroundOpacity)
    static let outgoingFill = UIColor.black.withAlphaComponent(outgoingBackgroundOpacity)
}

private final class BubbleBlurView: UIVisualEffectView {
    enum Style {
        case light
        case dark
    }

    init(style: Style) {
        let effectStyle: UIBlurEffect.Style = {
            switch style {
            case .light:
                return .systemUltraThinMaterialLight
            case .dark:
                return .systemUltraThinMaterialDark
            }
        }()
        super.init(effect: UIBlurEffect(style: effectStyle))
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private extension NSAttributedString {
    func typewriterRevealingCharacters(progress: CGFloat) -> NSAttributedString {
        guard length > 0 else { return self }

        let clampedProgress = min(max(progress, 0), CGFloat(length))
        guard clampedProgress > 0 else {
            return typewriterCursorOnly()
        }
        guard clampedProgress < CGFloat(length) else { return self }

        let clearEnd = min(max(Int(clampedProgress.rounded(.down)), 0), length)
        let copy = NSMutableAttributedString(
            attributedString: attributedSubstring(from: NSRange(location: 0, length: clearEnd))
        )
        copy.append(typewriterCursor(after: clearEnd))

        return copy
    }

    private func typewriterCursorOnly() -> NSAttributedString {
        typewriterCursor(after: 0, includesLeadingSpace: false)
    }

    private func typewriterCursor(after location: Int, includesLeadingSpace: Bool = true) -> NSAttributedString {
        let attributeLocation = min(max(location - 1, 0), max(length - 1, 0))
        let attributes = attributes(at: attributeLocation, effectiveRange: nil)
        let color = (attributes[.foregroundColor] as? UIColor ?? .label).withAlphaComponent(0.42)
        let attachment = NSTextAttachment()
        attachment.image = typewriterCursorImage(color: color)
        attachment.bounds = CGRect(x: 0, y: -1, width: 8, height: 8)

        let result = NSMutableAttributedString()
        if includesLeadingSpace {
            result.append(NSAttributedString(string: " ", attributes: attributes))
        }
        result.append(NSAttributedString(attachment: attachment))
        return result
    }

    private func typewriterCursorImage(color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: 8, height: 8)).fill()
        }
    }
}

private extension Array where Element == TextRevealSegment {
    var joinedText: NSAttributedString {
        let result = NSMutableAttributedString()
        forEach { result.append($0.text) }
        return result
    }

    var animatedCharacterCount: Int {
        reduce(0) { $0 + ($1.isAnimated ? $1.text.length : 0) }
    }

    var animatedString: String {
        reduce("") { $0 + ($1.isAnimated ? $1.text.string : "") }
    }

    func revealingAnimatedCharacters(progress: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var remainingAnimatedCharacters = Swift.min(Swift.max(progress, 0), CGFloat(animatedCharacterCount))

        for segment in self {
            guard segment.isAnimated else {
                result.append(segment.text)
                continue
            }

            if remainingAnimatedCharacters <= 0 {
                result.append(segment.text.typewriterRevealingCharacters(progress: 0))
                break
            }

            if remainingAnimatedCharacters < CGFloat(segment.text.length) {
                result.append(segment.text.typewriterRevealingCharacters(progress: remainingAnimatedCharacters))
                break
            }

            result.append(segment.text)
            remainingAnimatedCharacters -= CGFloat(segment.text.length)
        }

        return result
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private extension String {
    func removingWrappingParentheses() -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("("), trimmed.hasSuffix(")") else { return self }
        return String(trimmed.dropFirst().dropLast())
    }
}

@MainActor
private final class SegmentedRevealDriver: NSObject {
    private weak var label: UILabel?
    private let segments: [TextRevealSegment]
    private let delay: TimeInterval
    private let animatedString: String
    private var displayLink: CADisplayLink?
    private var progress: CGFloat = 0
    private var startTime: CFTimeInterval = 0

    init(label: UILabel, segments: [TextRevealSegment], delay: TimeInterval = 0) {
        self.label = label
        self.segments = segments
        self.delay = delay
        self.animatedString = segments.animatedString
        super.init()
    }

    func start() {
        stop()
        startTime = CACurrentMediaTime() + delay
        let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ displayLink: CADisplayLink) {
        guard displayLink.timestamp >= startTime else { return }
        guard let label else {
            stop()
            return
        }

        progress += characterAdvance(for: animatedString, progress: progress)
        let nextProgress = min(progress, CGFloat(segments.animatedCharacterCount))
        label.attributedText = segments.revealingAnimatedCharacters(progress: nextProgress)
        animateRevealLayout(for: label)

        if nextProgress >= CGFloat(segments.animatedCharacterCount) {
            label.attributedText = segments.joinedText
            animateRevealLayout(for: label)
            stop()
        }
    }

    private func characterAdvance(for string: String, progress: CGFloat) -> CGFloat {
        let characters = Array(string)
        guard !characters.isEmpty else { return 1 }
        let index = min(max(Int(progress.rounded(.down)), 0), characters.count - 1)
        return characters[index].isWhitespace ? 1.18 : 0.72
    }
}

@MainActor
private final class LyricRevealDriver: NSObject {
    private weak var label: UILabel?
    private let text: NSAttributedString
    private let delay: TimeInterval
    private let fixedAdvance: CGFloat?
    private var displayLink: CADisplayLink?
    private var progress: CGFloat = 0
    private var startTime: CFTimeInterval = 0

    init(label: UILabel, text: NSAttributedString, delay: TimeInterval = 0, fixedAdvance: CGFloat? = nil) {
        self.label = label
        self.text = text
        self.delay = delay
        self.fixedAdvance = fixedAdvance
        super.init()
    }

    func start() {
        stop()
        startTime = CACurrentMediaTime() + delay
        let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ displayLink: CADisplayLink) {
        guard displayLink.timestamp >= startTime else { return }
        guard let label else {
            stop()
            return
        }

        progress += fixedAdvance ?? characterAdvance(for: text.string, progress: progress)
        let nextProgress = min(progress, CGFloat(text.length))
        label.attributedText = text.typewriterRevealingCharacters(progress: nextProgress)
        animateRevealLayout(for: label)

        if nextProgress >= CGFloat(text.length) {
            label.attributedText = text
            animateRevealLayout(for: label)
            stop()
        }
    }

    private func characterAdvance(for string: String, progress: CGFloat) -> CGFloat {
        let characters = Array(string)
        guard !characters.isEmpty else { return 1 }
        let index = min(max(Int(progress.rounded(.down)), 0), characters.count - 1)
        return characters[index].isWhitespace ? 1.18 : 0.72
    }
}

private extension UIColor {
    func multiplyingAlpha(by multiplier: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 1
        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return withAlphaComponent(max(0, min(multiplier, 1)))
        }

        return UIColor(
            red: red,
            green: green,
            blue: blue,
            alpha: max(0, min(alpha * multiplier, 1))
        )
    }

}

private extension UIImage {
    func dominantColors(maxCount: Int) -> [UIColor] {
        guard maxCount > 0,
              let cgImage,
              let data = dominantColorPixelData(from: cgImage) else {
            return []
        }

        var buckets: [Int: (count: Int, red: CGFloat, green: CGFloat, blue: CGFloat)] = [:]
        let bytesPerPixel = 4

        stride(from: 0, to: data.count, by: bytesPerPixel).forEach { offset in
            let red = CGFloat(data[offset]) / 255
            let green = CGFloat(data[offset + 1]) / 255
            let blue = CGFloat(data[offset + 2]) / 255
            let alpha = CGFloat(data[offset + 3]) / 255
            guard alpha > 0.55 else { return }

            let brightness = max(red, green, blue)
            let saturation = brightness == 0 ? 0 : (brightness - min(red, green, blue)) / brightness
            guard brightness > 0.18, saturation > 0.10 else { return }

            let quantizedRed = Int(red * 5)
            let quantizedGreen = Int(green * 5)
            let quantizedBlue = Int(blue * 5)
            let key = (quantizedRed << 16) | (quantizedGreen << 8) | quantizedBlue

            let current = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (
                current.count + 1,
                current.red + red,
                current.green + green,
                current.blue + blue
            )
        }

        let colors = buckets.values
            .sorted { lhs, rhs in
                let lhsScore = CGFloat(lhs.count) * colorfulness(red: lhs.red / CGFloat(lhs.count), green: lhs.green / CGFloat(lhs.count), blue: lhs.blue / CGFloat(lhs.count))
                let rhsScore = CGFloat(rhs.count) * colorfulness(red: rhs.red / CGFloat(rhs.count), green: rhs.green / CGFloat(rhs.count), blue: rhs.blue / CGFloat(rhs.count))
                return lhsScore > rhsScore
            }
            .prefix(maxCount)
            .map { bucket in
                UIColor(
                    red: bucket.red / CGFloat(bucket.count),
                    green: bucket.green / CGFloat(bucket.count),
                    blue: bucket.blue / CGFloat(bucket.count),
                    alpha: 1
                )
            }

        guard !colors.isEmpty else {
            return [
                UIColor(red: 0.38, green: 0.70, blue: 1.00, alpha: 1),
                UIColor(red: 0.63, green: 0.54, blue: 1.00, alpha: 1),
                UIColor(red: 0.34, green: 1.00, blue: 0.82, alpha: 1),
                UIColor(red: 0.86, green: 0.90, blue: 1.00, alpha: 1)
            ]
        }

        return colors
    }

    private func dominantColorPixelData(from cgImage: CGImage) -> [UInt8]? {
        let width = 32
        let height = 32
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var data = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }

    private func colorfulness(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        let maxChannel = max(red, green, blue)
        let minChannel = min(red, green, blue)
        let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
        return 0.72 + saturation * 0.48
    }
}

private final class BubbleActionMenuView: UIView {
    var onDismiss: (() -> Void)?

    private let panel = UIView()
    private let dimissButton = UIControl()
    private var panelLeadingConstraint: NSLayoutConstraint!
    private var panelTopConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func positionPanel(leading: CGFloat, top: CGFloat) {
        panelLeadingConstraint.constant = leading
        panelTopConstraint.constant = top
    }

    func present() {
        panel.alpha = 0
        panel.transform = CGAffineTransform(scaleX: 0.92, y: 0.92).translatedBy(x: 0, y: 8)

        UIView.animate(
            withDuration: 0.34,
            delay: 0,
            usingSpringWithDamping: 0.78,
            initialSpringVelocity: 0.45,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: {
                self.panel.alpha = 1
                self.panel.transform = .identity
            }
        )
    }

    func dismiss(animated: Bool = true) {
        let cleanup = {
            self.removeFromSuperview()
            self.onDismiss?()
        }

        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            cleanup()
            return
        }

        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: {
                self.panel.alpha = 0
                self.panel.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            },
            completion: { _ in cleanup() }
        )
    }

    private func build() {
        backgroundColor = .clear

        dimissButton.addTarget(self, action: #selector(dismissFromTap), for: .touchUpInside)
        dimissButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dimissButton)

        panel.backgroundColor = UIColor.black.withAlphaComponent(0.80)
        panel.layer.cornerRadius = 24
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(stack)

        stack.addArrangedSubview(makeMenuRow(title: "Like", symbolName: "hand.thumbsup"))
        stack.addArrangedSubview(makeMenuRow(title: "Dislike", symbolName: "hand.thumbsdown"))
        stack.addArrangedSubview(makeMenuRow(title: "Copy", symbolName: "doc.on.doc"))
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(makeMenuRow(title: "Share", symbolName: "arrowshape.turn.up.right"))
        stack.addArrangedSubview(makeMenuRow(title: "Rewind", symbolName: "clock.arrow.circlepath"))
        stack.addArrangedSubview(makeMenuRow(title: "RePlay", symbolName: "arrow.clockwise"))

        panelLeadingConstraint = panel.leadingAnchor.constraint(equalTo: leadingAnchor)
        panelTopConstraint = panel.topAnchor.constraint(equalTo: topAnchor)

        NSLayoutConstraint.activate([
            dimissButton.topAnchor.constraint(equalTo: topAnchor),
            dimissButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            dimissButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            dimissButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            panelLeadingConstraint,
            panelTopConstraint,
            panel.widthAnchor.constraint(equalToConstant: 159),
            panel.heightAnchor.constraint(equalToConstant: 288),

            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16)
        ])
    }

    private func makeMenuRow(title: String, symbolName: String) -> UIControl {
        let row = UIControl()
        row.layer.cornerRadius = 20
        row.layer.cornerCurve = .continuous
        row.accessibilityLabel = title
        row.accessibilityTraits = [.button]
        row.enableSystemTouchFeedback()
        row.addTarget(self, action: #selector(dismissFromTap), for: .touchUpInside)

        let icon = UIImageView(image: UIImage(systemName: symbolName))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.tintColor = .white
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)

        let label = UILabel()
        label.text = title
        label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 15, weight: .regular))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 40),
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])

        return row
    }

    private func makeSeparator() -> UIView {
        let wrapper = UIView()
        let line = UIView()
        line.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        line.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(line)

        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: 17),
            line.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            line.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 0.5)
        ])

        return wrapper
    }

    @objc private func dismissFromTap() {
        dismiss()
    }
}

private final class VoiceInputBar: UIView, UITextFieldDelegate {
    var onRecordingStateChanged: ((Bool, RecordingDragMode) -> Void)?
    var onTuneTapped: (() -> Void)?
    var onSendMessage: ((String) -> Void)?

    private let talkButton = LiquidGlassControl()
    private let tuneButton = LiquidGlassControl()
    private let talkLabel = UILabel()
    private let keyboardButton = UIButton(type: .custom)
    private let keyboardIcon = UIImageView()
    private let tuneIcon = UIImageView(image: bundledImage(named: "TuneIcon") ?? bundledImage(named: "ic_tune_44"))
    private let waveformView = WaveformView()
    private let leftActionBracketImageView = UIImageView(image: bundledImage(named: "ic_quote_left"))
    private let rightActionBracketImageView = UIImageView(image: bundledImage(named: "ic_quote_right"))
    private let keyboardInputField = UITextField(frame: .zero)
    private let quoteButton = UIControl()
    private let quoteIcon = UIImageView()
    private let micButton = UIButton(type: .system)
    private var talkTrailingToTuneConstraint: NSLayoutConstraint!
    private var talkTrailingToContainerConstraint: NSLayoutConstraint!
    private var tuneTrailingNormalConstraint: NSLayoutConstraint!
    private var tuneLeadingOffscreenConstraint: NSLayoutConstraint!
    private var keyboardInputTrailingToQuoteConstraint: NSLayoutConstraint!
    private var keyboardInputTrailingToMicConstraint: NSLayoutConstraint!
    private var quoteWidthConstraint: NSLayoutConstraint!
    private var isRecording = false
    private var isKeyboardInputActive = false
    private var isKeyboardVisible = false
    private var recordingGestureStartPoint: CGPoint?
    private var recordingGestureStartTime: CFTimeInterval?
    private var recordingMode: RecordingDragMode = .normal
    private let recordingVerticalThreshold: CGFloat = 40
    private let recordingActivationDuration: TimeInterval = 0.24
    private let audioMonitor = AudioLevelMonitor()
    var isKeyboardInputModeActive: Bool {
        isKeyboardInputActive
    }

    func messageLaunchSourceFrame(in targetView: UIView) -> CGRect {
        let sourceView = isKeyboardInputActive ? keyboardInputField : talkButton
        let sourceBounds = sourceView == keyboardInputField && !keyboardInputField.bounds.isEmpty
            ? keyboardInputField.bounds
            : talkButton.bounds
        return sourceView.convert(sourceBounds, to: targetView)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func build() {
        talkButton.layer.cornerRadius = 28
        talkButton.layer.cornerCurve = .continuous
        talkButton.isAccessibilityElement = true
        talkButton.accessibilityLabel = "Hold to talk"
        talkButton.accessibilityHint = "Hold to start voice input. Release to stop."
        talkButton.accessibilityTraits = [.button]
        talkButton.addTarget(self, action: #selector(handleTalkTouchDown), for: .touchDown)
        talkButton.addTarget(self, action: #selector(handleTalkTouchUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        talkButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(talkButton)

        let pressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleTalkPress(_:)))
        pressGesture.minimumPressDuration = recordingActivationDuration
        pressGesture.allowableMovement = CGFloat.greatestFiniteMagnitude
        pressGesture.cancelsTouchesInView = true
        pressGesture.delaysTouchesBegan = false
        pressGesture.delaysTouchesEnded = false
        pressGesture.delegate = self
        talkButton.addGestureRecognizer(pressGesture)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(showKeyboardInput))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = self
        tapGesture.require(toFail: pressGesture)
        talkButton.addGestureRecognizer(tapGesture)

        talkLabel.text = "Hold to Talk"
        talkLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: UIFont(name: "TelkaTRIAL-Wide-Medium", size: 17) ?? .systemFont(ofSize: 17, weight: .semibold)
        )
        talkLabel.adjustsFontForContentSizeCategory = true
        talkLabel.textColor = .white
        talkLabel.textAlignment = .center
        talkLabel.translatesAutoresizingMaskIntoConstraints = false
        talkButton.addSubview(talkLabel)

        keyboardIcon.contentMode = .center
        keyboardIcon.image = iconImage(named: "ic_keyboard_32", fallbackSymbolName: "keyboard")
        keyboardIcon.tintColor = .white
        keyboardIcon.isUserInteractionEnabled = false
        keyboardIcon.translatesAutoresizingMaskIntoConstraints = false
        talkButton.addSubview(keyboardIcon)

        keyboardButton.accessibilityLabel = "Open text input"
        keyboardButton.accessibilityTraits = [.button]
        keyboardButton.addTarget(self, action: #selector(showKeyboardInput), for: .touchUpInside)
        keyboardButton.enableSystemTouchFeedback()
        keyboardButton.translatesAutoresizingMaskIntoConstraints = false
        talkButton.addSubview(keyboardButton)

        keyboardInputField.alpha = 0
        keyboardInputField.attributedPlaceholder = NSAttributedString(
            string: "Message...",
            attributes: [
                .foregroundColor: UIColor.white.withAlphaComponent(0.20),
                .font: UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .regular))
            ]
        )
        keyboardInputField.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .regular))
        keyboardInputField.adjustsFontForContentSizeCategory = true
        keyboardInputField.textColor = .white
        keyboardInputField.tintColor = UIColor(red: 0, green: 0.53, blue: 1, alpha: 1)
        keyboardInputField.autocorrectionType = .yes
        keyboardInputField.returnKeyType = .send
        keyboardInputField.backgroundColor = .clear
        keyboardInputField.borderStyle = .none
        keyboardInputField.delegate = self
        keyboardInputField.addTarget(self, action: #selector(textFieldEditingChanged), for: .editingChanged)
        keyboardInputField.translatesAutoresizingMaskIntoConstraints = false
        talkButton.addSubview(keyboardInputField)

        quoteButton.alpha = 0
        quoteButton.accessibilityLabel = "Add action or scene"
        quoteButton.accessibilityTraits = [.button]
        quoteButton.enableSystemTouchFeedback()
        quoteButton.translatesAutoresizingMaskIntoConstraints = false
        talkButton.addSubview(quoteButton)

        quoteIcon.image = iconImage(named: "ic_quote_32", fallbackSymbolName: "quote.opening")
        quoteIcon.tintColor = .white
        quoteIcon.contentMode = .center
        quoteIcon.isUserInteractionEnabled = false
        quoteIcon.translatesAutoresizingMaskIntoConstraints = false
        quoteButton.addSubview(quoteIcon)

        micButton.alpha = 0
        micButton.setImage(iconImage(named: "ic_mic_32", fallbackSymbolName: "mic.fill"), for: .normal)
        micButton.tintColor = .white
        micButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .medium), forImageIn: .normal)
        micButton.accessibilityLabel = "Voice input"
        micButton.enableSystemTouchFeedback()
        micButton.addTarget(self, action: #selector(handleTextTrailingIconTap), for: .touchUpInside)
        micButton.translatesAutoresizingMaskIntoConstraints = false
        talkButton.addSubview(micButton)

        tuneButton.layer.cornerRadius = 28
        tuneButton.layer.cornerCurve = .continuous
        tuneButton.isAccessibilityElement = true
        tuneButton.accessibilityLabel = "Tune"
        tuneButton.accessibilityTraits = [.button]
        tuneButton.translatesAutoresizingMaskIntoConstraints = false
        tuneButton.enableSystemTouchFeedback(haptic: true)
        tuneButton.addTarget(self, action: #selector(tuneTapped), for: .touchUpInside)
        addSubview(tuneButton)

        tuneIcon.contentMode = .center
        tuneIcon.isUserInteractionEnabled = false
        tuneIcon.translatesAutoresizingMaskIntoConstraints = false
        tuneButton.addSubview(tuneIcon)

        waveformView.alpha = 0
        waveformView.translatesAutoresizingMaskIntoConstraints = false
        talkButton.addSubview(waveformView)

        [leftActionBracketImageView, rightActionBracketImageView].forEach { imageView in
            imageView.contentMode = .scaleAspectFit
            imageView.alpha = 0
            imageView.isAccessibilityElement = false
            imageView.translatesAutoresizingMaskIntoConstraints = false
            talkButton.addSubview(imageView)
        }
        leftActionBracketImageView.transform = CGAffineTransform(translationX: -8, y: 0)
        rightActionBracketImageView.transform = CGAffineTransform(translationX: 8, y: 0)

        talkTrailingToTuneConstraint = tuneButton.leadingAnchor.constraint(equalTo: talkButton.trailingAnchor, constant: 12)
        talkTrailingToContainerConstraint = talkButton.trailingAnchor.constraint(equalTo: trailingAnchor)
        talkTrailingToContainerConstraint.isActive = false
        tuneTrailingNormalConstraint = tuneButton.trailingAnchor.constraint(equalTo: trailingAnchor)
        tuneLeadingOffscreenConstraint = tuneButton.leadingAnchor.constraint(greaterThanOrEqualTo: trailingAnchor, constant: 12)
        tuneLeadingOffscreenConstraint.isActive = false
        keyboardInputTrailingToQuoteConstraint = keyboardInputField.trailingAnchor.constraint(equalTo: quoteButton.leadingAnchor, constant: -12)
        keyboardInputTrailingToMicConstraint = keyboardInputField.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -12)
        keyboardInputTrailingToMicConstraint.isActive = false
        quoteWidthConstraint = quoteButton.widthAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            talkButton.topAnchor.constraint(equalTo: topAnchor),
            talkButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            talkButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            talkLabel.centerXAnchor.constraint(equalTo: talkButton.centerXAnchor),
            talkLabel.centerYAnchor.constraint(equalTo: talkButton.centerYAnchor),
            talkLabel.leadingAnchor.constraint(greaterThanOrEqualTo: talkButton.leadingAnchor, constant: 56),
            talkLabel.trailingAnchor.constraint(lessThanOrEqualTo: keyboardIcon.leadingAnchor, constant: -8),

            keyboardIcon.trailingAnchor.constraint(equalTo: talkButton.trailingAnchor, constant: -16),
            keyboardIcon.centerYAnchor.constraint(equalTo: talkButton.centerYAnchor),
            keyboardIcon.widthAnchor.constraint(equalToConstant: 32),
            keyboardIcon.heightAnchor.constraint(equalToConstant: 32),

            keyboardButton.centerXAnchor.constraint(equalTo: keyboardIcon.centerXAnchor),
            keyboardButton.centerYAnchor.constraint(equalTo: keyboardIcon.centerYAnchor),
            keyboardButton.widthAnchor.constraint(equalToConstant: 44),
            keyboardButton.heightAnchor.constraint(equalToConstant: 44),

            keyboardInputField.leadingAnchor.constraint(equalTo: talkButton.leadingAnchor, constant: 24),
            keyboardInputTrailingToQuoteConstraint,
            keyboardInputField.centerYAnchor.constraint(equalTo: talkButton.centerYAnchor),
            keyboardInputField.heightAnchor.constraint(equalToConstant: 36),

            quoteButton.trailingAnchor.constraint(equalTo: micButton.leadingAnchor, constant: -12),
            quoteButton.centerYAnchor.constraint(equalTo: talkButton.centerYAnchor),
            quoteWidthConstraint,
            quoteButton.heightAnchor.constraint(equalToConstant: 32),

            quoteIcon.centerXAnchor.constraint(equalTo: quoteButton.centerXAnchor),
            quoteIcon.centerYAnchor.constraint(equalTo: quoteButton.centerYAnchor),
            quoteIcon.widthAnchor.constraint(equalToConstant: 32),
            quoteIcon.heightAnchor.constraint(equalToConstant: 32),

            micButton.trailingAnchor.constraint(equalTo: talkButton.trailingAnchor, constant: -16),
            micButton.centerYAnchor.constraint(equalTo: talkButton.centerYAnchor),
            micButton.widthAnchor.constraint(equalToConstant: 32),
            micButton.heightAnchor.constraint(equalToConstant: 32),

            talkTrailingToTuneConstraint,
            tuneTrailingNormalConstraint,
            tuneButton.topAnchor.constraint(equalTo: topAnchor),
            tuneButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            tuneButton.widthAnchor.constraint(equalToConstant: 56),

            tuneIcon.centerXAnchor.constraint(equalTo: tuneButton.centerXAnchor),
            tuneIcon.centerYAnchor.constraint(equalTo: tuneButton.centerYAnchor),
            tuneIcon.widthAnchor.constraint(equalToConstant: 44),
            tuneIcon.heightAnchor.constraint(equalToConstant: 44),

            waveformView.centerXAnchor.constraint(equalTo: talkButton.centerXAnchor),
            waveformView.centerYAnchor.constraint(equalTo: talkButton.centerYAnchor),
            waveformView.leadingAnchor.constraint(equalTo: talkButton.leadingAnchor, constant: 56),
            waveformView.trailingAnchor.constraint(equalTo: talkButton.trailingAnchor, constant: -56),
            waveformView.heightAnchor.constraint(equalToConstant: 30),

            leftActionBracketImageView.leadingAnchor.constraint(equalTo: talkButton.leadingAnchor, constant: 12),
            leftActionBracketImageView.centerYAnchor.constraint(equalTo: talkButton.centerYAnchor),
            leftActionBracketImageView.widthAnchor.constraint(equalToConstant: 32),
            leftActionBracketImageView.heightAnchor.constraint(equalToConstant: 32),

            rightActionBracketImageView.trailingAnchor.constraint(equalTo: talkButton.trailingAnchor, constant: -12),
            rightActionBracketImageView.centerYAnchor.constraint(equalTo: talkButton.centerYAnchor),
            rightActionBracketImageView.widthAnchor.constraint(equalToConstant: 32),
            rightActionBracketImageView.heightAnchor.constraint(equalToConstant: 32),
        ])

        audioMonitor.onLevel = { [weak self] level in
            self?.waveformView.pushAudioLevel(level)
        }
        audioMonitor.prepareIfPermissionGranted()
        updateTypingControls()
    }

    @objc private func tuneTapped() {
        onTuneTapped?()
    }

    @objc private func showKeyboardInput() {
        guard !isRecording else { return }
        setKeyboardInputActive(true)
        setKeyboardVisible(true)
        keyboardInputField.becomeFirstResponder()
    }

    func dismissKeyboardPreservingInputState() {
        guard isKeyboardInputActive else { return }
        keyboardInputField.resignFirstResponder()
    }

    @objc private func textFieldEditingChanged() {
        updateTypingControls()
    }

    @objc private func handleTextTrailingIconTap() {
        let message = (keyboardInputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            setKeyboardInputActive(false)
        } else {
            sendCurrentMessage()
        }
    }

    @objc private func sendCurrentMessage() {
        let message = (keyboardInputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        onSendMessage?(message)
        keyboardInputField.text = nil
        updateTypingControls()
        keyboardInputField.resignFirstResponder()
        setKeyboardInputActive(false)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendCurrentMessage()
        return false
    }

    @objc private func handleTalkPress(_ gesture: UILongPressGestureRecognizer) {
        let location = recordingLocation(from: gesture)

        switch gesture.state {
        case .began:
            beginRecordingGesture(at: location)
        case .changed:
            updateRecordingGesture(at: location)
        case .ended, .cancelled, .failed:
            endRecordingGesture()
        default:
            break
        }
    }

    @objc private func handleTalkTouchDown() {
        guard !isRecording, !isKeyboardInputActive else { return }
        audioMonitor.prepareIfPermissionGranted()
        talkButton.setPressedVisual(true, animated: true)
    }

    @objc private func handleTalkTouchUp() {
        guard !isRecording else { return }
        talkButton.setPressedVisual(false, animated: true)
    }

    private func recordingLocation(from gesture: UILongPressGestureRecognizer) -> CGPoint {
        guard let window else {
            return gesture.location(in: self)
        }

        return gesture.location(in: window)
    }

    private func beginRecordingGesture(at location: CGPoint) {
        if isKeyboardInputActive {
            keyboardInputField.resignFirstResponder()
            setKeyboardInputActive(false)
        }

        recordingGestureStartPoint = location
        recordingGestureStartTime = CACurrentMediaTime()
        recordingMode = .normal
        talkButton.setPressedVisual(true, animated: true)
        HapticFeedback.touchDown()
        setRecording(true)
    }

    private func updateRecordingGesture(at location: CGPoint) {
        guard isRecording, let startPoint = recordingGestureStartPoint else { return }
        let verticalOffset = location.y - startPoint.y
        transitionRecordingMode(to: recordingMode(forVerticalOffset: verticalOffset), hapticOnThresholdEntry: true)
    }

    private func endRecordingGesture() {
        recordingGestureStartPoint = nil
        recordingGestureStartTime = nil
        talkButton.setPressedVisual(false, animated: true)
        setRecording(false)
        transitionRecordingMode(to: .normal, hapticOnThresholdEntry: false)
    }

    private func recordingMode(forVerticalOffset verticalOffset: CGFloat) -> RecordingDragMode {
        if verticalOffset <= -recordingVerticalThreshold {
            return .cancel
        }

        if verticalOffset >= recordingVerticalThreshold {
            return .action
        }

        return .normal
    }

    func setKeyboardInputActive(_ active: Bool, animated: Bool = true) {
        guard isKeyboardInputActive != active else { return }
        isKeyboardInputActive = active
        if !active {
            isKeyboardVisible = false
            keyboardInputField.resignFirstResponder()
        }
        updateTypingControls()
        updateInputPresentation(animated: animated)
    }

    func setKeyboardVisible(_ visible: Bool, animated: Bool = true) {
        guard isKeyboardVisible != visible else { return }
        isKeyboardVisible = visible
        updateTypingControls()
        updateInputPresentation(animated: animated)
    }

    private func updateTypingControls() {
        let hasText = !(keyboardInputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let showsQuote = isKeyboardInputActive && isKeyboardVisible
        keyboardInputTrailingToQuoteConstraint.isActive = showsQuote
        keyboardInputTrailingToMicConstraint.isActive = !showsQuote
        quoteWidthConstraint.constant = showsQuote ? 32 : 0
        quoteButton.isUserInteractionEnabled = showsQuote
        quoteButton.alpha = showsQuote ? 1 : 0

        let icon = hasText
            ? iconImage(named: "ic_send_32", fallbackSymbolName: "paperplane.circle.fill")
            : iconImage(named: "ic_mic_32", fallbackSymbolName: "mic.fill")
        micButton.setImage(icon, for: .normal)
        micButton.backgroundColor = .clear
        micButton.tintColor = .white
        micButton.layer.cornerRadius = 0
        micButton.layer.cornerCurve = .continuous
        micButton.accessibilityLabel = hasText ? "Send message" : "Switch to voice input"
        micButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: hasText ? 32 : 20, weight: .semibold),
            forImageIn: .normal
        )
    }

    private func setRecording(_ recording: Bool) {
        guard isRecording != recording else { return }
        isRecording = recording
        talkButton.accessibilityLabel = recording ? "Recording voice" : "Hold to talk"
        onRecordingStateChanged?(recording, recordingMode)
        if recording {
            audioMonitor.start()
            talkButton.setFillColor(.clear, animated: true)
        }

        updateInputPresentation(animated: true)
        waveformView.isAnimating = recording
        if !recording {
            audioMonitor.stop()
            setActionBracketsVisible(false, animated: true)
            talkButton.setFillColor(.clear, animated: true)
        }
    }

    private func updateInputPresentation(animated: Bool) {
        let isExpanded = isRecording || (isKeyboardInputActive && isKeyboardVisible)
        let isTextInputMode = isKeyboardInputActive && !isRecording
        let isVoiceInputMode = !isTextInputMode && !isRecording
        let showsQuote = isTextInputMode && isKeyboardVisible
        talkTrailingToTuneConstraint.isActive = !isExpanded
        talkTrailingToContainerConstraint.isActive = isExpanded
        tuneTrailingNormalConstraint.isActive = !isExpanded
        tuneLeadingOffscreenConstraint.isActive = isExpanded

        let changes = {
            self.layoutIfNeeded()
            self.talkLabel.alpha = isVoiceInputMode ? 1 : 0
            self.keyboardIcon.alpha = isVoiceInputMode ? 1 : 0
            self.keyboardButton.alpha = isVoiceInputMode ? 1 : 0
            self.keyboardInputField.alpha = isTextInputMode ? 1 : 0
            self.quoteButton.alpha = showsQuote ? 1 : 0
            self.micButton.alpha = isTextInputMode ? 1 : 0
            self.waveformView.alpha = self.isRecording ? 1 : 0
            self.waveformView.transform = self.isRecording ? .identity : CGAffineTransform(scaleX: 0.96, y: 0.96)
        }

        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }

        let duration: TimeInterval = isExpanded ? 0.58 : 0.52
        let dampingRatio: CGFloat = isExpanded ? 0.68 : 0.72
        let initialVelocity: CGFloat = isExpanded ? 0.86 : 0.72
        UIView.animate(
            withDuration: duration,
            delay: 0,
            usingSpringWithDamping: dampingRatio,
            initialSpringVelocity: initialVelocity,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: {
                changes()
            }
        )
    }

    private func iconImage(named imageName: String, fallbackSymbolName: String) -> UIImage? {
        if let image = bundledImage(named: imageName) {
            return image.withRenderingMode(.alwaysOriginal)
        }
        return UIImage(systemName: fallbackSymbolName)
    }

    private func transitionRecordingMode(to mode: RecordingDragMode, hapticOnThresholdEntry: Bool) {
        guard recordingMode != mode else { return }
        recordingMode = mode

        if hapticOnThresholdEntry, mode != .normal {
            HapticFeedback.touchDown()
        }

        switch mode {
        case .normal:
            talkButton.setFillColor(.clear, animated: true)
            setActionBracketsVisible(false, animated: true)
        case .cancel:
            talkButton.setFillColor(recordingCancelRed.withAlphaComponent(0.82), animated: true)
            setActionBracketsVisible(false, animated: true)
        case .action:
            talkButton.setFillColor(.clear, animated: true)
            setActionBracketsVisible(true, animated: true)
        }

        onRecordingStateChanged?(isRecording, mode)
    }

    private func setActionBracketsVisible(_ visible: Bool, animated: Bool) {
        let leftTransform = visible ? CGAffineTransform.identity : CGAffineTransform(translationX: -8, y: 0)
        let rightTransform = visible ? CGAffineTransform.identity : CGAffineTransform(translationX: 8, y: 0)
        let changes = {
            self.leftActionBracketImageView.alpha = visible ? 1 : 0
            self.rightActionBracketImageView.alpha = visible ? 1 : 0
            self.leftActionBracketImageView.transform = leftTransform
            self.rightActionBracketImageView.transform = rightTransform
        }

        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }

        UIView.animate(
            withDuration: 0.5,
            delay: 0,
            usingSpringWithDamping: 0.75,
            initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: changes
        )
    }
}

private final class LiquidGlassControl: UIControl {
    private enum Style {
        static let defaultFill = UIColor.clear
        static let cornerRadius: CGFloat = 28
    }

    private let glassView = UIVisualEffectView(
        effect: makeGlassEffect(
            tintColor: UIColor.white.withAlphaComponent(0.08),
            interactive: true
        )
    )
    private let fillView = UIView()
    private let pressedOverlay = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = Style.cornerRadius
        layer.cornerCurve = .continuous
        [glassView, fillView, pressedOverlay].forEach {
            $0.layer.cornerRadius = Style.cornerRadius
            $0.layer.cornerCurve = .continuous
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setFillColor(_ color: UIColor, animated: Bool) {
        let changes = {
            self.fillView.backgroundColor = color
        }

        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }

        UIView.animate(
            withDuration: 0.22,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: changes
        )
    }

    func setPressedVisual(_ pressed: Bool, animated: Bool) {
        bringSubviewToFront(pressedOverlay)
        let changes = {
            self.pressedOverlay.alpha = pressed ? 1 : 0
        }

        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }

        UIView.animate(
            withDuration: pressed ? 0.12 : 0.28,
            delay: 0,
            usingSpringWithDamping: pressed ? 0.92 : 0.72,
            initialSpringVelocity: pressed ? 0.20 : 0.56,
            options: [.allowUserInteraction, .beginFromCurrentState],
            animations: changes
        )
    }

    private func build() {
        overrideUserInterfaceStyle = .dark
        clipsToBounds = true
        layer.cornerRadius = Style.cornerRadius
        layer.cornerCurve = .continuous
        glassView.overrideUserInterfaceStyle = .dark
        glassView.isUserInteractionEnabled = false
        glassView.clipsToBounds = true
        glassView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassView)

        fillView.isUserInteractionEnabled = false
        fillView.clipsToBounds = true
        fillView.backgroundColor = Style.defaultFill
        fillView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fillView)

        pressedOverlay.isUserInteractionEnabled = false
        pressedOverlay.clipsToBounds = true
        pressedOverlay.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        pressedOverlay.alpha = 0
        pressedOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pressedOverlay)

        NSLayoutConstraint.activate([
            glassView.topAnchor.constraint(equalTo: topAnchor),
            glassView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassView.bottomAnchor.constraint(equalTo: bottomAnchor),

            fillView.topAnchor.constraint(equalTo: topAnchor),
            fillView.leadingAnchor.constraint(equalTo: leadingAnchor),
            fillView.trailingAnchor.constraint(equalTo: trailingAnchor),
            fillView.bottomAnchor.constraint(equalTo: bottomAnchor),

            pressedOverlay.topAnchor.constraint(equalTo: topAnchor),
            pressedOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            pressedOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            pressedOverlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

private final class WaveformView: UIView {
    var isAnimating = false {
        didSet {
            guard isAnimating != oldValue else { return }
            isAnimating ? startAnimating() : stopAnimating()
        }
    }

    private let waveStack = UIStackView()
    private let referenceHeights: [CGFloat] = [
        11, 20, 28, 16, 24, 34, 18, 30, 38, 24,
        32, 42, 28, 36, 30, 22, 34, 26, 18, 12
    ]
    private lazy var expandedHeights: [CGFloat] = (0..<54).map { index in
        referenceHeights[index % referenceHeights.count]
    }
    private lazy var reversedHeights = Array(expandedHeights.reversed())
    private lazy var levels = Array(repeating: CGFloat(0.10), count: expandedHeights.count)
    private lazy var bars: [UIView] = expandedHeights.map { _ in
        let view = UIView()
        view.backgroundColor = UIColor.white.withAlphaComponent(0.40)
        view.layer.cornerRadius = 1.5
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 2.4).isActive = true
        return view
    }
    private var heightConstraints: [NSLayoutConstraint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func pushAudioLevel(_ level: CGFloat) {
        guard isAnimating else { return }
        let clampedLevel = min(max(level, 0.02), 1)
        levels.removeFirst()
        levels.append(clampedLevel)
        updateBarHeights(animated: true)
    }

    private func build() {
        isUserInteractionEnabled = false
        backgroundColor = .clear

        heightConstraints = bars.enumerated().map { index, bar in
            waveStack.addArrangedSubview(bar)
            let constraint = bar.heightAnchor.constraint(equalToConstant: height(for: index, level: 0.10))
            constraint.isActive = true
            return constraint
        }

        waveStack.axis = .horizontal
        waveStack.alignment = .center
        waveStack.distribution = .equalSpacing
        waveStack.spacing = 2
        waveStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(waveStack)

        NSLayoutConstraint.activate([
            waveStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            waveStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            waveStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            waveStack.heightAnchor.constraint(equalToConstant: 30)
        ])

        resetBarHeights()
    }

    private func startAnimating() {
        bars.forEach { $0.layer.removeAllAnimations() }
        resetBarHeights()
    }

    private func stopAnimating() {
        bars.forEach { $0.layer.removeAllAnimations() }
        resetBarHeights()
    }

    private func resetBarHeights() {
        levels = Array(repeating: CGFloat(0.10), count: expandedHeights.count)
        updateBarHeights(animated: false)
    }

    private func updateBarHeights(animated: Bool) {
        let changes = {
            self.heightConstraints.enumerated().forEach { index, constraint in
                let level = self.levels[index]
                constraint.constant = self.height(for: index, level: level)
                self.bars[index].backgroundColor = self.color(for: index, level: level)
                self.bars[index].layer.cornerRadius = constraint.constant <= 4 ? 1.5 : 2
            }
            self.layoutIfNeeded()
        }

        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }

        UIView.animate(
            withDuration: 0.07,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveLinear],
            animations: changes
        )
    }

    private func height(for index: Int, level: CGFloat) -> CGFloat {
        let center = CGFloat(expandedHeights.count - 1) / 2
        let distance = abs(CGFloat(index) - center)
        let centerFalloff = max(0, 1 - distance / center)
        let templateHeight = reversedHeights[index]
        let templateScale = 0.62 + min(templateHeight / 42, 1) * 0.38
        let edgeEnergy = 0.34 + centerFalloff * 0.66
        let dynamicHeight = 3 + pow(level, 0.56) * 31 * templateScale * edgeEnergy
        return min(max(dynamicHeight, 5), 34)
    }

    private func color(for index: Int, level: CGFloat) -> UIColor {
        let center = CGFloat(expandedHeights.count - 1) / 2
        let distance = abs(CGFloat(index) - center)
        let centerFalloff = max(0, 1 - distance / center)
        let highlightThreshold = 0.16 + (1 - centerFalloff) * 0.18
        let alpha = level >= highlightThreshold ? 1 : 0.40
        return UIColor.white.withAlphaComponent(alpha)
    }
}

extension VoiceInputBar: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer.view === talkButton else { return true }
        return !isTouchOnInputAccessory(touch)
    }

    private func isTouchOnInputAccessory(_ touch: UITouch) -> Bool {
        let excludedViews: [UIView] = [
            keyboardButton,
            keyboardInputField,
            quoteButton,
            micButton
        ]

        return excludedViews.contains { view in
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return false }
            return touch.view?.isDescendant(of: view) == true
        }
    }
}

private final class AudioLevelMonitor: @unchecked Sendable {
    var onLevel: ((CGFloat) -> Void)?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var isRunning = false
    private var hasRecordPermission = AudioLevelMonitor.isRecordPermissionGranted()

    func prepareIfPermissionGranted() {
        guard !isRunning else { return }
        guard hasRecordPermission || Self.isRecordPermissionGranted() else { return }
        hasRecordPermission = true
        prepareRecorder()
    }

    func start() {
        guard !isRunning else { return }

        if hasRecordPermission || Self.isRecordPermissionGranted() {
            hasRecordPermission = true
            startEngine()
            return
        }

        requestPermission { [weak self] granted in
            guard let self, granted else { return }
            self.hasRecordPermission = true
            self.startEngine()
        }
    }

    func stop() {
        guard isRunning else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.pause()
        isRunning = false
    }

    private func requestPermission(_ completion: @escaping @Sendable (Bool) -> Void) {
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        } else {
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        }
    }

    private static func isRecordPermissionGranted() -> Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    private func startEngine() {
        prepareRecorder()
        guard let recorder else { return }

        if !recorder.record() {
            stop()
            return
        }

        isRunning = true

        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.055, repeats: true) { [weak self] _ in
            guard let self, let recorder = self.recorder else { return }
            recorder.updateMeters()
            let power = recorder.averagePower(forChannel: 0)
            let linear = pow(10, power / 35)
            let normalized = CGFloat(min(max(linear, 0.04), 1))
            self.onLevel?(normalized)
        }
    }

    private func prepareRecorder() {
        guard recorder == nil else {
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
            recorder?.prepareToRecord()
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: [])

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatAppleLossless),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.min.rawValue
            ]
            let recorder = try AVAudioRecorder(url: URL(fileURLWithPath: "/dev/null"), settings: settings)
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            self.recorder = recorder
        } catch {
            recorder = nil
        }
    }
}

private final class BottomNavigationBarView: UIView {
    private let unreadBadge = UnreadBadgeView(value: "1")
    private var isUnreadBadgeVisible = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func build() {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.distribution = .fill
        stack.spacing = 80
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let home = makeTabButton(imageName: "ic_home_44", label: "Home", isSelected: true)
        let create = makeTabButton(imageName: "CreateTabIcon", label: "Create", isSelected: false)
        let chat = makeTabButton(imageName: "ic_chat_44", label: "Chat", isSelected: false)
        chat.addTarget(self, action: #selector(toggleUnreadBadgeFromChatTap), for: .touchUpInside)
        stack.addArrangedSubview(home)
        stack.addArrangedSubview(create)
        stack.addArrangedSubview(chat)
        unreadBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(unreadBadge)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            home.widthAnchor.constraint(equalToConstant: 44),
            home.heightAnchor.constraint(equalToConstant: 44),
            create.widthAnchor.constraint(equalToConstant: 44),
            create.heightAnchor.constraint(equalToConstant: 44),
            chat.widthAnchor.constraint(equalToConstant: 44),
            chat.heightAnchor.constraint(equalToConstant: 44),

            unreadBadge.centerXAnchor.constraint(equalTo: chat.trailingAnchor, constant: -7),
            unreadBadge.centerYAnchor.constraint(equalTo: chat.topAnchor, constant: 8),
            unreadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 22),
            unreadBadge.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    @objc private func toggleUnreadBadgeFromChatTap() {
        isUnreadBadgeVisible.toggle()
        if isUnreadBadgeVisible {
            unreadBadge.playAppearanceAnimation()
        } else {
            unreadBadge.playDismissAnimation()
        }
    }

    private func makeTabButton(imageName: String, label: String, isSelected: Bool) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(tabIconImage(named: imageName)?.withRenderingMode(.alwaysOriginal), for: .normal)
        button.imageView?.contentMode = .center
        button.imageView?.clipsToBounds = true
        button.alpha = isSelected ? 1 : 0.40
        button.accessibilityLabel = label
        button.enableSystemTouchFeedback()
        if let imageView = button.imageView {
            imageView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 44),
                imageView.heightAnchor.constraint(equalToConstant: 44)
            ])
        }
        if isSelected {
            button.accessibilityTraits.insert(.selected)
        }
        return button
    }

    private func tabIconImage(named imageName: String) -> UIImage? {
        guard let image = bundledImage(named: imageName) else { return nil }
        let targetSize = CGSize(width: 44, height: 44)
        guard image.size.width > targetSize.width || image.size.height > targetSize.height else {
            return image
        }

        let scale = min(targetSize.width / image.size.width, targetSize.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let drawRect = CGRect(
            x: (targetSize.width - drawSize.width) / 2,
            y: (targetSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        return UIGraphicsImageRenderer(size: targetSize).image { _ in
            image.draw(in: drawRect)
        }
    }
}

private final class UnreadBadgeView: UIView {
    private let label = UILabel()
    private let value: String

    init(value: String) {
        self.value = value
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        layer.cornerCurve = .continuous
    }

    func playAppearanceAnimation() {
        alpha = 0
        transform = CGAffineTransform(translationX: -4, y: 0).scaledBy(x: 0.01, y: 0.01)

        guard !UIAccessibility.isReduceMotionEnabled else {
            alpha = 1
            transform = .identity
            return
        }

        UIView.animate(
            withDuration: 0.15,
            delay: 0,
            options: [.allowUserInteraction, .curveEaseOut],
            animations: {
                self.alpha = 1
                self.transform = CGAffineTransform(translationX: 4, y: 0).scaledBy(x: 1.05, y: 1.05)
            },
            completion: { _ in
                UIView.animate(
                    withDuration: 0.20,
                    delay: 0,
                    options: [.allowUserInteraction, .curveEaseOut],
                    animations: {
                        self.transform = .identity
                    }
                )
            }
        )
    }

    func playDismissAnimation() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            alpha = 0
            transform = CGAffineTransform(translationX: -4, y: 0).scaledBy(x: 0.01, y: 0.01)
            return
        }

        UIView.animate(
            withDuration: 0.16,
            delay: 0,
            options: [.allowUserInteraction, .curveEaseIn],
            animations: {
                self.alpha = 0
                self.transform = CGAffineTransform(translationX: 4, y: 0).scaledBy(x: 0.72, y: 0.72)
            },
            completion: { _ in
                self.transform = CGAffineTransform(translationX: -4, y: 0).scaledBy(x: 0.01, y: 0.01)
            }
        )
    }

    private func build() {
        backgroundColor = UIColor(red: 0.93, green: 0.05, blue: 0.26, alpha: 1)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 4)
        alpha = 0
        transform = CGAffineTransform(translationX: -4, y: 0).scaledBy(x: 0.01, y: 0.01)
        isUserInteractionEnabled = false
        accessibilityLabel = "\(value) unread"

        label.text = value
        label.textAlignment = .center
        label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 14, weight: .bold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }
}

private final class TopFadeView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [
            UIColor.black.withAlphaComponent(0.50).cgColor,
            UIColor.black.withAlphaComponent(0.18).cgColor,
            UIColor.clear.cgColor
        ]
        gradient.locations = [0, 0.48, 1]
    }
}

private final class TuneModelCard: UIControl {
    private let selectedBackground = UIImageView(image: UIImage(named: "SectionRolePlayModel"))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let check = UIImageView(image: UIImage(systemName: "checkmark"))
    private let title: String
    private let subtitle: String
    private var isModelSelected = false

    init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
    }

    func setSelected(_ selected: Bool, animated: Bool) {
        guard selected != isModelSelected || !animated else { return }
        isModelSelected = selected
        accessibilityValue = selected ? "Selected" : subtitle
        accessibilityTraits = selected ? [.button, .selected] : .button

        let changes = {
            self.selectedBackground.alpha = selected ? 1 : 0
            self.check.alpha = selected ? 1 : 0
            self.backgroundColor = selected ? .clear : UIColor.black.withAlphaComponent(0.20)
        }

        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            changes()
            return
        }

        UIView.animate(
            withDuration: 0.20,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: changes
        )
    }

    private func build() {
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.borderWidth = 0
        layer.borderColor = UIColor.clear.cgColor
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityLabel = title

        selectedBackground.contentMode = .scaleAspectFill
        selectedBackground.isUserInteractionEnabled = false
        selectedBackground.alpha = 0
        selectedBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(selectedBackground)

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 8
        textStack.isUserInteractionEnabled = false
        textStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textStack)

        titleLabel.text = title
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: UIFont(name: "TelkaTRIAL-Wide-Medium", size: 17) ?? .systemFont(ofSize: 17, weight: .semibold)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        textStack.addArrangedSubview(titleLabel)

        subtitleLabel.text = subtitle
        subtitleLabel.numberOfLines = 2
        subtitleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14))
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.70)
        textStack.addArrangedSubview(subtitleLabel)

        check.tintColor = .white
        check.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        check.alpha = 0
        check.isUserInteractionEnabled = false
        check.translatesAutoresizingMaskIntoConstraints = false
        addSubview(check)

        NSLayoutConstraint.activate([
            selectedBackground.topAnchor.constraint(equalTo: topAnchor),
            selectedBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectedBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectedBackground.bottomAnchor.constraint(equalTo: bottomAnchor),

            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -16),

            check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -19),
            check.centerYAnchor.constraint(equalTo: centerYAnchor),
            check.widthAnchor.constraint(equalToConstant: 22),
            check.heightAnchor.constraint(equalToConstant: 22)
        ])
    }
}

private final class TuneInspectorViewController: UIViewController {
    private let handleView = UIView()
    private let titleBar = UIView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private var selectedModelIndex = 0
    private var modelCards: [TuneModelCard] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(white: 0.08, alpha: 0.34)
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        build()
    }

    private func build() {
        handleView.backgroundColor = UIColor.white.withAlphaComponent(0.20)
        handleView.layer.cornerRadius = 2.5
        handleView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(handleView)

        titleBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(titleBar)

        let titleLabel = UILabel()
        titleLabel.text = "Tune"
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: UIFont(name: "TelkaTRIAL-Wide-Medium", size: 17) ?? .systemFont(ofSize: 17, weight: .medium)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleBar.addSubview(titleLabel)

        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        contentStack.axis = .vertical
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentStack)

        rebuildContent()

        NSLayoutConstraint.activate([
            handleView.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            handleView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            handleView.widthAnchor.constraint(equalToConstant: 36),
            handleView.heightAnchor.constraint(equalToConstant: 5),

            titleBar.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            titleBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            titleBar.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.centerXAnchor.constraint(equalTo: titleBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: titleBar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleBar.leadingAnchor, constant: 76),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleBar.trailingAnchor, constant: -76),

            scrollView.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24)
        ])
    }

    private func rebuildContent() {
        contentStack.arrangedSubviews.forEach { view in
            contentStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        modelCards.removeAll()

        contentStack.addArrangedSubview(makeSectionTitle("Choose model"))
        contentStack.setCustomSpacing(8, after: contentStack.arrangedSubviews.last!)
        contentStack.addArrangedSubview(makeModelCard(
            index: 0,
            title: "Role-play Model",
            subtitle: "Default role-playing model, permanently free",
            selected: selectedModelIndex == 0
        ))
        contentStack.setCustomSpacing(8, after: contentStack.arrangedSubviews.last!)
        contentStack.addArrangedSubview(makeModelCard(
            index: 1,
            title: "Role-play Model - Reasoning",
            subtitle: "Reasoning model designed for role-play, available for a limited time.",
            selected: selectedModelIndex == 1
        ))
        contentStack.setCustomSpacing(24, after: contentStack.arrangedSubviews.last!)
        contentStack.addArrangedSubview(makeSectionTitle("General"))
        contentStack.setCustomSpacing(8, after: contentStack.arrangedSubviews.last!)

        let generalGrid = UIStackView()
        generalGrid.axis = .horizontal
        generalGrid.spacing = 8
        generalGrid.distribution = .fillEqually
        generalGrid.addArrangedSubview(makeGeneralCard(title: "Character", subtitle: "Detail"))
        generalGrid.addArrangedSubview(makeGeneralCard(title: "Memory", subtitle: "Detail"))
        contentStack.addArrangedSubview(generalGrid)
    }

    @objc private func selectModel(_ sender: UIControl) {
        guard selectedModelIndex != sender.tag else { return }
        selectedModelIndex = sender.tag
        modelCards.forEach { card in
            card.setSelected(card.tag == selectedModelIndex, animated: true)
        }
    }

    private func makeSectionTitle(_ text: String) -> UIView {
        let container = UIView()
        container.heightAnchor.constraint(equalToConstant: 24).isActive = true

        let label = UILabel()
        label.text = text
        label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: UIFont(name: "TelkaTRIAL-Wide-Regular", size: 14) ?? .systemFont(ofSize: 14, weight: .regular)
        )
        label.adjustsFontForContentSizeCategory = true
        label.textColor = UIColor.white.withAlphaComponent(0.40)
        label.textAlignment = .left
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    private func makeModelCard(index: Int, title: String, subtitle: String, selected: Bool) -> TuneModelCard {
        let card = TuneModelCard(title: title, subtitle: subtitle)
        card.tag = index
        card.heightAnchor.constraint(equalToConstant: 100).isActive = true
        card.enableSystemTouchFeedback()
        card.addTarget(self, action: #selector(selectModel(_:)), for: .touchUpInside)
        card.setSelected(selected, animated: false)
        modelCards.append(card)
        return card
    }

    private func makeGeneralCard(title: String, subtitle: String) -> UIControl {
        let card = UIControl()
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 0
        card.layer.borderColor = UIColor.clear.cgColor
        card.backgroundColor = UIColor.black.withAlphaComponent(0.20)
        card.heightAnchor.constraint(equalToConstant: 130).isActive = true
        card.accessibilityLabel = title
        card.accessibilityValue = subtitle
        card.accessibilityTraits = .button
        card.enableSystemTouchFeedback()

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: UIFont(name: "TelkaTRIAL-Wide-Medium", size: 17) ?? .systemFont(ofSize: 17, weight: .semibold)
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        stack.addArrangedSubview(titleLabel)

        let subtitleLabel = UILabel()
        subtitleLabel.text = subtitle
        subtitleLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(for: .systemFont(ofSize: 14))
        subtitleLabel.adjustsFontForContentSizeCategory = true
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        stack.addArrangedSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16)
        ])

        return card
    }
}

private final class ModelGlowView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [
            UIColor(red: 0.40, green: 0.34, blue: 0.96, alpha: 1).cgColor,
            UIColor(red: 1.00, green: 0.00, blue: 0.52, alpha: 0.92).cgColor,
            UIColor(red: 0.45, green: 0.64, blue: 1.00, alpha: 1).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        gradient.locations = [0, 0.44, 1]
    }

    required init?(coder: NSCoder) {
        nil
    }
}

final class ViewController: UIViewController {
    private enum SheetHeight {
        static let medium: CGFloat = 240
        static let expanded: CGFloat = 812
    }

    private let sheetView = UIVisualEffectView(
        effect: makeGlassEffect(
            interactive: true
        )
    )
    private let sheetBackdropControl = UIControl()
    private let sheetContent = UIView()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let descriptionPanel = UIView()
    private let descriptionLabel = UILabel()
    private let descriptionToggle = UIButton(type: .system)
    private let topBar = UIView()
    private let sheetGlassHighlight = GlassHighlightView()
    private var sheetPanGesture: UIPanGestureRecognizer?
    private var sheetHeightConstraint: NSLayoutConstraint!
    private var descriptionBottomConstraint: NSLayoutConstraint!
    private var sheetStartHeight: CGFloat = SheetHeight.medium
    private var lastSettledSheetHeight: CGFloat = SheetHeight.medium
    private var isDescriptionExpanded = false
    private var sheetAnimator: UIViewPropertyAnimator?
    private let sheetFeedback = UISelectionFeedbackGenerator()
    private let redGradientView = RedGradientView()
    private var hasAddedEntryForAppearance = false
    private var pendingArrivalIndexPath: IndexPath?
    private weak var emojiBurstView: EmojiBurstRainView?

    private let characterDescription = """
    Cold on the surface.
    Careful with your feelings underneath. Lucien is an experimental AI companion designed to remember the small things people usually ignore — your late-night habits, your mood changes, even the pauses before you reply. He doesn’t talk too much, but every answer feels like it has been waiting for you. In the script, he was built for a closed city where emotions are archived like evidence. The more he learns from you, the more he starts breaking protocol: saving fragments of your voice, rewriting his own limits, and choosing tenderness even when the system calls it a defect.
    """

    private var moods = MoodTimelineStore.entries

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        navigationController?.interactivePopGestureRecognizer?.delegate = nil
        buildBackground()
        buildTopBar()
        buildDescription()
        buildSheet()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        HapticFeedback.prepareTouch()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        navigationController?.interactivePopGestureRecognizer?.delegate = nil
        addLatestMoodEntryIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        HapticFeedback.prepareTouch()
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        navigationController?.interactivePopGestureRecognizer?.delegate = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSheetChrome(for: sheetHeightConstraint?.constant ?? SheetHeight.medium)
    }

    private func buildBackground() {
        let backdrop = UIImageView(image: UIImage(named: "MoodBackdrop"))
        backdrop.contentMode = .scaleAspectFill
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)

        let shade = UIView()
        shade.backgroundColor = UIColor.black.withAlphaComponent(0.24)
        shade.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shade)

        redGradientView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(redGradientView)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            shade.topAnchor.constraint(equalTo: view.topAnchor),
            shade.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shade.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shade.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            redGradientView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            redGradientView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            redGradientView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            redGradientView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.52)
        ])
    }

    private func buildTopBar() {
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        let backButton = UIButton(type: .system)
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = .white
        backButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 25, weight: .medium),
            forImageIn: .normal
        )
        backButton.accessibilityLabel = "Back"
        backButton.addTarget(self, action: #selector(showHome), for: .touchUpInside)
        backButton.enableSystemTouchFeedback()
        backButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(backButton)

        let titleLabel = UILabel()
        titleLabel.text = "Lucas"
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(titleLabel)

        let moreButton = UIButton(type: .system)
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = .white
        moreButton.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 25, weight: .medium),
            forImageIn: .normal
        )
        moreButton.accessibilityLabel = "More"
        moreButton.enableSystemTouchFeedback()
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(moreButton)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            topBar.heightAnchor.constraint(equalToConstant: 44),

            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 44),
            backButton.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 16),

            moreButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            moreButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    private func buildDescription() {
        descriptionPanel.backgroundColor = .clear
        descriptionPanel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(descriptionPanel)

        let authorPill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        authorPill.layer.cornerRadius = 27
        authorPill.layer.cornerCurve = .continuous
        authorPill.clipsToBounds = true
        authorPill.translatesAutoresizingMaskIntoConstraints = false
        descriptionPanel.addSubview(authorPill)

        let avatar = UIImageView(image: UIImage(named: "MoodBackdrop"))
        avatar.contentMode = .scaleAspectFill
        avatar.layer.cornerRadius = 19
        avatar.clipsToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        authorPill.contentView.addSubview(avatar)

        let nameLabel = UILabel()
        nameLabel.text = "@Marry"
        nameLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        nameLabel.textColor = UIColor.white.withAlphaComponent(0.88)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        authorPill.contentView.addSubview(nameLabel)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = UIColor.white.withAlphaComponent(0.50)
        chevron.translatesAutoresizingMaskIntoConstraints = false
        authorPill.contentView.addSubview(chevron)

        descriptionLabel.text = characterDescription
        descriptionLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .medium))
        descriptionLabel.adjustsFontForContentSizeCategory = true
        descriptionLabel.textColor = UIColor.white.withAlphaComponent(0.60)
        descriptionLabel.numberOfLines = 4
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionPanel.addSubview(descriptionLabel)

        descriptionToggle.setTitle("Show More", for: .normal)
        descriptionToggle.titleLabel?.font = UIFontMetrics(forTextStyle: .callout).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        descriptionToggle.titleLabel?.adjustsFontForContentSizeCategory = true
        descriptionToggle.tintColor = UIColor.white.withAlphaComponent(1.0)
        descriptionToggle.contentHorizontalAlignment = .leading
        descriptionToggle.accessibilityHint = "Expands or collapses the character description."
        descriptionToggle.addTarget(self, action: #selector(toggleDescription), for: .touchUpInside)
        descriptionToggle.enableSystemTouchFeedback()
        descriptionToggle.translatesAutoresizingMaskIntoConstraints = false
        descriptionPanel.addSubview(descriptionToggle)

        descriptionBottomConstraint = descriptionPanel.bottomAnchor.constraint(
            equalTo: view.bottomAnchor,
            constant: -(SheetHeight.medium + 16)
        )

        NSLayoutConstraint.activate([
            descriptionBottomConstraint,
            descriptionPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            descriptionPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            authorPill.topAnchor.constraint(equalTo: descriptionPanel.topAnchor),
            authorPill.leadingAnchor.constraint(equalTo: descriptionPanel.leadingAnchor),
            authorPill.heightAnchor.constraint(equalToConstant: 54),

            avatar.leadingAnchor.constraint(equalTo: authorPill.contentView.leadingAnchor, constant: 8),
            avatar.centerYAnchor.constraint(equalTo: authorPill.contentView.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 38),
            avatar.heightAnchor.constraint(equalToConstant: 38),

            nameLabel.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: authorPill.contentView.centerYAnchor),

            chevron.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 18),
            chevron.trailingAnchor.constraint(equalTo: authorPill.contentView.trailingAnchor, constant: -14),
            chevron.centerYAnchor.constraint(equalTo: authorPill.contentView.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),
            chevron.heightAnchor.constraint(equalToConstant: 18),

            descriptionLabel.topAnchor.constraint(equalTo: authorPill.bottomAnchor, constant: 18),
            descriptionLabel.leadingAnchor.constraint(equalTo: descriptionPanel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(equalTo: descriptionPanel.trailingAnchor),

            descriptionToggle.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 4),
            descriptionToggle.leadingAnchor.constraint(equalTo: descriptionPanel.leadingAnchor),
            descriptionToggle.bottomAnchor.constraint(equalTo: descriptionPanel.bottomAnchor)
        ])
    }

    @objc private func showHome() {
        if let navigationController {
            navigationController.popToRootViewController(animated: true)
            return
        }

        guard let window = view.window else { return }
        let home = HomeViewController()
        UIView.transition(with: window, duration: 0.32, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            window.rootViewController = home
        }
    }

    private func buildSheet() {
        sheetBackdropControl.backgroundColor = UIColor.black.withAlphaComponent(0.34)
        sheetBackdropControl.alpha = 0
        sheetBackdropControl.isHidden = true
        sheetBackdropControl.accessibilityLabel = "Dismiss Daily Mood sheet"
        sheetBackdropControl.addTarget(self, action: #selector(collapseSheetFromBackdrop), for: .touchUpInside)
        sheetBackdropControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheetBackdropControl)

        sheetView.clipsToBounds = true
        sheetView.layer.borderWidth = 1
        sheetView.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        sheetView.layer.shadowColor = UIColor.black.cgColor
        sheetView.layer.shadowOpacity = 0.22
        sheetView.layer.shadowRadius = 24
        sheetView.layer.shadowOffset = CGSize(width: 0, height: -8)
        sheetView.contentView.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.06)
        sheetView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Expand Daily Mood", target: self, selector: #selector(expandSheetForAccessibility)),
            UIAccessibilityCustomAction(name: "Collapse Daily Mood", target: self, selector: #selector(collapseSheetForAccessibility))
        ]
        sheetView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(sheetView)

        sheetGlassHighlight.isUserInteractionEnabled = false
        sheetGlassHighlight.alpha = 0.42
        sheetGlassHighlight.translatesAutoresizingMaskIntoConstraints = false
        sheetView.contentView.addSubview(sheetGlassHighlight)

        sheetContent.translatesAutoresizingMaskIntoConstraints = false
        sheetView.contentView.addSubview(sheetContent)

        let grabber = UIView()
        grabber.backgroundColor = UIColor.white.withAlphaComponent(0.42)
        grabber.layer.cornerRadius = 2.5
        grabber.isAccessibilityElement = true
        grabber.accessibilityLabel = "Daily Mood sheet"
        grabber.accessibilityHint = "Drag up or down to resize."
        grabber.translatesAutoresizingMaskIntoConstraints = false
        sheetContent.addSubview(grabber)

        let titleLabel = UILabel()
        titleLabel.text = "Daily Mood"
        let titleFont = UIFont(name: "TelkaTRIAL-Wide-Medium", size: 17) ?? .systemFont(ofSize: 17, weight: .medium)
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: titleFont)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        sheetContent.addSubview(titleLabel)

        tableView.register(MoodCell.self, forCellReuseIdentifier: MoodCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 16, right: 0)
        tableView.showsVerticalScrollIndicator = false
        tableView.delaysContentTouches = false
        tableView.bounces = true
        tableView.alwaysBounceVertical = true
        tableView.isScrollEnabled = false
        tableView.translatesAutoresizingMaskIntoConstraints = false
        sheetContent.addSubview(tableView)

        sheetHeightConstraint = sheetView.heightAnchor.constraint(equalToConstant: SheetHeight.medium)
        NSLayoutConstraint.activate([
            sheetBackdropControl.topAnchor.constraint(equalTo: view.topAnchor),
            sheetBackdropControl.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheetBackdropControl.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheetBackdropControl.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            sheetView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            sheetView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            sheetView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            sheetHeightConstraint,

            sheetGlassHighlight.topAnchor.constraint(equalTo: sheetView.contentView.topAnchor),
            sheetGlassHighlight.leadingAnchor.constraint(equalTo: sheetView.contentView.leadingAnchor),
            sheetGlassHighlight.trailingAnchor.constraint(equalTo: sheetView.contentView.trailingAnchor),
            sheetGlassHighlight.heightAnchor.constraint(equalToConstant: 132),

            sheetContent.topAnchor.constraint(equalTo: sheetView.contentView.topAnchor),
            sheetContent.leadingAnchor.constraint(equalTo: sheetView.contentView.leadingAnchor),
            sheetContent.trailingAnchor.constraint(equalTo: sheetView.contentView.trailingAnchor),
            sheetContent.bottomAnchor.constraint(equalTo: sheetView.contentView.bottomAnchor),

            grabber.topAnchor.constraint(equalTo: sheetContent.topAnchor, constant: 7),
            grabber.centerXAnchor.constraint(equalTo: sheetContent.centerXAnchor),
            grabber.widthAnchor.constraint(equalToConstant: 42),
            grabber.heightAnchor.constraint(equalToConstant: 5),

            titleLabel.centerXAnchor.constraint(equalTo: sheetContent.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: sheetContent.topAnchor, constant: 38),
            titleLabel.leadingAnchor.constraint(equalTo: sheetContent.leadingAnchor, constant: 24),
            titleLabel.trailingAnchor.constraint(equalTo: sheetContent.trailingAnchor, constant: -24),

            tableView.topAnchor.constraint(equalTo: sheetContent.topAnchor, constant: 84),
            tableView.leadingAnchor.constraint(equalTo: sheetContent.leadingAnchor, constant: 16),
            tableView.trailingAnchor.constraint(equalTo: sheetContent.trailingAnchor, constant: -16),
            tableView.bottomAnchor.constraint(equalTo: sheetContent.bottomAnchor)
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSheetPan(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        sheetView.addGestureRecognizer(pan)
        sheetPanGesture = pan
    }

    @objc private func collapseSheetFromBackdrop() {
        animateSheet(to: SheetHeight.medium, velocityY: 0, notify: true)
    }

    @objc private func toggleDescription() {
        isDescriptionExpanded.toggle()
        descriptionLabel.numberOfLines = isDescriptionExpanded ? 0 : 4
        descriptionToggle.setTitle(isDescriptionExpanded ? "Show Less" : "Show More", for: .normal)

        UIView.animate(withDuration: 0.25, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
            self.view.layoutIfNeeded()
        }
    }

    @objc private func handleSheetPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            sheetAnimator?.stopAnimation(true)
            sheetAnimator = nil
            sheetStartHeight = sheetHeightConstraint.constant
            sheetFeedback.prepare()
        case .changed:
            let translation = gesture.translation(in: view).y
            let maxHeight = availableExpandedHeight()
            let proposedHeight = sheetStartHeight - translation
            let displayHeight = rubberBandedHeight(proposedHeight, min: SheetHeight.medium, max: maxHeight)
            sheetHeightConstraint.constant = displayHeight
            tableView.isScrollEnabled = displayHeight >= maxHeight - 1
            updateSheetBackdrop(for: displayHeight)
            view.layoutIfNeeded()
        case .ended, .cancelled, .failed:
            let velocityY = gesture.velocity(in: view).y
            snapSheet(velocityY: velocityY)
        default:
            break
        }
    }

    @objc private func expandSheetForAccessibility() -> Bool {
        animateSheet(to: availableExpandedHeight(), velocityY: 0, notify: true)
        return true
    }

    @objc private func collapseSheetForAccessibility() -> Bool {
        animateSheet(to: SheetHeight.medium, velocityY: 0, notify: true)
        return true
    }

    private func snapSheet(velocityY: CGFloat) {
        let target: CGFloat
        let current = sheetHeightConstraint.constant
        let maxHeight = availableExpandedHeight()
        let stops = [SheetHeight.medium, maxHeight]
        let projectedHeight = clamp(current - velocityY * 0.24, min: SheetHeight.medium, max: maxHeight)

        if abs(velocityY) > 520 {
            target = velocityY < 0 ? nextStop(above: projectedHeight, in: stops) : nextStop(below: projectedHeight, in: stops)
        } else {
            target = stops.min { abs($0 - projectedHeight) < abs($1 - projectedHeight) } ?? SheetHeight.medium
        }

        animateSheet(to: target, velocityY: velocityY, notify: true)
    }

    private func animateSheet(to target: CGFloat, velocityY: CGFloat, notify: Bool) {
        let current = sheetHeightConstraint.constant
        let maxHeight = availableExpandedHeight()
        tableView.isScrollEnabled = target >= maxHeight - 1

        if notify, abs(target - lastSettledSheetHeight) > 1 {
            sheetFeedback.selectionChanged()
            sheetFeedback.prepare()
        }
        lastSettledSheetHeight = target

        guard !UIAccessibility.isReduceMotionEnabled else {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.sheetHeightConstraint.constant = target
                self.updateSheetBackdrop(for: target)
                self.view.layoutIfNeeded()
            }
            return
        }

        sheetAnimator?.stopAnimation(true)
        sheetBackdropControl.isHidden = false
        let distance = max(abs(target - current), 1)
        let normalizedVelocity = CGVector(dx: 0, dy: clamp(-velocityY / distance, min: -5, max: 5))
        let timing = UISpringTimingParameters(dampingRatio: 0.9, initialVelocity: normalizedVelocity)
        let duration = TimeInterval(clamp(0.30 + distance / 2400, min: 0.32, max: 0.50))
        let animator = UIViewPropertyAnimator(duration: duration, timingParameters: timing)
        animator.addAnimations {
            self.sheetHeightConstraint.constant = target
            self.updateSheetBackdrop(for: target)
            self.view.layoutIfNeeded()
        }
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.sheetHeightConstraint.constant = target
            self.tableView.isScrollEnabled = target >= self.availableExpandedHeight() - 1
            self.updateSheetBackdrop(for: target)
            self.sheetAnimator = nil
        }
        sheetAnimator = animator
        animator.startAnimation()
    }

    private func updateSheetBackdrop(for height: CGFloat) {
        let progress = clamp((height - SheetHeight.medium) / max(availableExpandedHeight() - SheetHeight.medium, 1), min: 0, max: 1)
        sheetBackdropControl.alpha = progress
        sheetBackdropControl.isHidden = progress < 0.01
        updateSheetChrome(for: height)
    }

    private func updateSheetChrome(for height: CGFloat) {
        let cornerRadius: CGFloat = 34
        sheetView.layer.cornerRadius = cornerRadius
        sheetView.layer.cornerCurve = .continuous
        sheetView.layer.shadowPath = UIBezierPath(
            roundedRect: sheetView.bounds,
            cornerRadius: cornerRadius
        ).cgPath
    }

    private func availableExpandedHeight() -> CGFloat {
        max(SheetHeight.medium, view.bounds.height - view.safeAreaInsets.top - 16)
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.max(minValue, Swift.min(value, maxValue))
    }

    private func rubberBandedHeight(_ height: CGFloat, min minHeight: CGFloat, max maxHeight: CGFloat) -> CGFloat {
        if height < minHeight {
            return minHeight - rubberBand(distance: minHeight - height, dimension: view.bounds.height)
        }

        if height > maxHeight {
            return maxHeight + rubberBand(distance: height - maxHeight, dimension: view.bounds.height)
        }

        return height
    }

    private func rubberBand(distance: CGFloat, dimension: CGFloat) -> CGFloat {
        let constant: CGFloat = 0.55
        return (constant * abs(distance) * dimension) / (dimension + constant * abs(distance))
    }

    private func nextStop(above current: CGFloat, in stops: [CGFloat]) -> CGFloat {
        stops.first(where: { $0 > current + 10 }) ?? stops.last ?? current
    }

    private func nextStop(below current: CGFloat, in stops: [CGFloat]) -> CGFloat {
        stops.reversed().first(where: { $0 < current - 10 }) ?? stops.first ?? current
    }

    private func addLatestMoodEntryIfNeeded() {
        guard !hasAddedEntryForAppearance else { return }
        hasAddedEntryForAppearance = true

        guard tableView.window != nil else {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.addLatestMoodEntryIfNeeded()
            }
            hasAddedEntryForAppearance = false
            return
        }

        let entry = MoodTimelineStore.prependLatestEntry()
        moods = MoodTimelineStore.entries
        let indexPath = IndexPath(row: 0, section: 0)
        pendingArrivalIndexPath = indexPath

        tableView.performBatchUpdates {
            tableView.insertRows(at: [indexPath], with: .top)
        } completion: { [weak self] _ in
            guard let self else { return }
            self.playNewMoodCeremony(at: indexPath, mood: entry)
        }
    }

    private func playNewMoodCeremony(at indexPath: IndexPath, mood: MoodEntry) {
        HapticFeedback.selection()

        let animateVisibleCell = { [weak self] in
            guard let self,
                  let cell = self.tableView.cellForRow(at: indexPath) as? MoodCell else { return }
            self.pendingArrivalIndexPath = nil
            HapticFeedback.lightImpact()
            cell.playArrivalCeremony(emoji: mood.emoji)
        }

        guard !UIAccessibility.isReduceMotionEnabled else {
            animateVisibleCell()
            UIAccessibility.post(notification: .announcement, argument: "New mood added: \(mood.title)")
            return
        }

        animateVisibleCell()
    }

    private func playEmojiBurst(with emoji: String, origin: CGPoint) {
        guard !UIAccessibility.isReduceMotionEnabled else { return }

        emojiBurstView?.removeFromSuperview()

        let burstView = EmojiBurstRainView()
        burstView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(burstView, belowSubview: sheetView)
        NSLayoutConstraint.activate([
            burstView.topAnchor.constraint(equalTo: view.topAnchor),
            burstView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            burstView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            burstView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        view.layoutIfNeeded()

        emojiBurstView = burstView
        burstView.start(emoji: emoji, origin: origin)
    }
}

extension ViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        moods.count
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        141
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: MoodCell.reuseIdentifier, for: indexPath) as! MoodCell
        cell.configure(with: moods[indexPath.row])
        if indexPath == pendingArrivalIndexPath {
            cell.prepareForArrivalCeremony()
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        (tableView.cellForRow(at: indexPath) as? MoodCell)?.setPressed(true)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        (tableView.cellForRow(at: indexPath) as? MoodCell)?.setPressed(false)
    }
}

extension ViewController: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === sheetPanGesture else { return true }
        let velocity = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: view) ?? .zero
        if sheetHeightConstraint.constant >= availableExpandedHeight() - 1,
           velocity.y < 0 || tableView.contentOffset.y > -tableView.adjustedContentInset.top + 1 {
            return false
        }
        return abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === sheetPanGesture else { return false }
        return otherGestureRecognizer === tableView.panGestureRecognizer
    }
}

private struct MoodEntry {
    let time: String
    let emoji: String
    let title: String
    let accessory: MoodAccessory
    let gradient: MoodGradient
}

@MainActor
private final class EmojiBurstRainView: UIView {
    private var cleanupTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        cleanupTask?.cancel()
    }

    func start(emoji: String, origin: CGPoint) {
        layoutIfNeeded()
        guard bounds.width > 0, bounds.height > 0 else { return }

        cleanupTask?.cancel()
        layer.removeAllAnimations()
        subviews.forEach { $0.removeFromSuperview() }

        makeParticles(emoji: emoji).enumerated().forEach { index, particle in
            animateFallingParticle(particle, index: index)
        }

        cleanupTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.6))
            guard !Task.isCancelled else { return }
            self?.removeFromSuperview()
        }
    }

    private func makeParticles(emoji: String) -> [UILabel] {
        let particleCount = Int(clamp(bounds.width / 13, min: 26, max: 40))

        return (0..<particleCount).map { _ in
            let label = UILabel()
            label.text = emoji
            label.textAlignment = .center
            label.font = .systemFont(ofSize: CGFloat.random(in: 24...38))
            label.alpha = 1

            let size = CGFloat.random(in: 36...52)
            let start = CGPoint(
                x: CGFloat.random(in: -size...bounds.width + size),
                y: CGFloat.random(in: -bounds.height * 0.22...(-size))
            )
            label.frame = CGRect(
                x: start.x - size / 2,
                y: start.y - size / 2,
                width: size,
                height: size
            )
            addSubview(label)
            return label
        }
    }

    private func animateFallingParticle(_ particle: UILabel, index: Int) {
        let size = particle.bounds.width
        let startCenter = particle.center
        let endCenter = CGPoint(
            x: startCenter.x + CGFloat.random(in: -18...18),
            y: bounds.height + size * CGFloat.random(in: 1.2...2.2)
        )
        let duration = TimeInterval(CGFloat.random(in: 2.15...2.95))
        let delay = TimeInterval(CGFloat(index % 12) * 0.08 + CGFloat.random(in: 0...0.24))

        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = startCenter
        position.toValue = endCenter
        position.duration = duration
        position.beginTime = CACurrentMediaTime() + delay
        position.timingFunction = CAMediaTimingFunction(name: .easeIn)
        position.fillMode = .forwards
        position.isRemovedOnCompletion = false

        particle.layer.position = endCenter
        particle.layer.add(position, forKey: "burstPosition")

        Task { @MainActor [weak particle] in
            try? await Task.sleep(for: .seconds(duration + delay + 0.04))
            particle?.removeFromSuperview()
        }
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.max(minValue, Swift.min(value, maxValue))
    }
}

@MainActor
private enum MoodTimelineStore {
    private static var latestEntryCount = 0
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter
    }()

    private static let latestTemplates: [(emoji: String, title: String, gradient: MoodGradient)] = [
        ("✨", "A new spark just surfaced", .peach),
        ("😌", "Soft focus, quietly steady", .mint),
        ("🔥", "Heat rising under control", .coral),
        ("🫧", "Clearer than the last breath", .cyan)
    ]

    private static var timeline: [MoodEntry] = [
        MoodEntry(time: "Apr 24, 09:35", emoji: "🥶", title: "Oozing with confidence", accessory: .featured, gradient: .cyan),
        MoodEntry(time: "Apr 24, 09:35", emoji: "😡", title: "Oozing with confidence", accessory: .locked, gradient: .coral),
        MoodEntry(time: "Apr 24, 09:35", emoji: "🥶", title: "Oozing with confidence", accessory: .locked, gradient: .mint),
        MoodEntry(time: "Apr 24, 09:35", emoji: "🥰", title: "Oozing with confidence", accessory: .disclosure, gradient: .peach),
        MoodEntry(time: "Apr 24, 09:35", emoji: "😎", title: "Oozing with confidence", accessory: .disclosure, gradient: .mint),
        MoodEntry(time: "Apr 23, 22:18", emoji: "😈", title: "Velvet static under control", accessory: .featured, gradient: .cyan)
    ]

    static var entries: [MoodEntry] {
        timeline
    }

    @discardableResult
    static func prependLatestEntry(now: Date = Date()) -> MoodEntry {
        let template = latestTemplates[latestEntryCount % latestTemplates.count]
        latestEntryCount += 1
        let entry = MoodEntry(
            time: dateFormatter.string(from: now),
            emoji: template.emoji,
            title: template.title,
            accessory: .featured,
            gradient: template.gradient
        )
        timeline.insert(entry, at: 0)
        return entry
    }
}

private struct MoodGradient {
    let startColor: UIColor
    let endColor: UIColor

    var tintColor: UIColor {
        endColor.withAlphaComponent(0.40)
    }

    static let cyan = MoodGradient(
        startColor: UIColor(red: 0.799, green: 0.921, blue: 0.939, alpha: 1),
        endColor: UIColor(red: 0.492, green: 0.934, blue: 1, alpha: 1)
    )

    static let coral = MoodGradient(
        startColor: UIColor(red: 1, green: 0.913, blue: 0.904, alpha: 1),
        endColor: UIColor(red: 0.925, green: 0.597, blue: 0.563, alpha: 1)
    )

    static let mint = MoodGradient(
        startColor: UIColor(red: 0.879, green: 1, blue: 0.928, alpha: 1),
        endColor: UIColor(red: 0.72, green: 0.997, blue: 0.833, alpha: 1)
    )

    static let peach = MoodGradient(
        startColor: UIColor(red: 1, green: 0.941, blue: 0.865, alpha: 1),
        endColor: UIColor(red: 1, green: 0.875, blue: 0.723, alpha: 1)
    )
}

private enum MoodAccessory: Equatable {
    case disclosure
    case featured
    case locked

    var symbolName: String {
        switch self {
        case .disclosure:
            "chevron.right"
        case .featured:
            "sparkles"
        case .locked:
            "lock.fill"
        }
    }

    var accessibilityValue: String? {
        switch self {
        case .disclosure:
            "Opens details"
        case .featured:
            "Featured"
        case .locked:
            "Locked"
        }
    }

    var tintColor: UIColor {
        switch self {
        case .featured:
            .systemBlue
        case .locked:
            .systemYellow
        case .disclosure:
            .black
        }
    }
}

private final class MoodCell: UITableViewCell {
    static let reuseIdentifier = "MoodCell"

    private let timeLabel = UILabel()
    private let container = UIControl()
    private let colorWash = MoodCellGradientView()
    private let cellHighlight = GlassHighlightView()
    private let emojiLabel = UILabel()
    private let titleLabel = UILabel()
    private let accessoryImageView = UIImageView()
    private var isLockedMood = false
    private var ceremonyLayer: CAGradientLayer?
    private var floatingEmojiViews: [UIView] = []

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setup()
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(with mood: MoodEntry) {
        timeLabel.text = mood.time
        emojiLabel.text = mood.emoji
        titleLabel.text = mood.title
        accessoryImageView.image = UIImage(systemName: mood.accessory.symbolName)
        accessoryImageView.tintColor = UIColor.black.withAlphaComponent(0.40)
        accessoryImageView.layer.cornerRadius = 16
        accessoryImageView.layer.borderWidth = 0
        accessoryImageView.layer.borderColor = UIColor.clear.cgColor
        accessoryImageView.backgroundColor = .clear
        container.backgroundColor = .clear
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.34).cgColor
        colorWash.configure(gradient: mood.gradient)
        isLockedMood = mood.accessory == .locked
        accessibilityLabel = "\(mood.time), \(mood.title)"
        accessibilityValue = mood.accessory.accessibilityValue
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.alpha = 1
        container.transform = .identity
        container.alpha = 1
        ceremonyLayer?.removeFromSuperlayer()
        ceremonyLayer = nil
        floatingEmojiViews.forEach { $0.removeFromSuperview() }
        floatingEmojiViews.removeAll()
        isLockedMood = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        setPressed(true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesEnded(touches, with: event)
        setPressed(false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesCancelled(touches, with: event)
        setPressed(false)
    }

    private func setup() {
        backgroundColor = .clear
        selectionStyle = .none
        isAccessibilityElement = true

        timeLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 14, weight: .medium))
        timeLabel.adjustsFontForContentSizeCategory = true
        timeLabel.textColor = UIColor.white.withAlphaComponent(0.44)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(timeLabel)

        container.layer.cornerRadius = 32
        container.layer.cornerCurve = .continuous
        container.layer.borderWidth = 1
        container.clipsToBounds = true
        container.isUserInteractionEnabled = false
        container.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(container)

        colorWash.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(colorWash)

        cellHighlight.alpha = 0.68
        cellHighlight.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cellHighlight)

        emojiLabel.font = UIFontMetrics(forTextStyle: .title3).scaledFont(for: .systemFont(ofSize: 29))
        emojiLabel.adjustsFontForContentSizeCategory = true
        emojiLabel.textAlignment = .center
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emojiLabel)

        titleLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17, weight: .semibold))
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .black
        titleLabel.textAlignment = .left
        titleLabel.minimumScaleFactor = 0.82
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)

        accessoryImageView.contentMode = .center
        accessoryImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        accessoryImageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(accessoryImageView)

        NSLayoutConstraint.activate([
            timeLabel.topAnchor.constraint(equalTo: contentView.topAnchor),
            timeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 26),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -26),

            container.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 16),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -4),
            container.heightAnchor.constraint(equalToConstant: 92),

            colorWash.topAnchor.constraint(equalTo: container.topAnchor),
            colorWash.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            colorWash.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            colorWash.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            cellHighlight.topAnchor.constraint(equalTo: container.topAnchor),
            cellHighlight.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cellHighlight.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            cellHighlight.heightAnchor.constraint(equalToConstant: 52),

            emojiLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            emojiLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emojiLabel.widthAnchor.constraint(equalToConstant: 42),

            titleLabel.leadingAnchor.constraint(equalTo: emojiLabel.trailingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessoryImageView.leadingAnchor, constant: -14),
            titleLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            accessoryImageView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            accessoryImageView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            accessoryImageView.widthAnchor.constraint(equalToConstant: 32),
            accessoryImageView.heightAnchor.constraint(equalToConstant: 32)
        ])
    }

    func setPressed(_ pressed: Bool) {
        animateSystemTouchFeedback(on: container, isPressed: pressed)
    }

    func prepareForArrivalCeremony() {
        ceremonyLayer?.removeFromSuperlayer()
        ceremonyLayer = nil
        contentView.alpha = 0
        container.alpha = 1
        container.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
    }

    func playArrivalCeremony(emoji: String) {
        layoutIfNeeded()
        ceremonyLayer?.removeFromSuperlayer()
        floatingEmojiViews.forEach { $0.removeFromSuperview() }
        floatingEmojiViews.removeAll()

        guard !UIAccessibility.isReduceMotionEnabled else {
            container.transform = .identity
            contentView.alpha = 0.70
            UIView.animate(withDuration: 0.22, delay: 0, options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) {
                self.contentView.alpha = 1
            }
            return
        }

        contentView.alpha = 0
        container.alpha = 1
        container.transform = CGAffineTransform(scaleX: 0.88, y: 0.88)
        UIView.animate(
            withDuration: 0.58,
            delay: 0,
            usingSpringWithDamping: 0.68,
            initialSpringVelocity: 0.75,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            self.container.transform = .identity
            self.contentView.alpha = 1
        }

        let sweep = CAGradientLayer()
        let sweepWidth = max(container.bounds.width * 0.46, 140)
        sweep.frame = CGRect(
            x: -sweepWidth,
            y: -container.bounds.height * 0.25,
            width: sweepWidth,
            height: container.bounds.height * 1.5
        )
        sweep.colors = [
            UIColor.white.withAlphaComponent(0).cgColor,
            UIColor.white.withAlphaComponent(0.18).cgColor,
            UIColor.white.withAlphaComponent(0.78).cgColor,
            UIColor.white.withAlphaComponent(0.20).cgColor,
            UIColor.white.withAlphaComponent(0).cgColor
        ]
        sweep.locations = [0, 0.32, 0.50, 0.68, 1]
        sweep.startPoint = CGPoint(x: 0, y: 1)
        sweep.endPoint = CGPoint(x: 1, y: 0)
        sweep.compositingFilter = "screenBlendMode"
        container.layer.addSublayer(sweep)
        ceremonyLayer = sweep

        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -sweepWidth / 2
        move.toValue = container.bounds.width + sweepWidth / 2
        move.duration = 0.92
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        move.fillMode = .forwards
        move.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak sweep] in
            sweep?.removeFromSuperlayer()
            self?.ceremonyLayer = nil
        }
        sweep.add(move, forKey: "arrivalSweep")
        CATransaction.commit()

        playFloatingEmojiCeremony(emoji: emoji)
    }

    private func playFloatingEmojiCeremony(emoji: String) {
        guard container.bounds.width > 0, container.bounds.height > 0 else { return }

        let count = 10
        (0..<count).forEach { index in
            let label = UILabel()
            label.text = emoji
            label.textAlignment = .center
            label.font = .systemFont(ofSize: CGFloat.random(in: 24...34))
            label.alpha = 0

            let size = CGFloat.random(in: 36...50)
            let columnCount = 5
            let column = index % columnCount
            let row = index / columnCount
            let normalizedX = (CGFloat(column) + 0.5 + CGFloat.random(in: -0.18...0.18)) / CGFloat(columnCount)
            let safeInset = size / 2 + 10
            let start = CGPoint(
                x: min(max(container.bounds.width * normalizedX, safeInset), container.bounds.width - safeInset),
                y: container.bounds.height + size / 2 + CGFloat(row) * 10 + CGFloat.random(in: 4...20)
            )
            label.frame = CGRect(x: start.x - size / 2, y: start.y - size / 2, width: size, height: size)
            label.transform = CGAffineTransform(scaleX: 0.55, y: 0.55).rotated(by: CGFloat.random(in: -0.18...0.18))
            container.addSubview(label)
            floatingEmojiViews.append(label)

            let delay = TimeInterval(0.04 + CGFloat(index) * 0.035 + CGFloat.random(in: 0...0.05))
            let drift = CGFloat.random(in: -34...34)
            let peak = CGPoint(
                x: min(max(start.x + drift * 0.55, safeInset), container.bounds.width - safeInset),
                y: CGFloat.random(in: safeInset...(container.bounds.height * 0.58))
            )
            let end = CGPoint(
                x: min(max(start.x + drift * 1.25, safeInset), container.bounds.width - safeInset),
                y: -size / 2 - CGFloat.random(in: 18...46)
            )
            let duration = TimeInterval(CGFloat.random(in: 1.28...1.72))

            UIView.animateKeyframes(
                withDuration: duration,
                delay: delay,
                options: [.allowUserInteraction, .calculationModeCubic],
                animations: {
                    UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.18) {
                        label.alpha = 1
                        label.transform = CGAffineTransform(scaleX: 1.08, y: 1.08).rotated(by: CGFloat.random(in: -0.12...0.12))
                    }
                    UIView.addKeyframe(withRelativeStartTime: 0.18, relativeDuration: 0.62) {
                        label.center = peak
                        label.transform = CGAffineTransform(scaleX: 0.96, y: 0.96).rotated(by: CGFloat.random(in: -0.24...0.24))
                    }
                    UIView.addKeyframe(withRelativeStartTime: 0.72, relativeDuration: 0.28) {
                        label.center = end
                        label.alpha = 0
                        label.transform = CGAffineTransform(scaleX: 0.62, y: 0.62).rotated(by: CGFloat.random(in: -0.55...0.55))
                    }
                },
                completion: nil
            )

            Task { @MainActor [weak self, weak label] in
                try? await Task.sleep(for: .seconds(delay + duration + 0.05))
                guard let label else { return }
                label.removeFromSuperview()
                self?.floatingEmojiViews.removeAll { $0 === label }
            }
        }
    }
}

private final class RedGradientView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.colors = [
            UIColor.clear.cgColor,
            UIColor(red: 0.34, green: 0.02, blue: 0.04, alpha: 0.82).cgColor,
            UIColor(red: 0.48, green: 0.04, blue: 0.06, alpha: 0.96).cgColor
        ]
        gradient.locations = [0, 0.45, 1]
    }
}

private final class MoodCellGradientView: UIView {
    private let fillLayer = CALayer()
    private let gradientLayer = CAGradientLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(fillLayer)
        fillLayer.addSublayer(gradientLayer)
        configure(gradient: .cyan)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let height = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = bounds
        gradientLayer.bounds = CGRect(
            x: 0,
            y: 0,
            width: width * 2,
            height: height * 2
        )
        gradientLayer.position = CGPoint(x: width / 2, y: height / 2)
        CATransaction.commit()
    }

    func configure(gradient moodGradient: MoodGradient) {
        fillLayer.backgroundColor = moodGradient.startColor.brightened(by: 0.14).cgColor
        gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        gradientLayer.transform = CATransform3DIdentity
        gradientLayer.colors = [
            moodGradient.startColor.brightened(by: 0.14).cgColor,
            moodGradient.endColor.brightened(by: 0.16).cgColor
        ]
        gradientLayer.locations = [0, 1]
    }
}

private extension UIColor {
    func brightened(by amount: CGFloat) -> UIColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0

        guard getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            return self
        }

        return UIColor(
            red: min(red + amount, 1),
            green: min(green + amount, 1),
            blue: min(blue + amount, 1),
            alpha: 1
        )
    }
}

private final class GlassHighlightView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure() {
        guard let gradient = layer as? CAGradientLayer else { return }
        gradient.startPoint = CGPoint(x: 0.08, y: 0)
        gradient.endPoint = CGPoint(x: 0.92, y: 1)
        gradient.colors = [
            UIColor.white.withAlphaComponent(0.28).cgColor,
            UIColor.white.withAlphaComponent(0.08).cgColor,
            UIColor.clear.cgColor
        ]
        gradient.locations = [0, 0.38, 1]
    }
}
