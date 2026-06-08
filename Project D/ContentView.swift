//
//  ContentView.swift
//  Project D
//
//  Created by Fang on 2026/6/1.
//

import SwiftUI
import UIKit
import CoreText
import PhotosUI

private enum CreateRoleFocusedField: Hashable {
    case name
    case settings
    case opening
    case intro
}

private struct CreateRoleFieldFramePreferenceKey: PreferenceKey {
    static var defaultValue: [CreateRoleFocusedField: CGRect] = [:]

    static func reduce(value: inout [CreateRoleFocusedField: CGRect], nextValue: () -> [CreateRoleFocusedField: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private struct CreateRoleFieldFrameReader: View {
    let field: CreateRoleFocusedField

    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: CreateRoleFieldFramePreferenceKey.self,
                value: [field: proxy.frame(in: .global)]
            )
        }
    }
}

private struct AppearancePromptFramePreferenceKey: PreferenceKey {
    static var defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let newValue = nextValue()
        if newValue != .zero {
            value = newValue
        }
    }
}

private enum CreateRoleScrollAnchor {
    static let top = "create-role-top"
}

private enum CreateRoleInitialState {
    static let characterName = ""
    static let settings = ""
    static let opening = ""
    static let intro = ""
    static let appearanceGlowFocus = CGPoint(x: 0.5, y: 0.28)
}

private enum VoiceCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case male = "Male"
    case female = "Female"

    var id: String { rawValue }
}

private struct VoicePreset: Identifiable, Hashable {
    let id: String
    let name: String
    let primaryTrait: String
    let secondaryTrait: String
    let category: VoiceCategory
}

private struct VoiceMixSelection: Identifiable, Hashable {
    let preset: VoicePreset
    var weight: Double

    var id: String { preset.id }
}

private enum VoiceLibrary {
    static let maxMixedVoices = 3

    static let presets: [VoicePreset] = [
        VoicePreset(id: "funny-guy", name: "Funny Guy", primaryTrait: "Mid-age", secondaryTrait: "Elegant", category: .male),
        VoicePreset(id: "clever-character", name: "Clever Character", primaryTrait: "Refined", secondaryTrait: "Graceful", category: .female),
        VoicePreset(id: "sharp-witted-persona", name: "Sharp-Witted Persona", primaryTrait: "Chic", secondaryTrait: "Cultivated", category: .female),
        VoicePreset(id: "quick-witted-identity", name: "Quick-Witted Identity", primaryTrait: "Elegant", secondaryTrait: "Worldly", category: .male),
        VoicePreset(id: "smart-witty-persona", name: "Smart and Witty Persona", primaryTrait: "Elegant", secondaryTrait: "Worldly", category: .female),
        VoicePreset(id: "witty-charming-persona", name: "Witty and Charming Persona", primaryTrait: "Elegant", secondaryTrait: "Worldly", category: .male),
        VoicePreset(id: "bright-persona", name: "Bright Persona", primaryTrait: "Cultured", secondaryTrait: "Worldly", category: .female),
        VoicePreset(id: "warm-narrator", name: "Warm Narrator", primaryTrait: "Soft", secondaryTrait: "Measured", category: .male)
    ]

    static let initialSelections: [VoiceMixSelection] = []

    static func summary(for selections: [VoiceMixSelection]) -> String {
        guard !selections.isEmpty else { return "Unselected" }
        guard selections.count > 1 else { return selections[0].preset.name }
        return selections.map(\.preset.name).joined(separator: " + ")
    }
}

private enum CreateRolePlaceholder {
    static let name = "Enter character name"
    static let settings = "Personality, identity, speaking style, relationship with user, etc. Use \"User\" to refer to the person chatting with this character"
    static let opening = "The first thing your character says. Use () to describe actions or scene"
    static let intro = "The first thing your character says. Use () to describe actions or scene"
}

private enum CreateContentValidator {
    private static let blockedTerms = [
        "hate", "hates", "kill", "violent", "violence", "blood", "nude", "sex"
    ]

    static func tip(for text: String, minimumLength: Int, shortTip: String) -> String {
        let normalized = text.trimmedForValidation.lowercased()

        if normalized.count < minimumLength {
            return shortTip
        }

        if blockedTerms.contains(where: { normalized.contains($0) }) {
            return "Try safer wording"
        }

        return ""
    }
}

struct CreateRoleView: View {
    private let onBackToHome: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(onBackToHome: (() -> Void)? = nil) {
        self.onBackToHome = onBackToHome
        TelkaFont.registerFonts()
    }

    @State private var characterName = CreateRoleInitialState.characterName
    @State private var settings = CreateRoleInitialState.settings
    @State private var opening = CreateRoleInitialState.opening
    @State private var intro = CreateRoleInitialState.intro
    @State private var selectedVoices = VoiceLibrary.initialSelections
    @State private var voicePitch = 0.5
    @State private var voiceSpeed = 0.5
    @State private var showVoiceSelector = false
    @State private var playingVoiceID: String?
    @State private var isVoicePreviewLoading = false
    @State private var isVoicePreviewPlaying = false
    @State private var showImageToast = false
    @State private var toastMessage = ""
    @State private var hasAppearanceImage = false
    @State private var isGeneratingImage = false
    @State private var generationStartedAt = Date()
    @State private var showAppearanceSheet = false
    @State private var showAppearanceBackdrop = false
    @State private var appearanceSheetIsPresented = false
    @State private var appearanceGlowFocus = CreateRoleInitialState.appearanceGlowFocus
    @State private var appearanceSheetDragOffset: CGFloat = 0
    @State private var appearancePrompt = ""
    @State private var selectedAppearanceStyle = 0
    @State private var selectedReferenceItem: PhotosPickerItem?
    @State private var referenceImage: UIImage?
    @State private var nameValidationTip = ""
    @State private var settingsValidationTip = ""
    @State private var keyboardIsVisible = false
    @State private var keyboardFrame = CGRect.zero
    @State private var keyboardHeight: CGFloat = 0
    @State private var fieldFrames: [CreateRoleFocusedField: CGRect] = [:]
    @State private var navigationGlassProgress = 0.0
    @State private var isPageScrolling = false
    @State private var lastScrollOffsetY = 0.0
    @State private var scrollHideDistance = 0.0
    @State private var resetScrollToken = UUID()
    @State private var scrollIdleWorkItem: DispatchWorkItem?
    @FocusState private var focusedField: CreateRoleFocusedField?

    private let buttonHideAnimation = Animation.timingCurve(0.24, 0.0, 0.22, 1.0, duration: 0.34)
    private let buttonRevealAnimation = Animation.timingCurve(0.16, 1.0, 0.30, 1.0, duration: 0.42)

