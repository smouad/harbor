// Licensed under GPL-3.0. See LICENSE.
//
//  AutofillBridge.swift
//  Harbor
//
//  The page's side of password autofill: a script that notices when the person puts the cursor
//  in a login field, and fills one in when told to. It runs in its own content world, so the page
//  can neither call its handler nor read what it holds, and only the main frame is watched. What
//  to offer is the app's to decide (`PageSessionDelegate.autofillField`); the page is never told
//  which logins exist, and gets values only for the one the person picks.
//

import Foundation
import WebKit

/// A login field the person put the cursor in.
public struct AutofillField {
    public enum Kind: String { case username, password }

    public let kind: Kind
    /// Where the page's top frame is, taken from WebKit and not from the page's own message.
    public let scheme: String
    public let host: String
    /// The field's box in the page's own units (CSS pixels from the viewport's top left).
    public let rect: CGRect
    /// What is typed in a user name field so far, to narrow the list. Never set for a password.
    public let typed: String?
    public weak var webView: WKWebView?
}

public enum AutofillKey: String {
    case down, up, enter, escape
}

@MainActor
public final class AutofillBridge: NSObject, WKScriptMessageHandler {
    private weak var session: PageSession?
    private weak var userContentController: WKUserContentController?

    static let handlerName = "harborAutofill"
    /// Its own world: a page that posted to this handler could otherwise make the app show a
    /// dropdown over a site, and read the page-side state.
    static let world = WKContentWorld.world(name: "HarborAutofill")

