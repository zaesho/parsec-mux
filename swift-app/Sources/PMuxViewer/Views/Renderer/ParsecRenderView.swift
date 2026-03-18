/// ParsecRenderView — NSViewRepresentable bridge for one Parsec session pane.
/// Wraps SingleStreamMTKView + ParsecInputView in a container NSView.

import SwiftUI
import AppKit

struct ParsecRenderView: NSViewRepresentable {
    let sessionIndex: Int
    let client: ParsecClient?
    let metalContext: MetalContext?
    let isActive: Bool
    let inputDelegate: InputViewDelegate?

    /// Called with the InputView so the parent can manage first responder
    var onInputViewReady: ((ParsecInputView) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> RenderContainerView {
        let container = RenderContainerView()
        container.wantsLayer = true

        let mtkView = SingleStreamMTKView()
        if let ctx = metalContext {
            mtkView.setup(context: ctx)
        }
        mtkView.client = client
        mtkView.isActivePane = isActive

        let inputView = ParsecInputView(frame: .zero)
        inputView.parsecClient = client
        inputView.inputDelegate = inputDelegate

        container.addSubview(mtkView)
        container.addSubview(inputView)

        container.mtkView = mtkView
        container.inputView = inputView
        context.coordinator.mtkView = mtkView
        context.coordinator.inputView = inputView
        context.coordinator.onInputViewReady = onInputViewReady

        return container
    }

    func updateNSView(_ nsView: RenderContainerView, context: Context) {
        guard let mtkView = context.coordinator.mtkView,
              let inputView = context.coordinator.inputView else { return }

        mtkView.client = client
        mtkView.isActivePane = isActive
        inputView.parsecClient = client
        inputView.inputDelegate = inputDelegate

        // Sync dimensions whenever client or size changes
        mtkView.syncDimensions()

        // Ensure window accepts mouse moved events
        if let window = nsView.window {
            window.acceptsMouseMovedEvents = true
        }

        // Make active input view first responder
        if isActive {
            context.coordinator.onInputViewReady = onInputViewReady
            onInputViewReady?(inputView)
        }
    }

    class Coordinator {
        var mtkView: SingleStreamMTKView?
        var inputView: ParsecInputView?
        var onInputViewReady: ((ParsecInputView) -> Void)?
    }
}

/// Container NSView that properly sizes its MTKView + InputView children on layout.
class RenderContainerView: NSView {
    var mtkView: SingleStreamMTKView?
    var inputView: ParsecInputView?

    override func layout() {
        super.layout()
        let b = bounds
        mtkView?.frame = b
        inputView?.frame = b
    }

    override var acceptsFirstResponder: Bool { true }
}
