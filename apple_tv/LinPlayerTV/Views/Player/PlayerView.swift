import SwiftUI
import AVKit

struct PlayerView: View {
    let item: MediaItem
    let apiClient: EmbyApiClient

    @Environment(\.dismiss) private var dismiss
    @StateObject private var playerVM: PlayerViewModel

    init(item: MediaItem, apiClient: EmbyApiClient) {
        self.item = item
        self.apiClient = apiClient
        _playerVM = StateObject(wrappedValue: PlayerViewModel(item: item, apiClient: apiClient))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = playerVM.player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if playerVM.isLoading {
                ProgressView("正在加载...")
                    .tint(AppTheme.brandColor)
                    .foregroundColor(.white)
            } else if let error = playerVM.errorMessage {
                VStack(spacing: AppTheme.Spacing.lg) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundColor(AppTheme.brandColor)
                    Text(error)
                        .foregroundColor(.white)
                    Button("返回") { dismiss() }
                        .brandButton()
                }
            }
        }
        .onAppear { playerVM.setup() }
        .onDisappear { playerVM.cleanup() }
    }
}

@MainActor
final class PlayerViewModel: ObservableObject {
    let item: MediaItem
    let apiClient: EmbyApiClient

    @Published var player: AVPlayer?
    @Published var isLoading = true
    @Published var errorMessage: String?

    private var progressTimer: Timer?
    private var mediaSourceId: String?

    init(item: MediaItem, apiClient: EmbyApiClient) {
        self.item = item
        self.apiClient = apiClient
    }

    func setup() {
        Task {
            await loadPlayback()
        }
    }

    func cleanup() {
        progressTimer?.invalidate()
        progressTimer = nil

        if let player = player, let msid = mediaSourceId {
            let currentTime = player.currentTime()
            let ticks = Int(CMTimeGetSeconds(currentTime) * 10_000_000)
            Task {
                try? await apiClient.reportPlaybackStopped(
                    itemId: item.id,
                    mediaSourceId: msid,
                    positionTicks: ticks
                )
            }
        }

        player?.pause()
        player = nil
    }

    private func loadPlayback() async {
        do {
            let info = try await apiClient.getPlaybackInfo(itemId: item.id)
            guard let source = info.mediaSources.first else {
                errorMessage = "没有可用的媒体源"
                isLoading = false
                return
            }

            mediaSourceId = source.id
            guard let url = apiClient.getVideoStreamURL(
                itemId: item.id,
                mediaSourceId: source.id,
                container: source.container
            ) else {
                errorMessage = "无法生成播放链接"
                isLoading = false
                return
            }

            let avPlayer = AVPlayer(url: url)

            if let positionTicks = item.userData?.playbackPositionTicks, positionTicks > 0 {
                let seconds = Double(positionTicks) / 10_000_000.0
                await avPlayer.seek(to: CMTime(seconds: seconds, preferredTimescale: 1))
            }

            self.player = avPlayer
            self.isLoading = false
            avPlayer.play()

            try? await apiClient.reportPlaybackStart(itemId: item.id, mediaSourceId: source.id)

            startProgressReporting()
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func startProgressReporting() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.reportPlaybackProgress()
            }
        }
    }

    private func reportPlaybackProgress() async {
        guard let player, let msid = mediaSourceId else { return }

        let currentTime = player.currentTime()
        let ticks = Int(CMTimeGetSeconds(currentTime) * 10_000_000)
        let isPaused = player.rate == 0

        try? await apiClient.reportPlaybackProgress(
            itemId: item.id,
            mediaSourceId: msid,
            positionTicks: ticks,
            isPaused: isPaused
        )
    }
}
