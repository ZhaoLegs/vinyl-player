import Foundation
import MusicKit
import SwiftUI

/// One player for the entire app. Authorization is requested only after a tap.
@MainActor
final class AppleMusicStore: ObservableObject {
    @Published private(set) var authorization = MusicAuthorization.currentStatus
    @Published private(set) var albums: [Album] = []
    @Published private(set) var playlists: [Playlist] = []
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
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var showingPlayer = false

    private let player = ApplicationMusicPlayer.shared
    private var libraryLoaded = false
    private let pageSize = 50
    var authorized: Bool { authorization == .authorized }
    var hasCurrentTrack: Bool { !currentTitle.isEmpty }

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        authorization = await MusicAuthorization.request()
        await refreshAccess()
    }

    /// Recheck on returning from Settings; discard personal data after revocation.
    func refreshAccess() async {
        authorization = MusicAuthorization.currentStatus
        guard authorized else {
            albums = []
            playlists = []
            libraryLoaded = false
            hasMoreAlbums = false
            hasMorePlaylists = false
            canPlayCatalog = false
            subscriptionKnown = false
            player.stop()
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
            let albumResponse = try await albumRequest.response()
            let playlistResponse = try await playlistRequest.response()
            try Task.checkCancellation()
            guard MusicAuthorization.currentStatus == .authorized else { return }
            albums = Array(albumResponse.items)
            playlists = Array(playlistResponse.items)
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
            position = 0
            duration = 0
            isPlaying = false
            return
        }
        let entry = player.queue.currentEntry
        currentTitle = entry?.title ?? ""
        currentArtist = entry?.subtitle ?? ""
        currentArtwork = entry?.artwork
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

    var id: String {
        switch self {
        case .album(let album, let catalog): return "\(catalog)-album-\(album.id)"
        case .playlist(let playlist): return "playlist-\(playlist.id)"
        }
    }
    var title: String {
        switch self {
        case .album(let album, _): return album.title
        case .playlist(let playlist): return playlist.name
        }
    }
    var artist: String {
        switch self {
        case .album(let album, _): return album.artistName
        case .playlist(let playlist): return playlist.curatorName ?? "Apple Music"
        }
    }
    var artwork: Artwork? {
        switch self {
        case .album(let album, _): return album.artwork
        case .playlist(let playlist): return playlist.artwork
        }
    }
    var isCatalog: Bool {
        if case .album(_, let catalog) = self { return catalog }
        return false
    }

    func songs() async throws -> [Song] {
        var tracks: MusicItemCollection<MusicKit.Track>?
        switch self {
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
