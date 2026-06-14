import SwiftUI

struct HeroBanner: View {
    let items: [MediaItem]
    let apiClient: EmbyApiClient
    let onPlay: (MediaItem) -> Void

    @State private var currentIndex = 0
    @State private var timer: Timer?

    private var currentItem: MediaItem? {
        guard !items.isEmpty else { return nil }
        return items[currentIndex % items.count]
    }

    var body: some View {
        if let item = currentItem {
            ZStack(alignment: .bottomLeading) {
                bannerImage(for: item)

                LinearGradient(
                    colors: [.clear, .clear, AppTheme.background.opacity(0.7), AppTheme.background],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    logoOrTitle(for: item)

                    HStack(spacing: AppTheme.Spacing.md) {
                        if let rating = item.communityRating {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .foregroundColor(AppTheme.brandColor)
                                Text(String(format: "%.1f", rating))
                            }
                            .font(.system(size: AppTheme.FontSize.body))
                        }

                        if let year = item.productionYear {
                            Text("\(year)")
                                .font(.system(size: AppTheme.FontSize.body))
                                .foregroundColor(AppTheme.textSecondary)
                        }

                        if let runtime = item.formattedRuntime {
                            Text(runtime)
                                .font(.system(size: AppTheme.FontSize.body))
                                .foregroundColor(AppTheme.textSecondary)
                        }

                        if let rating = item.officialRating {
                            Text(rating)
                                .font(.system(size: 22))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.white.opacity(0.2))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }

                    if let genres = item.genres, !genres.isEmpty {
                        HStack(spacing: AppTheme.Spacing.sm) {
                            ForEach(genres.prefix(4), id: \.self) { genre in
                                Text(genre)
                                    .font(.system(size: 22))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.white.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }

                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: AppTheme.FontSize.caption))
                            .foregroundColor(AppTheme.textSecondary)
                            .lineLimit(2)
                            .frame(maxWidth: 800, alignment: .leading)
                    }

                    HStack(spacing: AppTheme.Spacing.md) {
                        Button(action: { onPlay(item) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text(item.progress != nil ? "继续播放" : "播放")
                            }
                            .brandButton()
                        }
                        .buttonStyle(.plain)

                        NavigationLink(destination: DetailView(itemId: item.id, apiClient: apiClient)) {
                            HStack(spacing: 8) {
                                Image(systemName: "info.circle")
                                Text("详情")
                            }
                            .font(.system(size: AppTheme.FontSize.body, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, AppTheme.Spacing.xl)
                            .padding(.vertical, AppTheme.Spacing.md)
                            .background(Color.white.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadius))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, AppTheme.Spacing.sm)

                    if items.count > 1 {
                        indicators
                    }
                }
                .padding(AppTheme.Spacing.xxl)
                .padding(.bottom, AppTheme.Spacing.xl)
            }
            .frame(height: 600)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, AppTheme.Spacing.xxl)
            .onAppear { startTimer() }
            .onDisappear { stopTimer() }
            .id(currentIndex)
            .transition(.opacity)
        }
    }

    private func bannerImage(for item: MediaItem) -> some View {
        let url: URL? = {
            if let tag = item.backdropImageTag {
                return apiClient.backdropImageURL(item.id, tag: tag, maxWidth: 1920)
            }
            if let tag = item.thumbImageTag {
                return apiClient.thumbImageURL(item.id, tag: tag, maxWidth: 1920)
            }
            return apiClient.primaryImageURL(item.id, tag: item.primaryImageTag, maxWidth: 1920)
        }()

        return AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            default:
                Rectangle()
                    .fill(AppTheme.surfaceColor)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 600)
        .clipped()
    }

    /// 优先使用 Logo 艺术字图片，无 Logo 时回退到文字标题
    @ViewBuilder
    private func logoOrTitle(for item: MediaItem) -> some View {
        if let logoURL = apiClient.logoImageURL(
            item.logoItemId ?? item.id,
            tag: item.logoImageTag
        ) {
            AsyncImage(url: logoURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 300, maxHeight: 60)
                default:
                    titleText(item.name)
                }
            }
        } else {
            titleText(item.name)
        }
    }

    private func titleText(_ name: String) -> some View {
        Text(name)
            .font(.system(size: AppTheme.FontSize.title1, weight: .bold))
            .foregroundColor(.white)
            .lineLimit(2)
    }

    private var indicators: some View {
        HStack(spacing: 8) {
            ForEach(0..<items.count, id: \.self) { index in
                Circle()
                    .fill(index == currentIndex % items.count ? AppTheme.brandColor : Color.white.opacity(0.3))
                    .frame(width: 10, height: 10)
            }
        }
    }

    private func startTimer() {
        guard items.count > 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                currentIndex = (currentIndex + 1) % items.count
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
