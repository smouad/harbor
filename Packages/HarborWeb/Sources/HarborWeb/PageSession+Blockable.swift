// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+Blockable.swift
//  Harbor
//
//  PageSession satisfies HarborBlocker's page seam as-is: itemID, isOAuthFlow and
//  webView are already its own stored properties. Task 6 moves this into HarborWeb.
//

import HarborBlocker

extension PageSession: BlockablePage {}
