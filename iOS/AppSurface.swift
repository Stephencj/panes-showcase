import SwiftUI
import WebKit

/// Hosts an app tab's web view (Xpra's web client). The view belongs to the
/// tab, so switching tabs doesn't reload the app.
struct AppSurface: UIViewRepresentable {
    @ObservedObject var tab: PaneTab

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        attach(to: host)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) { attach(to: host) }

    private func attach(to host: UIView) {
        let web = tab.webView
        guard web.superview !== host else { return }
        web.removeFromSuperview()
        web.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            web.topAnchor.constraint(equalTo: host.topAnchor),
            web.bottomAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor),
        ])
    }
}
