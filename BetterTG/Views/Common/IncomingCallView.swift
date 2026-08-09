import SwiftUI
import UIKit
import AVKit

struct IncomingCallView: View {
    let coordinator: IncomingCallCoordinator

    @State private var isMuted = false
    @State private var isCameraEnabled = false

    private var isConnected: Bool {
        if case .ready = coordinator.phase { return true }
        return false
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo.opacity(0.9), .blue.opacity(0.75), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if coordinator.isRemoteVideoActive,
               let mediaSession = coordinator.activeMediaSession,
               case .ready = coordinator.phase
            {
                RemoteCallVideoView(mediaSession: mediaSession)
                    .ignoresSafeArea()
            }

            VStack(spacing: 22) {
                Spacer()
                if coordinator.activeMediaSession == nil {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 136))
                        .foregroundStyle(.white.opacity(0.9))
                        .accessibilityHidden(true)
                }

                Text(coordinator.callerName)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)

                if case .ready(let emojis) = coordinator.phase, !emojis.isEmpty {
                    CallVerificationEmojiView(
                        emojis: emojis,
                        peerName: coordinator.callerName
                    )
                } else {
                    Label(
                        coordinator.phase.title,
                        systemImage: coordinator.isVideo ? "video.fill" : "phone.fill"
                    )
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.9))
                }
                Spacer()
            }
            .padding()
        }
        .interactiveDismissDisabled()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if coordinator.phase == .incoming {
                incomingControls
            } else {
                activeControls
            }
        }
        .onChange(of: coordinator.isVideo, initial: true) { _, value in
            isCameraEnabled = value
        }
    }

    private var incomingControls: some View {
        HStack {
            roundButton(title: "Decline", systemImage: "phone.down.fill", color: .red) {
                coordinator.decline()
            }
            Spacer()
            roundButton(
                title: "Accept",
                systemImage: coordinator.isVideo ? "video.fill" : "phone.fill",
                color: .green
            ) {
                coordinator.accept()
            }
        }
        .padding(.horizontal, 54)
        .padding(.vertical, 24)
        .background(.black.opacity(0.22))
    }

    private var activeControls: some View {
        HStack(spacing: 16) {
            roundButton(
                title: "Mute",
                systemImage: isMuted ? "mic.slash.fill" : "mic.fill",
                color: isMuted ? .white : .white.opacity(0.18),
                foreground: isMuted ? .black : .white
            ) {
                isMuted.toggle()
                coordinator.setMuted(isMuted)
            }
            .disabled(!isConnected)

            roundButton(
                title: isCameraEnabled ? "Camera off" : "Camera",
                systemImage: isCameraEnabled ? "video.fill" : "video.slash.fill",
                color: isCameraEnabled ? .white : .white.opacity(0.18),
                foreground: isCameraEnabled ? .black : .white
            ) {
                isCameraEnabled.toggle()
                coordinator.setVideoEnabled(isCameraEnabled)
            }
            .disabled(!isConnected)

            AudioRoutePickerButton(size: 60)
                .disabled(!isConnected)

            if isCameraEnabled {
                roundButton(title: "Flip", systemImage: "camera.rotate.fill", color: .white.opacity(0.18)) {
                    coordinator.switchCamera()
                }
                .disabled(!isConnected)
            }

            roundButton(title: "End", systemImage: "phone.down.fill", color: .red) {
                coordinator.hangUp()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 16)
        .background(.black.opacity(0.22))
    }

    private func roundButton(
        title: String,
        systemImage: String,
        color: Color,
        foreground: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .frame(width: 60, height: 60)
                    .foregroundStyle(foreground)
                    .background(color, in: Circle())
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .frame(minWidth: 70)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct CallVerificationEmojiView: View {
    let emojis: [String]
    let peerName: String

    var body: some View {
        VStack(spacing: 8) {
            Text(emojis.joined(separator: " "))
                .font(.system(size: 38))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

            Text("Compare these emoji with \(peerName)")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 18))
    }
}

struct AudioRoutePickerButton: View {
    let size: CGFloat

    var body: some View {
        VStack(spacing: 7) {
            SystemAudioRoutePicker()
                .frame(width: size, height: size)
                .background(.white.opacity(0.18), in: Circle())

            Text("Speaker")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .frame(minWidth: 70)
    }
}

private struct SystemAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .white
        picker.activeTintColor = .white
        picker.accessibilityLabel = "Choose audio device"
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}

struct RemoteCallVideoView: UIViewRepresentable {
    final class Coordinator {
        var isActive = true
        weak var renderedView: UIView?

        func invalidate() {
            isActive = false
            renderedView?.removeFromSuperview()
        }
    }

    let mediaSession: PrivateCallMediaSession

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .black
        let coordinator = context.coordinator

        mediaSession.makeIncomingVideoView { [weak container, weak coordinator] videoView in
            guard let container, let coordinator, coordinator.isActive, let videoView else { return }
            videoView.translatesAutoresizingMaskIntoConstraints = false
            videoView.updateIsEnabled(true)
            container.addSubview(videoView)
            NSLayoutConstraint.activate([
                videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                videoView.topAnchor.constraint(equalTo: container.topAnchor),
                videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            coordinator.renderedView = videoView
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.invalidate()
    }
}
