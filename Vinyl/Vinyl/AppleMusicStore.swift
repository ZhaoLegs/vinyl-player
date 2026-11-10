import Foundation
import MusicKit
import SwiftUI

/// Only progress displays observe the four-times-per-second playback clock.
@MainActor
final class PlaybackTimeline: ObservableObject {
    @Published var position: TimeInterval = 0
    @Published var demoElapsed: Double = 0.18 * AppleMusicStore.demoDuration
}

/// One player for the entire app. Authorization is requested only after a tap.
@MainActor
final class AppleMusicStore: ObservableObject {
    @Published private(set) var authorization: MusicAuthorization.Status = .notDetermined
    @Published private(set) var albums: [Album] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var songs: [Song] = []
    @Published private(set) var recentlyPlayed: [MusicCollection] = []
    /// Apple Music 推荐（个性化推荐，失败 / 为空时退回曲库排行榜）
    @Published private(set) var recommended: [MusicCollection] = []
    /// 仅在数据变化时合并首页，避免播放时钟每次更新都重新排序整个资料库。
    /// t193u：启动时先用上次的首页（磁盘缓存）立即渲染，后台刷新后按 id 原位替换
    @Published private(set) var collections: [MusicCollection] = GridScrollProfile.collections() ?? HomeCache.load()
    @Published private(set) var homePageRevision = 0
    /// 运行时实际成功的请求：MusicPersonalRecommendationsRequest / MusicCatalogChartsRequest / 空
    @Published private(set) var recommendationSource = ""
    @Published private(set) var isLoading = false
    /// t158u：首页至少完整加载过一次（之前显示占位格，之后才显示「空 / 失败」提示）
    @Published private(set) var homeLoadedOnce = false
    @Published private(set) var isConnecting = false
    @Published private(set) var canPlayCatalog = false
    @Published private(set) var subscriptionKnown = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false
    @Published private(set) var currentTitle = ""
    @Published private(set) var currentArtist = ""
    @Published private(set) var currentArtwork: Artwork?
    /// t226u：当前曲目所属专辑名（歌单里的歌 → mini player 显示它自己专辑的封面）
    @Published private(set) var currentAlbumTitle = ""
    @Published private(set) var currentSongID: MusicItemID?
    /// 队列条目自身的 ID（有时与 Song ID 不同）
    @Published private(set) var currentCatalogID: MusicItemID?
    let timeline = PlaybackTimeline()
    private(set) var position: TimeInterval {
        get { timeline.position }
        set { if timeline.position != newValue { timeline.position = newValue } }
    }
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?

    // 演示专辑（无音频文件）的播放状态：选中曲目、播放 / 暂停、模拟的播放时钟
    static let demoDuration: Double = 300
    @Published private(set) var demoTrack = 0
    @Published private(set) var demoPlaying = true
    private(set) var demoElapsed: Double {
        get { timeline.demoElapsed }
        set { if timeline.demoElapsed != newValue { timeline.demoElapsed = newValue } }
    }
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

    /// t126u：正在播放的演示专辑封面（迷你播放条小唱片中心标签用）
    @Published private(set) var demoCoverName = DS.coverName(AlbumData.featuredIndex)

    /// t132u：演示专辑的「下一首」—— 专辑队列中的下一曲（末曲后回到第一首），并开始播放
    func nextDemo() {
        let n = max(1, AlbumData.tracks.count)
        demoTrack = (demoTrack + 1) % n
        demoPlaying = true
        demoElapsed = 0
    }

