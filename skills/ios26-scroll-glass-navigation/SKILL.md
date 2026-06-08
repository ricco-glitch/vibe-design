---
name: ios26-scroll-glass-navigation
description: Use when implementing, refactoring, or reviewing an iOS/SwiftUI custom navigation bar whose background should fade into an iOS 26 glassEffect as ScrollView content scrolls, especially top bars using onScrollGeometryChange, safe-area overlays, zIndex layering, and gradient masks.
---

# iOS 26 Scroll Glass Navigation

Use this skill when a SwiftUI screen has a custom navigation/top bar and the user wants the bar background to transition into an iOS 26 glass effect while scrolling.

## Goal

Preserve the page's existing layout and navigation controls, but replace legacy blur layers such as `UIVisualEffectView`, `.background(.ultraThinMaterial)`, or custom static gradients with iOS 26 `glassEffect`.

## Workflow

1. Find the custom top bar and its background layer.
   - Look for names like `NavigationBar`, `TopNavigationBar`, `NavigationBackground`, `GlassBackground`, `LiquidGlass`, or `Blur`.
   - Look for scroll progress state such as `navigationGlassProgress`, `scrollProgress`, or `isScrolled`.

2. Keep existing scroll-driven progress if it already exists.
   - Prefer the local behavior over rewriting the screen.
   - For `ScrollView`, use `onScrollGeometryChange` when the project already targets a compatible SDK.

3. Replace only the material implementation.
   - Keep the same frame, mask, opacity, z-index, and hit-testing behavior unless the request says otherwise.
   - Do not convert the whole page to `NavigationStack` unless the user explicitly asks for a system navigation bar.

4. Validate iOS availability.
   - `glassEffect` is iOS 26+.
   - If the deployment target may be below iOS 26, add an availability fallback.
   - If the project target is already iOS 26+, keep the implementation direct and concise.

## Preferred Pattern

Use a dedicated background view so the effect stays reusable:

```swift
private struct GlassNavigationBackground: View {
    let progress: Double

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .glassEffect(
                .regular.tint(Color(hex: 0x121212).opacity(0.42)),
                in: Rectangle()
            )
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
```

Attach it above the scroll content and below controls:

```swift
GlassNavigationBackground(progress: navigationGlassProgress)
    .frame(height: 132)
    .ignoresSafeArea(edges: .top)
    .allowsHitTesting(false)
    .zIndex(1)

TopNavigationBar(onBack: handleBackTap)
    .zIndex(2)
```

Drive progress from scroll offset:

```swift
.onScrollGeometryChange(for: Double.self) { geometry in
    Double(geometry.contentOffset.y)
} action: { _, offsetY in
    navigationGlassProgress = min(max(offsetY / 56, 0), 1)
}
```

Reset the progress when the page resets:

```swift
navigationGlassProgress = 0
```

## Availability Fallback

Use this only if the app supports pre-iOS 26 targets:

```swift
@ViewBuilder
private var glassLayer: some View {
    if #available(iOS 26.0, *) {
        Rectangle()
            .fill(Color.clear)
            .glassEffect(.regular.tint(Color.black.opacity(0.42)), in: Rectangle())
    } else {
        Rectangle()
            .fill(.regularMaterial)
    }
}
```

## Review Checklist

- The top controls remain above the glass background.
- The glass background does not intercept touches.
- The effect fades in from `0...1` based on scroll offset.
- The view still ignores the top safe area for full bleed coverage.
- Bottom buttons, sheets, and full-screen overlays are not changed unless necessary.
- A build or Swift compile check was attempted; if Xcode asset/simulator issues block full build, report that separately from Swift errors.
