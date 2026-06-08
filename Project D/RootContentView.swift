import SwiftUI

private enum MainTab {
    case home
    case chat
}

struct ContentView: View {
    @State private var selectedTab: MainTab = .home
    @State private var isCreatePresented = false

    private let createPresentationAnimation = Animation.timingCurve(0.18, 0.92, 0.20, 1.0, duration: 0.46)

    var body: some View {
        ZStack {
            switch selectedTab {
            case .home:
                HomeContainerView {
                    selectedTab = .home
                } onCreateTapped: {
                    presentCreate()
                } onReturnHome: {
                    selectedTab = .home
                }
                .ignoresSafeArea()
            case .chat:
                ChatPlaceholderView {
                    selectedTab = .home
                } onCreateTapped: {
                    presentCreate()
                }
                    .ignoresSafeArea()
            }

            if isCreatePresented {
                CreateRoleView {
                    dismissCreate()
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom),
                        removal: .move(edge: .bottom)
                    )
                )
                .zIndex(10)
            }
        }
        .background(Color.black)
        .animation(createPresentationAnimation, value: isCreatePresented)
    }

    private func presentCreate() {
        withAnimation(createPresentationAnimation) {
            isCreatePresented = true
        }
    }

    private func dismissCreate() {
        withAnimation(createPresentationAnimation) {
            isCreatePresented = false
        }
    }
}

private struct HomeContainerView: UIViewControllerRepresentable {
    let onHomeTapped: () -> Void
    let onCreateTapped: () -> Void
    let onReturnHome: () -> Void

    func makeUIViewController(context: Context) -> UINavigationController {
        let viewController = HomeViewController()
        viewController.onHomeTabTapped = onHomeTapped
        viewController.onCreateTabTapped = onCreateTapped
        viewController.onReturnHomeRequested = onReturnHome
        let navigationController = UINavigationController(rootViewController: viewController)
        navigationController.setNavigationBarHidden(true, animated: false)
        return navigationController
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {
        uiViewController.setNavigationBarHidden(true, animated: false)
        if let homeViewController = uiViewController.viewControllers.first as? HomeViewController {
            homeViewController.onHomeTabTapped = onHomeTapped
            homeViewController.onCreateTabTapped = onCreateTapped
            homeViewController.onReturnHomeRequested = onReturnHome
        }
    }
}

private struct ChatPlaceholderView: View {
    let onHomeTapped: () -> Void
    let onCreateTapped: () -> Void

    var body: some View {
        ZStack {
            Color.black

            Text("Chat")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 80) {
                Button(action: onHomeTapped) {
                    Image("HomeTabIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .opacity(0.40)
                }
                .buttonStyle(.plain)

                Button(action: onCreateTapped) {
                    Image("CreateTabIcon")
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .opacity(0.40)
                }
                .buttonStyle(.plain)

                Image("ChatTabIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 8)
        }
    }
}