    var body: some View {
        ZStack(alignment: .top) {
            CreateRoleBackground()

            ZStack(alignment: .top) {
                ScrollViewReader { scrollProxy in
                    ScrollView(showsIndicators: false) {
                        Color.clear
                            .frame(height: 0)
                            .id(CreateRoleScrollAnchor.top)

                        Group {
                            if isGeneratingImage {
                                GeneratingImageContent(
                                    characterName: characterName,
                                    settings: settings,
                                    opening: opening,
                                    intro: intro,
                                    selectedVoice: selectedVoiceSummary,
                                    startedAt: generationStartedAt
                                )
                                .id(generationStartedAt)
                            } else {
                                CreateRoleFormContent(
                                    characterName: $characterName,
                                    settings: $settings,
                                    opening: $opening,
                                    intro: $intro,
                                    selectedVoice: selectedVoiceSummary,
                                    hasAppearanceImage: hasAppearanceImage,
                                    nameValidationTip: nameValidationTip,
                                    settingsValidationTip: settingsValidationTip,
                                    focusedField: $focusedField,
                                    onAppearanceTap: presentAppearanceSheet,
                                    onVoiceTap: presentVoiceSelector
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 64)
                        .padding(.bottom, keyboardIsVisible ? 16 : 122)
                    }
                    .onScrollGeometryChange(for: Double.self) { geometry in
                        Double(geometry.contentOffset.y)
                    } action: { _, offsetY in
                        navigationGlassProgress = min(max(offsetY / 56, 0), 1)
                        updateFloatingButtonVisibility(offsetY: offsetY)
                    }
                    .onPreferenceChange(CreateRoleFieldFramePreferenceKey.self) { frames in
                        fieldFrames = frames

                        if keyboardIsVisible, focusedField != nil, focusedField != .name {
                            adjustFocusedFieldForKeyboard(using: frames, delay: 0.01)
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if keyboardIsVisible {
                            Color.clear.frame(height: keyboardHeight)
                        }
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: focusedField) { _, newValue in
                        guard newValue != nil, keyboardIsVisible else { return }
                        scheduleFocusedFieldKeyboardAdjustments(for: newValue)
                    }
                    .onChange(of: keyboardIsVisible) { _, isVisible in
                        if isVisible {
                            scheduleFocusedFieldKeyboardAdjustments(for: focusedField)
                        }
                    }
                    .onChange(of: resetScrollToken) { _, _ in
                        withAnimation(.easeInOut(duration: 0.22)) {
                            scrollProxy.scrollTo(CreateRoleScrollAnchor.top, anchor: .top)
                        }
                    }
                }

                LiquidGlassNavigationBackground(progress: navigationGlassProgress)
                    .frame(height: 132)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
                    .zIndex(1)

                TopNavigationBar(onBack: handleBackTap)
                    .zIndex(2)

                if !keyboardIsVisible {
                    VStack {
                        Spacer()

                        PrimaryCreateButton {
                            if !isGeneratingImage {
                                handleCreateTap()
                            }
                        }
                            .padding(.horizontal, 16)
                            .padding(.bottom, 42)
                    }
                    .opacity(isPageScrolling ? 0.001 : 1)
                    .offset(y: isPageScrolling ? 72 : 0)
                    .allowsHitTesting(!isPageScrolling)
                    .scaleEffect(isPageScrolling ? 0.985 : 1, anchor: .bottom)
                    .animation(isPageScrolling ? buttonHideAnimation : buttonRevealAnimation, value: isPageScrolling)
                    .ignoresSafeArea(edges: .bottom)
                    .zIndex(3)
                }

                if showImageToast {
                    ToastView(message: toastMessage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .transition(
                            .asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.92)),
                                removal: .opacity.combined(with: .scale(scale: 0.98))
                            )
                        )
                        .zIndex(4)
                }

                KeyboardDismissLayer {
                    focusedField = nil
                    keyboardIsVisible = false
                    UIApplication.shared.endEditing()
                }
                .allowsHitTesting(keyboardIsVisible)
                .ignoresSafeArea()
            }
            .blur(radius: showAppearanceBackdrop ? 10 : 0)
            .overlay {
                if showAppearanceBackdrop {
                    FloatingBackdropGlow(focus: appearanceGlowFocus)
                        .ignoresSafeArea()
                        .transition(.opacity)

                    Color.black
                        .opacity(0.14)
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .animation(appearanceBackdropAnimation, value: showAppearanceBackdrop)

            if showAppearanceSheet {
                GeometryReader { proxy in
                    let sheetTopInset = proxy.safeAreaInsets.top > 0 ? proxy.safeAreaInsets.top : 54

                    ZStack(alignment: .top) {
                        Color.clear
                            .contentShape(Rectangle())
                            .ignoresSafeArea()
                            .onTapGesture {
                                dismissAppearanceSheet()
                            }

                        AppearanceSheetView(
                            prompt: $appearancePrompt,
                            selectedStyle: $selectedAppearanceStyle,
                            selectedReferenceItem: $selectedReferenceItem,
                            referenceImage: $referenceImage
                        ) {
                            showToast("Please fill in the content first")
                        } onGenerate: {
                            hasAppearanceImage = true
                            generationStartedAt = Date()
                            isGeneratingImage = true
                            showImageToast = false
                            dismissAppearanceSheet()
                        }
                        .frame(height: max(0, proxy.size.height - sheetTopInset))
                        .offset(
                            y: sheetTopInset
                                + appearanceSheetDragOffset
                                + (reduceMotion || appearanceSheetIsPresented ? 0 : proxy.size.height)
                        )
                        .opacity(reduceMotion ? (appearanceSheetIsPresented ? 1 : 0) : 1)
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    appearanceSheetDragOffset = max(0, value.translation.height)
                                }
                                .onEnded { value in
                                    let shouldDismiss = value.translation.height > 88 || value.predictedEndTranslation.height > 160

                                    if shouldDismiss {
                                        dismissAppearanceSheet()
                                    } else {
                                        withAnimation(appearanceSheetRestoreAnimation) {
                                            appearanceSheetDragOffset = 0
                                        }
                                    }
                                }
                        )
                        .ignoresSafeArea(edges: .bottom)
                    }
                }
                .ignoresSafeArea()
                .zIndex(10)
            }

            if showVoiceSelector {
                SelectVoiceView(
                    selectedVoices: $selectedVoices,
                    pitch: $voicePitch,
                    speed: $voiceSpeed,
                    playingVoiceID: $playingVoiceID,
                    isPreviewLoading: $isVoicePreviewLoading,
                    isPreviewPlaying: $isVoicePreviewPlaying,
                    onDone: dismissVoiceSelector,
                    onBack: dismissVoiceSelector,
                    onToast: showToast
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(12)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
            if let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                keyboardFrame = frame
                keyboardHeight = max(0, UIScreen.main.bounds.maxY - frame.minY)
            }
            keyboardIsVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsVisible = false
            keyboardFrame = .zero
            keyboardHeight = 0
        }
        .onChange(of: characterName) { _, _ in
            nameValidationTip = ""
        }
        .onChange(of: settings) { _, _ in
            settingsValidationTip = ""
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(.dark)
    }

    private var selectedVoiceSummary: String {
        VoiceLibrary.summary(for: selectedVoices)
    }

    private var appearanceBackdropAnimation: Animation {
        .easeOut(duration: reduceMotion ? 0.16 : 0.24)
    }

    private var appearanceSheetPresentationAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.16) : .spring(duration: 0.55, bounce: 0)
    }

    private var appearanceSheetDismissAnimation: Animation {
        .easeOut(duration: reduceMotion ? 0.16 : 0.24)
    }

    private var appearanceSheetRestoreAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.45, bounce: 0)
    }

    private func presentVoiceSelector() {
        focusedField = nil
        UIApplication.shared.endEditing()

        withAnimation(.timingCurve(0.18, 0.92, 0.20, 1.0, duration: 0.34)) {
            showVoiceSelector = true
            keyboardIsVisible = false
        }
    }

    private func dismissVoiceSelector() {
        playingVoiceID = nil
        isVoicePreviewLoading = false
        isVoicePreviewPlaying = false

        withAnimation(.timingCurve(0.18, 0.92, 0.20, 1.0, duration: 0.34)) {
            showVoiceSelector = false
        }
    }

    private func presentAppearanceSheet(focus: CGPoint) {
        appearanceGlowFocus = focus
        appearanceSheetDragOffset = 0

        withAnimation(appearanceBackdropAnimation) {
            showAppearanceBackdrop = true
        }

        showAppearanceSheet = true
        appearanceSheetIsPresented = false

        DispatchQueue.main.async {
            withAnimation(appearanceSheetPresentationAnimation) {
                appearanceSheetIsPresented = true
            }
        }

    }

    private func dismissAppearanceSheet() {
        withAnimation(appearanceSheetDismissAnimation) {
            appearanceSheetDragOffset = 0
            appearanceSheetIsPresented = false
        }

        withAnimation(appearanceBackdropAnimation) {
            showAppearanceBackdrop = false
        }

        let removalDelay = reduceMotion ? 0.16 : 0.24
        DispatchQueue.main.asyncAfter(deadline: .now() + removalDelay) {
            guard !appearanceSheetIsPresented else { return }
            showAppearanceSheet = false
        }
    }

    private func handleCreateTap() {
        guard hasRequiredCreateContent else {
            showToast("Please fill in the content first")
            return
        }

        guard validateCreateContent() else { return }

        if hasAppearanceImage {
            showImageToast = false
        } else {
            showToast("Generate a Image to continue")
        }
    }

    private var hasRequiredCreateContent: Bool {
        !characterName.trimmedForValidation.isEmpty && !settings.trimmedForValidation.isEmpty
    }

    private func showToast(_ message: String) {
        toastMessage = message

        withAnimation(.snappy(duration: 0.28, extraBounce: 0)) {
            showImageToast = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard toastMessage == message else { return }

            withAnimation(.easeInOut(duration: 0.20)) {
                showImageToast = false
            }
        }
    }

    private func validateCreateContent() -> Bool {
        nameValidationTip = CreateContentValidator.tip(
            for: characterName,
            minimumLength: 2,
            shortTip: "Required"
        )
        settingsValidationTip = CreateContentValidator.tip(
            for: settings,
            minimumLength: 12,
            shortTip: "Too short"
        )

        return nameValidationTip.isEmpty && settingsValidationTip.isEmpty
    }

    private func resetCreateFlow() {
        focusedField = nil
        UIApplication.shared.endEditing()
        scrollIdleWorkItem?.cancel()

        withAnimation(.easeInOut(duration: 0.22)) {
            resetFormState()
            resetAppearanceState()
            resetInteractionState()
        }
    }

    private func handleBackTap() {
        resetCreateFlow()
        onBackToHome?()
    }

    private func resetFormState() {
        characterName = CreateRoleInitialState.characterName
        settings = CreateRoleInitialState.settings
        opening = CreateRoleInitialState.opening
        intro = CreateRoleInitialState.intro
        selectedVoices = VoiceLibrary.initialSelections
        voicePitch = 0.5
        voiceSpeed = 0.5
    }

    private func resetAppearanceState() {
        hasAppearanceImage = false
        isGeneratingImage = false
        generationStartedAt = Date()
        showAppearanceSheet = false
        showAppearanceBackdrop = false
        appearanceSheetIsPresented = false
        showVoiceSelector = false
        appearanceGlowFocus = CreateRoleInitialState.appearanceGlowFocus
        appearanceSheetDragOffset = 0
        appearancePrompt = ""
        selectedAppearanceStyle = 0
        selectedReferenceItem = nil
        referenceImage = nil
        playingVoiceID = nil
        isVoicePreviewLoading = false
        isVoicePreviewPlaying = false
        nameValidationTip = ""
        settingsValidationTip = ""
    }

    private func resetInteractionState() {
        showImageToast = false
        toastMessage = ""
        keyboardIsVisible = false
        keyboardFrame = .zero
        keyboardHeight = 0
        fieldFrames = [:]
        navigationGlassProgress = 0
        isPageScrolling = false
        lastScrollOffsetY = 0
        scrollHideDistance = 0
        resetScrollToken = UUID()
        scrollIdleWorkItem = nil
    }

    private func updateFloatingButtonVisibility(offsetY: Double) {
        let delta = offsetY - lastScrollOffsetY
        lastScrollOffsetY = offsetY

        guard abs(delta) > 0.5 else { return }

        scrollIdleWorkItem?.cancel()

        if delta > 0, offsetY > 24 {
            scrollHideDistance += delta
        } else if delta < 0 {
            scrollHideDistance = 0
        }

        if scrollHideDistance > 44, !isPageScrolling {
            withAnimation(buttonHideAnimation) {
                isPageScrolling = true
            }
        } else if delta < -8, isPageScrolling {
            withAnimation(buttonRevealAnimation) {
                isPageScrolling = false
            }
        }

        let workItem = DispatchWorkItem {
            scrollHideDistance = 0

            if isPageScrolling {
                withAnimation(buttonRevealAnimation) {
                    isPageScrolling = false
                }
            }
        }
        scrollIdleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65, execute: workItem)
    }

    private func adjustFocusedFieldForKeyboard(
        using frames: [CreateRoleFocusedField: CGRect]? = nil,
        delay: Double = 0.08
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard
                let focusedField,
                keyboardFrame != .zero,
                let fieldFrame = (frames ?? fieldFrames)[focusedField]
            else {
                return
            }

            UIApplication.shared.keepFieldFrameAboveKeyboard(
                fieldFrame: fieldFrame,
                keyboardFrame: keyboardFrame,
                spacing: 16
            )
        }
    }

    private func scheduleFocusedFieldKeyboardAdjustments(for field: CreateRoleFocusedField?) {
        guard field != .name else { return }

        for delay in [0.08, 0.24, 0.40] {
            adjustFocusedFieldForKeyboard(delay: delay)
        }
    }
}

