import AppKit
import QuartzCore

/// Short opacity-only dismissal; no animation or timer remains after completion.
func fadeStatusWindow(_ window: NSWindow?, reduceMotion: Bool, completion: @escaping () -> Void) {
    guard let window = window, !reduceMotion else { completion(); return }
    // AppKit may omit animation completion when a window is ordered out mid-fade.
    // A bounded one-shot fallback must still finish dismissal exactly once.
    var finished = false
    var fallback: Timer?
    let finish = {
        guard !finished else { return }
        finished = true
        fallback?.invalidate()
        fallback = nil
        window.alphaValue = 0
        completion()
    }
    let timer = Timer(timeInterval: 0.22, repeats: false) { _ in finish() }
    fallback = timer
    RunLoop.main.add(timer, forMode: .common)
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.14
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        window.animator().alphaValue = 0
    }, completionHandler: finish)
}
