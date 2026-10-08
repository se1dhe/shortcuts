import SwiftUI
import AVKit

/// Dedicated view for managing, previewing, and selecting background music tracks.
struct MusicLibraryView: View {
    @Environment(AppSettings.self) private var settings
    @State private var tracks: [BackgroundMusicTrack] = []
    @State private var isLoading = false
    @State private var currentlyPlayingTrackURL: URL?
    @State private var player: AVPlayer?
    @State private var selectedFilter: String = "Все"
    
    private let filters = ["Все", "prrodan", "cinematic", "drama", "suspense", "sigma"]
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            
            if isLoading {
                ProgressView("Загрузка фоновой музыки…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredTracks.isEmpty {
                emptyState
            } else {
                trackList
            }
            
            Divider()
            footer
        }
        .task(id: settings.customMusicDirectory) {
            BackgroundMusicService.shared.startWatching(customDirectory: settings.customMusicDirectory)
            await refreshTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: BackgroundMusicService.musicLibraryDidChange)) { _ in
            Task { await refreshTracks() }
        }
        .onDisappear {
            stopPlayback()
        }
    }
    
    private var filteredTracks: [BackgroundMusicTrack] {
        if selectedFilter == "Все" {
            return tracks
        }
        return tracks.filter { $0.moodTag.lowercased() == selectedFilter.lowercased() }
    }
    
    // MARK: - Header
    
    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Библиотека фоновой музыки")
                    .font(.title2.weight(.bold))
                Text("Саундтреки для кинематографичных шортсов с автоматическим дакингом под голос (-14 LUFS)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Picker("Настроение", selection: $selectedFilter) {
                ForEach(filters, id: \.self) { filter in
                    Text(filter == "Все" ? "Все настроения" : filter.capitalized).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)
            
            Button {
                importCustomAudioTrack()
            } label: {
                Label("Добавить трек…", systemImage: "plus.circle")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .help("Импортировать свой аудиофайл в библиотеку шортсов")

            Button {
                Task { await refreshTracks() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Обновить список треков")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
    
    // MARK: - List
    
    private var trackList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(filteredTracks) { track in
                    trackRow(track)
                }
            }
            .padding(20)
        }
    }
    
    private func trackRow(_ track: BackgroundMusicTrack) -> some View {
        let isPlaying = currentlyPlayingTrackURL == track.url
        
        return HStack(spacing: 14) {
            Button {
                togglePlayback(for: track)
            } label: {
                ZStack {
                    Circle()
                        .fill(isPlaying ? Color.accentColor : Color.secondary.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundStyle(isPlaying ? .white : .primary)
                        .font(.system(size: 14))
                }
            }
            .buttonStyle(.plain)
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(track.name)
                        .font(.body.weight(.semibold))
                    if track.isBuiltIn {
                        Text("Встроенный")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    } else {
                        Text("Пользовательский")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.15), in: Capsule())
                            .foregroundStyle(.green)
                    }
                }
                
                Text(track.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Text(track.moodTag.uppercased())
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(.secondary)
            
            Button {
                NSWorkspace.shared.selectFile(track.url.path, inFileViewerRootedAtPath: track.url.deletingLastPathComponent().path)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Показать в Finder")
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isPlaying ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1.5)
        )
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Треки не найдены")
                .font(.headline)
            Text("Выберите папку с вашей музыкой в формате MP3, WAV, AAC или M4A")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Выбрать папку с музыкой…") {
                selectCustomMusicFolder()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Footer
    
    private var footer: some View {
        HStack {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text("Папка музыки:")
                .font(.caption.weight(.medium))
            Text(settings.customMusicDirectoryLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            
            Spacer()
            
            if settings.customMusicDirectory != nil {
                Button("Сбросить") {
                    settings.customMusicDirectory = nil
                }
                .controlSize(.small)
            }
            
            Button("Выбрать другую папку…") {
                selectCustomMusicFolder()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
    
    // MARK: - Playback & Discovery
    
    private func refreshTracks() async {
        isLoading = true
        tracks = await BackgroundMusicService.shared.loadAvailableTracks(customDirectory: settings.customMusicDirectory)
        isLoading = false
    }
    
    private func togglePlayback(for track: BackgroundMusicTrack) {
        if currentlyPlayingTrackURL == track.url {
            stopPlayback()
        } else {
            stopPlayback()
            currentlyPlayingTrackURL = track.url
            let p = AVPlayer(url: track.url)
            p.play()
            player = p
        }
    }
    
    private func stopPlayback() {
        player?.pause()
        player = nil
        currentlyPlayingTrackURL = nil
    }
    
    private func importCustomAudioTrack() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            .audio,
            .mp3,
            .wav,
            .mpeg4Audio,
            .aiff
        ]
        panel.message = "Выберите аудиофайл для добавления в библиотеку шортсов"
        panel.prompt = "Добавить трек"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                _ = try? await BackgroundMusicService.shared.importUserTrack(from: url)
                await refreshTracks()
            }
        }
    }

    private func selectCustomMusicFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Выберите папку с фоновой музыкой"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                settings.customMusicDirectory = url
                Task { await refreshTracks() }
            }
        }
    }
}