    public init(session: PageSession?, configuration: WKWebViewConfiguration) {
        self.session = session
        let controller = configuration.userContentController
        self.userContentController = controller
        super.init()
        // An agent's page has its own vault; a person's saved logins are never offered there.
        guard session?.isAgentPage != true else { return }
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: true, in: Self.world))
    }

    public func detach() {
        userContentController?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        userContentController = nil
    }

    // MARK: - From the page

    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let type = body["type"] as? String,
              let session, let delegate = session.controller?.sessionDelegate else { return }
        switch type {
        case "focus", "input":
            // The page's own origin comes from WebKit: nothing in the message is trusted for it.
            let origin = message.frameInfo.securityOrigin
            guard let kind = (body["kind"] as? String).flatMap(AutofillField.Kind.init(rawValue:)),
                  let rect = body["rect"] as? [String: Double],
                  let x = rect["x"], let y = rect["y"], let width = rect["width"], let height = rect["height"],
                  width > 0, height > 0 else { return }
            let typed = kind == .username ? (body["typed"] as? String).map { String($0.prefix(200)) } : nil
            delegate.autofillField(
                AutofillField(kind: kind, scheme: origin.protocol, host: origin.host,
                              rect: CGRect(x: x, y: y, width: width, height: height), typed: typed, webView: message.webView),
                focusedIn: session)
        case "key":
            if let key = (body["key"] as? String).flatMap(AutofillKey.init(rawValue:)) {
                delegate.autofillKey(key, in: session)
            }
        case "close":
            delegate.autofillDismiss(in: session)
        default:
            break
        }
    }

    // MARK: - To the page

    /// Fills the field the person is in, and the other half of its form: the user name beside a
    /// password, or the password under a user name. Returns how many fields were set.
    @discardableResult
    public static func fill(username: String?, password: String?, in webView: WKWebView) async -> Int {
        let result = try? await webView.callAsyncJavaScript(
            "return window.__harborAutofill ? window.__harborAutofill.fill(username, password) : 0",
            arguments: ["username": username ?? NSNull(), "password": password ?? NSNull()],
            in: nil, contentWorld: world)
        return (result as? Int) ?? 0
    }

    /// Tells the page whether the dropdown is up, and whether a row is highlighted, so the arrow
    /// keys and Return are taken only while they mean something.
    public static func setState(open: Bool, highlighted: Bool, in webView: WKWebView) {
        webView.callAsyncJavaScript(
            "if (window.__harborAutofill) { window.__harborAutofill.setState(open, highlighted); }",
            arguments: ["open": open, "highlighted": highlighted], in: nil, in: world, completionHandler: nil)
    }

    // MARK: - Script

    private static let script = """
    // Harbor Autofill
    (function () {
        if (window.__harborAutofill) { return; }
        const post = (message) => window.webkit.messageHandlers.harborAutofill.postMessage(message);
        const state = { target: null, open: false, highlighted: false };

        const visible = (el) => {
            if (!el || el.disabled || el.readOnly) { return false; }
            const box = el.getBoundingClientRect();
            if (box.width < 8 || box.height < 8) { return false; }
            const style = getComputedStyle(el);
            return style.visibility !== 'hidden' && style.display !== 'none';
        };
        const isPassword = (el) => el.tagName === 'INPUT' && el.type === 'password';
        const textTypes = ['text', 'email', 'tel', 'url', ''];
        const isTextual = (el) => el.tagName === 'INPUT' && textTypes.includes((el.getAttribute('type') || '').toLowerCase());
        const scope = (el) => el.form || document;
        const passwordFields = (root) => Array.from(root.querySelectorAll('input[type=password]')).filter(visible);

        // A user name field is one beside a password field, or one that says so itself.
        const kindOf = (el) => {
            if (!el || el.tagName !== 'INPUT' || !visible(el)) { return null; }
            if (isPassword(el)) { return 'password'; }
            if (!isTextual(el)) { return null; }
            const hint = (el.getAttribute('autocomplete') || '').toLowerCase();
            if (hint.includes('username') || hint.includes('email')) { return 'username'; }
            if (hint.includes('one-time') || hint.includes('cc-') || hint.includes('address') || hint.includes('search')) { return null; }
            return passwordFields(scope(el)).length > 0 ? 'username' : null;
        };

        const describe = (el, kind, type) => {
            const box = el.getBoundingClientRect();
            return { type, kind, rect: { x: box.left, y: box.top, width: box.width, height: box.height },
                     typed: kind === 'username' ? el.value : undefined };
        };

        const announce = (el) => {
            // A page that focuses its own field on load has had no click yet: nothing to offer.
            if (!(navigator.userActivation && navigator.userActivation.hasBeenActive)) { return; }
            const kind = kindOf(el);
            if (!kind) { return; }
            state.target = el;
            post(describe(el, kind, 'focus'));
        };

        // Only a real focus by the person counts: a script cannot make the app list logins.
        document.addEventListener('focusin', (event) => { if (event.isTrusted) { announce(event.target); } }, true);
        document.addEventListener('click', (event) => {
            if (!event.isTrusted) { return; }
            if (event.target === document.activeElement && event.target === state.target && !state.open) { announce(event.target); }
        }, true);
        document.addEventListener('input', (event) => {
            if (event.isTrusted && event.target === state.target && kindOf(event.target) === 'username') {
                post(describe(event.target, 'username', 'input'));
            }
        }, true);

        document.addEventListener('keydown', (event) => {
            if (!event.isTrusted || event.target !== state.target || !state.open) { return; }
            const names = { ArrowDown: 'down', ArrowUp: 'up', Enter: 'enter', Escape: 'escape' };
            const key = names[event.key];
            if (!key) { return; }
            // Return submits the form unless a row is highlighted, and Escape is the page's too.
            if (key === 'down' || key === 'up' || (key === 'enter' && state.highlighted)) {
                event.preventDefault();
                event.stopPropagation();
            }
            post({ type: 'key', key });
        }, true);

        // A click elsewhere closes the list. Scrolling or resizing keeps it under its field, which
        // is told to the app again at the next frame; it closes only once the field has left the view.
        const close = () => { if (state.open) { state.open = false; post({ type: 'close' }); } };
        document.addEventListener('pointerdown', (event) => { if (event.isTrusted && event.target !== state.target) { close(); } }, true);
        let moving = false;
        const follow = () => {
            if (!state.open || moving) { return; }
            moving = true;
            requestAnimationFrame(() => {
                moving = false;
                const el = state.target;
                if (!state.open || !el || !el.isConnected) { return close(); }
                const box = el.getBoundingClientRect();
                if (box.bottom < 0 || box.top > window.innerHeight || box.right < 0 || box.left > window.innerWidth) { return close(); }
                const kind = kindOf(el);
                if (kind) { post(describe(el, kind, 'input')); }
            });
        };
        window.addEventListener('scroll', follow, { capture: true, passive: true });
        window.addEventListener('resize', follow);

        const setNative = (el, value) => {
            const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(el), 'value').set;
            setter.call(el, value);
            el.dispatchEvent(new Event('input', { bubbles: true }));
            el.dispatchEvent(new Event('change', { bubbles: true }));
        };

        window.__harborAutofill = {
            setState(open, highlighted) { state.open = !!open; state.highlighted = !!highlighted; },
            fill(username, password) {
                const el = state.target;
                if (!el) { return 0; }
                const root = scope(el);
                const fields = Array.from(root.querySelectorAll('input')).filter(visible);
                let passwordField = isPassword(el) ? el : fields.filter(isPassword).find((f) => el.compareDocumentPosition(f) & Node.DOCUMENT_POSITION_FOLLOWING) || fields.find(isPassword);
                let userField = isPassword(el) ? null : el;
                if (!userField && passwordField) {
                    const before = fields.filter((f) => isTextual(f) && (f.compareDocumentPosition(passwordField) & Node.DOCUMENT_POSITION_FOLLOWING));
                    userField = before[before.length - 1] || null;
                }
                let filled = 0;
                if (userField && username !== null && username !== undefined) { setNative(userField, username); filled++; }
                if (passwordField && password !== null && password !== undefined) { setNative(passwordField, password); filled++; }
                state.open = false;
                return filled;
            },
        };
    })();
    """
}
