// Licensed under GPL-3.0. See LICENSE.
//
//  StageIndicator.swift
//  Harbor
//

import HarborDesign
import SwiftUI

/// How far through onboarding the person is: a thin line along the top of the card that fills
/// in the space's color.
struct StageIndicator: View {

    var stages: Int
    var activeStage: Int
    var accentHex: String

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.primary.opacity(0.06))
                Rectangle()
                    .fill(Color(hex: accentHex))
                    .frame(width: geo.size.width * CGFloat(activeStage + 1) / CGFloat(max(stages, 1)))
            }
        }
        .frame(height: 3)
        .animation(HarborDesign.Motion.standard, value: activeStage)
        .animation(HarborDesign.Motion.standard, value: accentHex)
        .accessibilityElement()
        .accessibilityLabel("Step \(activeStage + 1) of \(stages)")
    }
}
