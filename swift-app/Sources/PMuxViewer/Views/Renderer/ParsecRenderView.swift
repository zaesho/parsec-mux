/// ParsecRenderView — NSViewRepresentable bridge for one Parsec session pane.
/// Wraps SingleStreamMTKView + ParsecInputView in a container NSView.

import SwiftUI
import AppKit

struct ParsecRenderView: NSViewRepresentable {
    let sessionIndex: Int
    let client: ParsecClient?
    let metalContext: MetalContext?
    let isActive: Bool
    let isRelativeMode: Bool
    let inputDelegate: InputViewDelegate?

    /// Called with the InputView so the parent can manage first responder
    var onInputViewReady: ((ParsecInputView) -> Void)?
    /// Called when user clicks in this pane (for grid focus switching)
    var onPaneClicked: (() -> Void)?

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
        inputView.onMouseDown = onPaneClicked
        inputView.isRelativeMode = isRelativeMode

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
        inputView.onMouseDown = onPaneClicked
        inputView.isRelativeMode = isRelativeMode

        // Sync dimensions when size or client changes
        let currentSize = nsView.bounds.size
        let clientChanged = context.coordinator.lastClient !== client
        if currentSize != context.coordinator.lastSentSize || clientChanged {
            mtkView.syncDimensions()
            context.coordinator.lastSentSize = currentSize
            context.coordinator.lastClient = client
        }

        // Ensure window accepts mouse moved events
        if let window = nsView.window {
            window.acceptsMouseMovedEvents = true
        }

        // Notify parent of input view for focus management
        if isActive {
            context.coordinator.onInputViewReady = onInputViewReady
            // Always notify on first setup or when input view instance changes
            if context.coordinator.lastInputView !== inputView {
                context.coordinator.lastInputView = inputView
                onInputViewReady?(inputView)
            }
            // Ensure input view is first responder (may have been lost to sidebar/overlay)
            if let window = inputView.window, window.firstResponder !== inputView {
                window.makeFirstResponder(inputView)
            }
        }
    }

    class Coordinator {
        var mtkView: SingleStreamMTKView?
        var inputView: ParsecInputView?
        var onInputViewReady: ((ParsecInputView) -> Void)?
        var lastSentSize: CGSize = .zero
        var lastClient: ParsecClient?
        var lastInputView: ParsecInputView?
    }
}

/// Container NSView that properly sizes its MTKView + InputView children on layout.
/// Does NOT accept first responder — lets clicks pass through to ParsecInputView.
class RenderContainerView: NSView {
    var mtkView: SingleStreamMTKView?
    var inputView: ParsecInputView?

    override func layout() {
        super.layout()
        let b = bounds
        mtkView?.frame = b
        inputView?.frame = b
    }

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        // Ensure InputView becomes first responder on click
        if let iv = inputView {
            window?.makeFirstResponder(iv)
        }
        super.mouseDown(with: event)
    }
}
