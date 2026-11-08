#if DEBUG
import SwiftUI

@MainActor
final class Stage0HarnessModel: ObservableObject {
    @Published var isRunning = false
    @Published var report: Stage0ProofReport?

    func run() {
        guard !isRunning else {
            return
        }
        isRunning = true
        report = nil

        Task {
            let completed = await Stage0ProofRunner.run()
            report = completed
            isRunning = false
            print(
                "ILLUCET_STAGE0_REPORT_READY pass=\(completed.passedCount) fail=\(completed.failedCount)"
            )
        }
    }
}

struct Stage0HarnessView: View {
    @StateObject private var model = Stage0HarnessModel()

    var body: some View {
        NavigationStack {
            List {
                Section("Purpose") {
                    Text(
                        "\(AppIdentity.displayName) is for media you own or are authorized to save."
                    )
                    Text(
                        "This diagnostic harness exists only to prove the embedded runtimes before the complete interface is built."
                    )
                    .foregroundStyle(.secondary)
                }

                Section("Target") {
                    LabeledContent(
                        "Current validation",
                        value: currentValidationTarget
                    )
                    LabeledContent(
                        "Physical iPhone",
                        value: physicalDeviceStatus
                    )
                }

                Section("Embedded Runtime Proofs") {
                    Button {
                        model.run()
                    } label: {
                        if model.isRunning {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Run real proof")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("stage0.run")

                    if let report = model.report {
                        ForEach(report.checksForInspection) { check in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(check.name)
                                    Spacer()
                                    brandedText(check.status.rawValue)
                                        .foregroundStyle(
                                            check.status == .pass
                                                ? .green
                                                : .red
                                        )
                                }
                                Text(check.evidence)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            .accessibilityIdentifier("stage0.\(check.id)")
                        }
                    }
                }
            }
            .navigationTitle("Stage 0 Proof")
        }
        .task {
            if ProcessInfo.processInfo.arguments.contains("--stage0-autorun") {
                model.run()
            }
        }
    }

    private var currentValidationTarget: String {
        #if targetEnvironment(simulator)
        "iOS Simulator"
        #else
        "Physical iOS device"
        #endif
    }

    private var physicalDeviceStatus: String {
        #if targetEnvironment(simulator)
        "BLOCKED — not connected"
        #else
        "Current validation target"
        #endif
    }
}
#endif
