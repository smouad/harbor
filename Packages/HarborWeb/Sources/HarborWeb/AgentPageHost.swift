// Licensed under GPL-3.0. See LICENSE.
//
//  AgentPageHost.swift
//  HarborWeb
//
//  What an Agent space page asks the app: the scripts it gets, whether its task may open a site,
//  how to answer a JavaScript dialog, and which files a file picker gets. No person is watching an
//  agent page, so none of these may show UI; the app (AgentKit) decides from the agent's task.
//

import Foundation
import WebKit

public enum AgentDialogKind: String {
    case alert, confirm, prompt
}

public struct AgentDialogAnswer {
    public var accept: Bool
    public var text: String?

    public init(accept: Bool, text: String? = nil) {
        self.accept = accept
        self.text = text
    }
}

@MainActor
public protocol AgentPageHost: AnyObject {
    /// Scripts every agent page gets at document start. Each starts with `// Harbor`.
    func agentPageScripts() -> [WKUserScript]
    /// Whether the agent page may load `url` in its main frame.
    func agentPage(_ session: PageSession, mayLoad url: URL) -> Bool
    /// The answer to a JavaScript dialog the agent page opened.
    func agentPage(_ session: PageSession, dialog kind: AgentDialogKind, message: String, defaultText: String?) -> AgentDialogAnswer
    /// Files for a file picker the agent page opened; nil cancels it.
    func agentPageOpenPanel(_ session: PageSession, allowsMultipleSelection: Bool) -> [URL]?
}
