// Licensed under GPL-3.0. See LICENSE.
//
//  YouTube.swift
//  Harbor
//
//  Created by Claude on 26/03/2026.
//

import HarborSettings
import SwiftUI
import HarborDesign
import HarborTweaks

/// YouTube's sections of the Tweaks tab; the caller supplies the Form.
public struct YouTubeSettingsSections: View {
    @Environment(HarborSettingsService.self) var harborSettings

    public init() {}

    public var body: some View {
        @Bindable var settings = harborSettings
        Group {
            Section {
                Picker("Videos per row", selection: $settings.youTubeVideosPerRow) {
                    Text("Automatic").tag(0)
                    ForEach(YouTubeTweaks.videosPerRowRange, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                Toggle("Frame thumbnails", isOn: $settings.youTubeFrameThumbnails)
                #if os(macOS)
                // There is no hover on a touch screen.
                Toggle("Disable hover previews", isOn: $settings.youTubeNoHoverPreview)
                #endif
            } header: {
                Text("YouTube")
            } footer: {
                Text("Videos per row applies to Home, Subscriptions, and channel pages. Frame thumbnails show a still from the video instead of the uploader's thumbnail.")
            }

            Section("Hide on YouTube") {
                Toggle("Shorts", isOn: $settings.youTubeHideShorts)
                ForEach(YouTubeHomeSection.allCases) { section in
                    Toggle("Home: \(section.displayName)", isOn: Binding(
                        get: { harborSettings.youTubeHiddenHomeSections.contains(section.rawValue) },
                        set: { hidden in
                            harborSettings.youTubeHiddenHomeSections.removeAll { $0 == section.rawValue }
                            if hidden { harborSettings.youTubeHiddenHomeSections.append(section.rawValue) }
                        }
                    ))
                }
            }

            Section {
                Toggle("SponsorBlock", isOn: $settings.sponsorBlockEnabled)
            } footer: {
                Text("Skip sponsored segments, intros, and other non-content on YouTube using community data from SponsorBlock.")
            }

            if harborSettings.sponsorBlockEnabled {
                Section("SponsorBlock Categories") {
                    ForEach(SponsorBlockCategory.allCases) { category in
                        Picker(selection: Binding(
                            get: {
                                SponsorBlockSkipOption(rawValue: harborSettings.sponsorBlockCategoryOptions[category.rawValue] ?? category.defaultSkipOption.rawValue) ?? category.defaultSkipOption
                            },
                            set: { newValue in
                                harborSettings.sponsorBlockCategoryOptions[category.rawValue] = newValue.rawValue
                            }
                        )) {
                            ForEach(SponsorBlockSkipOption.allCases) { option in
                                Text(option.displayName).tag(option)
                            }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                                    Text(category.displayName)
                                    Text(category.description)
                                        .font(HarborDesign.Font.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Circle()
                                    .fill(sponsorBlockCategoryColor(category))
                                    .frame(
                                        width: HarborDesign.Size.statusDot,
                                        height: HarborDesign.Size.statusDot
                                    )
                            }
                        }
                    }
                }
            }
        }
    }

    private func sponsorBlockCategoryColor(_ category: SponsorBlockCategory) -> Color {
        switch category {
        case .sponsor: return .green
        case .selfpromo: return .yellow
        case .exclusive_access: return Color(red: 0, green: 0.54, blue: 0.36)
        case .interaction: return .purple
        case .intro: return .cyan
        case .outro: return .blue
        case .preview: return .teal
        case .filler: return .indigo
        case .music_offtopic: return .orange
        case .poi_highlight: return .pink
        }
    }
}