private struct CreateRoleFormContent: View {
    @Binding var characterName: String
    @Binding var settings: String
    @Binding var opening: String
    @Binding var intro: String
    let selectedVoice: String
    let hasAppearanceImage: Bool
    let nameValidationTip: String
    let settingsValidationTip: String
    var focusedField: FocusState<CreateRoleFocusedField?>.Binding
    let onAppearanceTap: (CGPoint) -> Void
    let onVoiceTap: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            AppearancePicker(hasImage: hasAppearanceImage) { focus in
                onAppearanceTap(focus)
            }

            VStack(spacing: 16) {
                FormField(title: "Name", tip: nameValidationTip) {
                    SingleLineInput(
                        text: $characterName,
                        placeholder: CreateRolePlaceholder.name,
                        focusedField: focusedField,
                        field: .name
                    )
                }
                .id(CreateRoleFocusedField.name)
                .background(CreateRoleFieldFrameReader(field: .name))

                FormField(title: "Settings", tip: settingsValidationTip) {
                    MultiLineInput(
                        text: $settings,
                        placeholder: CreateRolePlaceholder.settings,
                        focusedField: focusedField,
                        field: .settings
                    )
                }
                .id(CreateRoleFocusedField.settings)
                .background(CreateRoleFieldFrameReader(field: .settings))

                FormField(title: "Opening") {
                    MultiLineInput(
                        text: $opening,
                        placeholder: CreateRolePlaceholder.opening,
                        focusedField: focusedField,
                        field: .opening
                    )
                }
                .id(CreateRoleFocusedField.opening)
                .background(CreateRoleFieldFrameReader(field: .opening))

                FormField(title: "Intro   (Optional)") {
                    MultiLineInput(
                        text: $intro,
                        placeholder: CreateRolePlaceholder.intro,
                        focusedField: focusedField,
                        field: .intro
                    )
                }
                .id(CreateRoleFocusedField.intro)
                .background(CreateRoleFieldFrameReader(field: .intro))

                FormField(title: "Voice") {
                    VoiceRow(selectedVoice: selectedVoice, action: onVoiceTap)
                }
            }
        }
    }
}

private struct GeneratingImageContent: View {
    let characterName: String
    let settings: String
    let opening: String
    let intro: String
    let selectedVoice: String
    let startedAt: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let progress = GeneratingProgress.progress(for: timeline.date, startedAt: startedAt)
            let percent = GeneratingProgress.displayPercent(for: timeline.date, startedAt: startedAt)
            let imageReveal = GeneratingProgress.imageReveal(for: timeline.date, startedAt: startedAt)
            let didRevealImage = imageReveal > 0.78

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    GeneratingProfileImageCard(progress: progress, imageReveal: imageReveal)

                    if didRevealImage {
                        HStack(spacing: 6) {
                            Text("Choose Image")

                            Text("(6)")
                        }
                        .font(.telkaMedium(size: 14))
                        .foregroundStyle(Color(hex: 0x0088FF))
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .padding(.vertical, 10)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                    } else {
                        HStack(spacing: 4) {
                            Text("Generating...")
                                .fixedSize(horizontal: true, vertical: false)

                            AnimatedPercentText(percent: percent)
                                .frame(width: 35, alignment: .leading)
                        }
                        .font(.telkaMedium(size: 14))
                        .foregroundStyle(.white.opacity(0.80))
                        .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24, alignment: .center)
                        .padding(.vertical, 10)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                    }
                }

                VStack(spacing: 16) {
                    ReadOnlyField(
                        title: "Name",
                        text: characterName,
                        placeholder: CreateRolePlaceholder.name,
                        height: 56,
                        showCount: false
                    )
                    ReadOnlyField(
                        title: "Setting",
                        text: settings,
                        placeholder: CreateRolePlaceholder.settings,
                        height: 180
                    )
                    ReadOnlyField(
                        title: "Opening",
                        text: opening,
                        placeholder: CreateRolePlaceholder.opening,
                        height: 180
                    )
                    ReadOnlyField(
                        title: "Intro   (Optional)",
                        text: intro,
                        placeholder: CreateRolePlaceholder.intro,
                        height: 180
                    )

                    FormField(title: "Voice") {
                        VoiceRow(selectedVoice: selectedVoice, action: {})
                    }
                }
            }
        }
    }
}

private struct AnimatedPercentText: View {
    let percent: Int

    var body: some View {
        let displayText = percent < 100 ? String(format: "%2d%%", percent) : "100%"
        let characters = Array(displayText)

        HStack(alignment: .center, spacing: 0) {
            ForEach(characters.indices, id: \.self) { index in
                AnimatedPercentCharacter(
                    character: characters[index],
                    width: characterWidth(for: characters[index]),
                    delay: Double(index) * 0.055
                )
            }
        }
        .frame(height: 24, alignment: .center)
    }

    private func characterWidth(for character: Character) -> CGFloat {
        character == "%" ? 15 : 10
    }
}

private struct AnimatedPercentCharacter: View {
    let character: Character
    let width: CGFloat
    let delay: Double

    @State private var isSettled = true
    @State private var animationToken = UUID()

    var body: some View {
        Text(String(character))
            .monospacedDigit()
            .frame(width: width, height: 24, alignment: .leading)
            .opacity(isSettled ? 1 : 0)
            .blur(radius: isSettled ? 0 : 2)
            .offset(y: isSettled ? 0 : 6)
            .onChange(of: character, initial: true) {
                let token = UUID()
                animationToken = token
                isSettled = false

                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard animationToken == token else { return }

                    withAnimation(.timingCurve(0.34, 1.45, 0.64, 1, duration: 0.42)) {
                        isSettled = true
                    }
                }
            }
    }
}

private enum GeneratingProgress {
    private static let duration: TimeInterval = 26.0
    private static let revealStartPhase = 0.90
    private static let revealDuration: TimeInterval = 1.8

    static func progress(for date: Date, startedAt: Date) -> Double {
        let phase = phase(for: date, startedAt: startedAt)

        if phase < 0.10 {
            return eased(phase / 0.10) * 0.02
        } else if phase < 0.34 {
            return 0.02 + eased((phase - 0.10) / 0.24) * 0.24
        } else if phase < 0.66 {
            return 0.26 + eased((phase - 0.34) / 0.32) * 0.52
        } else if phase < 0.90 {
            return 0.78 + eased((phase - 0.66) / 0.24) * 0.18
        } else if phase < 0.97 {
            return 0.96 + eased((phase - 0.90) / 0.07) * 0.04
        } else {
            return 1
        }
    }

    static func imageReveal(for date: Date, startedAt: Date) -> Double {
        let elapsed = elapsed(for: date, startedAt: startedAt)
        let revealStart = duration * revealStartPhase
        let revealPhase = (elapsed - revealStart) / revealDuration
        return smoother(revealPhase)
    }

    static func displayPercent(for date: Date, startedAt: Date) -> Int {
        let rawPercent = Int((progress(for: date, startedAt: startedAt) * 100).rounded())
        let checkpoints = [
            0, 4, 9, 16, 24, 33, 43, 52, 61, 70,
            78, 85, 90, 94, 97, 99, 100
        ]

        return checkpoints.last { $0 <= rawPercent } ?? 0
    }

    private static func phase(for date: Date, startedAt: Date) -> Double {
        min(max(elapsed(for: date, startedAt: startedAt) / duration, 0), 1)
    }

    private static func elapsed(for date: Date, startedAt: Date) -> Double {
        max(0, date.timeIntervalSinceReferenceDate - startedAt.timeIntervalSinceReferenceDate)
    }

    private static func eased(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private static func smoother(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }
}

private struct GeneratingProfileImageCard: View {
    let progress: Double
    let imageReveal: Double

    var body: some View {
        OrganicPixelRevealCard(progress: progress, imageReveal: imageReveal)
        .frame(width: 166, height: 256)
    }
}

private struct OrganicPixelRevealCard: View {
    let progress: Double
    let imageReveal: Double

    private let cornerRadius: CGFloat = 24
    private let cornerStyle: RoundedCornerStyle = .continuous

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let transitionPulse = OrganicPixelRevealCard.transitionPulse(time: time, reveal: imageReveal)
            let imagePreview = OrganicPixelRevealCard.imagePreview(for: progress)
            let imagePresence = max(imageReveal, imagePreview)
            let softReveal = OrganicPixelRevealCard.softReveal(for: imagePresence)
            let imageOpacity = min(1, 0.10 + softReveal * 0.90)
            let imageBlur = max(0, (1 - softReveal) * 18)
            let loadingOpacity = max(0, 1 - softReveal * 1.08)
            let pixelFade = max(0, 1 - softReveal * 1.18)
            let pixelOpacity = imageReveal <= 0
                ? 1
                : max(0, pixelFade * 0.86 + transitionPulse * 0.22)
            let progressOpacity = max(0, 1 - softReveal * 1.12)

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.12),
                                Color.white.opacity(0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .opacity(loadingOpacity)

                Image("generated-profile")
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: imageBlur)
                    .saturation(0.82 + imagePresence * 0.18)
                    .opacity(imageOpacity)