    func selectDemo(_ index: Int, cover: String? = nil) {
        if let cover, cover != demoCoverName {
            demoCoverName = cover
            if index == demoTrack { demoPlaying = true; demoElapsed = 0; return }
        }
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
    private var albumCursor = MusicPageCursor(pageSize: 50)
    private var playlistCursor = MusicPageCursor(pageSize: 50)
    private var songCursor = MusicPageCursor(pageSize: 200)
    private var accessGeneration = 0
    private var nextHomeSource = 0

    private enum RecommendationPage {
        case groups(MusicItemCollection<MusicPersonalRecommendation>)
        case albums(MusicItemCollection<Album>)
        case playlists(MusicItemCollection<Playlist>)
    }
    private var recommendationPages: [RecommendationPage] = []
    private let connectionKey = "appleMusicConnectionRequested"
    var authorized: Bool { authorization == .authorized }
    var connectionRequested: Bool { UserDefaults.standard.bool(forKey: connectionKey) }
    var hasMoreHome: Bool {
        authorized && (albumCursor.hasMore || playlistCursor.hasMore
                       || songCursor.hasMore || !recommendationPages.isEmpty)
    }

    /// 最近播放 → 最近添加 → 推荐 → 资料库歌曲 → 歌单 → 专辑；跨来源只显示一次。
    private func rebuildHome() {
        let libraryAlbums = albums.map { MusicCollection.album($0, catalog: false) }
        let libraryPlaylists = playlists.map { MusicCollection.playlist($0) }
        let recentlyAdded = HomeFeed.latest(libraryAlbums + libraryPlaylists,
                                            date: \.libraryAddedDate, limit: 24)
        collections = HomeFeed.merged(
            groups: [recentlyPlayed, recentlyAdded, recommended,
                     songs.isEmpty ? [] : [.librarySongs(songs)], libraryPlaylists, libraryAlbums],
            identityKeys: \.identityKeys,
            // 保留来源位置，但已在资料库里的同专辑使用本地曲目，避免额外要求曲库订阅。
            preferredItems: libraryPlaylists + libraryAlbums
        ).filter { !hiddenHome.contains($0.id) }   // t192u：本地「从首页隐藏」
    }

    /// 授权撤销后，即使旧请求迟到，也不能重新填回个人数据。
    private func canApply(_ generation: Int) -> Bool {
        generation == accessGeneration && authorized
            && MusicAuthorization.currentStatus == .authorized && !Task.isCancelled
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
        let previousAuthorization = authorization
        authorization = MusicAuthorization.currentStatus
        guard authorized else {
            accessGeneration += 1
            showingPlayer = false
            albums = []
            playlists = []
            songs = []
            recentlyPlayed = []
            recommended = []
            collections = []
            HomeCache.clear()
            recommendationPages = []
            recommendationSource = ""
            libraryLoaded = false
            homeLoadedOnce = false
            albumCursor = MusicPageCursor(pageSize: pageSize)
            playlistCursor = MusicPageCursor(pageSize: pageSize)
            songCursor = MusicPageCursor(pageSize: 200)
            nextHomeSource = 0
            isLoading = false
            homePageRevision += 1
            canPlayCatalog = false
            subscriptionKnown = false
            existingPlayer?.stop()
            syncPlayback()
            return
        }
        if previousAuthorization != .authorized { accessGeneration += 1 }
        let generation = accessGeneration
        do {
            let canPlay = try await MusicSubscription.current.canPlayCatalogContent
            guard canApply(generation) else { return }
            canPlayCatalog = canPlay
            subscriptionKnown = true
        } catch {
            guard canApply(generation) else { return }
            subscriptionKnown = false
            // Library playback can still be available for purchased/local music.
        }
        // t158u：首页加载放进非结构化 Task —— scenePhase 抖动会取消外层 .task，
        // 原来请求被一起取消（-999）而 isLoading 又挡住了重试，首页就一直停在空 / 假数据。
        let reloadLibrary = !libraryLoaded, reloadRecs = recommended.isEmpty
        await Task { await self.refreshHome(reloadLibrary: reloadLibrary, reloadRecommendations: reloadRecs) }.value
    }

    func refreshHome(reloadLibrary: Bool = true, reloadRecommendations: Bool = true) async {
        guard authorized, !isLoading else { return }
        let generation = accessGeneration
        guard canApply(generation) else { return }
        isLoading = true
        errorMessage = nil
        defer { if generation == accessGeneration { isLoading = false } }
        if reloadLibrary { await loadLibrary(generation: generation) }
        await loadRecentlyPlayed(generation: generation)
        if reloadRecommendations { await loadRecommendations(generation: generation) }
        guard canApply(generation) else { return }
        nextHomeSource = 0
        rebuildHome()
        homeLoadedOnce = true
        homePageRevision += 1
        HomeCache.save(collections)
        print("[t158u] home loaded: \(collections.count) items at \(String(format: "%.2f", Date().timeIntervalSince(createdAt)))s since store init")
    }
    private let createdAt = Date()

    /// t148u：同一会话里同类提示最多出现一次（不反复弹）
    private var reportedActions = Set<String>()

    /// t148u：Apple Music API `GET /v1/me/recent/played` 的 limit 上限是 10（原来传 24 → 400 Invalid Parameter Value）。
    /// 每页 10 条，用 nextBatch 翻页凑满 24；失败重试一次，仍失败就静默不显示「最近播放」分组（首页还有资料库 / 推荐）。
    private func loadRecentlyPlayed(generation: Int) async {
        guard canApply(generation) else { return }
        var lastError: Error?
        for attempt in 0..<2 {
            do {
                var request = MusicRecentlyPlayedContainerRequest()
                request.limit = 10
                var batch = try await request.response().items
                var all = Array(batch)
                // 翻页失败不影响已取到的第一页（try?）
                while all.count < 24, batch.hasNextBatch, let next = try? await batch.nextBatch(limit: 10) {
                    batch = next
                    all += Array(next)
                }
                guard canApply(generation) else { return }
                recentlyPlayed = HomeFeed.merged(groups: [all.compactMap { item in
                    switch item {
                    case .album(let album): return .album(album, catalog: true)
                    case .playlist(let playlist): return .playlist(playlist)
                    case .station: return nil
                    @unknown default: return nil
                    }
                }], identityKeys: \.identityKeys)
                return
            } catch is CancellationError {
                return
            } catch {
                lastError = error
                print("[Vinyl] MusicRecentlyPlayedContainerRequest attempt \(attempt + 1) failed: \(String(reflecting: error))")
                if attempt == 0 { try? await Task.sleep(for: .seconds(1.5)) }
                guard canApply(generation) else { return }
            }
        }
        // 两次都失败：静默降级（不显示最近播放分组），本会话最多一次非阻塞提示
        recentlyPlayed = []
        if let lastError { reportOnce(lastError, action: "读取最近播放失败") }
    }

    private func recommendationContent(_ groups: MusicItemCollection<MusicPersonalRecommendation>)
        -> (items: [MusicCollection], pages: [RecommendationPage]) {
        var items: [MusicCollection] = []
        var pages: [RecommendationPage] = []
        for group in groups {
            items += group.albums.map { .album($0, catalog: true) }
            items += group.playlists.map { .playlist($0) }
            if group.albums.hasNextBatch { pages.append(.albums(group.albums)) }
            if group.playlists.hasNextBatch { pages.append(.playlists(group.playlists)) }
        }
        if groups.hasNextBatch { pages.append(.groups(groups)) }
        return (items, pages)
    }

    /// 先取个性化推荐（专辑 + 歌单，去重）；失败或为空（如无订阅）时退回当前地区的排行榜。
    private func loadRecommendations(generation: Int) async {
        guard canApply(generation) else { return }
        do {
            var request = MusicPersonalRecommendationsRequest()
            request.limit = 12
            let response = try await request.response()
            guard canApply(generation) else { return }
            let content = recommendationContent(response.recommendations)
            if !content.items.isEmpty {
                recommended = HomeFeed.merged(groups: [content.items], identityKeys: \.identityKeys)
                recommendationPages = content.pages
                recommendationSource = "MusicPersonalRecommendationsRequest"
                return
            }
        } catch is CancellationError { return
        } catch { /* 无订阅 / 无推荐：退回排行榜 */ }
        guard canApply(generation) else { return }
        do {
            var request = MusicCatalogChartsRequest(kinds: [.mostPlayed], types: [Album.self, Playlist.self])
            request.limit = 24
            let response = try await request.response()
            guard canApply(generation) else { return }
            var items: [MusicCollection] = []
            var pages: [RecommendationPage] = []
            for chart in response.albumCharts {
                items += chart.items.map { .album($0, catalog: true) }
                if chart.items.hasNextBatch { pages.append(.albums(chart.items)) }
            }
            for chart in response.playlistCharts {
                items += chart.items.map { .playlist($0) }
                if chart.items.hasNextBatch { pages.append(.playlists(chart.items)) }
            }
            recommended = HomeFeed.merged(groups: [items], identityKeys: \.identityKeys)
            recommendationPages = pages
            recommendationSource = items.isEmpty ? "" : "MusicCatalogChartsRequest"
        } catch is CancellationError {
        } catch {
            if canApply(generation) { report(error, action: "读取推荐失败") }
        }
    }

    private func loadLibrary(generation: Int) async {
        guard canApply(generation) else { return }
        do {
            var albumRequest = MusicLibraryRequest<Album>()
            albumRequest.limit = pageSize
            albumRequest.sort(by: \.libraryAddedDate, ascending: false)
            var playlistRequest = MusicLibraryRequest<Playlist>()
            playlistRequest.limit = pageSize
            playlistRequest.sort(by: \.libraryAddedDate, ascending: false)
            var songRequest = MusicLibraryRequest<Song>()
            songRequest.limit = songCursor.pageSize
            let albumResponse = try await albumRequest.response()
            let playlistResponse = try await playlistRequest.response()
            let songResponse = try? await songRequest.response()
            guard canApply(generation) else { return }
            albums = HomeFeed.merged(groups: [Array(albumResponse.items)], identityKeys: { [$0.id.rawValue] })
            playlists = HomeFeed.merged(groups: [Array(playlistResponse.items)], identityKeys: { [$0.id.rawValue] })
            songs = HomeFeed.merged(groups: [songResponse.map { Array($0.items) } ?? []],
                                    identityKeys: { [$0.id.rawValue] })
            albumCursor = MusicPageCursor(pageSize: pageSize)
            playlistCursor = MusicPageCursor(pageSize: pageSize)
            songCursor = MusicPageCursor(pageSize: 200)
            albumCursor.consume(albumResponse.items.count)
            playlistCursor.consume(playlistResponse.items.count)
            songCursor.consume(songResponse?.items.count ?? 0)
            libraryLoaded = true
        } catch is CancellationError {
        } catch {
            if canApply(generation) { report(error, action: "读取资料库失败") }
        }
    }

    /// 每次轮流取一个来源的一页，歌曲或重复页不会让网格底部的加载触发器停住。
    func loadMoreHome() async {
        guard hasMoreHome, !isLoading else { return }
        let generation = accessGeneration
        guard canApply(generation) else { return }
        let available = [playlistCursor.hasMore, albumCursor.hasMore,
                         !recommendationPages.isEmpty, songCursor.hasMore]
        guard let source = (0..<available.count).map({ (nextHomeSource + $0) % available.count })
            .first(where: { available[$0] }) else { return }
        isLoading = true
        defer { if generation == accessGeneration { isLoading = false } }
        do {
            switch source {
            case 0:
                var request = MusicLibraryRequest<Playlist>()
                request.limit = pageSize
                request.offset = playlistCursor.offset
                request.sort(by: \.libraryAddedDate, ascending: false)
                let items = try await request.response().items
                guard canApply(generation) else { return }
                playlists = HomeFeed.merged(groups: [playlists, Array(items)], identityKeys: { [$0.id.rawValue] })
                playlistCursor.consume(items.count)
            case 1:
                var request = MusicLibraryRequest<Album>()
                request.limit = pageSize
                request.offset = albumCursor.offset
                request.sort(by: \.libraryAddedDate, ascending: false)
                let items = try await request.response().items
                guard canApply(generation) else { return }
                albums = HomeFeed.merged(groups: [albums, Array(items)], identityKeys: { [$0.id.rawValue] })
                albumCursor.consume(items.count)
            case 2:
                try await loadMoreRecommendations(generation: generation)
            default:
                var request = MusicLibraryRequest<Song>()
                request.limit = songCursor.pageSize
                request.offset = songCursor.offset
                let items = try await request.response().items
                guard canApply(generation) else { return }
                songs = HomeFeed.merged(groups: [songs, Array(items)], identityKeys: { [$0.id.rawValue] })
                songCursor.consume(items.count)
            }
            guard canApply(generation) else { return }
            nextHomeSource = (source + 1) % available.count
            rebuildHome()
            homePageRevision += 1
        } catch is CancellationError {
        } catch {
            if canApply(generation) { report(error, action: "加载更多失败") }
        }
    }

    private func loadMoreRecommendations(generation: Int) async throws {
        guard let page = recommendationPages.first else { return }
        var items: [MusicCollection] = []
        var pages: [RecommendationPage] = []
        switch page {
        case .groups(let groups):
            if let next = try await groups.nextBatch(limit: 12) {
                let content = recommendationContent(next)
                items = content.items
                pages = content.pages
            }
        case .albums(let albums):
            if let next = try await albums.nextBatch(limit: pageSize) {
                items = next.map { .album($0, catalog: true) }
                if next.hasNextBatch { pages.append(.albums(next)) }
            }
        case .playlists(let playlists):
            if let next = try await playlists.nextBatch(limit: pageSize) {
                items = next.map { .playlist($0) }
                if next.hasNextBatch { pages.append(.playlists(next)) }
            }
        }
        guard canApply(generation) else { return }
        recommendationPages.removeFirst()
        recommendationPages += pages
        recommended = HomeFeed.merged(groups: [recommended, items], identityKeys: \.identityKeys)
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
            if !currentTitle.isEmpty { currentTitle = "" }
            if !currentArtist.isEmpty { currentArtist = "" }
            if currentArtwork != nil { currentArtwork = nil }
            if currentSongID != nil { currentSongID = nil }
            if currentCatalogID != nil { currentCatalogID = nil }
            position = 0
            if duration != 0 { duration = 0 }
            if isPlaying { isPlaying = false }
            return
        }
        let entry = player.queue.currentEntry
        let title = entry?.title ?? "", artist = entry?.subtitle ?? ""
        let artwork = entry?.artwork
        let catalogID = entry.map { MusicItemID($0.id) }
        if currentTitle != title { currentTitle = title }
        if currentArtist != artist { currentArtist = artist }
        if currentArtwork != artwork { currentArtwork = artwork }
        if currentCatalogID != catalogID { currentCatalogID = catalogID }
        let songID: MusicItemID?
        let songDuration: TimeInterval
        if case .song(let song) = entry?.item {
            songID = song.id
            songDuration = song.duration ?? 0
            if currentAlbumTitle != (song.albumTitle ?? "") { currentAlbumTitle = song.albumTitle ?? "" }
        } else {
            songID = nil
            songDuration = 0
        }
        if currentSongID != songID { currentSongID = songID }
        if duration != songDuration { duration = songDuration }
        let time = player.playbackTime
        position = time.isFinite ? max(0, time) : 0
        let playing = player.state.playbackStatus == .playing
        if isPlaying != playing { isPlaying = playing }
    }

