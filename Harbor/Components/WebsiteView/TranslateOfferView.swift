// Licensed under GPL-3.0. See LICENSE.
//
//  TranslateOfferView.swift
//  Harbor
//
//  The card offering to translate a page in another language, and the invisible host whose
//  .translationTask gives a page a session that can download a language pair.
//

import SwiftUI
import Translation
import HarborDesign
import HarborUI
import HarborWeb

struct TranslateOfferView: View {
    let session: PageSession
    let language: Locale.Language

    private var languageName: String {
        let code = language.languageCode?.identifier ?? language.minimalIdentifier
        return Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    var body: some View {
        HStack(spacing: HarborDesign.Spacing.md) {
            Text("Translate from \(languageName)?")
                .font(HarborDesign.Font.body)
                .foregroundStyle(.primary)
                .padding(.leading, HarborDesign.Spacing.sm)
            HStack(spacing: HarborDesign.Spacing.xxs) {
                Button("Not Now") { session.declineTranslationOffer() }
                Button("Translate") { session.toggleTranslation() }
            }
            .buttonStyle(RectNavButtonStyle())
            .controlSize(.small)
        }
        .padding(HarborDesign.Spacing.xxs)
        .harborFloatingSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
    }
}

/// Runs a translation that needs the system's download sheet. Keyed by the page, so switching
/// tabs ends the old page's task and coming back resumes it.
struct TranslationTaskHost: View {
    let session: PageSession

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .translationTask(session.translationRequest) { translator in
                await session.runTranslation(with: translator)
            }
            .id(session.itemID)
    }
}
