import Foundation
import MusicKit
import SwiftUI

/// One player for the entire app. Authorization is requested only after a tap.
@MainActor
final class AppleMusicStore: ObservableObject {
    @Published private(set) var authorization: MusicAuthorization.Status = .notDetermined
    @Published private(set) var albums: [Album] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var songs: [Song] = []
    /// Apple Music 推荐（个性化推荐，失败 / 为空时退回曲库排行榜），排在首页网格最前面
    @Published private(set) var recommended: [MusicCollection] = []
    /// 运行时实际成功的请求：MusicPersonalRecommendationsRequest / MusicCatalogChartsRequest / 空
    @Published private(set) var recommendationSource = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isConnecting = false
    @Published private(set) var hasMoreAlbums = false
    @Published private(set) var hasMorePlaylists = false
    @Published private(set) var canPlayCatalog = false
    @Published private(set) var subscriptionKnown = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var currentTitle = ""
    @Published private(set) var currentArtist = ""
    @Published private(set) var currentArtwork: Artwork?
    @Published private(set) var currentSongID: MusicItemID?
    /// 队列条目自身的 ID（有时与 Song ID 不同）
    @Published private(set) var currentCatalogID: MusicItemID?
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?

    // 演示专辑（无音频文件）的播放状态：选中曲目、播放 / 暂停、模拟的播放时钟
    static let demoDuration: Double = 300
    @Published private(set) var demoTrack = 0
    @Published private(set) var demoPlaying = true
    @Published private(set) var demoElapsed: Double = 0.18 * AppleMusicStore.demoDuration
    /// 点演示曲目：点当前行 = 暂停 / 继续；点其它行 = 切到该曲并开始播放
    // MARK: - 收藏（t105u）
    /// 本地收藏集合（UserDefaults）。MusicKit 只能「加入资料库」不能移除，所以取消收藏只记在本地。
    @Published private(set) var favorites: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "vinyl.favorites") ?? [])

    func isFavorite(_ key: String) -> Bool { favorites.contains(key) }

    private func saveFavorites() {
        UserDefaults.standard.set(Array(favorites), forKey: "vinyl.favorites")
    }

    /// 切换收藏；Apple Music 曲库歌曲在收藏时同时加入用户资料库，失败则静默回滚。
    func toggleFavorite(_ key: String, song: Song? = nil, fromCatalog: Bool = false) async {
        if favorites.contains(key) {
            favorites.remove(key); saveFavorites()
            return
        }
        favorites.insert(key); saveFavorites()
        guard let song, fromCatalog, authorized else { return }
        do { try await MusicLibrary.shared.add(song) }
        catch { favorites.remove(key); saveFavorites() }
    }

    func seekDemo(_ fraction: Double) {
        demoElapsed = min(1, max(0, fraction)) * Self.demoDuration
    }

    func selectDemo(_ index: Int) {
        if index == demoTrack { demoPlaying.toggle() }
        else { demoTrack = index; demoPlaying = true; demoElapsed = 0 }
    }
    /// 迷你播放条第一行：只显示歌名（不带 A1 · 面序前缀）
    var demoMiniTitle: String {
        let tracks = AlbumData.tracks
        guard tracks.indices.contains(demoTrack) else { return "" }
        return tracks[demoTrack].title.components(separatedBy: " - ").last ?? tracks[demoTrack].title
    }
    @Published var showingPlayer = false

    // MusicKit's player requires a provisioned app identity. Do not initialize it
    // while simply displaying onboarding (including unsigned CI launches).
    private var existingPlayer: ApplicationMusicPlayer?
    private var player: ApplicationMusicPlayer {
        if let existingPlayer { return existingPlayer }
        let created = ApplicationMusicPlayer.shared
        existingPlayer = created
        return created
    }
    private var libraryLoaded = false
    private let pageSize = 50
    private let connectionKey = "appleMusicConnectionRequested"
    var authorized: Bool { authorization == .authorized }
    var connectionRequested: Bool { UserDefaults.standard.bool(forKey: connectionKey) }
    /// 首页网格的真实内容：资料库歌曲（合成一张）→ 歌单 → 专辑。
    var collections: [MusicCollection] {
        guard authorized else { return [] }
        var items: [MusicCollection] = recommended
        if !songs.isEmpty { items.append(.librarySongs(songs)) }
        items += playlists.map { .playlist($0) }
        items += albums.map { .album($0, catalog: false) }
        return items
    }
    var hasCurrentTrack: Bool { !currentTitle.isEmpty }

    /// 这首歌是否为正在播放（或暂停中的）当前曲目。
    /// 资料库 Song 与播放队列条目的 ID 可能不同（资料库 ID vs 曲库 ID），
    /// 所以先比 ID，再退回比「标题 + 艺人」。
    func isCurrent(_ song: Song) -> Bool {
        guard hasCurrentTrack else { return false }
        if let id = currentSongID, id == song.id { return true }
        if let id = currentCatalogID, id == song.id { return true }
        return song.title == currentTitle && (currentArtist.isEmpty || song.artistName == currentArtist)
    }

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        UserDefaults.standard.set(true, forKey: connectionKey)
        authorization = await MusicAuthorization.request()
        await refreshAccess()
    }

    /// Recheck on returning from Settings; discard personal data after revocation.
    func refreshAccess() async {
        // A first launch is just onboarding. Once the user has requested a
        // connection, always consult the system again; this flag is not consent.
        guard UserDefaults.standard.bool(forKey: connectionKey) else { return }
        authorization = MusicAuthorization.currentStatus
        guard authorized else {
            showingPlayer = false
            albums = []
            playlists = []
            songs = []
            recommended = []
            recommendationSource = ""
            libraryLoaded = false
            hasMoreAlbums = false
            hasMorePlaylists = false
            canPlayCatalog = false
            subscriptionKnown = false
            existingPlayer?.stop()
            syncPlayback()
            return
        }
        do {
            canPlayCatalog = try await MusicSubscription.current.canPlayCatalogContent
            subscriptionKnown = true
        } catch {
            subscriptionKnown = false
            // Library playback can still be available for purchased/local music.
        }
        if !libraryLoaded { await loadLibrary() }
        if recommended.isEmpty { await loadRecommendations() }
    }

    /// 先取个性化推荐（专辑 + 歌单，去重）；失败或为空（如无订阅）时退回当前地区的排行榜。
    func loadRecommendations() async {
        guard authorized else { return }
        var items: [MusicCollection] = []
        var seen = Set<String>()
        func add(_ item: MusicCollection) { if seen.insert(item.id).inserted { items.append(item) } }
        do {
            var request = MusicPersonalRecommendationsRequest()
            request.limit = 12
            let response = try await request.response()
            for recommendation in response.recommendations {
                recommendation.albums.forEach { add(.album($0, catalog: true)) }
                recommendation.playlists.forEach { add(.playlist($0)) }
            }
            if !items.isEmpty, authorized {
                recommended = items
                recommendationSource = "MusicPersonalRecommendationsRequest"
                return
            }
        } catch is CancellationError { return
        } catch { /* 无订阅 / 无推荐：退回排行榜 */ }
        do {
            var request = MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Album.self, Playlist.self])
            request.limit = 24
            let response = try await request.response()
            response.albumCharts.flatMap { $0.items }.forEach { add(.album($0, catalog: true)) }
            response.playlistCharts.flatMap { $0.items }.forEach { add(.playlist($0)) }
            guard authorized else { return }
            recommended = items
            recommendationSource = items.isEmpty ? "" : "MusicCatalogChartsRequest"
        } catch is CancellationError {
        } catch { report(error, action: "读取推荐失败") }
    }

    func loadLibrary() async {
        guard authorized, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var albumRequest = MusicLibraryRequest<Album>()
            albumRequest.limit = pageSize
            var playlistRequest = MusicLibraryRequest<Playlist>()
            playlistRequest.limit = pageSize
            var songRequest = MusicLibraryRequest<Song>()
            songRequest.limit = 200
            let albumResponse = try await albumRequest.response()
            let playlistResponse = try await playlistRequest.response()
            let songResponse = try? await songRequest.response()
            try Task.checkCancellation()
            guard MusicAuthorization.currentStatus == .authorized else { return }
            albums = Array(albumResponse.items)
            playlists = Array(playlistResponse.items)
            songs = songResponse.map { Array($0.items) } ?? []
            hasMoreAlbums = albums.count == pageSize
            hasMorePlaylists = playlists.count == pageSize
            libraryLoaded = true
        } catch is CancellationError {
        } catch { report(error, action: "读取资料库失败") }
    }

    func loadMore(playlists loadPlaylists: Bool) async {
        guard authorized, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            if loadPlaylists {
                var request = MusicLibraryRequest<Playlist>()
                request.limit = pageSize
                request.offset = playlists.count
                let items = try await request.response().items
                try Task.checkCancellation()
                guard authorized else { return }
                playlists.append(contentsOf: items.filter { item in !playlists.contains { $0.id == item.id } })
                hasMorePlaylists = items.count == pageSize
            } else {
                var request = MusicLibraryRequest<Album>()
                request.limit = pageSize
                request.offset = albums.count
                let items = try await request.response().items
                try Task.checkCancellation()
                guard authorized else { return }
                albums.append(contentsOf: items.filter { item in !albums.contains { $0.id == item.id } })
                hasMoreAlbums = items.count == pageSize
            }
        } catch is CancellationError {
        } catch { report(error, action: "加载更多失败") }
    }

    func play(_ song: Song, in songs: [Song], fromCatalog: Bool) async {
        guard authorized, !isPreparing else { return }
        guard song.playParameters != nil else {
            errorMessage = "这首歌曲当前无法播放，可能尚未在你的地区上架。"
            return
        }
        isPreparing = true
        defer { isPreparing = false; syncPlayback() }
        do {
            if fromCatalog {
                canPlayCatalog = try await MusicSubscription.current.canPlayCatalogContent
                subscriptionKnown = true
                guard canPlayCatalog else {
                    errorMessage = "播放 Apple Music 曲库歌曲需要有效订阅。你仍可尝试播放资料库中的已购音乐。"
                    return
                }
            }
            player.queue = ApplicationMusicPlayer.Queue(for: songs, startingAt: song)
            try await player.play()
        } catch { report(error, action: "播放失败") }
    }

    func togglePlayback() async {
        guard authorized, hasCurrentTrack, !isPreparing else { return }
        if player.state.playbackStatus == .playing {
            player.pause()
        } else {
            isPreparing = true
            defer { isPreparing = false }
            do { try await player.play() }
            catch { report(error, action: "继续播放失败") }
        }
        syncPlayback()
    }

    func skip(next: Bool) async {
        guard authorized, hasCurrentTrack, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false; syncPlayback() }
        do {
            if next { try await player.skipToNextEntry() }
            else { try await player.skipToPreviousEntry() }
        } catch { report(error, action: "切换歌曲失败") }
    }

    func seek(to value: Double) {
        guard hasCurrentTrack, duration > 0, value.isFinite else { return }
        player.playbackTime = min(duration, max(0, value))
        syncPlayback()
    }

    /// Poll only while an active scene exists. Track changes and interruption state
    /// come from MusicKit, never from optimistic button state.
    func observePlayback() async {
        while !Task.isCancelled {
            syncPlayback()
            if demoPlaying {
                demoElapsed += 0.25
                if demoElapsed >= Self.demoDuration { demoElapsed = 0 }
            }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
        }
    }

    private func syncPlayback() {
        guard authorized else {
            currentTitle = ""
            currentArtist = ""
            currentArtwork = nil
            currentSongID = nil
            currentCatalogID = nil
            position = 0
            duration = 0
            isPlaying = false
            return
        }
        let entry = player.queue.currentEntry
        currentTitle = entry?.title ?? ""
        currentArtist = entry?.subtitle ?? ""
        currentArtwork = entry?.artwork
        currentCatalogID = entry.map { MusicItemID($0.id) }
        if case .song(let song) = entry?.item {
            currentSongID = song.id
            duration = song.duration ?? 0
        } else {
            currentSongID = nil
            duration = 0
        }
        let time = player.playbackTime
        position = time.isFinite ? max(0, time) : 0
        isPlaying = player.state.playbackStatus == .playing
    }

    private func report(_ error: Error, action: String) {
        errorMessage = "\(action)：\(error.localizedDescription)"
    }
}

