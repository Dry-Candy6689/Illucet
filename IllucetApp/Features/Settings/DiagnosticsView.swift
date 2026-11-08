import SwiftUI
import UIKit

struct DiagnosticsView: View {
    @Environment(\.illucetPalette) private var theme
    @EnvironmentObject private var model: IllucetAppModel

    var body: some View {
        Form {
            Section("Privacy") {
                LabeledContent("Analytics", value: "Off")
                LabeledContent("Advertising", value: "None")
                LabeledContent("Account", value: "Not required")
                LabeledContent("Hosted backend", value: "None")

                Toggle(
                    "SponsorBlock event logging",
                    isOn: $model.settings
                        .sponsorBlockDiagnosticLoggingEnabled
                )
                Text(
                    "When enabled, Illucet records redacted SponsorBlock lookup, validation, selection, and execution outcomes without URLs, titles, response bodies, or segment payloads."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    "Exported diagnostics redact URLs, signed media addresses, cookies, tokens, and authorization headers."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Diagnostic report") {
                Button {
                    model.exportDiagnostics()
                } label: {
                    Label(
                        "Create redacted report",
                        systemImage: "square.and.arrow.up"
                    )
                }
                if let URL = model.exportedDiagnosticURL {
                    ShareLink(item: URL) {
                        Label(
                            "Share generated report",
                            systemImage: "doc.badge.arrow.up"
                        )
                    }
                }
                Button("Refresh event list") {
                    model.refreshDiagnostics()
                }
                Button("Clear logs", role: .destructive) {
                    model.clearDiagnostics()
                }
            }

            Section("Embedded runtime proof") {
                Button {
                    model.runStage0Proof()
                } label: {
                    HStack {
                        if model.isRunningStage0 {
                            ProgressView()
                        } else {
                            Image(systemName: "testtube.2")
                        }
                        Text(
                            model.isRunningStage0
                                ? "Running proof…"
                                : "Run runtime proof"
                        )
                    }
                }
                .disabled(model.isRunningStage0)
                .accessibilityIdentifier("diagnostics.stage0")
                if let report = model.stage0Report {
                    LabeledContent(
                        "Result",
                        value: proofSummary(report)
                    )
                    ForEach(report.checksForInspection) { check in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(check.name)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                brandedText(check.status.rawValue)
                                    .font(.caption.bold())
                                    .foregroundStyle(
                                        proofStatusColor(check.status)
                                    )
                            }
                            Text(check.evidence)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(
                            "diagnostics.stage0.check.\(check.id)"
                        )
                    }
                } else {
                    Text(
                        "This executes the embedded Python, QuickJS, and controlled FFmpeg checks on the current target. Simulator results are labeled as simulator evidence."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("Recent events") {
                if model.diagnosticEntries.isEmpty {
                    Text("No diagnostic events recorded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.diagnosticEntries.prefix(30)) { entry in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.event)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                brandedText(entry.level.rawValue)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(entry.subsystem)
                                .font(.caption.monospaced())
                                .foregroundStyle(theme.foregroundAccent)
                            if let detail = entry.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                    }
                }
            }
        }
        .settingsFormBackground()
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshDiagnostics() }
    }

    private func proofSummary(_ report: Stage0ProofReport) -> String {
        var parts = [
            "\(report.passedCount) PASS",
            "\(report.failedCount) FAIL",
        ]
        if report.blockedCount > 0 {
            parts.append("\(report.blockedCount) BLOCKED")
        }
        if report.notRunCount > 0 {
            parts.append("\(report.notRunCount) NOT RUN")
        }
        return parts.joined(separator: " • ")
    }

    private func proofStatusColor(_ status: ProofStatus) -> Color {
        switch status {
        case .pass: IllucetTheme.success
        case .fail: IllucetTheme.danger
        case .blocked: IllucetTheme.warning
        case .notRun: .secondary
        }
    }
}
