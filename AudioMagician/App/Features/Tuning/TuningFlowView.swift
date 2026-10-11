import SwiftUI

/// Hosts one tuning session. The root is the speaker layout (or results when
/// reviewing a past session); every later step is pushed onto `flow.path`.
struct TuningFlowView: View {
    @Bindable var flow: TuningFlow
    var close: () -> Void

    var body: some View {
        NavigationStack(path: $flow.path) {
            Group {
                if flow.isReview {
                    Color.clear
                } else {
                    SpeakersView()
                }
            }
            .navigationDestination(for: TuningStep.self) { step in
                destination(step)
                    .navigationBarBackButtonHidden(step == .analyzing || step == .results)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { close() } label: { Image(systemName: "xmark") }
                        .tint(Theme.mist)
                        .accessibilityLabel("Close")
                }
            }
        }
        .environment(flow)
        .onChange(of: flow.path) { _, path in
            // Reviewing a saved result: popping past the first screen closes it.
            if flow.isReview && path.isEmpty { close() }
        }
    }

    @ViewBuilder
    private func destination(_ step: TuningStep) -> some View {
        switch step {
        case .speakers: SpeakersView()
        case .correction: CorrectionChoiceView()
        case .distances: DistancesView()
        case .connect: ConnectView()
        case .checklist: ReceiverChecklistView()
        case .placement: PlacementView()
        case .quiet: QuietCheckView()
        case .volume: VolumeCheckView()
        case .sweeps: SweepSeatView(seatIndex: 0)
        case .tones: ToneLevelsView(mode: .measure)
        case .seats: MoreSeatsView()
        case .analyzing: AnalyzingView()
        case .results: ResultsView(close: close)
        case .details: DetailsView()
        case .plan: FixPlanView()
        case .verify: VerifyView()
        }
    }
}
