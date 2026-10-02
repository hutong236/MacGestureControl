import SwiftUI

struct GestureHUDView: View {
    let state: GestureHUDState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.isLocked ? "lock.fill" : symbolName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(state.leftHandText)
                    Text(state.rightHandText)
                }
                .font(.caption.weight(.medium))

                Text(state.actionText)
                    .font(.subheadline.weight(state.isLocked ? .semibold : .medium))
                    .lineLimit(1)

                if let progress = state.holdProgress, state.mode == .holdCandidate {
                    ProgressView(value: min(max(progress, 0), 1))
                        .progressViewStyle(.linear)
                        .frame(width: 230)
                }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 0.7)
        }
        .shadow(radius: 8, y: 3)
        .allowsHitTesting(false)
    }

    private var symbolName: String {
        switch state.mode {
        case .idle: return "hand.raised"
        case .active: return "hand.point.up.left"
        case .holdCandidate: return "hand.pinch"
        case .latched: return "lock.fill"
        }
    }
}
