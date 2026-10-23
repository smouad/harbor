// Licensed under GPL-3.0. See LICENSE.
//
//  DevPerfView.swift
//  Harbor
//
//  Perf tab: load timings, LCP and INP from the page, and its WebContent process's memory and CPU.
//

import Darwin
import SwiftUI
import HarborDesign
import HarborWeb
import HarborUI

struct DevPerfView: View {
    let capture: DevCapture?
    let session: PageSession?

    @State private var process: ProcessSample?

    var body: some View {
        if let capture, let session {
            List {
                Section("Load") {
                    metric("Time to first byte", capture.perf.ttfb)
                    metric("First contentful paint", capture.perf.fcp)
                    metric("Largest contentful paint", capture.perf.lcp, target: capture.perf.lcpTarget,
                           path: capture.perf.lcpPath, session: session)
                    metric("DOMContentLoaded", capture.perf.domContentLoaded)
                    metric("Load", capture.perf.load)
                }
                Section("Interaction to Next Paint") {
                    if let worst = capture.perf.inp {
                        metric("\(worst.name) (\(capture.perf.interactionCount) interactions)", worst.duration,
                               target: worst.target, path: worst.path, session: session)
                        metric("Input delay", worst.inputDelay)
                        metric("Processing", worst.processing)
                        metric("Presentation delay", worst.presentationDelay)
                    } else {
                        Text("No interactions yet.").font(HarborDesign.Font.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Process") {
                    if let process {
                        row("Memory", Self.megabytes(process.footprint))
                        row("CPU", process.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "…")
                    } else {
                        Text("Not running.").font(HarborDesign.Font.caption).foregroundStyle(.secondary)
                    }
                }
                if !capture.perf.advice.isEmpty {
                    Section {
                        ForEach(capture.perf.advice, id: \.self) { line in
                            Text(line).font(HarborDesign.Font.bodyRegular).textSelection(.enabled)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .task(id: session.id) { await sampleProcess(of: session) }
        } else {
            DevPanelEmpty()
        }
    }

    private func metric(_ title: String, _ value: Double?, target: String? = nil, path: String? = nil,
                        session: PageSession? = nil) -> some View {
        HStack(spacing: HarborDesign.Spacing.sm) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(HarborDesign.Font.secondary)
                if let target, !target.isEmpty {
                    Text(target).font(HarborDesign.Font.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if let path, !path.isEmpty, let session {
                Button("Show", systemImage: "scope") { session.devHighlight(path) }
                    .harborIconButtons()
            }
            Text(value.map { "\(Int($0.rounded())) ms" } ?? "–")
                .font(HarborDesign.Font.secondary.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(HarborDesign.Font.secondary)
            Spacer()
            Text(value).font(HarborDesign.Font.secondary.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    /// Once a second while this tab is on screen; the task ends when it leaves.
    private func sampleProcess(of session: PageSession) async {
        var previous: (cpu: UInt64, at: UInt64)?
        while !Task.isCancelled {
            let pid = session.webProcessID
            if pid > 0, let usage = Self.rusage(pid) {
                let now = mach_absolute_time()
                let cpu = usage.ri_user_time + usage.ri_system_time
                var percent: Double?
                if let previous, now > previous.at { percent = Double(cpu &- previous.cpu) / Double(now - previous.at) * 100 }
                previous = (cpu, now)
                process = ProcessSample(footprint: usage.ri_phys_footprint, cpuPercent: percent)
            } else {
                process = nil
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// CPU times are mach ticks on Apple Silicon, the same unit as mach_absolute_time, so the ratio needs no timebase.
    private static func rusage(_ pid: Int32) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return result == 0 ? info : nil
    }

    private static func megabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}

private struct ProcessSample {
    var footprint: UInt64
    var cpuPercent: Double?
}
