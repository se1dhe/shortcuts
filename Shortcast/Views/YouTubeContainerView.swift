import SwiftUI

/// Unified YouTube entry point with two sub-tabs: Search and Trending Movie Shorts.
struct YouTubeContainerView: View {
    let onVideoReady: (URL, VideoSourceMetadata?) -> Void

    @Environment(AppSettings.self) private var settings
    @Environment(MovieShortsBrowserModel.self) private var browser

    private func label(_ tab: MovieShortsBrowserModel.Tab) -> LocalizedStringKey {
        switch tab {
        case .search: "Search"
        case .shorts: "Movie Shorts"
        }
    }

    var body: some View {
        @Bindable var browser = browser
        @Bindable var settings = settings

        return VStack(spacing: 14) {
            HStack(spacing: 16) {
                Picker("", selection: $browser.selectedTab) {
                    ForEach(MovieShortsBrowserModel.Tab.allCases) { tab in
                        Text(label(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)

                Toggle(isOn: $settings.transcriptionEnabled) {
                    Label("Транскрибация (Whisper)", systemImage: "captions.bubble")
                        .font(.callout.weight(.medium))
                }
                .toggleStyle(.switch)
                .help("Выключите транскрибацию, чтобы редактор открывался мгновенно после скачивания.")
            }

            switch browser.selectedTab {
            case .search:
                YouTubeSearchView(onVideoReady: onVideoReady)
            case .shorts:
                YouTubeMovieClipsView(onVideoReady: onVideoReady)
            }
        }
    }
}


#Preview {
    YouTubeContainerView { _, _ in }
        .environment(AppSettings())
        .environment(MovieShortsBrowserModel())
}
