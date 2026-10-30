import SwiftUI

/// Preparing the selected film and its audio track before thematic analysis.
struct ProcessingView: View {
    @Environment(WorkspaceModel.self) private var workspace
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(StudioTheme.accent)
                .frame(width: 64, height: 64)
                .background(StudioTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
            ProgressView().controlSize(.large).tint(StudioTheme.accent)
            Text(workspace.inputPreparationMessage ?? "Подготовка фильма…")
                .font(.title3.weight(.semibold))
            if let job = workspace.job {
                Text("\(job.fileName) · \(job.durationLabel)").font(.callout).foregroundStyle(StudioTheme.muted)
            }
        }
        .studioPanel(padding: 36)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudioTheme.background)
    }
}