enum MusicCollection: Identifiable {
    case album(Album, catalog: Bool)
    case playlist(Playlist)
    case librarySongs([Song])

    var id: String {
        switch self {
        case .album(let album, let catalog): return "\(catalog)-album-\(album.id)"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        case .librarySongs: return "library-songs"
        }
    }
    var title: String {
        switch self {
        case .album(let album, _): return album.title
        case .playlist(let playlist): return playlist.name
        case .librarySongs: return "资料库歌曲"
        }
    }
    var artist: String {
        switch self {
        case .album(let album, _): return album.artistName
        case .playlist(let playlist): return playlist.curatorName ?? "Apple Music"
        case .librarySongs(let songs): return "\(songs.count) 首歌曲"
        }
    }
    var artwork: Artwork? {
        switch self {
        case .album(let album, _): return album.artwork
        case .playlist(let playlist): return playlist.artwork
        case .librarySongs(let songs): return songs.first(where: { $0.artwork != nil })?.artwork
        }
    }
    var isCatalog: Bool {
        switch self {
        case .album(_, let catalog): return catalog
        case .playlist(let playlist): return playlist.id.rawValue.hasPrefix("pl.")   // 曲库歌单 ID 以 pl. 开头
        case .librarySongs: return false
        }
    }

    func songs() async throws -> [Song] {
        if case .librarySongs(let songs) = self { return songs }
        var tracks: MusicItemCollection<MusicKit.Track>?
        switch self {
        case .librarySongs: return []
        case .album(let album, _): tracks = try await album.with(.tracks).tracks
        case .playlist(let playlist): tracks = try await playlist.with(.tracks).tracks
        }
        var songs: [Song] = []
        while let batch = tracks {
            try Task.checkCancellation()
            songs.append(contentsOf: batch.compactMap {
                if case .song(let song) = $0 { return song }
                return nil
            })
            tracks = batch.hasNextBatch ? try await batch.nextBatch() : nil
        }
        return songs
    }
}
