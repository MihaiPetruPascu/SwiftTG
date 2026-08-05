import AppKit
import SwiftUI

/// The seam between the future macOS call engine and the call UI.
/// A tgcalls-backed media session can conform once a macOS framework slice is available.
protocol MacRemoteCallVideoProviding: AnyObject {
    func makeIncomingVideoView(completion: @escaping (NSView?) -> Void)
}

/// Hosts the native incoming-video renderer without coupling SwiftUI to tgcalls.
struct MacRemoteCallVideoView: NSViewRepresentable {
    final class Coordinator {
        var isActive = true
        weak var renderedView: NSView?

        func invalidate() {
            isActive = false
            renderedView?.removeFromSuperview()
        }
    }

    let provider: any MacRemoteCallVideoProviding

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        let coordinator = context.coordinator

        provider.makeIncomingVideoView { [weak container, weak coordinator] videoView in
            DispatchQueue.main.async {
                guard let container, let coordinator, coordinator.isActive, let videoView else { return }
                videoView.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(videoView)
                NSLayoutConstraint.activate([
                    videoView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    videoView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                    videoView.topAnchor.constraint(equalTo: container.topAnchor),
                    videoView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                ])
                coordinator.renderedView = videoView
            }
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.invalidate()
    }
}
