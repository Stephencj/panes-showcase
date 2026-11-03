import SwiftUI
import WebKit

/// Hosts an app tab's web view (Xpra's web client). The view belongs to the
/// tab, so switching tabs doesn't reload the app.
struct AppSurface: UIViewRepresentable {
    @ObservedObject var tab: PaneTab
    @Binding var keyboard: Bool

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        let keys = PageKeyView()
        keys.tab = tab
        keys.tag = PageKeyView.tagValue
        keys.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        host.addSubview(keys)
        attach(to: host)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        attach(to: host)
        guard let keys = host.viewWithTag(PageKeyView.tagValue) as? PageKeyView else { return }
        keys.tab = tab
        DispatchQueue.main.async {
            if keyboard && !keys.isFirstResponder { keys.becomeFirstResponder() }
            if !keyboard && keys.isFirstResponder { keys.resignFirstResponder() }
        }
    }

    private func attach(to host: UIView) {
        let web = tab.webView
        guard web.superview !== host else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        host.insertSubview(web, at: 0)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            web.topAnchor.constraint(equalTo: host.topAnchor),
            web.bottomAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor),
        ])
    }
}

/// The keyboard for an app tab: the same key row and hardware keys as window
/// tabs, delivered into the Xpra page.
final class PageKeyView: KeyInputView {
    static let tagValue = 7_420
    weak var tab: PaneTab?
    override func emit(_ e: InputEvent) { tab?.sendToPage(e) }
}
