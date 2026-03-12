import SwiftUI

enum AuditFlowStep {
    case setup
    case capture(AuditSession)
    case processing(AuditSession)
    case review(AuditSession)
    case results(AuditSession)
    case liveScan(AuditSession)
    case liveScanResults(AuditSession)
}

struct AuditFlowView: View {
    @Environment(\.dismiss) private var dismiss
    let authViewModel: AuthViewModel
    @State private var auditViewModel = AuditViewModel()
    @State private var liveScanViewModel = LiveScanViewModel()
    @State private var step: AuditFlowStep = .setup

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .setup:
                    NewAuditSetupView(
                        authViewModel: authViewModel,
                        auditViewModel: auditViewModel
                    ) { session in
                        if session.mode == .realTimeScan {
                            step = .liveScan(session)
                        } else {
                            step = .capture(session)
                        }
                    }
                case .capture(let session):
                    CaptureView(
                        session: session,
                        auditViewModel: auditViewModel,
                        isAdmin: authViewModel.isAdmin
                    ) {
                        step = .processing(session)
                    }
                case .processing(let session):
                    ProcessingView(
                        session: session,
                        auditViewModel: auditViewModel
                    ) {
                        // Route to review if there are pending items, otherwise straight to results
                        if session.status == .reviewRequired {
                            step = .review(session)
                        } else {
                            step = .results(session)
                        }
                    }
                case .review(let session):
                    AuditReviewGateView(
                        session: session,
                        auditViewModel: auditViewModel,
                        onFinalize: {
                            step = .results(session)
                        }
                    )
                case .results(let session):
                    ResultsSummaryView(
                        session: session,
                        auditViewModel: auditViewModel,
                        onDismiss: { dismiss() }
                    )
                case .liveScan(let session):
                    LiveScanView(
                        session: session,
                        viewModel: liveScanViewModel,
                        onFinish: {
                            step = .liveScanResults(session)
                        }
                    )
                case .liveScanResults(let session):
                    LiveScanResultsView(
                        viewModel: liveScanViewModel,
                        session: session,
                        onDismiss: { dismiss() }
                    )
                }
            }
            .animation(.easeInOut(duration: 0.25), value: stepId)
        }
    }

    private var stepId: String {
        switch step {
        case .setup: "setup"
        case .capture: "capture"
        case .processing: "processing"
        case .review: "review"
        case .results: "results"
        case .liveScan: "liveScan"
        case .liveScanResults: "liveScanResults"
        }
    }
}

// MARK: - Review Gate View

/// Wraps ReviewQueueView with a finalize button that only enables when all items are resolved.
struct AuditReviewGateView: View {
    let session: AuditSession
    let auditViewModel: AuditViewModel
    let onFinalize: () -> Void

    @State private var showReviewQueue = true

    private var pendingCount: Int {
        session.lineItems.reduce(0) { total, item in
            total + item.evidence.filter { $0.reviewStatus == .pending }.count
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Required")
                        .font(.headline)
                    Text(pendingCount > 0
                         ? "\(pendingCount) item\(pendingCount == 1 ? "" : "s") need\(pendingCount == 1 ? "s" : "") review"
                         : "All items reviewed")
                        .font(.caption)
                        .foregroundStyle(pendingCount > 0 ? .orange : .green)
                }
                Spacer()
                Button {
                    if auditViewModel.finalizeSession(session) {
                        onFinalize()
                    }
                } label: {
                    Label("Finalize", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(pendingCount == 0 ? .green : .gray.opacity(0.3), in: Capsule())
                        .foregroundStyle(pendingCount == 0 ? .white : .secondary)
                }
                .disabled(pendingCount > 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial)

            ReviewQueueView(session: session, auditViewModel: auditViewModel)
        }
        .navigationBarBackButtonHidden()
    }
}

