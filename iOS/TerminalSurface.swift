import SwiftTerm
import SwiftUI

/// Hosts a terminal tab's SwiftTerm view. The view belongs to the tab, so
/// switching tabs keeps the screen and scrollback.
struct TerminalSurface: UIViewRepresentable {
    @ObservedObject var tab: PaneTab
    @Binding var keyboard: Bool

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .black
        attach(to: host)
        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        attach(to: host)
        let term = tab.terminalView
        DispatchQueue.main.async {
            if keyboard && !term.isFirstResponder { term.becomeFirstResponder() }
            if !keyboard && term.isFirstResponder { term.resignFirstResponder() }
        }
    }

    private func attach(to host: UIView) {
        let term = tab.terminalView
        guard term.superview !== host else { return }
        term.removeFromSuperview()
        term.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(term)
        NSLayoutConstraint.activate([
            term.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            term.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            term.topAnchor.constraint(equalTo: host.topAnchor),
            term.bottomAnchor.constraint(equalTo: host.keyboardLayoutGuide.topAnchor),
        ])
    }
}
