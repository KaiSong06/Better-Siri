import SwiftUI

// MARK: – Entry point

/// Shows the right activation indicator for the current device:
/// - Dynamic Island phones: an expanding pill that overlays the island
/// - All other phones: a banner that slides down from the top
struct ActivationIndicator: View {
    let state: PipelineState

    // Deferred to onAppear so the window is fully set up before we read
    // the safe-area inset (calling at init time can return 0).
    @State private var useDynamicIsland = false

    var body: some View {
        Group {
            if useDynamicIsland {
                DynamicIslandBar(state: state)
            } else {
                BannerBar(state: state)
            }
        }
        .onAppear {
            let inset = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.keyWindow?.safeAreaInsets.top ?? 0
            useDynamicIsland = inset >= 59
        }
    }
}

// MARK: – Dynamic Island indicator

/// Overlays a pill on top of the Dynamic Island hardware cutout.
/// When idle the pill is invisible (black on black); when active it expands
/// to show the current stage icon and label, mimicking a Live Activity expansion.
private struct DynamicIslandBar: View {

    let state: PipelineState
    private var isActive: Bool { state != .idle }

    // Dynamic Island resting dimensions (points).
    private let islandWidth:  CGFloat = 126
    private let islandHeight: CGFloat = 37
    private let islandTop:    CGFloat = 11   // distance from absolute top to island top

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Black pill — always at Dynamic Island size.
                Capsule()
                    .fill(Color.black)
                    .frame(width: islandWidth, height: islandHeight)

                // Icon fades in when active.
                Image(systemName: state.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state.color)
                    .opacity(isActive ? 1 : 0)
                    .scaleEffect(isActive ? 1 : 0.5)
            }
            .animation(.spring(duration: 0.35, bounce: 0.3), value: isActive)
            .animation(.easeInOut(duration: 0.2), value: state)
            .padding(.top, islandTop)

            Spacer()
        }
        // ignoresSafeArea must be on the outermost container so the VStack
        // starts at the absolute top of the screen, not below the status bar.
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}

// MARK: – Banner indicator (notch / older devices)

/// A pill-shaped banner that slides down from the top of the safe area
/// when the pipeline leaves idle, then slides back up when idle resumes.
private struct BannerBar: View {

    let state: PipelineState
    private var isActive: Bool { state != .idle }

    var body: some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: state.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(state.color)

                Text(state.label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
            .padding(.top, 8)
            // Slide in from above when active.
            .offset(y: isActive ? 0 : -120)
            .animation(.spring(duration: 0.45, bounce: 0.25), value: isActive)
            .animation(.easeInOut(duration: 0.2), value: state)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}