    /// The profiling timer supplies a fixed queue snapshot at the real player's 4 Hz cadence.
    func profilePlayback(time: TimeInterval) {
        guard TracklistProfile.enabled, let song = TracklistProfile.songs.first else { return }
        if currentTitle != song.title { currentTitle = song.title }
        if currentArtist != song.artistName { currentArtist = song.artistName }
        if currentArtwork != nil { currentArtwork = nil }
        if currentSongID != song.id { currentSongID = song.id }
        if currentCatalogID != song.id { currentCatalogID = song.id }
        if duration != (song.duration ?? 0) { duration = song.duration ?? 0 }
        position = time
        if !isPlaying { isPlaying = true }
    }

    private func report(_ error: Error, action: String) {
        errorMessage = "\(action)：\(error.localizedDescription)"
    }

    private func reportOnce(_ error: Error, action: String) {
        guard !reportedActions.contains(action) else { return }
        reportedActions.insert(action)
        report(error, action: action)
    }
}

enum MusicCollection: Identifiable {
    case album(Album, catalog: Bool)
    case playlist(Playlist)
    case librarySongs([Song])

    var id: String {
        switch self {
        case .album(let album, _): return "album-\(album.id)"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        case .librarySongs: return "library-songs"
        }
    }
    var identityKeys: [String] {
        switch self {
        case .album(let album, _):
            var keys = ["album-\(album.id)"]
            if let upc = album.upc, !upc.isEmpty { keys.append("album-upc-\(upc)") }
            return keys
        case .playlist, .librarySongs: return [id]
        }
    }
    var libraryAddedDate: Date? {
        switch self {
        case .album(let album, _): return album.libraryAddedDate
        case .playlist(let playlist): return playlist.libraryAddedDate
        case .librarySongs: return nil
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

    /// t181u：读取曲目。每条路径失败都打印真实 MusicKit 错误；依次尝试：
    /// ① 对象自身 .with(.tracks) → ② 按 ID 重新请求（曲库：MusicCatalogResourceRequest；资料库：MusicLibraryRequest）再 .with(.tracks)
    /// → 整体失败 0.8s 后再重试一次。
    func songs() async throws -> [Song] {
        if case .librarySongs(let songs) = self { return songs }
        do { return try await loadSongs() } catch {
            if error is CancellationError { throw error }
            print("[t181u] songs() attempt 1 failed for \(title): \(error) | \(String(reflecting: error))")
            try await Task.sleep(for: .milliseconds(800))
            do { return try await loadSongs() } catch {
                print("[t181u] songs() attempt 2 failed for \(title): \(error) | \(String(reflecting: error))")
                throw error
            }
        }
    }

    private func loadSongs() async throws -> [Song] {
        var tracks: MusicItemCollection<MusicKit.Track>?
        switch self {
        case .librarySongs: return []
        case .album(let album, let catalog):
            do { tracks = try await album.with(.tracks).tracks }
            catch {
                print("[t181u] album.with(.tracks) failed (\(album.id.rawValue), catalog=\(catalog)): \(error)")
                if catalog {
                    var r = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: album.id); r.properties = [.tracks]
                    tracks = try await r.response().items.first?.tracks
                } else {
                    var r = MusicLibraryRequest<Album>(); r.filter(matching: \.id, equalTo: album.id)
                    tracks = try await r.response().items.first?.with(.tracks).tracks
                }
            }
        case .playlist(let playlist):
            do { tracks = try await playlist.with(.tracks).tracks }
            catch {
                print("[t181u] playlist.with(.tracks) failed (\(playlist.id.rawValue)): \(error)")
                if playlist.id.rawValue.hasPrefix("pl.") {
                    var r = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: playlist.id); r.properties = [.tracks]
                    tracks = try await r.response().items.first?.tracks
                } else {
                    var r = MusicLibraryRequest<Playlist>(); r.filter(matching: \.id, equalTo: playlist.id)
                    tracks = try await r.response().items.first?.with(.tracks).tracks
                }
            }
        }
        var songs: [Song] = []
        while let batch = tracks {
            try Task.checkCancellation()
            songs.append(contentsOf: batch.compactMap {
                if case .song(let song) = $0 { return song }
                return nil
            })
            // t181u：后续分页失败不让整张列表失败（保留已读到的曲目）
            if batch.hasNextBatch {
                do { tracks = try await batch.nextBatch() }
                catch { print("[t181u] tracks.nextBatch failed for \(title): \(error)"); tracks = nil }
            } else { tracks = nil }
        }
        return songs
    }
}