                OrganicPixelField(time: time)
                    .opacity(pixelOpacity)
                    .allowsHitTesting(false)

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: cornerStyle))
            .overlay {
                TopStartedRoundedRectSegment(startProgress: 0, endProgress: progress, cornerRadius: cornerRadius, cornerStyle: cornerStyle)
                    .stroke(
                        .white.opacity(0.92 * progressOpacity),
                        style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                    )
            }
        }
    }

    private static func transitionPulse(time: TimeInterval, reveal: Double) -> Double {
        guard reveal > 0, reveal < 1 else { return 0 }
        let wave = (sin(time * 10.0) + 1) / 2
        let envelope = sin(.pi * min(max(reveal, 0), 1))
        return pow(wave, 2.0) * envelope
    }

    private static func softReveal(for value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }

    private static func imagePreview(for progress: Double) -> Double {
        let phase = min(max((progress - 0.90) / 0.05, 0), 1)
        let eased = phase * phase * phase
        return eased * 0.34
    }
}

private struct TopStartedRoundedRectSegment: Shape {
    var startProgress: Double
    var endProgress: Double
    let cornerRadius: CGFloat
    let cornerStyle: RoundedCornerStyle

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(startProgress, endProgress) }
        set {
            startProgress = newValue.first
            endProgress = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let clampedStart = min(max(startProgress, 0), 1)
        let clampedEnd = min(max(endProgress, 0), 1)
        guard clampedEnd > clampedStart else { return Path() }

        let width = rect.width
        let height = rect.height
        let radius = min(cornerRadius, width / 2, height / 2)
        let smoothing = cornerStyle == .continuous ? 1.0 : 0.5522847498
        let arcLength = CGFloat.pi * radius / 2
        let segments: [(length: CGFloat, point: (CGFloat) -> CGPoint)] = [
            (width / 2 - radius, { t in CGPoint(x: width / 2 + (width / 2 - radius) * t, y: 0) }),
            (arcLength, { t in smoothCornerPoint(center: CGPoint(x: width - radius, y: radius), radius: radius, start: -.pi / 2, end: 0, smoothing: smoothing, t: t) }),
            (height - radius * 2, { t in CGPoint(x: width, y: radius + (height - radius * 2) * t) }),
            (arcLength, { t in smoothCornerPoint(center: CGPoint(x: width - radius, y: height - radius), radius: radius, start: 0, end: .pi / 2, smoothing: smoothing, t: t) }),
            (width - radius * 2, { t in CGPoint(x: width - radius - (width - radius * 2) * t, y: height) }),
            (arcLength, { t in smoothCornerPoint(center: CGPoint(x: radius, y: height - radius), radius: radius, start: .pi / 2, end: .pi, smoothing: smoothing, t: t) }),
            (height - radius * 2, { t in CGPoint(x: 0, y: height - radius - (height - radius * 2) * t) }),
            (arcLength, { t in smoothCornerPoint(center: CGPoint(x: radius, y: radius), radius: radius, start: .pi, end: .pi * 1.5, smoothing: smoothing, t: t) }),
            (width / 2 - radius, { t in CGPoint(x: radius + (width / 2 - radius) * t, y: 0) })
        ]

        let totalLength = segments.reduce(CGFloat.zero) { $0 + $1.length }
        var distance = CGFloat.zero
        let targetDistance = totalLength * CGFloat(clampedEnd)
        var path = Path()
        var didMove = false

        for segment in segments {
            let segmentStartDistance = distance
            let segmentEndDistance = distance + segment.length
            let drawStart = max(totalLength * CGFloat(clampedStart), segmentStartDistance)
            let drawEnd = min(targetDistance, segmentEndDistance)
            distance = segmentEndDistance

            guard drawEnd > drawStart else {
                if segmentStartDistance > targetDistance { break }
                continue
            }

            let localStart = (drawStart - segmentStartDistance) / max(segment.length, 0.001)
            let localEnd = (drawEnd - segmentStartDistance) / max(segment.length, 0.001)
            let samples = max(1, Int(ceil(segment.length / 3)))

            if !didMove {
                path.move(to: segment.point(localStart))
                didMove = true
            }

            for sample in 1...samples {
                let t = localStart + (localEnd - localStart) * CGFloat(sample) / CGFloat(samples)
                path.addLine(to: segment.point(t))

                if t >= localEnd {
                    break
                }
            }
        }

        return path
    }

    private func smoothCornerPoint(center: CGPoint, radius: CGFloat, start: CGFloat, end: CGFloat, smoothing: CGFloat, t: CGFloat) -> CGPoint {
        let angle = start + (end - start) * t
        let easedT = t * t * (3 - 2 * t)
        let smoothRadius = radius * (1 + (smoothing - 0.5522847498) * 0.08 * sin(.pi * easedT))
        return CGPoint(
            x: center.x + cos(angle) * smoothRadius,
            y: center.y + sin(angle) * smoothRadius
        )
    }
}

private struct OrganicPixelField: View {
    let time: TimeInterval

    private let columns = 14
    private let rows = 22

    var body: some View {
        GeometryReader { proxy in
            let cellWidth = proxy.size.width / CGFloat(columns)
            let cellHeight = proxy.size.height / CGFloat(rows)

            ForEach(0..<(columns * rows), id: \.self) { index in
                let column = index % columns
                let row = index / columns
                let seed = OrganicPixelField.seed(for: index)
                let block = OrganicPixelField.blockWave(time: time, column: column, row: row, seed: seed)
                let twinkle = OrganicPixelField.twinkle(time: time, column: column, row: row, seed: seed)
                let flow = OrganicPixelField.flowWave(time: time, column: column, row: row, seed: seed)
                let size = min(cellWidth, cellHeight) * 0.96
                let opacity = 0.006 + block * 0.032 + twinkle * 0.014 + flow * 0.018

                RoundedRectangle(cornerRadius: max(1.2, size * 0.16), style: .continuous)
                    .fill(OrganicPixelField.color(seed: seed).opacity(opacity))
                    .frame(width: size, height: size)
                    .position(
                        x: (CGFloat(column) + 0.5) * cellWidth,
                        y: (CGFloat(row) + 0.5) * cellHeight
                    )
            }
        }
        .clipped()
    }

    private static func seed(for index: Int) -> Double {
        let value = sin(Double(index) * 12.9898) * 43758.5453
        return value - floor(value)
    }

    private static func blockWave(time: TimeInterval, column: Int, row: Int, seed: Double) -> Double {
        let fineColumn = Double(column) * 0.78
        let fineRow = Double(row) * 0.64
        let value = sin(time * 1.18 + fineColumn + fineRow + seed * 3.4)
        let normalized = (value + 1) / 2
        return pow(normalized, 1.85)
    }

    private static func twinkle(time: TimeInterval, column: Int, row: Int, seed: Double) -> Double {
        let fineNoise = Double(column) * 1.46 + Double(row) * 1.08
        let value = sin(time * 1.62 + fineNoise + seed * 28.0)
        return pow((value + 1) / 2, 2.55)
    }

    private static func flowWave(time: TimeInterval, column: Int, row: Int, seed: Double) -> Double {
        let diagonal = Double(column - row) * 0.52
        let value = sin(time * 0.92 + diagonal + seed * 1.6)
        let normalized = (value + 1) / 2
        return pow(normalized, 2.2)
    }

    private static func color(seed: Double) -> Color {
        if seed < 0.34 {
            return Color.white
        } else if seed < 0.68 {
            return Color(hex: 0xE6DFFF)
        } else {
            return Color(hex: 0xD8E4FF)
        }
    }
}

private struct GeneratingSparkleIcon: View {
    let time: TimeInterval
    let progress: Double

    var body: some View {
        let basePhase = time * 1.05 + progress * .pi * 1.4
        let primaryOpacity = GeneratingSparkleIcon.opacity(basePhase)
        let secondaryOpacity = GeneratingSparkleIcon.opacity(basePhase + .pi)

        ZStack {
            Image("GenerateSparkleLarge")
                .resizable()
                .scaledToFit()
                .frame(width: 23, height: 23)
                .offset(x: 4, y: -4)
                .opacity(primaryOpacity)

            Image("GenerateSparkleSmall")
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .offset(x: -8, y: 8)
                .opacity(secondaryOpacity)
        }
            .frame(width: 32, height: 32)
    }

    private static func opacity(_ phase: Double) -> Double {
        let wave = (sin(phase) + 1) / 2
        return 0.32 + pow(wave, 2.2) * 0.68
    }
}

private struct GenerateSparkleAsset: View {
    let primaryGlow: Double
    let secondaryGlow: Double

    var body: some View {
        ZStack {
            SparkleShape()
                .fill(Color.white.opacity(primaryGlow))
                .frame(width: 26, height: 26)
                .offset(x: 4, y: -3)
                .shadow(color: .white.opacity(max(0, primaryGlow - 0.42) * 0.55), radius: 6, x: 0, y: 0)

            SparkleShape()
                .fill(Color.white.opacity(secondaryGlow))
                .frame(width: 11, height: 11)
                .offset(x: -10, y: 8)
                .shadow(color: .white.opacity(max(0, secondaryGlow - 0.38) * 0.60), radius: 4, x: 0, y: 0)
        }
        .frame(width: 44, height: 44)
    }
}

