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
                    .disabled(music.isLoading)
            }
        }
    }
}

struct MusicLibraryView: View {
    @EnvironmentObject private var music: AppleMusicStore
    @State private var showsPlaylists = false
    @State private var selected: MusicCollection?

    var body: some View {
        NavigationStack {
            Group {
                if !music.authorized {
                    MusicAccessView()
                } else {
                    ScrollView {
                        Picker("资料库类型", selection: $showsPlaylists) {
                            Text("专辑").tag(false)
                            Text("歌单").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .padding(.bottom)
                        if music.isLoading && music.albums.isEmpty && music.playlists.isEmpty {
                            ProgressView("正在读取资料库").padding(40)
                        } else if showsPlaylists ? music.playlists.isEmpty : music.albums.isEmpty {
                            ContentUnavailableView("资料库暂无内容", systemImage: "square.stack",
                                                   description: Text("在 Apple Music 中收藏专辑或歌单，或前往搜索发现音乐。"))
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 16)], spacing: 20) {
                                if showsPlaylists {
                                    ForEach(music.playlists) { playlist in
                                        collectionButton(.playlist(playlist))
                                    }
                                } else {
                                    ForEach(music.albums) { album in
                                        collectionButton(.album(album, catalog: false))
                                    }
                                }
                            }
                        }
                        if showsPlaylists ? music.hasMorePlaylists : music.hasMoreAlbums {
                            Button("加载更多") { Task { await music.loadMore(playlists: showsPlaylists) } }
                                .disabled(music.isLoading)
                                .padding()
                        }
                    }
                    .padding(.horizontal, 20)
                    .refreshable { await music.loadLibrary() }
                    .toolbar {
                        Button("刷新", systemImage: "arrow.clockwise") {
                            Task { await music.loadLibrary() }
                        }.disabled(music.isLoading)
                    }
                }
            }
            .navigationTitle("资料库")
            .background { AuroraBackground() }
            .safeAreaInset(edge: .bottom) { MusicMiniPlayer() }
            .sheet(item: $selected) { MusicCollectionView(collection: $0) }
        }
    }

    private func collectionButton(_ collection: MusicCollection) -> some View {
        Button {
            selected = collection
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                MusicArtwork(artwork: collection.artwork, size: 100)
                Text(collection.title).font(.caption.weight(.semibold)).lineLimit(2)
                Text(collection.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(collection.title)，\(collection.artist)")
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
            .safeAreaInset(edge: .bottom) { MusicMiniPlayer() }
            .sheet(item: $selected) { MusicCollectionView(collection: $0) }
            .task(id: "\(music.authorized)-\(query)") { await search() }
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
                if music.currentSongID == song.id {
                    Image(systemName: music.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
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
            .safeAreaInset(edge: .bottom) { MusicMiniPlayer(expands: false) }
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

struct MusicMiniPlayer: View {
    @EnvironmentObject private var music: AppleMusicStore
    var expands = true

    var body: some View {
        if music.hasCurrentTrack {
            HStack(spacing: 10) {
                Button { music.showingPlayer = true } label: {
                    HStack {
                        MusicArtwork(artwork: music.currentArtwork, size: 36)
                        VStack(alignment: .leading) {
                            Text(music.currentTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(music.currentArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }.buttonStyle(.plain).disabled(!expands)
                Button(music.isPlaying ? "暂停" : "播放",
                       systemImage: music.isPlaying ? "pause.fill" : "play.fill") {
                    Task { await music.togglePlayback() }
                }.labelStyle(.iconOnly).disabled(music.isPreparing)
                Button("下一首", systemImage: "forward.end.fill") {
                    Task { await music.skip(next: true) }
                }.labelStyle(.iconOnly).disabled(music.isPreparing)
            }
            .padding(.horizontal, 14)
            .glassCapsule(height: 56)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}

struct MusicPlayerView: View {
    @EnvironmentObject private var music: AppleMusicStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrubbing = false
    @State private var scrubValue = 0.0
    @State private var rotation = 0.0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    ZStack {
                        Circle().fill(Color(white: 0.08))
                        ForEach(0..<14) { index in
                            Circle().stroke(.white.opacity(0.08), lineWidth: 1)
                                .padding(CGFloat(index * 5 + 10))
                        }
                        MusicArtwork(artwork: music.currentArtwork, size: 104).clipShape(Circle())
                        Circle().fill(.white).frame(width: 7, height: 7)
                    }
                    .frame(width: 280, height: 280)
                    .rotationEffect(.degrees(rotation))
                    .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text(music.currentTitle).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(music.currentArtist).foregroundStyle(.secondary)
                    }
                    VStack {
                        Slider(value: Binding(get: {
                            scrubbing ? scrubValue : min(music.position, max(1, music.duration))
                        }, set: { scrubValue = $0 }),
                               in: 0...max(1, music.duration),
                               onEditingChanged: { editing in
                            if editing { scrubValue = music.position }
                            scrubbing = editing
                            if !editing { music.seek(to: scrubValue) }
                        })
                        .disabled(music.duration <= 0)
                        .accessibilityLabel("播放进度")
                        HStack {
                            Text(musicTime(scrubbing ? scrubValue : music.position))
                            Spacer()
                            Text(musicTime(music.duration))
                        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 42) {
                        Button("上一首", systemImage: "backward.end.fill") { Task { await music.skip(next: false) } }
                        Button(music.isPlaying ? "暂停" : "播放",
                               systemImage: music.isPlaying ? "pause.fill" : "play.fill") {
                            Task { await music.togglePlayback() }
                        }
                        Button("下一首", systemImage: "forward.end.fill") { Task { await music.skip(next: true) } }
                    }
                    .font(.title)
                    .labelStyle(.iconOnly)
                    .disabled(music.isPreparing || !music.hasCurrentTrack)
                    if music.isPreparing { ProgressView("正在准备播放") }
                }
                .padding(28)
            }
            .background { AuroraBackground() }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
            .task(id: music.isPlaying && !reduceMotion) {
                guard music.isPlaying, !reduceMotion else { return }
                while !Task.isCancelled {
                    withAnimation(.linear(duration: 0.1)) { rotation += 4.5 }
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                }
            }
        }
    }
}

struct MusicAccountView: View {
    @EnvironmentObject private var music: AppleMusicStore
    @State private var showsDemo = false

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
                    } else {
                        MusicAccessView()
                    }
                }
                Section {
                    Button("查看黑胶动效演示") { showsDemo = true }
                } footer: {
                    Text("演示使用内置素材，不会播放音乐。")
                }
            }
            .navigationTitle("我的")
            .safeAreaInset(edge: .bottom) { MusicMiniPlayer() }
            .fullScreenCover(isPresented: $showsDemo) {
                LibraryView().overlay(alignment: .topTrailing) {
                    Button("退出演示") { showsDemo = false }
                        .buttonStyle(.borderedProminent).padding()
                }
            }
        }
    }
}

private func musicTime(_ seconds: TimeInterval) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}