// MARK: - t192u：首页长按菜单动作

extension AppleMusicStore {
    private static let hiddenKey = "vinyl.hiddenHome"
    private static let lovedKey = "vinyl.lovedCollections"

    var hiddenHome: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []) }
    var hiddenCount: Int { hiddenHome.count }

    /// 只在本地记下 ID 并从首页移除，绝不改动 Apple Music 资料库
    func hideFromHome(_ c: MusicCollection) {
        var h = hiddenHome; h.insert(c.id)
        UserDefaults.standard.set(Array(h), forKey: Self.hiddenKey)
        collections.removeAll { $0.id == c.id }
        HomeCache.save(collections)   // t211u：缓存里也去掉，重启首帧不会再出现
    }
    func unhideAll() {
        UserDefaults.standard.removeObject(forKey: Self.hiddenKey)
        // t211u：资料库已载入 → 立即原位重建；否则（刚冷启动，只有缓存）后台完整刷新一次
        if libraryLoaded {
            rebuildHome()
            homePageRevision += 1
            HomeCache.save(collections)
        } else {
            Task { await refreshHome() }
        }
    }

    private func playable(_ c: MusicCollection) async -> [Song] {
        do { return try await c.songs().filter { $0.playParameters != nil } }
        catch { report(error, action: "读取曲目失败"); return [] }
    }

    /// 播放 / 随机播放整张专辑（ApplicationMusicPlayer）
    func playCollection(_ c: MusicCollection, shuffle: Bool) async {
        let songs = await playable(c)
        guard let first = shuffle ? songs.randomElement() : songs.first else { return }
        player.state.shuffleMode = shuffle ? .songs : .off
        await play(first, in: songs, fromCatalog: c.isCatalog)
    }

    /// 下一首播放（.afterCurrentEntry）/ 加到播放队列末尾（.tail）；当前没有队列时直接开始播放
    func enqueue(_ c: MusicCollection, next: Bool) async {
        let songs = await playable(c)
        guard !songs.isEmpty else { return }
        guard hasCurrentTrack else { await play(songs[0], in: songs, fromCatalog: c.isCatalog); return }
        do { try await player.queue.insert(songs, position: next ? .afterCurrentEntry : .tail) }
        catch { report(error, action: next ? "下一首播放失败" : "加入播放队列失败") }
    }

    // MARK: t229u：单曲动作（详情页歌曲长按菜单）
    func enqueue(_ s: Song, next: Bool, fromCatalog: Bool) async {
        guard s.playParameters != nil else { return }
        guard hasCurrentTrack else { await play(s, in: [s], fromCatalog: fromCatalog); return }
        do { try await player.queue.insert([s], position: next ? .afterCurrentEntry : .tail) }
        catch { report(error, action: next ? "下一首播放失败" : "加入播放队列失败") }
    }
    /// 曲库歌曲（ID 不是资料库 i. 前缀）才显示「添加」
    func canAddToLibrary(_ s: Song, fromCatalog: Bool) -> Bool { fromCatalog && !s.id.rawValue.hasPrefix("i.") }
    func addToLibrary(_ s: Song) async {
        do { try await MusicLibrary.shared.add(s); print("[t229u] added song to library: \(s.title)") }
        catch { report(error, action: "加到资料库失败") }
    }
    func addToPlaylist(_ s: Song, playlist: Playlist) async {
        do { _ = try await MusicLibrary.shared.add(MusicKit.Track.song(s), to: playlist) }
        catch { report(error, action: "加到歌单失败") }
    }

    /// 资料库里的条目（ID 以 l. / p. 开头）不显示「加到资料库」
    func canAddToLibrary(_ c: MusicCollection) -> Bool {
        switch c {
        case .album(_, let catalog): return catalog
        case .playlist: return c.isCatalog
        case .librarySongs: return false
        }
    }
    func addToLibrary(_ c: MusicCollection) async {
        do {
            switch c {
            case .album(let a, _): try await MusicLibrary.shared.add(a)
            case .playlist(let p): try await MusicLibrary.shared.add(p)
            case .librarySongs: return
            }
            print("[t192u] added to library: \(c.title)")
        } catch { report(error, action: "加到资料库失败") }
    }

    /// 可编辑的资料库歌单（MusicLibrary.add(_:to:) 只能写用户自己的歌单）
    var editablePlaylists: [Playlist] { playlists.filter { !$0.id.rawValue.hasPrefix("pl.") } }

    func addToPlaylist(_ c: MusicCollection, playlist: Playlist) async {
        let songs = await playable(c)
        var n = 0
        for s in songs {
            do { _ = try await MusicLibrary.shared.add(MusicKit.Track.song(s), to: playlist); n += 1 }
            catch { report(error, action: "加到歌单失败"); break }
        }
        print("[t192u] added \(n)/\(songs.count) tracks of \(c.title) to \(playlist.name)")
    }

    // MARK: 喜欢：MusicKit 没有「喜欢」API → 用 Apple Music API 的 ratings 端点（PUT/DELETE /v1/me/ratings/…，value 1 = 喜欢），同时本地记状态
    var lovedCollections: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Self.lovedKey) ?? []) }
    func isLoved(_ c: MusicCollection) -> Bool { lovedCollections.contains(c.id) }

    func toggleLove(_ c: MusicCollection) async {
        var set = lovedCollections
        let on = !set.contains(c.id)
        if on { set.insert(c.id) } else { set.remove(c.id) }
        UserDefaults.standard.set(Array(set), forKey: Self.lovedKey)
        objectWillChange.send()
        let path: String
        switch c {
        case .album(let a, let catalog): path = (catalog ? "albums/" : "library-albums/") + a.id.rawValue
        case .playlist(let p): path = (c.isCatalog ? "playlists/" : "library-playlists/") + p.id.rawValue
        case .librarySongs: return
        }
        guard let url = URL(string: "https://api.music.apple.com/v1/me/ratings/" + path) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = on ? "PUT" : "DELETE"
        if on {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = #"{"type":"rating","attributes":{"value":1}}"#.data(using: .utf8)
        }
        do {
            let r = try await MusicDataRequest(urlRequest: req).response()
            print("[t192u] rating \(req.httpMethod ?? "") \(path): HTTP \(r.urlResponse.statusCode)")
        } catch {
            print("[t192u] rating \(req.httpMethod ?? "") \(path) failed: \(error) — 只保留本地状态")
        }
    }
}