private struct SparkleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let longX = rect.width * 0.50
        let longY = rect.height * 0.50
        let shortX = rect.width * 0.14
        let shortY = rect.height * 0.14

        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - longY))
        path.addCurve(
            to: CGPoint(x: center.x + shortX, y: center.y - shortY),
            control1: CGPoint(x: center.x + rect.width * 0.03, y: center.y - rect.height * 0.30),
            control2: CGPoint(x: center.x + rect.width * 0.08, y: center.y - rect.height * 0.18)
        )
        path.addCurve(
            to: CGPoint(x: center.x + longX, y: center.y),
            control1: CGPoint(x: center.x + rect.width * 0.18, y: center.y - rect.height * 0.08),
            control2: CGPoint(x: center.x + rect.width * 0.30, y: center.y - rect.height * 0.03)
        )
        path.addCurve(
            to: CGPoint(x: center.x + shortX, y: center.y + shortY),
            control1: CGPoint(x: center.x + rect.width * 0.30, y: center.y + rect.height * 0.03),
            control2: CGPoint(x: center.x + rect.width * 0.18, y: center.y + rect.height * 0.08)
        )
        path.addCurve(
            to: CGPoint(x: center.x, y: center.y + longY),
            control1: CGPoint(x: center.x + rect.width * 0.08, y: center.y + rect.height * 0.18),
            control2: CGPoint(x: center.x + rect.width * 0.03, y: center.y + rect.height * 0.30)
        )
        path.addCurve(
            to: CGPoint(x: center.x - shortX, y: center.y + shortY),
            control1: CGPoint(x: center.x - rect.width * 0.03, y: center.y + rect.height * 0.30),
            control2: CGPoint(x: center.x - rect.width * 0.08, y: center.y + rect.height * 0.18)
        )
        path.addCurve(
            to: CGPoint(x: center.x - longX, y: center.y),
            control1: CGPoint(x: center.x - rect.width * 0.18, y: center.y + rect.height * 0.08),
            control2: CGPoint(x: center.x - rect.width * 0.30, y: center.y + rect.height * 0.03)
        )
        path.addCurve(
            to: CGPoint(x: center.x - shortX, y: center.y - shortY),
            control1: CGPoint(x: center.x - rect.width * 0.30, y: center.y - rect.height * 0.03),
            control2: CGPoint(x: center.x - rect.width * 0.18, y: center.y - rect.height * 0.08)
        )
        path.addCurve(
            to: CGPoint(x: center.x, y: center.y - longY),
            control1: CGPoint(x: center.x - rect.width * 0.08, y: center.y - rect.height * 0.18),
            control2: CGPoint(x: center.x - rect.width * 0.03, y: center.y - rect.height * 0.30)
        )
        path.closeSubpath()
        return path
    }
}
private struct ReadOnlyField: View {
    let title: String
    let text: String
    let placeholder: String
    let height: CGFloat
    var showCount = true
    private var isShowingPlaceholder: Bool {
        text.trimmedForValidation.isEmpty
    }
    private var displayText: String {
        isShowingPlaceholder ? placeholder : text
    }

    var body: some View {
        FormField(title: title) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))

                Text(displayText)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white.opacity(isShowingPlaceholder ? 0.20 : 0.80))
                    .lineSpacing(0)
                    .tracking(-0.43)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)

                if showCount {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text("\(isShowingPlaceholder ? 0 : text.count)/4000")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(.white.opacity(0.20))
                                .padding(.trailing, 16)
                                .padding(.bottom, 14)
                        }
                    }
                }
            }
            .frame(height: height)
            .clipped()
        }
    }
}

private struct CreateRoleBackground: View {
    var body: some View {
        FlowingGlowBackground()
            .ignoresSafeArea()
    }
}

private struct FlowingGlowBackground: View {
    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / 430
            let glowWidth = 553 * scale
            let glowHeight = 583 * scale
            let glowCenterY = (-346 + 583 / 2) * scale

            ZStack {
                Color(hex: 0x121212)

                FigmaBackgroundGlow(scale: scale)
                    .frame(width: glowWidth + 240 * scale, height: glowHeight + 240 * scale)
                    .position(x: proxy.size.width / 2 + 0.5 * scale, y: glowCenterY)
            }
            .clipped()
            .allowsHitTesting(false)
        }
    }
}

private struct FigmaBackgroundGlow: View {
    let scale: CGFloat

    var body: some View {
        ZStack {
            Ellipse()
                .stroke(Color(hex: 0x834159).opacity(0.22), lineWidth: 140 * scale)
                .frame(width: 553 * scale, height: 583 * scale)
                .blur(radius: 45 * scale)

            Ellipse()
                .fill(Color(hex: 0x0B011D))
                .frame(width: 553 * scale, height: 583 * scale)
                .overlay {
                    Ellipse()
                        .stroke(Color(hex: 0x834159).opacity(0.50), lineWidth: 80 * scale)
                        .padding(-40 * scale)
                }
                .compositingGroup()
                .blur(radius: 45 * scale)
        }
    }
}

private struct TopNavigationBar: View {
    let onBack: () -> Void

    var body: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "xmark")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .contentShape(Rectangle())
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .frame(height: 64)
        .padding(.top, 0)
    }
}

private struct LiquidGlassNavigationBackground: View {
    let progress: Double

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .glassEffect(.regular.tint(Color(hex: 0x121212).opacity(0.42)), in: Rectangle())
            .opacity(progress)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.96), location: 0.00),
                        .init(color: .black.opacity(0.96), location: 0.32),
                        .init(color: .black.opacity(0.72), location: 0.46),
                        .init(color: .black.opacity(0.28), location: 0.64),
                        .init(color: .black.opacity(0.00), location: 0.88),
                        .init(color: .black.opacity(0.00), location: 1.00)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

private struct VisualEffectBlur: UIViewRepresentable {
    let style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
    }
}

private struct FloatingBackdropGlow: View {
    let focus: CGPoint

    var body: some View {
        GeometryReader { proxy in
            let baseX = proxy.size.width * min(max(focus.x, 0.12), 0.88)
            let baseY = proxy.size.height * min(max(focus.y, 0.12), 0.72)

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(hex: 0x0B011D))
                .frame(width: 166, height: 256)
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color(hex: 0x834159).opacity(0.50), lineWidth: 80)
                        .padding(-40)
                }
                .compositingGroup()
                .blur(radius: 120)
                .position(x: baseX, y: baseY)
                .allowsHitTesting(false)
        }
    }
}

private struct AppearancePicker: View {
    let hasImage: Bool
    let action: (CGPoint) -> Void

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.white.opacity(0.20))
                        .frame(width: 166, height: 256)

                    if hasImage {
                        LinearGradient(
                            colors: [
                                Color(red: 0.72, green: 0.61, blue: 0.86),
                                Color(red: 0.33, green: 0.40, blue: 0.51)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .frame(width: 166, height: 256)

                        Image(systemName: "sparkles")
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let normalizedFocus = CGPoint(
                                x: value.location.x / max(proxy.size.width, 1),
                                y: value.location.y / max(proxy.size.height, 1)
                            )
                            action(normalizedFocus)
                        }
                )

                Text("Click to set appearance")
                    .font(.telkaMedium(size: 14))
                    .foregroundStyle(.white.opacity(0.70))
                    .frame(height: 37)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, minHeight: 301, maxHeight: 301)
    }
}

private struct AppearanceSheetView: View {
    @Binding var prompt: String
    @Binding var selectedStyle: Int
    @Binding var selectedReferenceItem: PhotosPickerItem?
    @Binding var referenceImage: UIImage?
    @State private var promptValidationTip = ""
    @State private var keyboardFrame = CGRect.zero
    @State private var promptFrame = CGRect.zero
    let onMissingContent: () -> Void
    let onGenerate: () -> Void

    private let styles = ["Default", "Style 1", "Style 2", "Style 3"]
    private let keyboardSpacing: CGFloat = 16

    var body: some View {
        GeometryReader { sheetProxy in
            let verticalScale = min(1, sheetProxy.size.height / 878)
            let navTopSpacing = 10 * verticalScale
            let sectionTopSpacing = 24 * verticalScale
            let promptHeight = adjustedPromptHeight(
                sheetFrame: sheetProxy.frame(in: .global),
                navTopSpacing: navTopSpacing,
                sectionTopSpacing: sectionTopSpacing,
                basePromptHeight: 421 * verticalScale
            )
            let styleTopSpacing = 24 * verticalScale
            let buttonBottomPadding = 42 * verticalScale

            ZStack(alignment: .top) {
                VisualEffectBlur(style: .systemUltraThinMaterialDark)
                    .overlay(Color.black.opacity(0.60))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIApplication.shared.endEditing()
                    }

                VStack(spacing: 0) {
                    Capsule()
                        .fill(Color.white.opacity(0.20))
                        .frame(width: 36, height: 5)
                        .padding(.top, 6)

                    ZStack {
                        Text("Appearance")
                            .font(.telkaMedium(size: 17))
                            .foregroundStyle(.white)
                            .frame(maxWidth: 278)
                    }
                    .frame(height: 44)
                    .padding(.top, navTopSpacing)

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            Text("Image prompt")
                                .font(.telkaRegular(size: 14))
                                .foregroundStyle(.white.opacity(0.40))

                            Spacer(minLength: 8)

                            if !promptValidationTip.isEmpty {
                                Text(promptValidationTip)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(Color(hex: 0xFE3824))
                                    .lineLimit(1)
                            }
                        }
                            .frame(height: 40)
                            .padding(.horizontal, 16)

                        AppearancePromptEditor(
                            prompt: $prompt,
                            selectedReferenceItem: $selectedReferenceItem,
                            referenceImage: $referenceImage
                        )
                        .frame(height: promptHeight)
                        .background(
                            GeometryReader { promptProxy in
                                Color.clear.preference(
                                    key: AppearancePromptFramePreferenceKey.self,
                                    value: promptProxy.frame(in: .global)
                                )
                            }
                        )
                        .animation(.easeOut(duration: 0.25), value: promptHeight)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, sectionTopSpacing)

                    GeometryReader { proxy in
                        let horizontalPadding: CGFloat = 16
                        let spacing: CGFloat = 16
                        let availableWidth = proxy.size.width - horizontalPadding * 2
                        let itemWidth = (availableWidth - spacing * CGFloat(styles.count - 1)) / CGFloat(styles.count)

                        HStack(spacing: spacing) {
                            ForEach(styles.indices, id: \.self) { index in
                                AppearanceStyleOption(
                                    title: styles[index],
                                    index: index,
                                    size: itemWidth,
                                    isSelected: selectedStyle == index
                                ) {
                                    selectedStyle = index
                                }
                            }
                        }
                        .padding(.horizontal, horizontalPadding)
                    }
                    .frame(height: 112)
                    .padding(.top, styleTopSpacing)

                    Spacer(minLength: 0)

                    Button {
                        guard !prompt.trimmedForValidation.isEmpty else {
                            onMissingContent()
                            return
                        }

                        guard validatePrompt() else { return }
                        onGenerate()
                    } label: {
                        HStack(spacing: 8) {
                            Image("GenerateSparkle")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 24, height: 24)

                            Text("Generate")
                                .font(.telkaMedium(size: 17))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(Color(hex: 0x0088FF), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.bottom, buttonBottomPadding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38))
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }

