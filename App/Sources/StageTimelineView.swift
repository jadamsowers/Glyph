import SwiftUI
import VectorEngine

/// One thumbnail per pipeline stage. Stages light up as the pipeline streams them in; clicking
/// one shows it on the canvas; ▶ replays the whole refinement sequence.
struct StageTimelineView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button {
                model.isReplaying ? model.stopReplay() : model.replay()
            } label: {
                Image(systemName: model.isReplaying ? "stop.fill" : "play.fill")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.completed.isEmpty)
            .help("Replay the refinement stages")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Stage.allCases, id: \.self) { stage in
                        StageThumbnail(stage: stage,
                                       picture: model.completed.contains(stage) ? model.pictures[stage] : nil,
                                       isSelected: model.displayedStage == stage,
                                       duration: nil)
                            .onTapGesture { model.selectedStage = model.selectedStage == stage ? nil : stage }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(10)
        .frame(height: 112)
        .animation(.easeOut(duration: 0.25), value: model.completed)
    }
}

struct StageThumbnail: View {
    var stage: Stage
    var picture: CGImage?
    var isSelected: Bool
    var duration: Duration?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let picture {
                    Image(decorative: picture, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: 4))
                        .padding(3)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 96, height: 68)
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            }
            Text("\(stage.rawValue + 1). \(stage.title)")
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .contentShape(Rectangle())
    }
}
