import SwiftUI

enum AuditFlowStep {
    case setup
    case capture(AuditSession)
    case processing(AuditSession)
    case results(AuditSession)
}

struct AuditFlowView: View {
    @Environment(\.dismiss) private var dismiss
    let authViewModel: AuthViewModel
    @State private var auditViewModel = AuditViewModel()
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
                        step = .capture(session)
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
                        step = .results(session)
                    }
                case .results(let session):
                    ResultsSummaryView(
                        session: session,
                        auditViewModel: auditViewModel,
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
        case .results: "results"
        }
    }
}