            withAnimation(.easeOut(duration: 0.25)) {
                keyboardFrame = frame
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardFrame = .zero
            }
        }
        .onPreferenceChange(AppearancePromptFramePreferenceKey.self) { frame in
            promptFrame = frame
        }
        .onChange(of: selectedReferenceItem) { _, newItem in
            guard let newItem else { return }

            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await MainActor.run {
                        referenceImage = image
                    }
                }
            }
        }
        .onChange(of: prompt) { _, _ in
            promptValidationTip = ""
        }
    }

    private func adjustedPromptHeight(
        sheetFrame: CGRect,
        navTopSpacing: CGFloat,
        sectionTopSpacing: CGFloat,
        basePromptHeight: CGFloat
    ) -> CGFloat {
        guard keyboardFrame != .zero else { return basePromptHeight }

        let fallbackPromptTop = sheetFrame.minY
            + 11
            + navTopSpacing
            + 44
            + sectionTopSpacing
            + 40
        let promptTop = promptFrame == .zero ? fallbackPromptTop : promptFrame.minY
        let targetBottom = keyboardFrame.minY - keyboardSpacing
        let availableHeight = targetBottom - promptTop

        return min(basePromptHeight, max(0, availableHeight))
    }

    private func validatePrompt() -> Bool {
        promptValidationTip = CreateContentValidator.tip(
            for: prompt,
            minimumLength: 12,
            shortTip: "Too short"
        )

        return promptValidationTip.isEmpty
    }
}

private struct AppearancePromptEditor: View {
    @Binding var prompt: String
    @Binding var selectedReferenceItem: PhotosPickerItem?
    @Binding var referenceImage: UIImage?
    @State private var referenceControlExpanded = false
    @State private var displayedReferenceImage: UIImage?
    @State private var isClearingReference = false
    private let limit = 4000
    private let placeholder = "You are my boyfriend who hates u... he’s always busy in “Work” with his secretary...\u{200B}she’s kim"
    private let promptInset: CGFloat = 16
    private let referenceCollapsedWidth: CGFloat = 121
    private let referenceExpandedWidth: CGFloat = 159
    private let referenceControlAnimation = Animation.timingCurve(0.20, 0.0, 0.16, 1.0, duration: 0.36)
    private var hasDisplayedReference: Bool {
        displayedReferenceImage != nil
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))

            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.white.opacity(0.20))
                        .lineSpacing(0)
                        .tracking(-0.43)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 1)
                        .padding(.trailing, 2)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $prompt)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white.opacity(0.80))
                    .tracking(-0.43)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .textInputAutocapitalization(.sentences)
                    .padding(.horizontal, -4)
                    .padding(.vertical, -8)
                    .onChange(of: prompt) { _, newValue in
                        if newValue.count > limit {
                            prompt = String(newValue.prefix(limit))
                        }
                    }
            }
            .padding(promptInset)
            .padding(.bottom, 62)

            VStack {
                Spacer()
                HStack {
                    HStack(spacing: 8) {
                        PhotosPicker(selection: $selectedReferenceItem, matching: .images) {
                            HStack(spacing: 8) {
                                ReferenceImageSlot(
                                    image: displayedReferenceImage,
                                    isClearing: isClearingReference
                                )

                                Text("Image ref")
                                    .font(.system(size: 14, weight: .regular))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundStyle(.white.opacity(0.80))
                            .frame(height: 44)
                        }
                        .buttonStyle(.plain)

                        if hasDisplayedReference {
                            Button {
                                isClearingReference = true

                                withAnimation(referenceControlAnimation) {
                                    referenceControlExpanded = false
                                }

                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                                    var transaction = Transaction()
                                    transaction.disablesAnimations = true

                                    withTransaction(transaction) {
                                        selectedReferenceItem = nil
                                        referenceImage = nil
                                        displayedReferenceImage = nil
                                        isClearingReference = false
                                    }
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.86))
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                            .frame(width: referenceControlExpanded ? 32 : 0)
                            .opacity(referenceControlExpanded ? 1 : 0)
                            .clipped()
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(width: !hasDisplayedReference || !referenceControlExpanded ? referenceCollapsedWidth : referenceExpandedWidth, height: 44, alignment: .leading)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .animation(referenceControlAnimation, value: referenceControlExpanded)
                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.bottom, 16)
            }
        }
        .clipped()
        .onChange(of: referenceImage) { _, newImage in
            guard let newImage else {
                guard !isClearingReference else { return }
                guard !referenceControlExpanded else { return }
                displayedReferenceImage = nil
                return
            }

            withAnimation(referenceControlAnimation) {
                displayedReferenceImage = newImage
                referenceControlExpanded = true
            }
        }
    }
}

private struct ReferenceImageSlot: View {
    let image: UIImage?
    let isClearing: Bool
    @State private var thumbnailVisible = false

    var body: some View {
        ZStack {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 16, weight: .medium))
                .opacity(iconOpacity)
                .scaleEffect(thumbnailVisible ? 0.92 : 1)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .opacity(thumbnailVisible && !isClearing ? 1 : 0)
                    .scaleEffect(thumbnailVisible && !isClearing ? 1 : 0.94)
            }
        }
        .frame(width: 32, height: 32)
        .animation(.easeOut(duration: 0.22), value: thumbnailVisible)
        .animation(.easeInOut(duration: 0.18), value: isClearing)
        .onChange(of: image != nil, initial: true) { _, hasImage in
            guard hasImage else {
                thumbnailVisible = false
                return
            }

            thumbnailVisible = false
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.22)) {
                    thumbnailVisible = true
                }
            }
        }
    }

    private var iconOpacity: Double {
        if image == nil {
            return isClearing ? 0 : 1
        }

        return thumbnailVisible || isClearing ? 0 : 1
    }
}

private struct AppearanceStyleOption: View {
    let title: String
    let index: Int
    let size: CGFloat
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AppearanceThumbnail(index: index)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 2)
                    )

                Text(title)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.20))
                    .frame(width: size)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct AppearanceThumbnail: View {
    let index: Int

    var body: some View {
        Image("style")
            .resizable()
            .scaledToFill()
            .clipped()
    }
}

private struct FormField<Content: View>: View {
    let title: String
    var tip = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.telkaRegular(size: 14))
                    .foregroundStyle(.white.opacity(0.40))

                Spacer(minLength: 8)

                if !tip.isEmpty {
                    Text(tip)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(Color(hex: 0xFE3824))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .padding(.horizontal, 16)

            content
        }
    }
}

private struct SingleLineInput: View {
    @Binding var text: String
    let placeholder: String
    var focusedField: FocusState<CreateRoleFocusedField?>.Binding
    let field: CreateRoleFocusedField

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))

            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white.opacity(0.20))
                    .tracking(-0.43)
                    .padding(.horizontal, 16)
            }

            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(.white.opacity(0.80))
                .tracking(-0.43)
                .padding(.horizontal, 16)
                .focused(focusedField, equals: field)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            guard focusedField.wrappedValue != field else { return }
            focusedField.wrappedValue = field
        }
        .frame(height: 56)
    }
}

private struct MultiLineInput: View {
    @Binding var text: String
    let placeholder: String
    var focusedField: FocusState<CreateRoleFocusedField?>.Binding
    let field: CreateRoleFocusedField
    private let limit = 4000

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.08))

            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(.white.opacity(0.20))
                        .lineSpacing(0)
                        .tracking(-0.43)
                        .lineLimit(5)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextEditor(text: $text)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white.opacity(0.80))
                    .tracking(-0.43)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, -5)
                    .padding(.vertical, -8)
                    .focused(focusedField, equals: field)
                    .onChange(of: text) { _, newValue in
                        if newValue.count > limit {
                            text = String(newValue.prefix(limit))
                        }
                    }
            }
            .padding(16)
            .padding(.bottom, 26)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Text("\(text.isEmpty ? 0 : min(text.count, limit))/\(limit)")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.white.opacity(0.20))
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture {
            guard focusedField.wrappedValue != field else { return }
            focusedField.wrappedValue = field
        }
        .clipped()
        .frame(height: 180)
    }
}

