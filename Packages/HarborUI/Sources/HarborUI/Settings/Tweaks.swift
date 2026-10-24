// Licensed under GPL-3.0. See LICENSE.
//
//  Tweaks.swift
//  Harbor
//
//  Created by Claude on 15/09/2026.
//

import SwiftUI
import HarborDesign
import HarborSettings

/// Per-site tweaks: media downloads, presenting as Chrome, Facebook, Reddit, YouTube and SponsorBlock.
public struct SettingsTweaksTab: View {
    @Environment(HarborSettingsService.self) var harborSettings
    public init() {}

    public var body: some View {
        @Bindable var settings = harborSettings
        Form {
            SiteListSection(sites: $settings.mediaDownloadSites, title: "Download Button",
                            footer: "Shows a download button on photos and videos, and saves the largest size the page offers to Downloads. Subdomains are included.")

            SiteListSection(sites: $settings.chromeIdentitySites, title: "Present as Chrome",
                            footer: "These sites see Harbor as Google Chrome, for sites that turn Safari away or give it a lesser page. Subdomains are included. Takes effect on the next page load.")

            Section {
                Toggle("Hide Reels", isOn: $settings.facebookHideReels)
                Toggle("Hide suggested posts", isOn: $settings.facebookHideSuggested)
            } header: {
                Text("Facebook")
            } footer: {
                Text("Hide Reels removes the Reels carousel from the news feed. Hide suggested posts removes posts from groups, pages, and people you don't follow, and People You May Know. Friends, followed pages, and groups stay.")
            }

            Section {
                Toggle("Sort feeds by Hot", isOn: $settings.redditSortHot)
            } header: {
                Text("Reddit")
            } footer: {
                Text("Opens the home feed, subreddits and custom feeds sorted by Hot instead of Best. Choosing another sort still works.")
            }

            YouTubeSettingsSections()
        }
        .formStyle(.grouped)
    }
}

/// A list of sites with remove buttons and an Add Site row; same rows as Site Search in General.
private struct SiteListSection: View {
    @Binding var sites: [String]
    let title: String
    let footer: String
    @State private var newSite = ""
    @State private var adding = false

    var body: some View {
        Section {
            ForEach(sites, id: \.self) { site in
                LabeledContent {
                    Button {
                        sites.removeAll { $0 == site }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                } label: {
                    Text(site)
                }
            }

            Button {
                adding = true
            } label: {
                Label("Add Site", systemImage: "plus")
            }
        } header: {
            Text(title)
        } footer: {
            Text(footer)
        }
        .alert("Add Site", isPresented: $adding) {
            TextField("Add a site (e.g. instagram.com)", text: $newSite)
            Button("Add", action: add)
                .disabled(SiteRoutingRule.normalizeDomain(newSite).isEmpty)
            Button("Cancel", role: .cancel) { newSite = "" }
        }
    }

    private func add() {
        let domain = SiteRoutingRule.normalizeDomain(newSite)
        guard !domain.isEmpty, !sites.contains(domain) else { return }
        sites.append(domain)
        newSite = ""
    }
}