extension MusicCollection {
    var shareURL: URL? {
        switch self {
        case .album(let a, _): return a.url
        case .playlist(let p): return p.url
        case .librarySongs: return nil
        }
    }
    var artistURL: URL? {
        if case .album(let a, _) = self { return a.artistURL }
        return nil
    }
}


// MARK: - t193u：首页列表持久化（MusicKit 的 Album / Playlist / Song 都是 Codable，含封面 URL 与 Apple 封面颜色）

enum HomeCache {
    private enum Item: Codable {
        case album(Album, Bool)
        case playlist(Playlist)
        case librarySongs([Song])
    }
    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("home-feed.json")
    }
    static let launch = Date()

    @MainActor static func load() -> [MusicCollection] {
        guard !DemoMode.enabled, MusicAuthorization.currentStatus == .authorized,
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        let decoded: [MusicCollection] = items.map {
            switch $0 {
            case .album(let a, let c): return .album(a, catalog: c)
            case .playlist(let p): return .playlist(p)
            case .librarySongs(let s): return .librarySongs(s)
            }
        }
        // t211u：缓存首帧同样过滤「从首页隐藏」
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "vinyl.hiddenHome") ?? [])
        let list = decoded.filter { !hidden.contains($0.id) }
        print("[t193u] home cache: \(list.count) items decoded in \(String(format: "%.0f", Date().timeIntervalSince(launch) * 1000))ms")
        // 预取前 6 行封面（磁盘 → 内存），首屏直接命中内存
        let side = max(1, (UIScreen.main.bounds.width - 2 * DS.contentInset - 3 * 18) / 4)
        let pixels = max(1, Int((side * UIScreen.main.scale).rounded(.up)))
        let urls = list.prefix(24).compactMap { $0.artwork?.url(width: pixels, height: pixels) }
        ArtworkCache.shared.prefetch(urls, pixelSize: pixels)
        return list
    }

    static func save(_ list: [MusicCollection]) {
        let items: [Item] = list.prefix(150).map {
            switch $0 {
            case .album(let a, let c): return .album(a, c)
            case .playlist(let p): return .playlist(p)
            case .librarySongs(let s): return .librarySongs(Array(s.prefix(200)))
            }
        }
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(items) { try? data.write(to: url, options: .atomic) }
        }
    }
    static func clear() { try? FileManager.default.removeItem(at: url) }
}
