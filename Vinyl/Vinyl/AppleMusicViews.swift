import MusicKit
import SwiftUI

struct MusicArtwork: View {
    let artwork: Artwork?
    var size: CGFloat = 72

    var body: some View {
        Group {
            if let artwork {
                ArtworkImage(artwork, width: size, height: size)
            } else {
                ZStack {
                    Color.secondary.opacity(0.1)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
    }
}

struct MusicAccessView: View {
    @EnvironmentObject private var music: AppleMusicStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("连接 Apple Music", systemImage: "music.note")
        } description: {
            Text(music.authorization == .denied
                 ? "访问已关闭。请在系统设置中允许 Vinyl 访问媒体与 Apple Music。"
                 : music.authorization == .restricted
                 ? "此设备限制了音乐访问，请检查屏幕使用时间或设备管理设置。"
                 : "浏览你的专辑和歌单，搜索音乐并在 Vinyl 中播放。")
        } actions: {
            if music.authorization == .denied {
                Button("打开设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }.buttonStyle(.borderedProminent)
            } else if music.authorization != .restricted {
                Button("连接 Apple Music") { Task { await music.connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(music.isConnecting)
            }
        }
    }
}

struct MusicSearchView: View {
    @EnvironmentObject private var music: AppleMusicStore
    @State private var query = ""
    @State private var albums: [Album] = []
    @State private var songs: [Song] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var selected: MusicCollection?

    var body: some View {
        NavigationStack {
            Group {
                if !music.authorized {
                    MusicAccessView()
                } else {
                    List {
                        if loading { ProgressView("正在搜索") }
                        if let failure { Text(failure).foregroundStyle(.secondary) }
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            ContentUnavailableView("搜索 Apple Music", systemImage: "magnifyingglass",
                                                   description: Text("输入歌曲、艺人或专辑名称。"))
                        } else if !loading && failure == nil && albums.isEmpty && songs.isEmpty {
                            ContentUnavailableView.search(text: query)
                        }
                        if !albums.isEmpty {
                            Section("专辑") {
                                ForEach(albums) { album in
                                    Button {
                                        selected = .album(album, catalog: true)
                                    } label: {
                                        HStack {
                                            MusicArtwork(artwork: album.artwork, size: 48)
                                            VStack(alignment: .leading) {
                                                Text(album.title)
                                                Text(album.artistName).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if !songs.isEmpty {
                            Section("歌曲") {
                                ForEach(songs) { song in
                                    MusicSongRow(song: song) {
                                        await music.play(song, in: songs, fromCatalog: true)
                                    }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .searchable(text: $query, prompt: "歌曲、艺人、专辑")
                }
            }
            .navigationTitle("搜索")
            .background { AuroraBackground() }
            .modifier(MiniPlayerBar())
            .sheet(item: $selected) { MusicCollectionView(collection: $0) }
            .task(id: "\(music.authorized)-\(query)") { await search() }
            .onChange(of: music.authorized) { _, authorized in
                if !authorized {
                    selected = nil
                    albums = []
                    songs = []
                }
            }
        }
    }

    private func search() async {
        albums = []
        songs = []
        failure = nil
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard music.authorized, !term.isEmpty else { loading = false; return }
        loading = true
        do {
            try await Task.sleep(for: .milliseconds(350))
            var request = MusicCatalogSearchRequest(term: term, types: [Album.self, Song.self])
            request.limit = 20
            let response = try await request.response()
            try Task.checkCancellation()
            albums = Array(response.albums)
            songs = Array(response.songs)
            loading = false
        } catch is CancellationError {
            // A newer query owns the loading/results state.
        } catch {
            guard !Task.isCancelled else { return }
            failure = "搜索失败：\(error.localizedDescription)"
            loading = false
        }
    }
}

struct MusicSongRow: View {
    @EnvironmentObject private var music: AppleMusicStore
    let song: Song
    let play: () async -> Void

    var body: some View {
        Button { Task { await play() } } label: {
            HStack {
                MusicArtwork(artwork: song.artwork, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).foregroundStyle(.primary)
                    Text(song.artistName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if music.isCurrent(song) {
                    PlaybackSymbol(isPlaying: music.isPlaying)
                }
                if song.playParameters == nil {
                    Text("不可播放").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(musicTime(song.duration ?? 0)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(music.isPreparing || song.playParameters == nil)
        .accessibilityLabel("播放 \(song.title)，\(song.artistName)")
    }
}

struct MusicCollectionView: View {
    @EnvironmentObject private var music: AppleMusicStore
    @Environment(\.dismiss) private var dismiss
    let collection: MusicCollection
    @State private var songs: [Song] = []
    @State private var loading = true
    @State private var failure: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            List {
                VStack(spacing: 12) {
                    MusicArtwork(artwork: collection.artwork, size: 230)
                    Text(collection.title).font(.title2.bold())
                    Text(collection.artist).foregroundStyle(.secondary)
                    Button("播放", systemImage: "play.fill") {
                        if let first = songs.first(where: { $0.playParameters != nil }) {
                            Task { await music.play(first, in: songs, fromCatalog: collection.isCatalog) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(loading || music.isPreparing || !songs.contains { $0.playParameters != nil })
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                if loading { ProgressView("正在读取曲目") }
                if let failure {
                    Text(failure)
                    Button("重试") { attempt += 1 }
                } else if !loading && songs.isEmpty {
                    Text("没有可显示的歌曲。此列表可能为空或仅包含音乐视频。").foregroundStyle(.secondary)
                }
                ForEach(Array(songs.enumerated()), id: \.offset) { _, song in
                    MusicSongRow(song: song) {
                        await music.play(song, in: songs, fromCatalog: collection.isCatalog)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background { AuroraBackground() }
            .navigationTitle("Apple Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .safeAreaInset(edge: .top) { MusicErrorBanner() }
            .onChange(of: music.authorized) { _, authorized in
                if !authorized { songs = []; dismiss() }
            }
            .task(id: attempt) {
                loading = true
                failure = nil
                do {
                    let loaded = try await collection.songs()
                    try Task.checkCancellation()
                    songs = loaded
                    loading = false
                } catch is CancellationError {
                } catch {
                    failure = "读取曲目失败：\(error.localizedDescription)"
                    loading = false
                }
            }
        }
    }
}

struct MusicAccountView: View {
    @EnvironmentObject private var music: AppleMusicStore

    var body: some View {
        NavigationStack {
            Form {
                Section("Apple Music") {
                    if music.authorized {
                        Label("已允许访问音乐", systemImage: "checkmark.circle")
                        Text(music.subscriptionKnown
                             ? (music.canPlayCatalog ? "订阅可播放 Apple Music 曲库" : "当前订阅不可播放曲库")
                             : "订阅状态暂时无法获取")
                        Button("刷新连接状态") { Task { await music.refreshAccess() } }
                        Text(music.recommendationSource.isEmpty ? "推荐：暂无" : "推荐来源：\(music.recommendationSource)")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        MusicAccessView()
                    }
                }
                Section {
                    Text("首页按最近播放、最近添加、推荐、资料库歌曲、歌单和专辑排列；滑到底部继续加载，点封面即开始播放。未授权时显示内置演示封面。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("我的")
            .modifier(MiniPlayerBar())
        }
    }
}

func musicTime(_ seconds: TimeInterval) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}

/// Inline errors stay visible above presented collection/player content.
struct MusicErrorBanner: View {
    @EnvironmentObject private var music: AppleMusicStore
    var body: some View {
        if let message = music.errorMessage {
            HStack(alignment: .top) {
                Text(message).font(.callout)
                Spacer(minLength: 8)
                Button("关闭提示", systemImage: "xmark") { music.errorMessage = nil }
                    .labelStyle(.iconOnly)
            }
            .padding()
            .background(.regularMaterial)
        }
    }
}

/// 其它 tab 也挂同一个 mini player（与首页同一套宽度 / 12pt 间距 token）。
struct MiniPlayerBar: ViewModifier {
    @EnvironmentObject private var music: AppleMusicStore
    private var show: Bool { music.hasCurrentTrack || DemoMode.enabled }   // t158u
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaBar(edge: .bottom, spacing: 0) {
                if show {
                    MiniPlayer()
                        .padding(.horizontal, DS.tabBarSideInset)
                        .padding(.bottom, DS.miniPlayerBottomPadding)
                }
            }
        } else {
            content.safeAreaInset(edge: .bottom) {
                if show { MiniPlayer().padding(.horizontal, 16).padding(.bottom, 10) }
            }
        }
    }
}

/// 用固定渲染尺寸取 MusicKit 封面，再按容器缩放：转场每帧改 frame 时不会反复重新请求图片。
struct ArtworkFill: View {
    let artwork: Artwork?
    var render: CGFloat = 320

    var body: some View {
        GeometryReader { geo in
            let side = max(1, geo.size.width)
            Group {
                if let artwork {
                    ArtworkImage(artwork, width: render, height: render)
                } else {
                    ZStack {
                        Color(hex: 0xE4E0DC)
                        Image(systemName: "music.note")
                            .font(.system(size: render * 0.3))
                            .foregroundStyle(DS.secondary)
                    }
                    .frame(width: render, height: render)
                }
            }
            .frame(width: render, height: render)
            .scaleEffect(side / render, anchor: .topLeading)
            .frame(width: side, height: side, alignment: .topLeading)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}
