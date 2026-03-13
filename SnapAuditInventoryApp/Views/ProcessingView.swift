import SwiftUI

struct ProcessingView: View {
    @Environment(\.modelContext) private var modelContext
    let session: AuditSession
    let auditViewModel: AuditViewModel
    let onComplete: () -> Void

    @State private var hasStarted = false

    private let stages: [(label: String, threshold: Double)] = [
        ("Sampling frames", 0.20),
        ("Multi-scale detection", 0.45),
        ("Hotspot analysis", 0.70),
        ("Deduping & counting", 0.85),
        ("Summarizing results", 1.00)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            progressRing
                .padding(.bottom, 32)

            VStack(spacing: 6) {
                Text(auditViewModel.processingProgress >= 1.0 ? "Analysis Complete" : "Analyzing Capture")
                    .font(.title3.weight(.semibold))

                Text(auditViewModel.processingStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(minHeight: 20)
                    .animation(.easeInOut(duration: 0.2), value: auditViewModel.processingStatus)
            }
            .padding(.bottom, 28)

            stageTimeline
                .padding(.horizontal, 32)
                .padding(.bottom, 28)

            sessionInfoCard
                .padding(.horizontal, 24)

            Spacer()

            if auditViewModel.processingProgress >= 1.0 {
                viewResultsButton
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Processing")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: auditViewModel.processingProgress >= 1.0)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            auditViewModel.setup(context: modelContext)
            await auditViewModel.processSession(session)
        }
    }

    private var progressRing: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray5), lineWidth: 8)
                .frame(width: 130, height: 130)

            Circle()
                .trim(from: 0, to: auditViewModel.processingProgress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .frame(width: 130, height: 130)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: auditViewModel.processingProgress)

            VStack(spacing: 2) {
                if auditViewModel.processingProgress >= 1.0 {
                    Image(systemName: "checkmark")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text("\(Int(auditViewModel.processingProgress * 100))%")
                        .font(.title.bold().monospacedDigit())
                        .contentTransition(.numericText())
                }
            }
            .animation(.spring(response: 0.3), value: auditViewModel.processingProgress >= 1.0)
        }
    }

    private var stageTimeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(stages.indices, id: \.self) { i in
                let stage = stages[i]
                let isComplete = auditViewModel.processingProgress >= stage.threshold
                let prevThreshold = i > 0 ? stages[i - 1].threshold : 0.0
                let isActive = auditViewModel.processingProgress >= prevThreshold && auditViewModel.processingProgress < stage.threshold

                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(isComplete ? Color.green : isActive ? Color.blue : Color(.systemGray5))
                            .frame(width: 22, height: 22)
                            .animation(.spring(response: 0.3), value: isComplete)

                        if isComplete {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else if isActive {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.55)
                                .tint(.white)
                        }
                    }

                    Text(stage.label)
                        .font(.subheadline)
                        .foregroundStyle(isComplete ? .primary : isActive ? .primary : .tertiary)
                        .animation(.easeInOut, value: isComplete)
                }

                if i < stages.count - 1 {
                    Rectangle()
                        .fill(isComplete ? Color.green.opacity(0.4) : Color(.systemGray5))
                        .frame(width: 2, height: 14)
                        .padding(.leading, 10)
                        .animation(.easeInOut, value: isComplete)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var sessionInfoCard: some View {
        VStack(spacing: 8) {
            infoRow(label: "Shelf", value: session.locationName)
            Divider()
            infoRow(label: "Mode", value: session.mode.displayName)
            Divider()
            infoRow(label: "Capture", value: session.captureQualityMode.badgeTitle)
            Divider()
            infoRow(label: "Media", value: "\(session.capturedMedia.count) items")
            Divider()
            infoRow(label: "Workflow", value: session.reviewWorkflow.displayName)
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(.rect(cornerRadius: 14))
    }

    private var viewResultsButton: some View {
        Button {
            onComplete()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.doc.horizontal")
                    .font(.body.weight(.semibold))
                Text("View Results")
                    .font(.body.weight(.semibold))
                let pending = session.pendingLineItemCount
                if pending > 0 {
                    Text("\(pending) pending")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.white.opacity(0.25), in: Capsule())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.blue)
            .foregroundStyle(.white)
            .clipShape(.rect(cornerRadius: 14))
        }
        .sensoryFeedback(.success, trigger: auditViewModel.processingProgress >= 1.0)
    }

    private var ringColor: Color {
        if auditViewModel.processingProgress >= 1.0 { return .green }
        if auditViewModel.processingProgress > 0.6 { return .blue }
        return Color(.systemOrange)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.weight(.medium))
        }
    }
}