private struct KeyboardDismissLayer: UIViewRepresentable {
    let onDismiss: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tapGesture.cancelsTouchesInView = false
        tapGesture.delegate = context.coordinator
        view.addGestureRecognizer(tapGesture)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onDismiss = onDismiss
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        @objc func handleTap() {
            onDismiss()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            var touchedView: UIView? = touch.view

            while let view = touchedView {
                if view is UIControl || view is UITextView || view is UITextField {
                    return false
                }

                touchedView = view.superview
            }

            return true
        }
    }
}

private struct VoiceRow: View {
    let selectedVoice: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)

                Text("Character Voice")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white)
                    .tracking(-0.43)
                    .lineLimit(1)

                Spacer()

                Text(selectedVoice)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(.white.opacity(0.40))
                    .tracking(-0.43)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.40))
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SelectVoiceView: View {
    @Binding var selectedVoices: [VoiceMixSelection]
    @Binding var pitch: Double
    @Binding var speed: Double
    @Binding var playingVoiceID: String?
    @Binding var isPreviewLoading: Bool
    @Binding var isPreviewPlaying: Bool

    let onDone: () -> Void
    let onBack: () -> Void
    let onToast: (String) -> Void

    @State private var selectedCategory: VoiceCategory = .all

    private var filteredPresets: [VoicePreset] {
        VoiceLibrary.presets.filter { preset in
            selectedCategory == .all || preset.category == selectedCategory
        }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color(hex: 0x121212).ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 28) {
                        VoiceMixSection(
                            selectedVoices: $selectedVoices,
                            pitch: $pitch,
                            speed: $speed,
                            isPreviewLoading: $isPreviewLoading,
                            isPreviewPlaying: $isPreviewPlaying,
                            onPlayVoice: playVoice,
                            onRemove: removeVoice,
                            onPreview: previewVoiceMix
                        )

                        VoiceListSection(
                            selectedCategory: $selectedCategory,
                            presets: filteredPresets,
                            selectedVoices: selectedVoices,
                            playingVoiceID: playingVoiceID,
                            onPlay: playVoice,
                            onToggle: toggleVoice
                        )
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 132)
                }

                LinearGradient(
                    colors: [Color(hex: 0x121212).opacity(0), Color(hex: 0x121212)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 114)
                .overlay(alignment: .bottom) {
                    Button(action: onDone) {
                        Text("Done")
                            .font(.telkaMedium(size: 17))
                        .foregroundStyle(.white)
                        .frame(height: 56)
                        .frame(maxWidth: .infinity)
                        .background(Color(hex: 0x0088FF), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 42)
                }
                    .buttonStyle(.plain)
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Select Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    .accessibilityLabel("Back")
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func toggleVoice(_ preset: VoicePreset) {
        if let index = selectedVoices.firstIndex(where: { $0.preset.id == preset.id }) {
            selectedVoices.remove(at: index)
            normalizeWeights()
            return
        }

        guard selectedVoices.count < VoiceLibrary.maxMixedVoices else {
            onToast("You can mix up to 3 voices")
            return
        }

        selectedVoices.append(VoiceMixSelection(preset: preset, weight: selectedVoices.isEmpty ? 1 : 0.5))
        normalizeWeights()
    }

    private func removeVoice(_ selection: VoiceMixSelection) {
        selectedVoices.removeAll { $0.id == selection.id }
        normalizeWeights()
    }

    private func normalizeWeights() {
        guard !selectedVoices.isEmpty else { return }

        if selectedVoices.count == 1 {
            selectedVoices[0].weight = 1
        } else {
            let total = max(selectedVoices.reduce(0) { $0 + $1.weight }, 0.01)
            for index in selectedVoices.indices {
                selectedVoices[index].weight = selectedVoices[index].weight / total
            }
        }
    }

    private func playVoice(_ preset: VoicePreset) {
        isPreviewLoading = false
        isPreviewPlaying = false
        playingVoiceID = playingVoiceID == preset.id ? nil : preset.id
    }

    private func previewVoiceMix() {
        guard !selectedVoices.isEmpty else {
            onToast("Select a voice first")
            return
        }

        if isPreviewPlaying {
            isPreviewPlaying = false
            isPreviewLoading = false
            return
        }

        isPreviewLoading = true
        playingVoiceID = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            guard isPreviewLoading else { return }
            isPreviewLoading = false
            isPreviewPlaying = true
        }
    }
}

private enum VoiceMixMotion {
    static let response = Animation.timingCurve(0.24, 0.0, 0.20, 1.0, duration: 0.34)
    static let quickExit = Animation.easeOut(duration: 0.10)
    static let contentFadeIn = Animation.easeOut(duration: 0.18).delay(0.22)
    static let contentFadeOut = Animation.easeOut(duration: 0.08)
    static let emptyHeight: CGFloat = 56
}

private struct VoiceMixContentHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = VoiceMixMotion.emptyHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let nextValue = nextValue()
        if nextValue > 0 {
            value = max(value, nextValue)
        }
    }
}

private struct VoiceMixHeightReader: View {
    var body: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: VoiceMixContentHeightPreferenceKey.self,
                value: proxy.size.height
            )
        }
    }
}

private struct VoiceMixSection: View {
    @Binding var selectedVoices: [VoiceMixSelection]
    @Binding var pitch: Double
    @Binding var speed: Double
    @Binding var isPreviewLoading: Bool
    @Binding var isPreviewPlaying: Bool

    let onPlayVoice: (VoicePreset) -> Void
    let onRemove: (VoiceMixSelection) -> Void
    let onPreview: () -> Void

    @State private var contentHeight = VoiceMixMotion.emptyHeight
    @State private var showsControls = false

    private var hasSelectedVoices: Bool {
        !selectedVoices.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionTabTitle("Voice mix")

            ZStack(alignment: .top) {
                VoiceMixEmptyState()
                    .opacity(hasSelectedVoices ? 0 : 1)
                    .allowsHitTesting(!hasSelectedVoices)

                if hasSelectedVoices {
                    VoiceMixControls(
                        selectedVoices: $selectedVoices,
                        pitch: $pitch,
                        speed: $speed,
                        isPreviewLoading: isPreviewLoading,
                        isPreviewPlaying: isPreviewPlaying,
                        onPlayVoice: onPlayVoice,
                        onRemove: onRemove,
                        onPreview: onPreview
                    )
                    .opacity(showsControls ? 1 : 0)
                    .allowsHitTesting(showsControls)
                    .background(VoiceMixHeightReader())
                }

                if !hasSelectedVoices {
                    VoiceMixEmptyState()
                        .hidden()
                        .background(VoiceMixHeightReader())
                }
            }
            .frame(height: contentHeight, alignment: .top)
            .padding(.horizontal, 16)
            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)
            .animation(VoiceMixMotion.response, value: hasSelectedVoices)
            .animation(VoiceMixMotion.response, value: selectedVoices.count)
            .onPreferenceChange(VoiceMixContentHeightPreferenceKey.self) { height in
                withAnimation(VoiceMixMotion.response) {
                    contentHeight = height
                }
            }
            .onChange(of: hasSelectedVoices) { _, isActive in
                if isActive {
                    showsControls = false
                    withAnimation(VoiceMixMotion.contentFadeIn) {
                        showsControls = true
                    }
                } else {
                    withAnimation(VoiceMixMotion.contentFadeOut) {
                        showsControls = false
                    }
                }
            }
            .onAppear {
                showsControls = hasSelectedVoices
            }
            .background {
                if hasSelectedVoices {
                    VoiceMixControls(
                        selectedVoices: $selectedVoices,
                        pitch: $pitch,
                        speed: $speed,
                        isPreviewLoading: isPreviewLoading,
                        isPreviewPlaying: isPreviewPlaying,
                        onPlayVoice: onPlayVoice,
                        onRemove: onRemove,
                        onPreview: onPreview
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .background(VoiceMixHeightReader())
                } else {
                    VoiceMixEmptyState()
                        .hidden()
                        .background(VoiceMixHeightReader())
                }
            }
        }
    }
}

private struct VoiceMixEmptyState: View {
    var body: some View {
        Text("Select up to 3 voices to mix")
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(.white.opacity(0.40))
            .frame(maxWidth: .infinity)
            .frame(height: VoiceMixMotion.emptyHeight)
    }
}

private struct VoiceMixControls: View {
    @Binding var selectedVoices: [VoiceMixSelection]
    @Binding var pitch: Double
    @Binding var speed: Double

    let isPreviewLoading: Bool
    let isPreviewPlaying: Bool
    let onPlayVoice: (VoicePreset) -> Void
    let onRemove: (VoiceMixSelection) -> Void
    let onPreview: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            selectionRows

            VStack(spacing: 12) {
                VoiceAdjustmentSlider(title: "Pitch", lowLabel: "Low", highLabel: "High", value: $pitch)

                VoiceAdjustmentSlider(title: "Speed", lowLabel: "Slow", highLabel: "Fast", value: $speed)
            }
            .padding(.top, 16)
            .padding(.bottom, 16)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)

            PreviewVoiceButton(
                isLoading: isPreviewLoading,
                isPlaying: isPreviewPlaying,
                action: onPreview
            )
        }
    }

    @ViewBuilder
    private var selectionRows: some View {
        VStack(spacing: selectedVoices.count > 1 ? 12 : 0) {
            ForEach($selectedVoices) { $selection in
                VoiceWeightRow(
                    selection: $selection,
                    showsWeightControls: selectedVoices.count > 1,
                    onPlay: onPlayVoice,
                    onRemove: onRemove
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.top, 8)
        .animation(VoiceMixMotion.response, value: selectedVoices.count)
    }
}

private struct SectionTabTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.telkaMedium(size: 17))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 52)
            .padding(.leading, 32)
    }
}

