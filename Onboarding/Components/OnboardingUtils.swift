// Licensed under GPL-3.0. See LICENSE.
//
//  OnboardingUtils.swift
//  Harbor
//
//  Created by Maciek Bagiński on 19/02/2026.
//

import SwiftUI
import AppKit

struct BlurSlideModifier: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

extension AnyTransition {
    static var slideAndBlur: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: BlurSlideModifier(offset: 100, blur: 10, opacity: 0.5),
                identity: BlurSlideModifier(offset: 0, blur: 0, opacity: 1)
            ),
            removal: .modifier(
                active: BlurSlideModifier(offset: -100, blur: 0, opacity: 0),
                identity: BlurSlideModifier(offset: 0, blur: 0, opacity: 1)
            )
        )
    }
}

extension AnyTransition {
    /// Between onboarding steps: a cross-fade with a short slide, the 250-350 ms move Arc and Dia
    /// use between their cards.
    static var onboardingStep: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 12)),
            removal: .opacity.combined(with: .offset(x: -12))
        )
    }
}