private struct SingleVoiceMixHeader: View {
    let selection: VoiceMixSelection
    let onPlay: (VoicePreset) -> Void
    let onRemove: (VoiceMixSelection) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button {
                onPlay(selection.preset)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)

            Text(selection.preset.name)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .tracking(-0.43)
                .lineLimit(1)

            Spacer()

            Button {
                onRemove(selection)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.white.opacity(0.20))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct VoiceWeightRow: View {
    @Binding var selection: VoiceMixSelection
    let showsWeightControls: Bool
    let onPlay: (VoicePreset) -> Void
    let onRemove: (VoiceMixSelection) -> Void

    var body: some View {
        VStack(spacing: showsWeightControls ? 8 : 0) {
            SingleVoiceMixHeader(selection: selection, onPlay: onPlay, onRemove: onRemove)
                .frame(height: 40)
                .transaction { transaction in
                    transaction.animation = nil
                }

            if showsWeightControls {
                HStack(spacing: 8) {
                    VoiceWeightSlider(value: $selection.weight)
                        .frame(height: 44)
                }
                .padding(.leading, 8)
                .transition(.opacity.animation(VoiceMixMotion.contentFadeIn))
            }
        }
        .frame(height: showsWeightControls ? 92 : 40, alignment: .top)
        .clipped()
        .animation(VoiceMixMotion.response, value: showsWeightControls)
    }
}

private struct VoiceAdjustmentSlider: View {
    let title: String
    let lowLabel: String
    let highLabel: String
    @Binding var value: Double

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 22)
                .padding(.leading, 4)

            VoiceTickSlider(value: $value)
                .frame(height: 44)

            HStack {
                Text(lowLabel)
                Spacer()
                Text(highLabel)
            }
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(.white.opacity(0.40))
            .frame(height: 18)
            .padding(.horizontal, 4)
        }
    }
}

private struct VoiceTickSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                VoiceDesignedSliderTrack()
                    .frame(height: VoiceSliderStyle.designedTrackHeight)

                SystemThumbSlider(value: $value, range: 0...1)
            }
        }
    }
}

private struct VoiceWeightSlider: View {
    @Binding var value: Double

    private let valueWidth: CGFloat = 42

    var body: some View {
        HStack(spacing: 8) {
            Slider(value: $value, in: 0.1...1)
                .tint(VoiceSliderStyle.highlightColor)

            Text("\(Int(min(max(value, 0.1), 1) * 100))%")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.white.opacity(0.58))
                .monospacedDigit()
                .frame(width: valueWidth, alignment: .trailing)
        }
    }
}

private enum VoiceSliderStyle {
    static let highlightColor = Color(hex: 0x0A9BFF)
    static let designedTrackHeight: CGFloat = 24
    static let designedTrackCornerRadius: CGFloat = 12
}

private struct VoiceDesignedSliderTrack: View {
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: VoiceSliderStyle.designedTrackCornerRadius, style: .continuous)
                .fill(Color.white.opacity(0.04))

            HStack(spacing: 0) {
                ForEach(0..<9, id: \.self) { index in
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 2, height: index % 4 == 0 ? 8 : 6)

                    if index < 8 {
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 26)
        }
        .clipShape(RoundedRectangle(cornerRadius: VoiceSliderStyle.designedTrackCornerRadius, style: .continuous))
    }
}

private struct SystemThumbSlider: UIViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>

    func makeUIView(context: Context) -> UISlider {
        let slider = UISlider(frame: .zero)
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.value = Float(value)
        slider.minimumTrackTintColor = .clear
        slider.maximumTrackTintColor = .clear
        slider.addTarget(context.coordinator, action: #selector(Coordinator.valueChanged(_:)), for: .valueChanged)
        return slider
    }

    func updateUIView(_ slider: UISlider, context: Context) {
        slider.minimumValue = Float(range.lowerBound)
        slider.maximumValue = Float(range.upperBound)
        slider.minimumTrackTintColor = .clear
        slider.maximumTrackTintColor = .clear

        let nextValue = Float(value)
        if abs(slider.value - nextValue) > 0.0001 {
            slider.value = nextValue
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }

    final class Coordinator: NSObject {
        @Binding private var value: Double

        init(value: Binding<Double>) {
            _value = value
        }

        @objc func valueChanged(_ sender: UISlider) {
            value = Double(sender.value)
        }
    }
}

private struct PreviewVoiceButton: View {
    let isLoading: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .tint(.white)
                        .frame(width: 24, height: 24)
                } else {
                    Image(systemName: isPlaying ? "arrow.counterclockwise" : "headphones")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)

                    Text(isPlaying ? "Replay" : "Tap to listen")
                        .font(.telkaMedium(size: 14))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
        }
        .buttonStyle(.plain)
    }
}

private struct VoiceListSection: View {
    @Binding var selectedCategory: VoiceCategory
    let presets: [VoicePreset]
    let selectedVoices: [VoiceMixSelection]
    let playingVoiceID: String?
    let onPlay: (VoicePreset) -> Void
    let onToggle: (VoicePreset) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                ForEach(VoiceCategory.allCases) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        Text(category.rawValue)
                            .font(.telkaMedium(size: 17))
                            .foregroundStyle(selectedCategory == category ? .white : .white.opacity(0.36))
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding(.leading, 32)

            VStack(spacing: 10) {
                ForEach(presets) { preset in
                    SelectVoiceListRow(
                        preset: preset,
                        isSelected: selectedVoices.contains { $0.preset.id == preset.id },
                        isPlaying: playingVoiceID == preset.id,
                        onPlay: { onPlay(preset) },
                        onToggle: { onToggle(preset) }
                    )
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

private struct SelectVoiceListRow: View {
    let preset: VoicePreset
    let isSelected: Bool
    let isPlaying: Bool
    let onPlay: () -> Void
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlay) {
                Image(systemName: isPlaying ? "waveform" : "play.fill")
                    .font(.system(size: isPlaying ? 15 : 16, weight: .medium))
                    .foregroundStyle(isPlaying ? .white : .white.opacity(0.92))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                Text(preset.name)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected || isPlaying ? .white : .white.opacity(0.82))
                    .tracking(-0.43)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(preset.primaryTrait)
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 1, height: 12)
                    Text(preset.secondaryTrait)
                }
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.40))
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                onToggle()
            }

            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: isSelected ? 0 : 2)
                        .frame(width: 20, height: 20)

                    if isSelected {
                        Circle()
                            .fill(.white)
                            .frame(width: 20, height: 20)

                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color(hex: 0x121212))
                    }
                }
                .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(height: 72)
        .background(Color.white.opacity(isSelected ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PrimaryCreateButton: View {
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 8) {
                Text("Create")
                    .font(.telkaMedium(size: 17))
            }
            .foregroundStyle(.white)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .background(Color(hex: 0x0088FF), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct ToastView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 17, weight: .regular))
            .foregroundStyle(.white)
            .tracking(-0.43)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: 270, minHeight: 48)
            .background(Color(hex: 0x444444), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private enum TelkaFont {
    static let regularName = "TelkaTRIAL-Wide-Regular"
    static let mediumName = "TelkaTRIAL-Wide-Medium"
    static let boldName = "TelkaTRIAL-Wide-Bold"
    private static var didRegister = false

    static func registerFonts() {
        guard !didRegister else { return }
        didRegister = true

        [
            "TelkaTRIAL-Wide-Regular",
            "TelkaTRIAL-Wide-Medium",
            "TelkaTRIAL-Wide-Bold"
        ].forEach { fileName in
            guard let url = Bundle.main.url(forResource: fileName, withExtension: "otf") else { return }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

private extension Font {
    static func telkaRegular(size: CGFloat) -> Font {
        .custom(TelkaFont.regularName, size: size)
    }

    static func telkaMedium(size: CGFloat) -> Font {
        .custom(TelkaFont.mediumName, size: size)
    }

    static func telkaBold(size: CGFloat) -> Font {
        .custom(TelkaFont.boldName, size: size)
    }
}

private extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

private extension String {
    var trimmedForValidation: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension UIApplication {
    func endEditing() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    func keepFieldFrameAboveKeyboard(
        fieldFrame: CGRect,
        keyboardFrame: CGRect,
        spacing: CGFloat
    ) {
        guard
            let window = activeKeyWindow,
            let scrollView = window.firstResponder?.enclosingPageScrollView
        else {
            return
        }

        let keyboardFrameInWindow = window.convert(keyboardFrame, from: nil)
        let visibleBottom = keyboardFrameInWindow.minY - spacing
        let offsetAdjustment = fieldFrame.maxY - visibleBottom

        guard offsetAdjustment > 0 else { return }

        let minOffsetY = -scrollView.adjustedContentInset.top
        let maxOffsetY = max(
            minOffsetY,
            scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        )
        let targetOffsetY = min(
            max(scrollView.contentOffset.y + offsetAdjustment, minOffsetY),
            maxOffsetY
        )

        guard abs(targetOffsetY - scrollView.contentOffset.y) > 0.5 else { return }

        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: targetOffsetY),
                animated: false
            )
        }
    }

    private var activeKeyWindow: UIWindow? {
        connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
    }
}

private extension UIView {
    var firstResponder: UIView? {
        if isFirstResponder {
            return self
        }

        for subview in subviews {
            if let responder = subview.firstResponder {
                return responder
            }
        }

        return nil
    }

    var enclosingPageScrollView: UIScrollView? {
        var view = superview

        while let currentView = view {
            if let scrollView = currentView as? UIScrollView,
               scrollView.isScrollEnabled,
               scrollView.bounds.height > 240 {
                return scrollView
            }

            view = currentView.superview
        }

        return nil
    }
}

struct CreateRoleView_Previews: PreviewProvider {
    static var previews: some View {
        CreateRoleView()
    }
}
