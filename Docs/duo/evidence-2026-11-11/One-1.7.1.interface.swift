Preparing to build Swift interface...
Building Swift interface...
Swift interface built successfully.
import Swift
import _Concurrency
import _StringProcessing
import _SwiftConcurrencyShims

class AccountFavoritesModel {
    var _folders: Combine.Published<[One.AccountFolder]>
    var _folderId: Combine.Published<Swift.Int>
    var _items: Combine.Published<[One.Article]>
    var _loading: Combine.Published<Swift.Bool>
    var _loadingMore: Combine.Published<Swift.Bool>
    var _hasMore: Combine.Published<Swift.Bool>
    var _error: Combine.Published<Swift.String>
    var page: Swift.Int
    var generation: Swift.Int
}
struct AccountFavoritesView<A> where A: SwiftUI.View {
    let header: A
    var _model: SwiftUI.StateObject<One.AccountFavoritesModel>
}
struct AccountLoginView {
    var _dismiss: SwiftUI.Environment<SwiftUI.DismissAction>
    var __area: SwiftUI.State<Swift.String>
    var __mobile: SwiftUI.State<Swift.String>
    var __password: SwiftUI.State<Swift.String>
    var __loading: SwiftUI.State<Swift.Bool>
    var __errorText: SwiftUI.State<Swift.String>
}
struct AccountFolder {
    let id: Swift.Int
    let name: Swift.String
    let count: Swift.Int
    let isDefault: Swift.Bool
}
struct AccountRecord {
    enum CodingKeys {
        case area
        case mobile
        case user
        case vipExpiry
    }
    var area: Swift.String
    var mobile: Swift.String
    var user: One.OneUser
    var vipExpiry: Swift.String
}
class ActorModel {
    let performerId: Swift.Int
    var _intro: Combine.Published<Swift.String>
    var _profile: Combine.Published<One.Performer?>
    var _totalWorks: Combine.Published<Swift.Int?>
    var _works: Combine.Published<[One.Article]>
    var _loading: Combine.Published<Swift.Bool>
    var _loadingMore: Combine.Published<Swift.Bool>
    var _hasMore: Combine.Published<Swift.Bool>
    var _error: Combine.Published<Swift.String>
    var _sort: Combine.Published<One.ContentSort>
    var page: Swift.Int
    var loaded: Swift.Bool
    var generation: Swift.Int
}
struct ActorView {
    let performer: One.Performer
    var _model: SwiftUI.StateObject<One.ActorModel>
    var _follows: SwiftUI.ObservedObject<One.FollowStore>
    var _twoColumn: SwiftUI.AppStorage<Swift.Bool>
    var __gridWidth: SwiftUI.State<CoreGraphics.CGFloat>
    var __gridFold: SwiftUI.State<One.FoldGap?>
}
struct LargeCanvas {
    var _horizontal: SwiftUI.Environment<SwiftUI.UserInterfaceSizeClass?>
    var _vertical: SwiftUI.Environment<SwiftUI.UserInterfaceSizeClass?>
}
struct FoldGap {
    var minX: CoreGraphics.CGFloat
    var maxX: CoreGraphics.CGFloat
}
struct OcclusionInsets {
    var top: CoreGraphics.CGFloat
    var bottom: CoreGraphics.CGFloat
}
struct OcclusionAvoider {
    let band: CoreGraphics.CGFloat
    var __insets: SwiftUI.State<One.OcclusionInsets>
}
struct SideBarsReader {
    var _sideBars: SwiftUI.Binding<Swift.Bool>
}
struct VerticalEdgeReader {
    var _sideBars: SwiftUI.Binding<Swift.Bool>
    var _edge: SwiftUI.Environment<SwiftUI.HorizontalEdge?>
}
struct TrailingToolbar<A, B> where A: SwiftUI.View, B: SwiftUI.View {
    let showsSecondary: Swift.Bool
    let primary: A
    let secondary: B
}
struct GeometryValueReader<A> where A: Swift.Equatable {
    let read: (_: SwiftUI.GeometryProxy) -> A
    let update: (_: A) -> ()
}
struct FoldSplit<A, B> where A: SwiftUI.View, B: SwiftUI.View {
    var spacing: CoreGraphics.CGFloat
    var fold: One.FoldGap?
    var containerWidth: CoreGraphics.CGFloat
    var leading: A
    var trailing: B
}
struct FoldSplitLayout {
    var spacing: CoreGraphics.CGFloat
    var fold: One.FoldGap?
    var containerWidth: CoreGraphics.CGFloat
}
actor ApiHostDirectory {
    var avoidUntil: [Swift.String : Foundation.Date]
}
struct EffectiveConfig {
    var notice: Swift.String
    var hosts: [Swift.String]
    var prefixes: [Swift.String]
    var appVersion: Swift.String
    var userAgent: Swift.String
    var paths: [Swift.String : Swift.String]
    var cbcKey: [Swift.UInt8]
    var cbcIV: [Swift.UInt8]
    var ecbKey: [Swift.UInt8]
    var hlsKey: [Swift.UInt8]
    var signKey: Swift.String
    var landingPassphrase: Swift.String
    var filePlay: [Swift.String]
    var fileDownload: [Swift.String]
    var hls: [Swift.String]
    var hlsEnabled: Swift.Bool
    var hlsPrefersH264: Swift.Bool
    var hlsMinIndexBytes: Swift.Int
    var detailPlatform: Swift.String
    var imageHosts: [Swift.String]
    var officialEntry: Swift.String
    var officialBundles: [Swift.String]
    var latestRelease: One.LatestRelease?
}
struct RemoteConfig {
    struct MediaPrefs {
        enum CodingKeys {
            case filePlay
            case fileDownload
            case hls
            case hlsEnabled
            case hlsPreferH264
            case hlsMinIndexMB
            case detailPlatform
        }
        var filePlay: [Swift.String]?
        var fileDownload: [Swift.String]?
        var hls: [Swift.String]?
        var hlsEnabled: Swift.Bool?
        var hlsPreferH264: Swift.Bool?
        var hlsMinIndexMB: Swift.Double?
        var detailPlatform: Swift.String?
    }
    struct CryptoKeys {
        enum CodingKeys {
            case cbcKey
            case cbcIV
            case ecbKey
            case hlsKey
            case signKey
            case landingPassphrase
        }
        var cbcKey: Swift.String?
        var cbcIV: Swift.String?
        var ecbKey: Swift.String?
        var hlsKey: Swift.String?
        var signKey: Swift.String?
        var landingPassphrase: Swift.String?
    }
    struct UpdateInfo {
        enum CodingKeys {
            case version
            case build
            case url
            case notes
            case ipa
        }
        var version: Swift.String?
        var build: Swift.Int?
        var url: Swift.String?
        var notes: Swift.String?
        var ipa: Swift.String?
    }
    enum CodingKeys {
        case schema
        case notice
        case update
        case hosts
        case prefixes
        case appVersion
        case userAgent
        case paths
        case crypto
        case media
        case imageHosts
        case officialEntry
        case officialBundles
    }
    var schema: Swift.Int?
    var notice: Swift.String?
    var update: One.RemoteConfig.UpdateInfo?
    var hosts: [Swift.String]?
    var prefixes: [Swift.String]?
    var appVersion: Swift.String?
    var userAgent: Swift.String?
    var paths: [Swift.String : Swift.String]?
    var crypto: One.RemoteConfig.CryptoKeys?
    var media: One.RemoteConfig.MediaPrefs?
    var imageHosts: [Swift.String]?
    var officialEntry: Swift.String?
    var officialBundles: [Swift.String]?
}
class SettingsStore {
    var _settings: Combine.Published<One.AppSettings>
}
struct AppSettings {
    enum CodingKeys {
        case playerSpeed
        case playerFill
        case playerAutoFullscreen
        case subtitlesEnabled
        case subtitleFontSize
        case subtitleOpacity
        case subtitleBackgroundOpacity
        case subtitlePositionX
        case subtitlePositionY
        case downloadConnections
        case downloadChunkMB
        case downloadParallel
        case keepScreenAwake
        case configURL
        case externalPlayer
        case customPlayerTemplate
        case screenshotFeedback
        case privacyBlur
        case homePaging
        case vodLayout
        case discoverLayout
        case showPlaybackStats
        case fastStart
        case heartPicksFolder
        case preferHLS
    }
    var playerSpeed: Swift.Double
    var playerFill: Swift.Bool
    var playerAutoFullscreen: Swift.Bool
    var subtitlesEnabled: Swift.Bool
    var subtitleFontSize: Swift.Double
    var subtitleOpacity: Swift.Double
    var subtitleBackgroundOpacity: Swift.Double
    var subtitlePositionX: Swift.Double
    var subtitlePositionY: Swift.Double
    var downloadConnections: Swift.Int
    var downloadChunkMB: Swift.Int
    var downloadParallel: Swift.Int
    var keepScreenAwake: Swift.Bool
    var configURL: Swift.String
    var externalPlayer: Swift.String
    var customPlayerTemplate: Swift.String
    var screenshotFeedback: Swift.Bool
    var privacyBlur: Swift.Double
    var homePaging: Swift.Bool
    var vodLayout: Swift.String
    var discoverLayout: Swift.String
    var showPlaybackStats: Swift.Bool
    var fastStart: Swift.Bool
    var heartPicksFolder: Swift.Bool
    var preferHLS: Swift.Bool
}
struct LatestRelease {
    let version: Swift.String
    let build: Swift.Int?
    let url: Foundation.URL
    let notes: Swift.String
    let ipa: Foundation.URL?
}
class DetailModel {
    let fallbackTitle: Swift.String
    var _currentId: Combine.Published<Swift.Int>
    var _detail: Combine.Published<One.ArticleDetail?>
    var _episodes: Combine.Published<[One.CollectionEpisode]>
    var _loading: Combine.Published<Swift.Bool>
    var _switching: Combine.Published<Swift.Bool>
    var _error: Combine.Published<Swift.String>
}
struct CollectionEpisode {
    let id: Swift.Int
    let episode: Swift.Int
    let number: Swift.String
    let name: Swift.String
    let length: Swift.String
    let size: Swift.String
    let quality: Swift.String
    let cover: Swift.String
}
struct ArticleDetail {
    var id: Swift.Int
    var modelId: Swift.Int
    var title: Swift.String
    var subtitle: Swift.String
    var author: Swift.String
    var publishedAt: Swift.String
    var likeNumber: Swift.Int
    var collectNumber: Swift.Int
    var replyCount: Swift.Int
    var views: Swift.Int
    var tags: [One.DetailTag]
    var coverPath: Swift.String
    var bodyText: Swift.String
    var photoURLs: [Swift.String]
    var bodyBlocks: [One.ArticleBodyBlock]
    var leadText: Swift.String
    var videoPath: Swift.String
    var audioPath: Swift.String
    var downloadPath: Swift.String
    var hlsPaths: [Swift.String]
    var hasMedia: Swift.Bool
    var subtitlePath: Swift.String
    var pid: Swift.Int
    var episode: Swift.Int
    var episodeName: Swift.String
    var episodes: [One.CollectionEpisode]
    var favoriteArticle: One.Article
}
enum ArticleBodyBlock {
    case paragraph(Swift.String, centered: Swift.Bool, emphasized: Swift.Bool)
    case heading(Swift.String)
    case image(display: Swift.String, original: Swift.String)
}
struct DetailTag {
    let name: Swift.String
    let actorId: Swift.Int?
}
struct LoadMoreRow {
    let loading: Swift.Bool
    let action: () -> ()
}
struct LoadingRow {}
struct ArticleRow {
    let item: One.Article
    var _typeSize: SwiftUI.Environment<SwiftUI.DynamicTypeSize>
}
struct EmptyHint {
    let icon: Swift.String
    let title: Swift.String
    var message: Swift.String
}
struct ArticleCard {
    let item: One.Article
}
struct ArticleMeta {
    let item: One.Article
}
struct ArticleThumb {
    let item: One.Article
}
struct ArticleGridCell {
    let item: One.Article
}
struct TypeBadge {
    let audio: Swift.Bool
}
struct AuthorFooter {
    var _openURL: SwiftUI.Environment<SwiftUI.OpenURLAction>
}
class BackupCenter {
    var _working: Combine.Published<Swift.String?>
    var job: Swift.Task<(), Swift.Never>?
    var uploading: Swift.Bool
    var waiting: One.BackupQuestion?
    weak var visible: __C.UIAlertController?
    var asked: Swift.Int
}
struct BackupQuestion {
    let title: Swift.String
    let message: Swift.String
    let confirmTitle: Swift.String
    let onConfirm: @Swift.MainActor () -> ()
}
struct BackupFile {
    enum CodingKeys {
        case app
        case format
        case createdAt
        case appVersion
        case favorites
        case folders
        case follows
        case progress
    }
    var app: Swift.String
    var format: Swift.Int
    var createdAt: Swift.Double
    var appVersion: Swift.String
    var favorites: [One.Favorite]
    var folders: [One.FavoriteFolder]
    var follows: [One.FollowedActor]
    var progress: [Swift.String : One.ProgressStore.Entry]
}
enum BackupError {
    case download(Swift.String)
    case notBackup
    case tooNew
    case tooBig
    case badLink
    case notBackupLink
    case noCloudBackup
    case emptyLocal
}
struct Lossy<A> where A: Swift.Decodable {
    let value: A?
}
struct ExportedFile {
    let id: Foundation.UUID
    let url: Foundation.URL
}
struct BackupView {
    var _backup: SwiftUI.ObservedObject<One.BackupCenter>
    var _favorites: SwiftUI.ObservedObject<One.FavoritesStore>
    var _follows: SwiftUI.ObservedObject<One.FollowStore>
    var __exported: SwiftUI.State<One.ExportedFile?>
    var __showLinkPrompt: SwiftUI.State<Swift.Bool>
    var __linkText: SwiftUI.State<Swift.String>
    var __draft: SwiftUI.State<One.WebDAVConfig>
    var __draftLoaded: SwiftUI.State<Swift.Bool>
}
struct ShareSheet {
    let url: Foundation.URL
    let onFinish: (_: Swift.Bool) -> ()
}
struct StorageBreakdown {
    var downloads: Swift.Int64
    var parts: Swift.Int64
    var cache: Swift.Int64
}
struct CacheSummary {
    var fileCount: Swift.Int
    var fileBytes: Swift.Int64
    var taskCount: Swift.Int
    var progressCount: Swift.Int
}
class ChunkedDownload {
    let partURL: Foundation.URL
    var onSnapshot: ((_: One.DownloadSnapshot) -> ())?
    var onPersist: ((Swift.Int64, Swift.Int64, [Swift.Int64], Swift.Bool) -> ())?
    var onEnd: ((_: One.DownloadEnd) -> ())?
    let urls: [Swift.String]
    let connections: Swift.Int
    let maxAttempts: Swift.Int
    let lock: __C.NSLock
    var total: Swift.Int64
    var chunkSize: Swift.Int64
    var received: [Swift.Int64]
    var rangeSupported: Swift.Bool
    var inflight: [Swift.Bool]
    var attempts: [Swift.Int]
    var retryAfter: [Foundation.Date]
    var unknownLengthDone: Swift.Bool
    var written: Swift.Int64
    var activeLanes: Swift.Int
    var failure: Swift.Error?
    var stopRequested: Swift.Bool
    var mainTask: Swift.Task<(), Swift.Never>?
    var samples: [(time: Foundation.Date, bytes: Swift.Int64)]
    var lastPersist: Foundation.Date
    var fd: Swift.Int32
}
enum DownloadEnd {
    case failed(Swift.Error)
    case completed
    case stopped
}
struct DownloadSnapshot {
    var bytesDone: Swift.Int64
    var totalBytes: Swift.Int64
    var speed: Swift.Double
    var activeConnections: Swift.Int
}
struct OneComment {
    let id: Swift.Int
    let userId: Swift.Int
    let author: Swift.String
    let avatarPath: Swift.String
    let isVip: Swift.Bool
    let vipLevel: Swift.Int
    let isDivine: Swift.Bool
    let replyTo: Swift.String
    let text: Swift.String
    let createdAt: Swift.String
    let likes: Swift.Int
    let replyCount: Swift.Int
    let images: [One.CommentImage]
    let stickerThumb: Swift.String
    let replies: [One.OneComment]
}
enum CommentSort {
    case hot
    case latest
}
struct CommentImage {
    let small: Swift.String
    let big: Swift.String
    let width: Swift.Double
    let height: Swift.Double
}
struct CommentRow {
    let comment: One.OneComment
    var _model: SwiftUI.ObservedObject<One.CommentsModel>
    var palette: One.CommentPalette
    var compact: Swift.Bool
    var openImages: ([Swift.String], Swift.Int) -> ()
    var _blocklist: SwiftUI.ObservedObject<One.CommentBlocklist>
}
struct CommentMenu {
    let comment: One.OneComment
}
struct ReplyRow {
    let reply: One.OneComment
    let palette: One.CommentPalette
    let openImages: ([Swift.String], Swift.Int) -> ()
}
struct CompactLabelStyle {}
struct CommentContent {
    let comment: One.OneComment
    let palette: One.CommentPalette
    let lineLimit: Swift.Int?
    let openImages: ([Swift.String], Swift.Int) -> ()
}
struct CommentHeader {
    let comment: One.OneComment
    let palette: One.CommentPalette
}
struct CommentAvatar {
    let path: Swift.String
    let size: CoreGraphics.CGFloat
    var palette: One.CommentPalette
}
struct CommentPalette {
    let strong: SwiftUI.Color
    let body: SwiftUI.Color
    let soft: SwiftUI.Color
    let faint: SwiftUI.Color
    let fill: SwiftUI.Color
}
struct CommentImagesRow {
    let images: [One.CommentImage]
    let palette: One.CommentPalette
    let open: ([Swift.String], Swift.Int) -> ()
}
struct Badge {
    let text: Swift.String
    let color: SwiftUI.Color
}
class CommentsModel {
    let articleId: Swift.Int
    var _sort: Combine.Published<One.CommentSort>
    var _items: Combine.Published<[One.OneComment]>
    var _loading: Combine.Published<Swift.Bool>
    var _loadingMore: Combine.Published<Swift.Bool>
    var _hasMore: Combine.Published<Swift.Bool>
    var _error: Combine.Published<Swift.String>
    var _expanded: Combine.Published<Swift.Set<Swift.Int>>
    var _fetchedReplies: Combine.Published<[Swift.Int : [One.OneComment]]>
    var _loadingReplies: Combine.Published<Swift.Set<Swift.Int>>
    let remembersSort: Swift.Bool
    var page: Swift.Int
    var loaded: Swift.Bool
    var generation: Swift.Int
}
class CommentBlocklist {
    var _userIds: Combine.Published<Swift.Set<Swift.Int>>
}
struct CommentsSheet {
    let total: Swift.Int
    let dark: Swift.Bool
    var _model: SwiftUI.StateObject<One.CommentsModel>
    var _blocklist: SwiftUI.ObservedObject<One.CommentBlocklist>
    var _dismiss: SwiftUI.Environment<SwiftUI.DismissAction>
    var __viewing: SwiftUI.State<One.ViewerItem?>
}
struct DarkSheet {
    let enabled: Swift.Bool
}
struct PassThroughAtMedium {}
struct CommentsPreview {
    let total: Swift.Int
    let dark: Swift.Bool
    var _model: SwiftUI.StateObject<One.CommentsModel>
    var _blocklist: SwiftUI.ObservedObject<One.CommentBlocklist>
    var __showAll: SwiftUI.State<Swift.Bool>
}
class DailyPrompts {
    enum Prompt {
        case notice(Swift.String)
        case update(One.LatestRelease)
    }
    var configReady: Swift.Bool
    var scheduled: Swift.Bool
    weak var visible: __C.UIAlertController?
}
struct DetailView {
    let title: Swift.String
    var _model: SwiftUI.StateObject<One.DetailModel>
}
struct EpisodeRow {
    let item: One.CollectionEpisode
    let current: Swift.Bool
}
class DiscoverModel {
    enum Mode {
        case content
        case actor
    }
    var _mode: Combine.Published<One.DiscoverModel.Mode>
    var _tabId: Combine.Published<Swift.Int>
    var _navId: Combine.Published<Swift.Int>
    var _month: Combine.Published<Swift.String>
    var _actorQuery: Combine.Published<Swift.String>
    var _navs: Combine.Published<[One.ActorNav]>
    var _articles: Combine.Published<[One.Article]>
    var _actors: Combine.Published<[One.Performer]>
    var _articlesAreSeries: Combine.Published<Swift.Bool>
    var _loading: Combine.Published<Swift.Bool>
    var _loadingMore: Combine.Published<Swift.Bool>
    var _hasMore: Combine.Published<Swift.Bool>
    var _error: Combine.Published<Swift.String>
    var page: Swift.Int
    var generation: Swift.Int
    var loadedKey: Swift.String
}
struct DiscoverView {
    var _model: SwiftUI.StateObject<One.DiscoverModel>
    var _settingsStore: SwiftUI.ObservedObject<One.SettingsStore>
    var __actorInput: SwiftUI.State<Swift.String>
    var __openingLive: SwiftUI.State<Swift.Bool>
    var __pageWidth: SwiftUI.State<CoreGraphics.CGFloat>
    var __pageFold: SwiftUI.State<One.FoldGap?>
    var _largeCanvas: One.LargeCanvas
}
struct PerformerRow {
    let performer: One.Performer
}
class DownloadCenter {
    var _items: Combine.Published<[One.DownloadItem]>
    let downloadsDirectory: Foundation.URL
    let supportDirectory: Foundation.URL
    var records: [Swift.Int : One.DownloadRecord]
    var engines: [Swift.Int : One.ChunkedDownload]
    var live: [Swift.Int : One.DownloadSnapshot]
    var starting: Swift.Set<Swift.Int>
    var cancelAfterStop: Swift.Set<Swift.Int>
    var pausedByBackground: Swift.Set<Swift.Int>
    var backgroundExpired: Swift.Bool
    var backgroundTask: __C.UIBackgroundTaskIdentifier
    var saveScheduled: Swift.Bool
    var settingsObserver: Combine.AnyCancellable?
    let ioQueue: __C.OS_dispatch_queue
}
struct DownloadRecord {
    enum CodingKeys {
        case id
        case modelId
        case title
        case cover
        case ext
        case fileName
        case mediaPath
        case urls
        case totalBytes
        case chunkSize
        case received
        case rangeSupported
        case state
        case error
        case createdAt
        case finishedAt
        case fileBytes
        case noSubtitleAt
    }
    var id: Swift.Int
    var modelId: Swift.Int
    var title: Swift.String
    var cover: Swift.String
    var ext: Swift.String
    var fileName: Swift.String
    var mediaPath: Swift.String
    var urls: [Swift.String]
    var totalBytes: Swift.Int64
    var chunkSize: Swift.Int64
    var received: [Swift.Int64]
    var rangeSupported: Swift.Bool
    var state: One.DownloadState
    var error: Swift.String?
    var createdAt: Swift.Double
    var finishedAt: Swift.Double?
    var fileBytes: Swift.Int64
    var noSubtitleAt: Swift.Double?
}
struct DownloadItem {
    var id: Swift.Int
    var modelId: Swift.Int
    var title: Swift.String
    var cover: Swift.String
    var ext: Swift.String
    var state: One.DownloadState
    var error: Swift.String?
    var bytesDone: Swift.Int64
    var totalBytes: Swift.Int64
    var speed: Swift.Double
    var connections: Swift.Int
    var createdAt: Swift.Double
    var finishedAt: Swift.Double?
    var fileBytes: Swift.Int64
}
enum DownloadState {
    case queued
    case downloading
    case paused
    case failed
    case completed
}
enum DownloadError {
    case noFile
    case unreachable
}
struct DownloadItemRow {
    let item: One.DownloadItem
    var showTitle: Swift.Bool
    var onPlay: ((_: One.DownloadItem) -> ())?
    var _center: SwiftUI.ObservedObject<One.DownloadCenter>
}
struct DownloadSection {
    let detail: One.ArticleDetail
    let coverURL: Swift.String
    var _center: SwiftUI.ObservedObject<One.DownloadCenter>
    var __resolving: SwiftUI.State<Swift.Bool>
    var __errorText: SwiftUI.State<Swift.String>
}
struct EditorialDetail {
    enum PhotoMode {
        case stream
        case grid
    }
    var _model: SwiftUI.ObservedObject<One.DetailModel>
    let title: Swift.String
    var _photoMode: SwiftUI.AppStorage<Swift.String>
    let margin: CoreGraphics.CGFloat
    let smoothScrollMaxImages: Swift.Int
    var _modePickerWidth: SwiftUI.ScaledMetric<CoreGraphics.CGFloat>
    var __fold: SwiftUI.State<One.FoldGap?>
    var __showsTopButton: SwiftUI.State<Swift.Bool>
    var _reduceMotion: SwiftUI.Environment<Swift.Bool>
}
struct ScrollZoneReader {
    let report: (_: One.ScrollZone) -> ()
}
struct ContentTopProbe {}
struct BodyRow {
    let id: Swift.Int
    let block: One.ArticleBodyBlock
    let imageIndex: Swift.Int
}
enum PageAnchor {
    case top
}
struct ContentTopKey {}
enum ScrollZone {
    case top
    case middle
    case past
}
enum ExternalPlayer {
    case builtin
    case infuse
    case senplayer
    case vlc
    case nplayer
    case custom
}
class FavoritesStore {
    var _items: Combine.Published<[One.Favorite]>
    var _folders: Combine.Published<[One.FavoriteFolder]>
}
struct FavoriteFolder {
    enum CodingKeys {
        case id
        case name
        case createdAt
    }
    var id: Swift.String
    var name: Swift.String
    var createdAt: Swift.Double
}
struct Favorite {
    enum CodingKeys {
        case article
        case savedAt
        case folderId
    }
    var article: One.Article
    var savedAt: Swift.Double
    var folderId: Swift.String?
}
enum FavoriteScope {
    case folder(Swift.String)
    case all
    case ungrouped
}
struct FavoritesView {
    enum Source {
        case local
        case account
    }
    enum Filter {
        case all
        case video
        case radio
        case other
    }
    var _store: SwiftUI.ObservedObject<One.FavoritesStore>
    var _follows: SwiftUI.ObservedObject<One.FollowStore>
    var __filter: SwiftUI.State<One.FavoritesView.Filter>
    var __scope: SwiftUI.State<One.FavoriteScope>
    var __confirmClear: SwiftUI.State<Swift.Bool>
    var __showNewFolder: SwiftUI.State<Swift.Bool>
    var __newFolderName: SwiftUI.State<Swift.String>
    var __renamingFolder: SwiftUI.State<One.FavoriteFolder?>
    var __renameText: SwiftUI.State<Swift.String>
    var __deletingFolder: SwiftUI.State<One.FavoriteFolder?>
    var __source: SwiftUI.State<One.FavoritesView.Source>
    var __loggedIn: SwiftUI.State<Swift.Bool>
}
struct FolderMenuLabel {
    let name: Swift.String
    let selected: Swift.Bool
}
struct FavoriteButton {
    let article: One.Article
    var idleColor: SwiftUI.Color
    var _store: SwiftUI.ObservedObject<One.FavoritesStore>
    var _settingsStore: SwiftUI.ObservedObject<One.SettingsStore>
    var _reduceMotion: SwiftUI.Environment<Swift.Bool>
    var __showNewFolder: SwiftUI.State<Swift.Bool>
    var __newFolderName: SwiftUI.State<Swift.String>
}
struct FollowListView {
    var _follows: SwiftUI.ObservedObject<One.FollowStore>
    var __query: SwiftUI.State<Swift.String>
}
class FollowStore {
    var _actors: Combine.Published<[One.FollowedActor]>
}
struct FollowedActor {
    enum CodingKeys {
        case performer
        case followedAt
    }
    var performer: One.Performer
    var followedAt: Swift.Double
}
class GateStore {
    var _passed: Combine.Published<Swift.Bool>
    var _privacyMode: Combine.Published<Swift.Bool>
    var _backgroundBlur: Combine.Published<Swift.Bool>
}
struct GateView {
    var _gate: SwiftUI.ObservedObject<One.GateStore>
    var _reduceMotion: SwiftUI.Environment<Swift.Bool>
    var __answer: SwiftUI.State<Swift.String>
    var __wrong: SwiftUI.State<Swift.Bool>
    var __shake: SwiftUI.State<CoreGraphics.CGFloat>
    var __solved: SwiftUI.State<Swift.Bool>
    var __appeared: SwiftUI.State<Swift.Bool>
    var _focused: SwiftUI.FocusState<Swift.Bool>
    var _fieldWidth: SwiftUI.ScaledMetric<CoreGraphics.CGFloat>
    var _contrast: SwiftUI.Environment<SwiftUI.ColorSchemeContrast>
    let ink: SwiftUI.Color
}
class HLSLease {
    let url: Foundation.URL
    let variant: Swift.String
    let token: Swift.String
}
class OneShot {
    let lock: __C.NSLock
    var fired: Swift.Bool
}
class HLSProxyServer {
    let queue: __C.OS_dispatch_queue
    let lock: __C.NSLock
    var listener: Network.NWListener?
    var port: Swift.UInt16
    var lastPort: Swift.UInt16
    var starting: Swift.Bool
    var waiters: [Swift.CheckedContinuation<Swift.UInt16, Swift.Error>]
    var sessions: [Swift.String : One.HLSSession]
    var order: [Swift.String]
}
class HLSSession {
    let token: Swift.String
    let playlistName: Swift.String
    let bases: [Swift.String]
    let key: [Swift.UInt8]
    let lock: __C.NSLock
    var preferred: Swift.Int
    var cache: [Swift.String : Foundation.Data]
    var cacheOrder: [Swift.String]
    var cacheBytes: Swift.Int
    var inflight: [Swift.String : Swift.Task<Foundation.Data, Swift.Error>]
    var resources: [Swift.String]
    var resourceIndex: [Swift.String : Swift.Int]
    var closed: Swift.Bool
}
enum HLSError {
    case http(Swift.Int)
    case notDecryptable(Swift.String)
    case serverUnavailable(Swift.String)
    case notWorthIt(Swift.String)
    case tooHeavy(Swift.String)
    case noPlaylist
    case badPlaylist
    case timedOut
}
class HomeModel {
    var _days: Combine.Published<[Swift.String]>
    var _selected: Combine.Published<Swift.String>
    var _contents: Combine.Published<[Swift.String : One.DayContent]>
    var _loadingDays: Combine.Published<Swift.Set<Swift.String>>
    var _errors: Combine.Published<[Swift.String : Swift.String]>
    var _starting: Combine.Published<Swift.Bool>
    var _startError: Combine.Published<Swift.String>
    var _pickerDate: Combine.Published<Foundation.Date>
    var latest: Swift.String
    var started: Swift.Bool
}
struct DayContent {
    var card: One.DailyCard?
    var topText: Swift.String
}
struct HomeView {
    var _model: SwiftUI.StateObject<One.HomeModel>
    var _settingsStore: SwiftUI.ObservedObject<One.SettingsStore>
    var __showDatePicker: SwiftUI.State<Swift.Bool>
    var __fold: SwiftUI.State<One.FoldGap?>
    var __contentWidth: SwiftUI.State<CoreGraphics.CGFloat>
}
struct HomeDayPage {
    var _model: SwiftUI.ObservedObject<One.HomeModel>
    let day: Swift.String
    let pickDate: () -> ()
    let fold: One.FoldGap?
    let containerWidth: CoreGraphics.CGFloat
    var _wide: One.LargeCanvas
}
struct DailyCardView {
    let card: One.DailyCard
    var wide: Swift.Bool
    var fold: One.FoldGap?
    var containerWidth: CoreGraphics.CGFloat
    var __showComments: SwiftUI.State<Swift.Bool>
}
struct DayHeader {
    let day: Swift.String
    let topText: Swift.String
    let pick: () -> ()
}
struct HeroImage {
    let url: Swift.String
    var maxHeight: CoreGraphics.CGFloat
    var _loader: SwiftUI.StateObject<One.ImageLoader>
}
struct CappedAspectLayout {
    var ratio: CoreGraphics.CGFloat
    var maxHeight: CoreGraphics.CGFloat
}
class ViewerCenter {
    var _item: Combine.Published<One.ViewerItem?>
}
struct ViewerItem {
    let id: Foundation.UUID
    let urls: [Swift.String]
    let index: Swift.Int
}
class ImageCache {
    let cache: __C.NSCache<__C.NSString, __C.UIImage>
}
class ImageLoader {
    var _image: Combine.Published<__C.UIImage?>
    var _failed: Combine.Published<Swift.Bool>
    var currentKey: Swift.String
}
class LaneSession: __C.NSObject {
    enum Action {
        case abort(Swift.Error)
        case proceed
    }
    let lock: __C.NSLock
    var urlSession: __C.NSURLSession?
    var currentTask: __C.NSURLSessionDataTask?
    var continuation: Swift.CheckedContinuation<(), Swift.Error>?
    var responseHandler: ((_: __C.NSHTTPURLResponse) -> One.LaneSession.Action)?
    var dataHandler: ((_: Foundation.Data) -> ())?
    var abortError: Swift.Error?
    var dropData: Swift.Bool
    var cancelled: Swift.Bool
}
enum DownloadFailure {
    case http(Swift.Int)
    case shortRead(expected: Swift.Int64, got: Swift.Int64)
    case sizeMismatch(expected: Swift.Int64, got: Swift.Int64)
    case badRange(expected: Swift.Int64, got: Swift.Int64)
    case file(Swift.String)
    case noSource
    case probeDone
}
struct LineMenu<A> where A: SwiftUI.View {
    var _lines: SwiftUI.ObservedObject<One.PlayLines>
    var label: () -> A
}
struct PlayLine {
    let url: Swift.String
    let index: Swift.Int
    var latency: Swift.Int?
    var failed: Swift.Bool
}
struct SearchField {
    var _text: SwiftUI.Binding<Swift.String>
    var placeholder: Swift.String
    var onSubmit: (_: Swift.String) -> ()
    var onClear: (() -> ())?
    var showsSearchButton: Swift.Bool
}
struct MonthPicker {
    var _month: SwiftUI.Binding<Swift.String>
    var title: Swift.String
}
struct SearchHistoryChips {
    var _history: SwiftUI.ObservedObject<One.SearchHistoryStore>
    var onSelect: (_: Swift.String) -> ()
    var onClear: () -> ()
}
struct LayoutToggleButton {
    let page: One.ListPage
    var _settingsStore: SwiftUI.ObservedObject<One.SettingsStore>
}
struct ArticleListItem {
    let item: One.Article
    let layout: One.ListLayout
}
struct ArticleGrid {
    let items: [One.Article]
    let layout: One.ListLayout
    let columns: Swift.Int
    let route: (_: One.Article) -> One.Route
    var __width: SwiftUI.State<CoreGraphics.CGFloat>
    var __fold: SwiftUI.State<One.FoldGap?>
}
struct FilterPanel<A> where A: SwiftUI.View {
    var content: A
}
enum ListLayout {
    case card
    case list
}
enum ListPage {
    case vod
    case discover
}
struct LocalPlayerView {
    let item: One.DownloadItem
    var _dismiss: SwiftUI.Environment<SwiftUI.DismissAction>
    var _lines: SwiftUI.StateObject<One.PlayLines>
    var __subtitleURL: SwiftUI.State<Swift.String>
}
struct MeBackground {}
struct GlassDivider {
    var _iconWidth: SwiftUI.ScaledMetric<CoreGraphics.CGFloat>
}
struct GlassRow {
    let icon: Swift.String
    let title: Swift.String
    var value: Swift.String
    var _iconWidth: SwiftUI.ScaledMetric<CoreGraphics.CGFloat>
}
struct GlassTile {
    let icon: Swift.String
    let title: Swift.String
    var badge: Swift.Int
    var _iconHeight: SwiftUI.ScaledMetric<CoreGraphics.CGFloat>
}
struct SectionLabel {
    let title: Swift.String
}
struct MeListPage<A> where A: SwiftUI.View {
    let title: Swift.String
    var content: () -> A
}
struct StorageBar {
    let segments: [(color: SwiftUI.Color, bytes: Swift.Int64)]
}
struct GlassCard<A> where A: SwiftUI.View {
    var padding: CoreGraphics.CGFloat
    var content: () -> A
}
struct GlassShape {
    var radius: CoreGraphics.CGFloat
    var _reduceTransparency: SwiftUI.Environment<Swift.Bool>
}
class MeModel {
    var _sessionLabel: Combine.Published<Swift.String>
    var _renewing: Combine.Published<Swift.Bool>
    var _cacheInfo: Combine.Published<(updatedAt: Swift.Double, expiresAt: Swift.Double)?>
    var _clearing: Combine.Published<Swift.Bool>
    var _cacheMessage: Combine.Published<Swift.String>
    var _summary: Combine.Published<One.CacheSummary>
    var _storage: Combine.Published<One.StorageBreakdown>
    var _notice: Combine.Published<Swift.String>
    var _apiInfo: Combine.Published<Swift.String>
    var _configStatus: Combine.Published<Swift.String>
    var _configChecking: Combine.Published<Swift.Bool>
    var _configUpdatedAt: Combine.Published<Swift.Double?>
    var _updateChecking: Combine.Published<Swift.Bool>
    var _account: Combine.Published<One.AccountInfo?>
    var _loggingOut: Combine.Published<Swift.Bool>
    var cancellables: Swift.Set<Combine.AnyCancellable>
}
struct MeView {
    var _model: SwiftUI.StateObject<One.MeModel>
    var _downloads: SwiftUI.ObservedObject<One.DownloadCenter>
    var _settingsStore: SwiftUI.ObservedObject<One.SettingsStore>
    var _gate: SwiftUI.ObservedObject<One.GateStore>
    var __confirmClearDownloads: SwiftUI.State<Swift.Bool>
    var __confirmClearCache: SwiftUI.State<Swift.Bool>
    var __editingConfig: SwiftUI.State<Swift.Bool>
    var __configDraft: SwiftUI.State<Swift.String>
    var __showLogin: SwiftUI.State<Swift.Bool>
    var __confirmLogout: SwiftUI.State<Swift.Bool>
    var __playingDownload: SwiftUI.State<One.DownloadItem?>
}
class MediaResolver {
    enum ProbeState {
        case ok(One.ResolvedMedia)
        case pending
        case failed
    }
    let lock: __C.NSLock
    var cache: [Swift.String : (media: One.ResolvedMedia, until: Foundation.Date)]
    let probeSession: __C.NSURLSession
}
struct ResolvedMedia {
    var url: Swift.String
    var size: Swift.Int64
}
actor MemberAccountService {
    var inflight: Swift.Task<One.MemberAccount?, Swift.Never>?
    var lastAttempt: Swift.Double
}
struct MiniRadioInset {
    var __active: SwiftUI.State<Swift.Bool>
    var _largeCanvas: One.LargeCanvas
}
struct FloatingBarBackground {}
struct MiniRadioBar {
    var compact: Swift.Bool
    var _radio: SwiftUI.ObservedObject<One.RadioPlayer>
}
struct DemandTag {
    var id: Swift.Int
    var title: Swift.String
}
struct MemberAccount {
    enum CodingKeys {
        case token
        case userKey
        case updatedAt
    }
    var token: Swift.String
    var userKey: Swift.String
    var updatedAt: Swift.Double
}
struct DailyCard {
    var id: Swift.Int
    var credit: Swift.String
    var text: Swift.String
    var author: Swift.String
    var imagePath: Swift.String
    var vol: Swift.Int?
    var likes: Swift.Int
    var comments: Swift.Int
    var collects: Swift.Int
}
struct ActorNav {
    var id: Swift.Int
    var name: Swift.String
}
enum ContentSort {
    case latest
    case popular
}
struct Performer {
    enum CodingKeys {
        case id
        case name
        case nickname
        case mainName
        case avatar
        case thumb
        case thumbnail
        case cover
    }
    var id: Swift.Int
    var name: Swift.String?
    var nickname: Swift.String?
    var mainName: Swift.String?
    var avatar: Swift.String?
    var thumb: Swift.String?
    var thumbnail: Swift.String?
    var cover: Swift.String?
}
struct Article {
    enum CodingKeys {
        case id
        case modelId
        case title
        case subtitle
        case intro
        case author
        case thumb
        case thumbnail
        case publishedAt
        case likeNumber
        case chapter
        case number
    }
    var id: Swift.Int
    var modelId: Swift.Int
    var title: Swift.String
    var subtitle: Swift.String?
    var intro: Swift.String?
    var author: Swift.String?
    var thumb: Swift.String?
    var thumbnail: Swift.String?
    var publishedAt: Swift.String?
    var likeNumber: Swift.Int?
    var chapter: Swift.Int?
    var number: Swift.String?
}
enum Route {
    case detail(id: Swift.Int, title: Swift.String)
    case series(id: Swift.Int, title: Swift.String, cover: Swift.String)
    case actor(One.Performer)
    case search(scope: Swift.Int, keyword: Swift.String)
    case follows
}
struct SeriesInfo {
    var title: Swift.String
    var author: Swift.String
    var thumb: Swift.String
    var chapters: [One.Article]
}
actor OfficialSiteScanner {
    struct Findings {
        var hosts: [Swift.String]
        var prefix: Swift.String?
        var origin: Swift.String
    }
    var lastAttempt: Foundation.Date
    var gotResponse: Swift.Bool
    let session: __C.NSURLSession
}
struct DiscoveryTab {
    let id: Swift.Int
    let title: Swift.String
}
struct OneApp {
    var _appDelegate: SwiftUI.UIApplicationDelegateAdaptor<One.AppDelegate>
}
class OneClient {
    struct RaceOutcome {
        var session: One.OneSession?
        var lastError: Swift.Error?
        var reachable: [Swift.String]
    }
    enum AttemptResult {
        case ok(One.OneSession)
        case refused(Swift.Error)
        case dead(Swift.Error)
    }
    let lock: __C.NSLock
    var session: One.OneSession?
    var inflight: Swift.Task<One.OneSession, Swift.Error>?
    var lastHeal: Foundation.Date
    var accountRecord: One.AccountRecord?
    var learnedImageHosts: [Swift.String]
    var preferredImageHost: Swift.String?
    var imageHostCache: (key: [Swift.String], hosts: [Swift.String])?
    let http: __C.NSURLSession
}
struct OneSession {
    enum CodingKeys {
        case user
        case domain
        case apiBase
        case apiPrefix
        case account
    }
    var user: One.OneUser
    var domain: [Swift.String : [Swift.String]]
    var apiBase: Swift.String
    var apiPrefix: Swift.String
    var account: One.AccountInfo?
}
struct AccountInfo {
    enum CodingKeys {
        case area
        case mobile
        case vipExpiry
    }
    var area: Swift.String
    var mobile: Swift.String
    var vipExpiry: Swift.String
}
struct OneUser {
    enum CodingKeys {
        case id
        case nickname
        case token
        case userKey
        case vipStatus
        case isVisitor
    }
    var id: Swift.Int
    var nickname: Swift.String
    var token: Swift.String
    var userKey: Swift.String
    var vipStatus: Swift.Int
    var isVisitor: Swift.Int
}
enum OneError {
    case message(Swift.String)
    case api(code: Swift.Int, message: Swift.String)
    case undecryptable(Swift.String)
    case noHost
    case interception
}
class OrientationLock {
    var mask: __C.UIInterfaceOrientationMask
}
class AppDelegate: __C.NSObject {}
class DismissPanRecognizer: __C.UIPanGestureRecognizer {
    var touchDown: __C.CGPoint?
}
class ZoomingScrollView: __C.UIScrollView {
    var onSwipe: (_: __C.CGSize?) -> ()
    var onDismiss: () -> ()
    var image: __C.UIImage?
    let imageView: __C.UIImageView
    let dismissPan: One.DismissPanRecognizer
    var fittedSize: __C.CGSize
}
struct PhotoViewer {
    let urls: [Swift.String]
    var _index: SwiftUI.State<Swift.Int>
    var __saving: SwiftUI.State<Swift.Bool>
    var __status: SwiftUI.State<Swift.String>
    var __statusIsError: SwiftUI.State<Swift.Bool>
    var __swipingToDismiss: SwiftUI.State<Swift.Bool>
    var _dismiss: SwiftUI.Environment<SwiftUI.DismissAction>
}
struct ZoomableImage {
    let url: Swift.String
    let onSwipeToDismiss: (_: Swift.Bool) -> ()
    let onDismiss: () -> ()
    var _loader: SwiftUI.StateObject<One.ImageLoader>
    var __swipeOffset: SwiftUI.State<__C.CGSize>
}
struct ZoomingImageView {
    let image: __C.UIImage?
    let onSwipe: (_: __C.CGSize?) -> ()
    let onDismiss: () -> ()
}
class PlayLines {
    var _lines: Combine.Published<[One.PlayLine]>
    var _testing: Combine.Published<Swift.Bool>
    var _selectedBase: Combine.Published<Swift.String?>
    var latencyByBase: [Swift.String : Swift.Int]
    var failedBases: Swift.Set<Swift.String>
    var generation: Swift.Int
    var pendingTests: Swift.Int
}
class PrivacyShield {
    enum Mode {
        case hidden
        case blur
        case gate
    }
    var window: __C.UIWindow?
    var mode: One.PrivacyShield.Mode
    var inactive: Swift.Bool
    var passed: Swift.Bool
    var backgroundBlur: Swift.Bool
    var unlockedOnce: Swift.Bool
    var previousKey: __C.UIWindow?
    var previewTask: Swift.Task<(), Swift.Never>?
    var cancellables: Swift.Set<Combine.AnyCancellable>
}
class BlurShieldController: __C.UIViewController {
    let image: __C.UIImage?
    let onTap: (() -> ())?
}
enum ProgressStore {
    struct Entry {
        enum CodingKeys {
            case t
            case d
            case at
        }
        var t: Swift.Int
        var d: Swift.Int
        var at: Swift.Double
    }
}
class RadioPlayer {
    struct PlayRequest {
        let id: Swift.Int
        let title: Swift.String
        let artist: Swift.String
        let mediaPath: Swift.String
        let artworkURL: Swift.String
        let localFile: Foundation.URL?
    }
    enum Status {
        case idle
        case loading
        case playing
        case paused
    }
    var _status: Combine.Published<One.RadioPlayer.Status>
    var _articleId: Combine.Published<Swift.Int>
    var _title: Combine.Published<Swift.String>
    var _artist: Combine.Published<Swift.String>
    var _artworkURL: Combine.Published<Swift.String>
    var _currentTime: Combine.Published<Swift.Double>
    var _duration: Combine.Published<Swift.Double>
    var _error: Combine.Published<Swift.String?>
    var _inlineBarsOnScreen: Combine.Published<Swift.Set<Swift.Int>>
    var player: __C.AVPlayer?
    var timeObserver: Any?
    var observers: Swift.Set<Combine.AnyCancellable>
    var artworkImage: __C.UIImage?
    var remoteCommandsInstalled: Swift.Bool
    var playToken: Swift.Int
    var lastRequest: One.RadioPlayer.PlayRequest?
}
struct RadioPlayerBar {
    let id: Swift.Int
    let title: Swift.String
    let author: Swift.String
    let audioPath: Swift.String
    let localFile: Foundation.URL?
    let cover: Swift.String
    var _radio: SwiftUI.ObservedObject<One.RadioPlayer>
    var __seeking: SwiftUI.State<Swift.Double?>
}
actor RemoteConfigService {
    var lastAttempt: Foundation.Date
}
struct RemoteImage {
    let url: Swift.String
    var contentMode: SwiftUI.ContentMode
    var background: SwiftUI.Color
    var maxPixel: Swift.Int
    var interpolation: SwiftUI.Image.Interpolation
    var _loader: SwiftUI.StateObject<One.ImageLoader>
}
struct NaturalRemoteImage {
    let url: Swift.String
    var _loader: SwiftUI.StateObject<One.ImageLoader>
}
struct RootView {
    var _gate: SwiftUI.ObservedObject<One.GateStore>
    var _viewer: SwiftUI.ObservedObject<One.ViewerCenter>
    var _interception: SwiftUI.ObservedObject<One.InterceptionMonitor>
    var _scenePhase: SwiftUI.Environment<SwiftUI.ScenePhase>
    var __unlockedOnce: SwiftUI.State<Swift.Bool>
}
struct MainTabView {
    var __radioActive: SwiftUI.State<Swift.Bool>
}
struct GlassTabBar {
    let radioActive: Swift.Bool
    var _largeCanvas: One.LargeCanvas
}
struct TabBarBackgroundBeforeGlass {}
struct RadioAccessory {
    var _placement: SwiftUI.Environment<SwiftUI.TabViewBottomAccessoryPlacement?>
}
struct RouteDestination {
    let route: One.Route
}
struct ScaledFont {
    var _size: SwiftUI.ScaledMetric<CoreGraphics.CGFloat>
    let weight: SwiftUI.Font.Weight
    let design: SwiftUI.Font.Design
    let monospacedDigit: Swift.Bool
}
class ScreenshotFeedback {
    var observer: __C.NSObject?
    var lastShown: Foundation.Date
}
class SearchHistoryStore {
    var _items: Combine.Published<[Swift.String]>
}
class SearchModel {
    var _scopeId: Combine.Published<Swift.Int>
    var _sort: Combine.Published<One.ContentSort>
    var _dateFilter: Combine.Published<One.SearchDateFilter>
    var _query: Combine.Published<Swift.String>
    var _items: Combine.Published<[One.Article]>
    var _scanned: Combine.Published<Swift.Int>
    var _loading: Combine.Published<Swift.Bool>
    var _loadingMore: Combine.Published<Swift.Bool>
    var _hasMore: Combine.Published<Swift.Bool>
    var _error: Combine.Published<Swift.String>
    var page: Swift.Int
    var seen: Swift.Set<Swift.Int>
    var serverHasMore: Swift.Bool
    var generation: Swift.Int
    var loadedKey: Swift.String
}
struct SearchDateFilter {
    var year: Swift.Int?
    var month: Swift.Int?
}
struct SearchEntryButton {
    let scope: Swift.Int
}
struct SearchView {
    var _model: SwiftUI.StateObject<One.SearchModel>
    var _history: SwiftUI.ObservedObject<One.SearchHistoryStore>
    var __input: SwiftUI.State<Swift.String>
    var __confirmClear: SwiftUI.State<Swift.Bool>
    var __showFilters: SwiftUI.State<Swift.Bool>
    var __expandedGroups: SwiftUI.State<Swift.Set<Swift.String>>
    var _reduceMotion: SwiftUI.Environment<Swift.Bool>
}
struct SearchFilterSheet {
    var _dismiss: SwiftUI.Environment<SwiftUI.DismissAction>
    var _sort: SwiftUI.State<One.ContentSort>
    var _dateFilter: SwiftUI.State<One.SearchDateFilter>
    let onApply: (One.ContentSort, One.SearchDateFilter) -> ()
}
struct SearchEpisodeRow {
    let item: One.Article
}
struct SearchGroupHeader {
    let group: One.SearchGroup
    let expanded: Swift.Bool
    let toggle: () -> ()
    var _typeSize: SwiftUI.Environment<SwiftUI.DynamicTypeSize>
}
struct SearchGroup {
    let id: Swift.Int
    let key: Swift.String
    var articles: [One.Article]
}
struct SearchScope {
    let id: Swift.Int
    let title: Swift.String
}
class SeriesModel {
    let seriesId: Swift.Int
    var _title: Combine.Published<Swift.String>
    var _cover: Combine.Published<Swift.String>
    var _chapters: Combine.Published<[One.Article]>
    var _loading: Combine.Published<Swift.Bool>
    var _error: Combine.Published<Swift.String>
    var loaded: Swift.Bool
}
struct SeriesView {
    var _model: SwiftUI.StateObject<One.SeriesModel>
}
struct SubtitleCue {
    let start: Swift.Double
    let end: Swift.Double
    let text: Swift.String
}
struct TagChips {
    let tags: [One.DetailTag]
}
struct FlowLayout {
    var spacing: CoreGraphics.CGFloat
    var lineSpacing: CoreGraphics.CGFloat
}
class ToastCenter {
    var _message: Combine.Published<Swift.String?>
    var hideTask: Swift.Task<(), Swift.Never>?
}
struct ToastOverlay {
    var _center: SwiftUI.ObservedObject<One.ToastCenter>
    var _largeCanvas: One.LargeCanvas
    var __radioActive: SwiftUI.State<Swift.Bool>
    var __sideBars: SwiftUI.State<Swift.Bool>
}
class InterceptionMonitor {
    var _detected: Combine.Published<Swift.Bool>
    var lastShown: Foundation.Date
}
class TrustedSessionDelegate: __C.NSObject {
    let requireSameHost: Swift.Bool
}
struct AmbientBackground {
    let cover: Swift.String
}
struct VideoDetailPage {
    var _model: SwiftUI.ObservedObject<One.DetailModel>
    let detail: One.ArticleDetail
    var _settingsStore: SwiftUI.ObservedObject<One.SettingsStore>
    var _reduceMotion: SwiftUI.Environment<Swift.Bool>
    var _wide: One.LargeCanvas
    var __pageSize: SwiftUI.State<__C.CGSize>
    var __division: SwiftUI.State<__C.CGRect?>
    var _playLines: SwiftUI.StateObject<One.PlayLines>
    var __playing: SwiftUI.State<Swift.Bool>
    var __autoPlayAfterSwitch: SwiftUI.State<Swift.Bool>
    var __useBuiltinOnce: SwiftUI.State<Swift.Bool>
    var __showEpisodes: SwiftUI.State<Swift.Bool>
    var __bodyExpanded: SwiftUI.State<Swift.Bool>
}
struct EpisodesSheet {
    let episodes: [One.CollectionEpisode]
    let currentId: Swift.Int
    var onSelect: (_: One.CollectionEpisode) -> ()
    var _dismiss: SwiftUI.Environment<SwiftUI.DismissAction>
}
struct DownloadCard {
    let detail: One.ArticleDetail
    let coverURL: Swift.String
    var _center: SwiftUI.ObservedObject<One.DownloadCenter>
    var __resolving: SwiftUI.State<Swift.Bool>
    var __errorText: SwiftUI.State<Swift.String>
}
struct EpisodeCard {
    let item: One.CollectionEpisode
    let cover: Swift.String
    let current: Swift.Bool
    let progress: Swift.Double?
}
struct DownloadIconButton {
    let detail: One.ArticleDetail
    let coverURL: Swift.String
    var _center: SwiftUI.ObservedObject<One.DownloadCenter>
}
struct VideoPlayerCard {
    let cover: Swift.String
    let mediaPath: Swift.String
    let subtitleURL: Swift.String
    let maxSurfaceHeight: CoreGraphics.CGFloat
    var _model: SwiftUI.StateObject<One.VideoPlayerModel>
    var _lines: SwiftUI.ObservedObject<One.PlayLines>
    var _settingsStore: SwiftUI.ObservedObject<One.SettingsStore>
    var __showSubtitleStyle: SwiftUI.State<Swift.Bool>
}
struct SubtitleStyleSheet {
    var _settingsStore: SwiftUI.ObservedObject<One.SettingsStore>
    var _dismiss: SwiftUI.Environment<SwiftUI.DismissAction>
}
class PiPKeeper {
    let lock: __C.NSLock
    var entries: [(controller: __C.AVPlayerViewController, player: __C.AVPlayer)]
}
class PlayerBox {
    let player: __C.AVPlayer
    var timeObserver: Any?
    var subtitleObserver: Any?
}
class VideoPlayerModel {
    enum Source {
        case local
        case hls
        case mp4
    }
    let articleId: Swift.Int
    let mediaPath: Swift.String
    let localFile: Foundation.URL?
    let hlsPaths: [Swift.String]
    var subtitleURL: Swift.String
    var subtitleRequested: Swift.String
    let box: One.PlayerBox
    var _hasSource: Combine.Published<Swift.Bool>
    var _source: Combine.Published<One.VideoPlayerModel.Source>
    var _error: Combine.Published<Swift.String>
    var _failure: Combine.Published<Swift.Error?>
    var _currentLineURL: Combine.Published<Swift.String>
    var _speed: Combine.Published<Swift.Double>
    var _loop: Combine.Published<Swift.Bool>
    var _fill: Combine.Published<Swift.Bool>
    var _autoFullscreen: Combine.Published<Swift.Bool>
    var _resumeAt: Combine.Published<Swift.Double>
    var _hasSubtitle: Combine.Published<Swift.Bool>
    var _subtitlesEnabled: Combine.Published<Swift.Bool>
    var _subtitleText: Combine.Published<Swift.String>
    var _stats: Combine.Published<Swift.String>
    var cancellables: Swift.Set<Combine.AnyCancellable>
    let autoplayRequested: Swift.Bool
    var tStart: Swift.Double
    var tResolved: Swift.Double
    var tReady: Swift.Double
    var tFirst: Swift.Double
    var itemObservers: Swift.Set<Combine.AnyCancellable>
    var started: Swift.Bool
    var resumed: Swift.Bool
    var pendingSeek: Swift.Double
    var playAfterLoad: Swift.Bool
    var isFullscreen: Swift.Bool
    let preferredLine: Swift.String?
    var subtitleCues: [One.SubtitleCue]
    var hlsAttempt: Swift.Int
    var hlsAbandoned: Swift.Bool
    var hlsVariant: Swift.String
    var sourceNotes: [Swift.String]
    var epoch: Swift.Int
    var advancingEpoch: Swift.Int
    var hlsWatchdog: Swift.Task<(), Swift.Never>?
    var stallWatchdog: Swift.Task<(), Swift.Never>?
    var left: Swift.Bool
}
class SubtitleOverlayView: __C.UIView {
    let bubble: One.SubtitleBubbleView
    let rotateButton: __C.UIButton
    var positionX: Swift.Double
    var positionY: Swift.Double
    var onDragEnd: ((Swift.Double, Swift.Double) -> ())?
}
class SubtitleBubbleView: __C.UIView {
    let label: __C.UILabel
}
struct VideoSurface {
    class Coordinator: __C.NSObject {
        var onFullscreen: (Swift.Bool, Swift.Bool) -> ()
        var owner: Swift.ObjectIdentifier?
        weak var subtitleHost: One.SubtitleOverlayView?
    }
    let player: __C.AVPlayer
    let fill: Swift.Bool
    let autoFullscreen: Swift.Bool
    let subtitleText: Swift.String
    let subtitleFontSize: Swift.Double
    let subtitleOpacity: Swift.Double
    let subtitleBackgroundOpacity: Swift.Double
    let orientationOwner: Swift.ObjectIdentifier
    let onFullscreen: (Swift.Bool, Swift.Bool) -> ()
}
class VodModel {
    var _tags: Combine.Published<[One.DemandTag]>
    var _tagId: Combine.Published<Swift.Int>
    var _sort: Combine.Published<One.ContentSort>
    var _month: Combine.Published<Swift.String>
    var _items: Combine.Published<[One.Article]>
    var _loading: Combine.Published<Swift.Bool>
    var _loadingMore: Combine.Published<Swift.Bool>
    var _hasMore: Combine.Published<Swift.Bool>
    var _error: Combine.Published<Swift.String>
    var page: Swift.Int
    var generation: Swift.Int
    var loadedKey: Swift.String
    var tagsLoaded: Swift.Bool
}
struct VodView {
    var _model: SwiftUI.StateObject<One.VodModel>
    var _settingsStore: SwiftUI.ObservedObject<One.SettingsStore>
    var __pageWidth: SwiftUI.State<CoreGraphics.CGFloat>
    var __pageFold: SwiftUI.State<One.FoldGap?>
    var _largeCanvas: One.LargeCanvas
}
class NoRedirect: __C.NSObject {}
struct WebDAVConfig {
    enum CodingKeys {
        case url
        case user
        case password
        case appName
    }
    var url: Swift.String
    var user: Swift.String
    var password: Swift.String
    var appName: Swift.String
}
enum WebDAVError {
    case status(Swift.Int)
    case network(Swift.String)
    case incomplete
    case badURL
    case unauthorized
    case forbidden
    case missingFolder
    case locked
    case full
    case redirected
    case busy
}
struct WebDAVClient {
    let folder: Foundation.URL
    let authorization: Swift.String
}
class ResourceBundleClass {}

extension __C.UIBackgroundTaskIdentifier: @retroactive Swift._HasCustomAnyHashableRepresentation {
    func _toCustomAnyHashable() -> Swift.AnyHashable?
}
extension __C.UIBackgroundTaskIdentifier: @retroactive Swift.RawRepresentable {
    typealias RawValue = Swift.Int

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension __C.UIBackgroundTaskIdentifier: @retroactive Swift._SwiftNewtypeWrapper {}
extension __C.UIBackgroundTaskIdentifier: @retroactive Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension __C.UIBackgroundTaskIdentifier: @retroactive Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension __C.UIBackgroundTaskIdentifier: @retroactive Swift._ObjectiveCBridgeable {
    typealias _ObjectiveCType = __C.NSNumber

    func _bridgeToObjectiveC() -> Self._ObjectiveCType

    static func _forceBridgeFromObjectiveC(_: Self._ObjectiveCType, result: inout Self?)
    static func _conditionallyBridgeFromObjectiveC(_: Self._ObjectiveCType, result: inout Self?) -> Swift.Bool
    static func _unconditionallyBridgeFromObjectiveC(_: Self._ObjectiveCType?) -> Self
}
extension __C.UIInterfaceOrientationMask: @retroactive Swift.ExpressibleByArrayLiteral {
    typealias ArrayLiteralElement = __C.UIInterfaceOrientationMask

    init(arrayLiteral: Self.ArrayLiteralElement...)
}
extension __C.UIInterfaceOrientationMask: @retroactive Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension __C.UIInterfaceOrientationMask: @retroactive Swift.SetAlgebra {
    typealias Element = __C.UIInterfaceOrientationMask

    init()
    init<A1>(_: consuming A1) where A1: Swift.Sequence, Self.Element == A1.Element

    var isEmpty: Swift.Bool {
        get
    }

    func contains(_: Self.Element) -> Swift.Bool
    func union(_: consuming Self) -> Self
    func intersection(_: Self) -> Self
    func symmetricDifference(_: consuming Self) -> Self
    func insert(_: consuming Self.Element) -> (inserted: Swift.Bool, memberAfterInsert: Self.Element)
    func remove(_: Self.Element) -> Self.Element?
    func update(with: consuming Self.Element) -> Self.Element?
    func formUnion(_: consuming Self)
    func formIntersection(_: Self)
    func formSymmetricDifference(_: consuming Self)
    func subtracting(_: Self) -> Self
    func isSubset(of: Self) -> Swift.Bool
    func isDisjoint(with: Self) -> Swift.Bool
    func isSuperset(of: Self) -> Swift.Bool
    func subtract(_: Self)
}
extension __C.UIInterfaceOrientationMask: @retroactive Swift.RawRepresentable {
    typealias RawValue = Swift.UInt

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension __C.UIInterfaceOrientationMask: @retroactive Swift.OptionSet {
    typealias Element = __C.UIInterfaceOrientationMask

    init(rawValue: Self.RawValue)
}
extension One.AccountFavoritesModel: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension __C.UIWindowLevel: @retroactive Swift._HasCustomAnyHashableRepresentation {
    func _toCustomAnyHashable() -> Swift.AnyHashable?
}
extension __C.UIWindowLevel: @retroactive Swift.RawRepresentable {
    typealias RawValue = CoreGraphics.CGFloat

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension __C.UIWindowLevel: @retroactive Swift._SwiftNewtypeWrapper {}
extension __C.UIWindowLevel: @retroactive Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension __C.UIWindowLevel: @retroactive Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension __C.UIWindowLevel: @retroactive Swift._ObjectiveCBridgeable {
    typealias _ObjectiveCType = __C.NSNumber

    func _bridgeToObjectiveC() -> Self._ObjectiveCType

    static func _forceBridgeFromObjectiveC(_: Self._ObjectiveCType, result: inout Self?)
    static func _conditionallyBridgeFromObjectiveC(_: Self._ObjectiveCType, result: inout Self?) -> Swift.Bool
    static func _unconditionallyBridgeFromObjectiveC(_: Self._ObjectiveCType?) -> Self
}
extension __C.UIApplicationOpenExternalURLOptionsKey: @retroactive Swift._HasCustomAnyHashableRepresentation {
    func _toCustomAnyHashable() -> Swift.AnyHashable?
}
extension __C.UIApplicationOpenExternalURLOptionsKey: @retroactive Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension __C.UIApplicationOpenExternalURLOptionsKey: @retroactive Swift._SwiftNewtypeWrapper {}
extension __C.UIApplicationOpenExternalURLOptionsKey: @retroactive Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension __C.UIApplicationOpenExternalURLOptionsKey: @retroactive Swift._ObjectiveCBridgeable {
    typealias _ObjectiveCType = __C.NSString

    func _bridgeToObjectiveC() -> Self._ObjectiveCType

    static func _forceBridgeFromObjectiveC(_: Self._ObjectiveCType, result: inout Self?)
    static func _conditionallyBridgeFromObjectiveC(_: Self._ObjectiveCType, result: inout Self?) -> Swift.Bool
    static func _unconditionallyBridgeFromObjectiveC(_: Self._ObjectiveCType?) -> Self
}
extension __C.UIApplicationOpenExternalURLOptionsKey: @retroactive Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension __C.NSFileAttributeKey: @retroactive Swift._HasCustomAnyHashableRepresentation {
    func _toCustomAnyHashable() -> Swift.AnyHashable?
}
extension __C.NSFileAttributeKey: @retroactive Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension __C.NSFileAttributeKey: @retroactive Swift._SwiftNewtypeWrapper {}
extension __C.NSFileAttributeKey: @retroactive Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension __C.NSFileAttributeKey: @retroactive Swift._ObjectiveCBridgeable {
    typealias _ObjectiveCType = __C.NSString

    func _bridgeToObjectiveC() -> Self._ObjectiveCType

    static func _forceBridgeFromObjectiveC(_: Self._ObjectiveCType, result: inout Self?)
    static func _conditionallyBridgeFromObjectiveC(_: Self._ObjectiveCType, result: inout Self?) -> Swift.Bool
    static func _unconditionallyBridgeFromObjectiveC(_: Self._ObjectiveCType?) -> Self
}
extension __C.NSFileAttributeKey: @retroactive Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension __C.CFStringRef: @retroactive Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension __C.CFStringRef: @retroactive Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension __C.CFStringRef: @retroactive CoreFoundation._CFObject {}
extension __C.PHAuthorizationStatus: @retroactive Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension __C.PHAuthorizationStatus: @retroactive Swift.RawRepresentable {
    typealias RawValue = Swift.Int

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension __C.NSURLResourceKey: @retroactive Swift._HasCustomAnyHashableRepresentation {
    func _toCustomAnyHashable() -> Swift.AnyHashable?
}
extension __C.NSURLResourceKey: @retroactive Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension __C.NSURLResourceKey: @retroactive Swift._SwiftNewtypeWrapper {}
extension __C.NSURLResourceKey: @retroactive Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension __C.NSURLResourceKey: @retroactive Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension __C.NSURLResourceKey: @retroactive Swift._ObjectiveCBridgeable {
    typealias _ObjectiveCType = __C.NSString

    func _bridgeToObjectiveC() -> Self._ObjectiveCType

    static func _forceBridgeFromObjectiveC(_: Self._ObjectiveCType, result: inout Self?)
    static func _conditionallyBridgeFromObjectiveC(_: Self._ObjectiveCType, result: inout Self?) -> Swift.Bool
    static func _unconditionallyBridgeFromObjectiveC(_: Self._ObjectiveCType?) -> Self
}
extension One.AccountFavoritesView: SwiftUI.View {
    typealias Body = accessor function at 31612

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension __C.AVPlayerTimeControlStatus: @retroactive Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension __C.AVPlayerTimeControlStatus: @retroactive Swift.RawRepresentable {
    typealias RawValue = Swift.Int

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension __C.AVPlayerItemStatus: @retroactive Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension __C.AVPlayerItemStatus: @retroactive Swift.RawRepresentable {
    typealias RawValue = Swift.Int

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.AccountLoginView: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.NavigationStack<SwiftUI.NavigationPath, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7toolbar7contentQrqd__yXE_tAA14ToolbarContentRd__lF", 0) __<One.MeListPage<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Section<SwiftUI.EmptyView, SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Text, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12keyboardTypeyQrSo010UIKeyboardE0VF", 0) __<SwiftUI.TextField<SwiftUI.Text>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FrameLayout>)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Text, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12keyboardTypeyQrSo010UIKeyboardE0VF", 0) __<SwiftUI.TextField<SwiftUI.Text>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.String>>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Text, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.SecureField<SwiftUI.Text>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.String>>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>)>>)>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>, SwiftUI.ModifiedContent<SwiftUI.Section<SwiftUI.EmptyView, SwiftUI.ModifiedContent<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(Swift.Optional<SwiftUI.ProgressView<SwiftUI.EmptyView, SwiftUI.EmptyView>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._FlexFrameLayout>)>>, SwiftUI._FlexFrameLayout>>, SwiftUI._EnvironmentKeyTransformModifier<Swift.Bool>>, SwiftUI.EmptyView>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>)>>, SwiftUI.ToolbarItem<(), SwiftUI.Button<SwiftUI.Text>>>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.ColorScheme>>, SwiftUI._PreferenceWritingModifier<SwiftUI.PreferredColorSchemeKey>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.AccountFolder: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.AccountFolder: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.AccountFolder: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.AccountRecord: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.AccountRecord: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.AccountRecord: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.AccountRecord.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.AccountRecord.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.AccountRecord.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.AccountRecord.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.AccountRecord.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.ActorModel: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.ActorView: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<accessor function at 31612, SwiftUI._ValueActionModifier<One.Performer?>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.LargeCanvas: SwiftUI.DynamicProperty {
    func update()

    static var _propertyBehaviors: Swift.UInt32 {
        get
    }
    static var _propertyStorageSize: Swift.Int? {
        get
    }

    static func _makeProperty<A1>(in: inout SwiftUI._DynamicPropertyBuffer, container: SwiftUI._GraphValue<A1>, fieldOffset: Swift.Int, inputs: inout SwiftUI._GraphInputs)
}
extension One.SideBarsReader: SwiftUI.ViewModifier {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.AnyView, SwiftUI._ViewModifier_Content<One.SideBarsReader>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.OcclusionAvoider: SwiftUI.ViewModifier {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI._ViewModifier_Content<One.OcclusionAvoider>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, One.GeometryValueReader<One.OcclusionInsets>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.OcclusionInsets: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.FoldGap: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.VerticalEdgeReader: SwiftUI.ViewModifier {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE8onChange2of7initial_Qrqd___Sbyqd___qd__tctSQRd__lF", 0) __<SwiftUI._ViewModifier_Content<One.VerticalEdgeReader>, Swift.Bool>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.TrailingToolbar: SwiftUI.ViewModifier {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.AnyView, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7toolbar7contentQrqd__yXE_tAA14ToolbarContentRd__lF", 0) __<SwiftUI._ViewModifier_Content<One.TrailingToolbar<A, B>>, SwiftUI.ToolbarItemGroup<SwiftUI.TupleView<(A, Swift.Optional<B>)>>>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.GeometryValueReader: SwiftUI.ViewModifier {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.AnyView, SwiftUI._ViewModifier_Content<One.GeometryValueReader<A>>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.FoldSplit: SwiftUI.View {
    typealias Body = SwiftUI._VariadicView.Tree<SwiftUI._LayoutRoot<One.FoldSplitLayout>, SwiftUI.TupleView<(A, B)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.FoldSplitLayout: SwiftUI.Animatable {
    typealias AnimatableData = SwiftUI.EmptyAnimatableData

    var animatableData: Self.AnimatableData {
        get
        set
    }

    static func _makeAnimatable(value: inout SwiftUI._GraphValue<Self>, inputs: SwiftUI._GraphInputs)
}
extension One.FoldSplitLayout: SwiftUI.Layout {
    typealias Cache = ()

    func makeCache(subviews: SwiftUI.LayoutSubviews) -> Self.Cache
    func updateCache(_: inout Self.Cache, subviews: SwiftUI.LayoutSubviews)
    func spacing(subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> SwiftUI.ViewSpacing
    func sizeThatFits(proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> __C.CGSize
    func placeSubviews(in: __C.CGRect, proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache)
    func explicitAlignment(of: SwiftUI.HorizontalAlignment, in: __C.CGRect, proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> CoreGraphics.CGFloat?
    func explicitAlignment(of: SwiftUI.VerticalAlignment, in: __C.CGRect, proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> CoreGraphics.CGFloat?

    static var layoutProperties: SwiftUI.LayoutProperties {
        get
    }

    static func _makeLayoutView(root: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewOutputs
}
extension One.ApiHostDirectory: Swift.Actor {
    var unownedExecutor: Swift.UnownedSerialExecutor {
        get
    }
}
extension One.RemoteConfig: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.RemoteConfig: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.RemoteConfig: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.RemoteConfig.UpdateInfo: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.RemoteConfig.UpdateInfo: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.RemoteConfig.UpdateInfo: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.RemoteConfig.CryptoKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.RemoteConfig.CryptoKeys: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.RemoteConfig.CryptoKeys: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.RemoteConfig.MediaPrefs: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.RemoteConfig.MediaPrefs: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.RemoteConfig.MediaPrefs: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.RemoteConfig.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.RemoteConfig.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.RemoteConfig.CodingKeys: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.RemoteConfig.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.RemoteConfig.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.RemoteConfig.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.RemoteConfig.MediaPrefs.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.RemoteConfig.MediaPrefs.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.RemoteConfig.MediaPrefs.CodingKeys: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.RemoteConfig.MediaPrefs.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.RemoteConfig.MediaPrefs.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.RemoteConfig.MediaPrefs.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.RemoteConfig.CryptoKeys.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.RemoteConfig.CryptoKeys.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.RemoteConfig.CryptoKeys.CodingKeys: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.RemoteConfig.CryptoKeys.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.RemoteConfig.CryptoKeys.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.RemoteConfig.CryptoKeys.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.RemoteConfig.UpdateInfo.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.RemoteConfig.UpdateInfo.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.RemoteConfig.UpdateInfo.CodingKeys: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.RemoteConfig.UpdateInfo.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.RemoteConfig.UpdateInfo.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.RemoteConfig.UpdateInfo.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.AppSettings: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.AppSettings: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.AppSettings: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.SettingsStore: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.AppSettings.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.AppSettings.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.AppSettings.CodingKeys: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.AppSettings.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.AppSettings.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.AppSettings.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.LatestRelease: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.CollectionEpisode: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.CollectionEpisode: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.CollectionEpisode: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.DetailModel: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.DetailTag: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.DetailTag: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.DetailTag: Swift.Identifiable {
    typealias ID = Swift.String

    var id: Self.ID {
        get
    }
}
extension One.ArticleBodyBlock: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.ArticleBodyBlock: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.EmptyHint: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, One.ScaledFont>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>?)>>, SwiftUI._FlexFrameLayout>, SwiftUI._PaddingLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.LoadMoreRow: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI._ConditionalContent<One.LoadingRow, SwiftUI.ModifiedContent<SwiftUI.Button<SwiftUI.Text>, SwiftUI._FlexFrameLayout>>>, SwiftUI._AppearanceActionModifier>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ArticleRow: SwiftUI.View {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(One.ArticleThumb, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>?, One.ArticleMeta)>>)>>, SwiftUI._PaddingLayout>, SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(One.ArticleThumb, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>?, One.ArticleMeta)>>, SwiftUI.Spacer)>>, SwiftUI._PaddingLayout>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.LoadingRow: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Spacer, SwiftUI.ProgressView<SwiftUI.EmptyView, SwiftUI.EmptyView>, SwiftUI.Spacer)>>, SwiftUI._PaddingLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ArticleThumb: SwiftUI.View {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ZStack<SwiftUI.TupleView<(SwiftUI._ConditionalContent<SwiftUI.TupleView<(SwiftUI.Color, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Font?>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FlexFrameLayout>)>, One.RemoteImage>, SwiftUI.ModifiedContent<One.TypeBadge, SwiftUI._PaddingLayout>?)>>, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ZStack<SwiftUI.TupleView<(SwiftUI._ConditionalContent<SwiftUI.TupleView<(SwiftUI.Color, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FlexFrameLayout>)>, One.RemoteImage>, Swift.Optional<SwiftUI.ModifiedContent<One.TypeBadge, SwiftUI._PaddingLayout>>)>>, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ArticleMeta: SwiftUI.View {
    typealias Body = SwiftUI.ViewThatFits<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>?, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FixedSizeLayout>?, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE20accessibilityElement8childrenQrAA26AccessibilityChildBehaviorV_tF", 0) __<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, SwiftUI._FixedSizeLayout>>, SwiftUI.AccessibilityAttachmentModifier>?)>>, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>?, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FixedSizeLayout>?, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE20accessibilityElement8childrenQrAA26AccessibilityChildBehaviorV_tF", 0) __<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, SwiftUI._FixedSizeLayout>>, SwiftUI.AccessibilityAttachmentModifier>?)>>)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ArticleCard: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>?, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Text)>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Font?>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>?, SwiftUI.Text, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>?, One.ArticleMeta)>>)>>, SwiftUI._PaddingLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.TypeBadge: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15dynamicTypeSizeyQrqd__SXRd__AA07DynamiceF0O5BoundRtd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, One.ScaledFont>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.ModifiedContent<SwiftUI.Text, One.ScaledFont>)>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, Swift.PartialRangeThrough<SwiftUI.DynamicTypeSize>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ArticleGridCell: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ZStack<SwiftUI.TupleView<(SwiftUI.Color, One.RemoteImage?, SwiftUI.ModifiedContent<One.TypeBadge, SwiftUI._PaddingLayout>?)>>, SwiftUI._AspectRatioLayout>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, One.ArticleMeta)>>, SwiftUI._FlexFrameLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.AuthorFooter: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>>, SwiftUI.BorderlessButtonStyle>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>>, SwiftUI.BorderlessButtonStyle>)>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Font?>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, SwiftUI._FlexFrameLayout>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.BackupCenter: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.BackupError: Foundation.LocalizedError {
    var errorDescription: Swift.String? {
        get
    }
    var failureReason: Swift.String? {
        get
    }
    var helpAnchor: Swift.String? {
        get
    }
    var recoverySuggestion: Swift.String? {
        get
    }
}
extension One.BackupError: Swift.Error {
    var _code: Swift.Int {
        get
    }
    var _domain: Swift.String {
        get
    }
    var _userInfo: Swift.AnyObject? {
        get
    }

    func _getEmbeddedNSError() -> Swift.AnyObject?
}
extension One.BackupFile: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.BackupFile: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.BackupFile.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.BackupFile.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.BackupFile.CodingKeys: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.BackupFile.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.BackupFile.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.BackupFile.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.Lossy: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.ExportedFile: Swift.Identifiable {
    typealias ID = Foundation.UUID

    var id: Self.ID {
        get
    }
}
extension One.BackupView: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE5alert_11isPresented7actions7messageQrAA18LocalizedStringKeyV_AA7BindingVySbGqd__yXEqd_0_yXEtAaBRd__AaBRd_0_r0_lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE5sheet4item9onDismiss7contentQrAA7BindingVyqd__SgG_yycSgqd_0_qd__cts12IdentifiableRd__AaBRd_0_r0_lF", 0) __<SwiftUI.ModifiedContent<One.MeListPage<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Section<SwiftUI.Text, SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.Spacer, SwiftUI.Text)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.Spacer, SwiftUI.Text)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.Spacer, SwiftUI.Text)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.Spacer, SwiftUI.Text)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.Spacer, SwiftUI.Text)>>)>, SwiftUI.Text>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>, SwiftUI.ModifiedContent<SwiftUI.Section<SwiftUI.Text, SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FrameLayout>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE21disableAutocorrectionyQrSbSgF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE27textInputAutocapitalizationyQrAA04TexteF0VSgF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12keyboardTypeyQrSo010UIKeyboardE0VF", 0) __<SwiftUI.TextField<SwiftUI.Text>>>>)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FrameLayout>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE21disableAutocorrectionyQrSbSgF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE27textInputAutocapitalizationyQrAA04TexteF0VSgF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12keyboardTypeyQrSo010UIKeyboardE0VF", 0) __<SwiftUI.TextField<SwiftUI.Text>>>>)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FrameLayout>, SwiftUI.SecureField<SwiftUI.Text>)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FrameLayout>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE21disableAutocorrectionyQrSbSgF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE27textInputAutocapitalizationyQrAA04TexteF0VSgF", 0) __<SwiftUI.TextField<SwiftUI.Text>>>)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FrameLayout>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, Swift.Optional<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ProgressView<SwiftUI.EmptyView, SwiftUI.EmptyView>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>>)>, SwiftUI.Text>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>, SwiftUI.ModifiedContent<SwiftUI.Section<SwiftUI.Text, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>, SwiftUI.Text>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>)>>, SwiftUI._AppearanceActionModifier>, One.ExportedFile, One.ShareSheet>, SwiftUI.TupleView<(@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE21disableAutocorrectionyQrSbSgF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE27textInputAutocapitalizationyQrAA04TexteF0VSgF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12keyboardTypeyQrSo010UIKeyboardE0VF", 0) __<SwiftUI.TextField<SwiftUI.Text>>>>, SwiftUI.Button<SwiftUI.Text>, SwiftUI.Button<SwiftUI.Text>)>, SwiftUI.Text>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ShareSheet: SwiftUI.UIViewControllerRepresentable {
    typealias UIViewControllerType = __C.UIActivityViewController
    typealias Coordinator = ()

    func makeUIViewController(context: SwiftUI.UIViewControllerRepresentableContext<Self>) -> Self.UIViewControllerType
    func updateUIViewController(_: Self.UIViewControllerType, context: SwiftUI.UIViewControllerRepresentableContext<Self>)
    func makeCoordinator() -> Self.Coordinator
    func sizeThatFits(_: SwiftUI.ProposedViewSize, uiViewController: Self.UIViewControllerType, context: SwiftUI.UIViewControllerRepresentableContext<Self>) -> __C.CGSize?
    func _identifiedViewTree(in: Self.UIViewControllerType) -> SwiftUI._IdentifiedViewTree

    static func dismantleUIViewController(_: Self.UIViewControllerType, coordinator: Self.Coordinator)
    static func _layoutOptions(_: Self.UIViewControllerType) -> SwiftUI._PlatformViewRepresentableLayoutOptions
}
extension One.ShareSheet: SwiftUI.View {
    typealias Body = Swift.Never

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.CommentSort: Swift.Identifiable {
    typealias ID = Swift.String

    var id: Self.ID {
        get
    }
}
extension One.CommentSort: Swift.CaseIterable {
    typealias AllCases = [One.CommentSort]

    static var allCases: Self.AllCases {
        get
    }
}
extension One.CommentSort: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.CommentSort: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.CommentSort: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.OneComment: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.OneComment: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.OneComment: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.CommentImage: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.CommentImage: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.CommentRow: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(One.CommentAvatar, SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(One.CommentHeader, One.CommentContent, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE10labelStyleyQrqd__AA05LabelE0Rd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>, SwiftUI.AccessibilityAttachmentModifier>>, Swift.Optional<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, One.CompactLabelStyle>, Swift.Optional<Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ForEach<Swift.Array<One.OneComment>, Swift.Int, One.ReplyRow>, Swift.Optional<SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.ProgressView<SwiftUI.EmptyView, SwiftUI.EmptyView>, SwiftUI._FlexFrameLayout>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>>>)>>, SwiftUI._PaddingLayout>, SwiftUI._FlexFrameLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.RoundedRectangle, SwiftUI.Color>>>>>)>>, SwiftUI._FlexFrameLayout>)>>, SwiftUI._PaddingLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>, One.CommentMenu>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.CommentAvatar: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Group<SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, One.RemoteImage>>, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.Circle>>, SwiftUI.AccessibilityAttachmentModifier>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.CommentHeader: SwiftUI.View {
    typealias Body = SwiftUI.ViewThatFits<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>, One.Badge?, One.Badge?, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>?)>>, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FixedSizeLayout>)>>, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>, One.Badge?, One.Badge?, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>?)>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FixedSizeLayout>)>>)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.CommentContent: SwiftUI.View {
    typealias Body = SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<CoreGraphics.CGFloat>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>, SwiftUI._FixedSizeLayout>, SwiftUI._FlexFrameLayout>?, One.CommentImagesRow?, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FrameLayout>, SwiftUI.AccessibilityAttachmentModifier>?)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ReplyRow: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(One.CommentAvatar, SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(One.CommentHeader, One.CommentContent, Swift.Optional<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE10labelStyleyQrqd__AA05LabelE0Rd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, One.CompactLabelStyle>>)>>, SwiftUI._FlexFrameLayout>)>>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>, One.CommentMenu>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.CompactLabelStyle: SwiftUI.LabelStyle {
    typealias Body = SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.LabelStyleConfiguration.Icon, SwiftUI.LabelStyleConfiguration.Title)>>

    func makeBody(configuration: SwiftUI.LabelStyleConfiguration) -> Self.Body
}
extension One.CommentMenu: SwiftUI.View {
    typealias Body = SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>?, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>?)>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.Badge: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15dynamicTypeSizeyQrqd__SXRd__AA07DynamiceF0O5BoundRtd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, One.ScaledFont>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._OverlayModifier<SwiftUI._ShapeView<SwiftUI._StrokedShape<SwiftUI.Capsule._Inset>, SwiftUI.Color>>>, SwiftUI._FixedSizeLayout>, Swift.PartialRangeThrough<SwiftUI.DynamicTypeSize>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.CommentImagesRow: SwiftUI.View {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI._AspectRatioLayout>, SwiftUI._FlexFrameLayout>, SwiftUI.HStack<SwiftUI.ForEach<[(offset: Swift.Int, element: One.CommentImage)], Swift.Int, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI._FrameLayout>, SwiftUI._OverlayModifier<SwiftUI.TupleView<(SwiftUI.Color, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>)>?>>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.CommentBlocklist: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.CommentsModel: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.CommentsSheet: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE19presentationDetentsyQrShyAA18PresentationDetentVGF", 0) __<accessor function at 31612>, One.PassThroughAtMedium>, One.DarkSheet>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.CommentsPreview: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE5sheet11isPresented9onDismiss7contentQrAA7BindingVySbG_yycSgqd__yctAaBRd__lF", 0) __<accessor function at 31612, One.CommentsSheet>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.PassThroughAtMedium: SwiftUI.ViewModifier {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.AnyView, SwiftUI._ViewModifier_Content<One.PassThroughAtMedium>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.DarkSheet: SwiftUI.ViewModifier {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI._ViewModifier_Content<One.DarkSheet>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.ColorScheme>>, SwiftUI._PreferenceWritingModifier<SwiftUI.PreferredColorSchemeKey>>, SwiftUI._ViewModifier_Content<One.DarkSheet>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.DetailView: SwiftUI.View {
    typealias Body = accessor function at 31612

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.EpisodeRow: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FlexFrameLayout>, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>?)>>, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>?)>>, SwiftUI._PaddingLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.DiscoverModel.Mode: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.DiscoverModel.Mode: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.DiscoverModel.Mode: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.DiscoverModel: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.DiscoverView: SwiftUI.View {
    typealias Body = accessor function at 44012

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.PerformerRow: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Font?>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FrameLayout>, SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.Circle>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.Circle>>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>>, SwiftUI.Text, SwiftUI.Spacer)>>, SwiftUI._PaddingLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.DownloadCenter: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.DownloadItem: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.DownloadItem: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.DownloadRecord: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.DownloadRecord: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.DownloadRecord: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.DownloadState: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.DownloadState: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.DownloadState: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.DownloadState: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.DownloadState: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.DownloadRecord.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.DownloadRecord.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.DownloadRecord.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.DownloadRecord.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.DownloadRecord.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.DownloadError: Foundation.LocalizedError {
    var errorDescription: Swift.String? {
        get
    }
    var failureReason: Swift.String? {
        get
    }
    var helpAnchor: Swift.String? {
        get
    }
    var recoverySuggestion: Swift.String? {
        get
    }
}
extension One.DownloadError: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.DownloadError: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.DownloadError: Swift.Error {
    var _code: Swift.Int {
        get
    }
    var _domain: Swift.String {
        get
    }
    var _userInfo: Swift.AnyObject? {
        get
    }

    func _getEmbeddedNSError() -> Swift.AnyObject?
}
extension One.DownloadItemRow: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>, SwiftUI.Spacer)>>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>, SwiftUI.Spacer)>>>?, SwiftUI._ConditionalContent<SwiftUI._ConditionalContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>>, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, SwiftUI.Spacer, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.AccessibilityAttachmentModifier>>)>>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>?, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Font?>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.AccessibilityAttachmentModifier>?)>>>, SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.TupleView<(@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.ShareLink<Swift.CollectionOfOne<Foundation.URL>, Swift.Never, Swift.Never, SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.BorderlessButtonStyle>, (@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.BorderlessButtonStyle>)?)>?, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.BorderlessButtonStyle>)>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Font?>>)>>, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.ContentTransition>>, SwiftUI._AnimationModifier<Swift.Int>>, SwiftUI.Spacer, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.Text>, SwiftUI.BorderlessButtonStyle>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.Text>, SwiftUI.BorderlessButtonStyle>)>>, SwiftUI.ProgressView<SwiftUI.EmptyView, SwiftUI.EmptyView>, SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15monospacedDigitQryF", 0) __<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.ContentTransition>>, SwiftUI._AnimationModifier<Swift.Int64>>?, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15monospacedDigitQryF", 0) __<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.ContentTransition>>, SwiftUI._AnimationModifier<Swift.Double>>?, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>?, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15monospacedDigitQryF", 0) __<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.ContentTransition>>, SwiftUI._AnimationModifier<Swift.Double>>?)>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Font?>>)>>>, SwiftUI._ConditionalContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Text, SwiftUI.Spacer, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.Text>, SwiftUI.BorderlessButtonStyle>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.Text>, SwiftUI.BorderlessButtonStyle>)>>, SwiftUI.ProgressView<SwiftUI.EmptyView, SwiftUI.EmptyView>)>>, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>)>>)>>, SwiftUI.HStack<SwiftUI.TupleView<(@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.BorderlessButtonStyle>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.BorderlessButtonStyle>)>>)>>>>)>>, SwiftUI._PaddingLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.DownloadSection: SwiftUI.View {
    typealias Body = SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI._ConditionalContent<One.DownloadItemRow, SwiftUI.ModifiedContent<SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI._EnvironmentKeyTransformModifier<Swift.Bool>>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>)>>, SwiftUI._PaddingLayout>, SwiftUI._FlexFrameLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.RoundedRectangle, SwiftUI.Color>>>)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.EditorialDetail: SwiftUI.View {
    typealias Body = SwiftUI.ScrollViewReader<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE29navigationBarTitleDisplayModeyQrAA010NavigationE4ItemV0fgH0OF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15navigationTitleyQrAA18LocalizedStringKeyVF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ScrollView<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.LazyVStack<SwiftUI._ConditionalContent<SwiftUI._ConditionalContent<SwiftUI.TupleView<(SwiftUI._ConditionalContent<SwiftUI.IDView<SwiftUI._ConditionalContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12onTapGesture5count7performQrSi_yyctF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ZStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FlexFrameLayout>, SwiftUI._FrameLayout>, SwiftUI.ModifiedContent<SwiftUI.LinearGradient, SwiftUI._AllowsHitTestingModifier>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, One.ScaledFont>, SwiftUI._EnvironmentKeyWritingModifier<CoreGraphics.CGFloat>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FixedSizeLayout>, SwiftUI._ShadowEffect>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>>)>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>)>>, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.Rectangle>>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12onTapGesture5count7performQrSi_yyctF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ZStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FlexFrameLayout>, SwiftUI._FrameLayout>, SwiftUI.ModifiedContent<SwiftUI.LinearGradient, SwiftUI._AllowsHitTestingModifier>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, One.ScaledFont>, SwiftUI._EnvironmentKeyWritingModifier<CoreGraphics.CGFloat>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FixedSizeLayout>, SwiftUI._ShadowEffect>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>>)>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>)>>, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.Rectangle>>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>, One.PageAnchor>, SwiftUI.IDView<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, One.ScaledFont>, SwiftUI._EnvironmentKeyWritingModifier<CoreGraphics.CGFloat>>, SwiftUI._FixedSizeLayout>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FixedSizeLayout>>)>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, One.PageAnchor>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.VStack<SwiftUI.TupleView<(Swift.Optional<SwiftUI.Text>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(Swift.Optional<SwiftUI.Text>, Swift.Optional<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.Text)>>>)>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.FavoriteButton, SwiftUI._FrameLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Circle, SwiftUI.Color>>>)>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, Swift.Optional<SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RadioPlayerBar, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.RoundedRectangle, SwiftUI.Color>>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI._ConditionalContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12onTapGesture5count7performQrSi_yyctF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12onTapGesture5count7performQrSi_yyctF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>>>, Swift.Optional<SwiftUI._ConditionalContent<SwiftUI.TupleView<(Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI._ConditionalContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE13textSelectionyQrqd__AA17TextSelectabilityRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, One.ScaledFont>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<CoreGraphics.CGFloat>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FixedSizeLayout>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, One.ScaledFont>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>>, SwiftUI.ModifiedContent<SwiftUI._ShapeView<SwiftUI.Rectangle, SwiftUI.Color>, SwiftUI._FrameLayout>)>>, SwiftUI._FlexFrameLayout>, SwiftUI._PaddingLayout>, SwiftUI.EnabledTextSelectability>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE13textSelectionyQrqd__AA17TextSelectabilityRd__lF", 0) __<SwiftUI.VStack<SwiftUI.ForEach<Swift.Array<(offset: Swift.Int, element: Swift.String)>, Swift.Int, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<CoreGraphics.CGFloat>>, SwiftUI._FixedSizeLayout>>>, SwiftUI.EnabledTextSelectability>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.LazyVStack<SwiftUI.ForEach<Swift.Array<One.BodyRow>, Swift.Int, SwiftUI._ConditionalContent<SwiftUI._ConditionalContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE13textSelectionyQrqd__AA17TextSelectabilityRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<CoreGraphics.CGFloat>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FixedSizeLayout>, SwiftUI._FlexFrameLayout>, SwiftUI.EnabledTextSelectability>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE13textSelectionyQrqd__AA17TextSelectabilityRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._FixedSizeLayout>, SwiftUI._PaddingLayout>, SwiftUI.EnabledTextSelectability>>, SwiftUI._ConditionalContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12onTapGesture5count7performQrSi_yyctF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.NaturalRemoteImage, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12onTapGesture5count7performQrSi_yyctF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.NaturalRemoteImage, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>>>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>)>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI._ConditionalContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE13textSelectionyQrqd__AA17TextSelectabilityRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, One.ScaledFont>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<CoreGraphics.CGFloat>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FixedSizeLayout>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, One.ScaledFont>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>>, SwiftUI.ModifiedContent<SwiftUI._ShapeView<SwiftUI.Rectangle, SwiftUI.Color>, SwiftUI._FrameLayout>)>>, SwiftUI._FlexFrameLayout>, SwiftUI._PaddingLayout>, SwiftUI.EnabledTextSelectability>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE13textSelectionyQrqd__AA17TextSelectabilityRd__lF", 0) __<SwiftUI.VStack<SwiftUI.ForEach<Swift.Array<(offset: Swift.Int, element: Swift.String)>, Swift.Int, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<CoreGraphics.CGFloat>>, SwiftUI._FixedSizeLayout>>>, SwiftUI.EnabledTextSelectability>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>>>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.DownloadSection, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.ForEach<Swift.Array<(offset: Swift.Int, element: One.CollectionEpisode)>, Swift.Int, SwiftUI.TupleView<(@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.EpisodeRow, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>>, SwiftUI.PlainButtonStyle>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.Divider, SwiftUI._PaddingLayout>>)>>>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.RoundedRectangle, SwiftUI.Color>>>)>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.Spacer, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11pickerStyleyQrqd__AA06PickerE0Rd__lF", 0) __<SwiftUI.Picker<SwiftUI.Text, Swift.String, SwiftUI.ForEach<Swift.Array<One.EditorialDetail.PhotoMode>, Swift.String, accessor function at 39380>>, SwiftUI.SegmentedPickerStyle>, SwiftUI._FrameLayout>)>>, SwiftUI._PaddingLayout>, SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.LazyVGrid<SwiftUI.ForEach<Swift.Array<(offset: Swift.Int, element: Swift.String)>, Swift.Int, SwiftUI._ConditionalContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12onTapGesture5count7performQrSi_yyctF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Color, SwiftUI._AspectRatioLayout>, SwiftUI._OverlayModifier<One.RemoteImage>>, SwiftUI._ClipEffect<SwiftUI.Rectangle>>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12onTapGesture5count7performQrSi_yyctF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Color, SwiftUI._AspectRatioLayout>, SwiftUI._OverlayModifier<One.RemoteImage>>, SwiftUI._ClipEffect<SwiftUI.Rectangle>>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>>>, SwiftUI._PaddingLayout>, SwiftUI.ModifiedContent<SwiftUI.LazyVStack<SwiftUI.ForEach<Swift.ArraySlice<(offset: Swift.Int, element: Swift.String)>, Swift.Int, SwiftUI._ConditionalContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12onTapGesture5count7performQrSi_yyctF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.NaturalRemoteImage, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12onTapGesture5count7performQrSi_yyctF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.NaturalRemoteImage, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>>>, SwiftUI._PaddingLayout>>)>>, SwiftUI._PaddingLayout>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.FavoriteButton, SwiftUI._FrameLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Circle, SwiftUI.Color>>>, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._PaddingLayout>, SwiftUI._FlexFrameLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._ContentShapeModifier<SwiftUI.Capsule>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>)>>, SwiftUI._FlexFrameLayout>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.IDView<One.CommentsPreview, Swift.Int>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI.ModifiedContent<SwiftUI.Color, SwiftUI._FrameLayout>)>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ProgressView<SwiftUI.EmptyView, SwiftUI.EmptyView>, SwiftUI._FlexFrameLayout>, SwiftUI._PaddingLayout>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, One.ScaledFont>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.Text>, SwiftUI.BorderedButtonStyle>)>>, SwiftUI._FlexFrameLayout>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>>>, One.ContentTopProbe>, SwiftUI._FlexFrameLayout>, SwiftUI._FlexFrameLayout>, SwiftUI._FrameLayout>, SwiftUI._FlexFrameLayout>>, One.ScrollZoneReader>, SwiftUI._OverlayModifier<Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Spacer, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FrameLayout>, SwiftUI._InsettableBackgroundShapeModifier<SwiftUI.Material, SwiftUI.Circle>>, SwiftUI._OverlayModifier<SwiftUI._ShapeView<SwiftUI._StrokedShape<SwiftUI.Circle._Inset>, SwiftUI.Color>>>, SwiftUI._ShadowEffect>, SwiftUI._ContentShapeModifier<SwiftUI.Circle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>)>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._FlexFrameLayout>, SwiftUI._FlexFrameLayout>, SwiftUI._FrameLayout>, SwiftUI._FlexFrameLayout>, SwiftUI._TraitWritingModifier<SwiftUI.TransitionTraitKey>>>>>, One.GeometryValueReader<Swift.Optional<One.FoldGap>>>, SwiftUI._BackgroundStyleModifier<SwiftUI.Color>>>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.PageAnchor: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.PageAnchor: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.EditorialDetail.PhotoMode: Swift.CaseIterable {
    typealias AllCases = [One.EditorialDetail.PhotoMode]

    static var allCases: Self.AllCases {
        get
    }
}
extension One.EditorialDetail.PhotoMode: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.EditorialDetail.PhotoMode: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.EditorialDetail.PhotoMode: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.EditorialDetail.PhotoMode: Swift.Identifiable {
    typealias ID = Swift.String

    var id: Self.ID {
        get
    }
}
extension One.BodyRow: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.ScrollZoneReader: SwiftUI.ViewModifier {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.AnyView, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI._ViewModifier_Content<One.ScrollZoneReader>, SwiftUI._CoordinateSpaceModifier<Swift.String>>, SwiftUI._PreferenceActionModifier<One.ContentTopKey>>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.ContentTopProbe: SwiftUI.ViewModifier {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI._ViewModifier_Content<One.ContentTopProbe>, SwiftUI._BackgroundModifier<SwiftUI.GeometryReader<SwiftUI.ModifiedContent<SwiftUI.Color, SwiftUI._PreferenceWritingModifier<One.ContentTopKey>>>>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.ScrollZone: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.ScrollZone: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.ContentTopKey: SwiftUI.PreferenceKey {
    typealias Value = CoreGraphics.CGFloat

    static var _includesRemovedValues: Swift.Bool {
        get
    }
    static var _isReadableByHost: Swift.Bool {
        get
    }
    static var defaultValue: Self.Value {
        get
    }

    static func reduce(value: inout Self.Value, nextValue: () -> Self.Value)
    static func _preferenceValuesEqual(_: Self.Value, _: Self.Value) -> Swift.Bool
}
extension One.ExternalPlayer: Swift.CaseIterable {
    typealias AllCases = [One.ExternalPlayer]

    static var allCases: Self.AllCases {
        get
    }
}
extension One.ExternalPlayer: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.ExternalPlayer: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.ExternalPlayer: Swift.Identifiable {
    typealias ID = Swift.String

    var id: Self.ID {
        get
    }
}
extension One.ExternalPlayer: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.Favorite: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.Favorite: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.Favorite: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.Favorite: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.Favorite: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.FavoriteFolder: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.FavoriteFolder: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.FavoriteFolder: Swift.Identifiable {
    typealias ID = Swift.String

    var id: Self.ID {
        get
    }
}
extension One.FavoriteFolder: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.FavoriteFolder: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.FavoritesStore: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.FavoriteFolder.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.FavoriteFolder.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.FavoriteFolder.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.FavoriteFolder.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.FavoriteFolder.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.Favorite.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.Favorite.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.Favorite.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.Favorite.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.Favorite.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.FavoriteScope: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.FavoriteScope: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.FavoritesView.Filter: Swift.Identifiable {
    typealias ID = Swift.String

    var id: Self.ID {
        get
    }
}
extension One.FavoritesView.Filter: Swift.CaseIterable {
    typealias AllCases = [One.FavoritesView.Filter]

    static var allCases: Self.AllCases {
        get
    }
}
extension One.FavoritesView.Filter: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.FavoritesView.Filter: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.FavoritesView.Filter: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.FavoritesView.Source: Swift.Identifiable {
    typealias ID = Swift.String

    var id: Self.ID {
        get
    }
}
extension One.FavoritesView.Source: Swift.CaseIterable {
    typealias AllCases = [One.FavoritesView.Source]

    static var allCases: Self.AllCases {
        get
    }
}
extension One.FavoritesView.Source: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.FavoritesView.Source: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.FavoritesView.Source: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.FavoritesView: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE5alert_11isPresented7actionsQrAA18LocalizedStringKeyV_AA7BindingVySbGqd__yXEtAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE5alert_11isPresented7actions7messageQrAA18LocalizedStringKeyV_AA7BindingVySbGqd__yXEqd_0_yXEtAaBRd__AaBRd_0_r0_lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE18confirmationDialog_11isPresented15titleVisibility7actionsQrAA18LocalizedStringKeyV_AA7BindingVySbGAA0I0Oqd__yXEtAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE18confirmationDialog_11isPresented15titleVisibility7actionsQrAA18LocalizedStringKeyV_AA7BindingVySbGAA0I0Oqd__yXEtAaBRd__lF", 0) __<SwiftUI.SubscriptionView<(extension in Foundation):__C.NSNotificationCenter.Publisher, SwiftUI.NavigationStack<SwiftUI.NavigationPath, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE21navigationDestination3for11destinationQrqd__m_qd_0_qd__ctSHRd__AaBRd_0_r0_lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7toolbar7contentQrqd__yXE_tAA14ToolbarContentRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15navigationTitleyQrAA18LocalizedStringKeyVF", 0) __<SwiftUI.Group<SwiftUI._ConditionalContent<SwiftUI._ConditionalContent<One.AccountFavoritesView<Swift.Optional<SwiftUI.Section<SwiftUI.EmptyView, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11pickerStyleyQrqd__AA06PickerE0Rd__lF", 0) __<SwiftUI.Picker<SwiftUI.Text, One.FavoritesView.Source, SwiftUI.ForEach<Swift.Array<One.FavoritesView.Source>, Swift.String, accessor function at 39380>>, SwiftUI.SegmentedPickerStyle>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowInsetsTraitKey>>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>, SwiftUI.EmptyView>>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE9listStyleyQrqd__AA04ListE0Rd__lF", 0) __<SwiftUI.List<Swift.Never, SwiftUI.TupleView<(Swift.Optional<SwiftUI.Section<SwiftUI.EmptyView, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11pickerStyleyQrqd__AA06PickerE0Rd__lF", 0) __<SwiftUI.Picker<SwiftUI.Text, One.FavoritesView.Source, SwiftUI.ForEach<Swift.Array<One.FavoritesView.Source>, Swift.String, accessor function at 39380>>, SwiftUI.SegmentedPickerStyle>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowInsetsTraitKey>>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>, SwiftUI.EmptyView>>, SwiftUI.Section<SwiftUI.EmptyView, SwiftUI.NavigationLink<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FrameLayout>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Text, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, Swift.Never>, SwiftUI.EmptyView>, SwiftUI.ModifiedContent<One.EmptyHint, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>)>>, SwiftUI.InsetGroupedListStyle>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE9listStyleyQrqd__AA04ListE0Rd__lF", 0) __<SwiftUI.List<Swift.Never, SwiftUI.TupleView<(Swift.Optional<SwiftUI.Section<SwiftUI.EmptyView, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11pickerStyleyQrqd__AA06PickerE0Rd__lF", 0) __<SwiftUI.Picker<SwiftUI.Text, One.FavoritesView.Source, SwiftUI.ForEach<Swift.Array<One.FavoritesView.Source>, Swift.String, accessor function at 39380>>, SwiftUI.SegmentedPickerStyle>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowInsetsTraitKey>>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>, SwiftUI.EmptyView>>, SwiftUI.Section<SwiftUI.EmptyView, SwiftUI.NavigationLink<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FrameLayout>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Text, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, Swift.Never>, SwiftUI.EmptyView>, SwiftUI.Section<SwiftUI.EmptyView, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ScrollView<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.ForEach<Swift.Array<One.FavoriteFolder>, Swift.String, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI._StrokedShape<SwiftUI.Capsule._Inset>, SwiftUI.Color>>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>)>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowInsetsTraitKey>>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>, SwiftUI.Text>, SwiftUI.Section<SwiftUI.EmptyView, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11pickerStyleyQrqd__AA06PickerE0Rd__lF", 0) __<SwiftUI.Picker<SwiftUI.Text, One.FavoritesView.Filter, SwiftUI.ForEach<Swift.Array<One.FavoritesView.Filter>, Swift.String, accessor function at 39380>>, SwiftUI.SegmentedPickerStyle>, SwiftUI.EmptyView>, SwiftUI.Section<SwiftUI.EmptyView, SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.ForEach<Swift.Array<One.Favorite>, Swift.Int, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12swipeActions4edge15allowsFullSwipe7contentQrAA14HorizontalEdgeO_Sbqd__yXEtAaBRd__lF", 0) __<SwiftUI.NavigationLink<One.ArticleRow, Swift.Never>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>>, SwiftUI.TupleView<(SwiftUI.Menu<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>, SwiftUI.TupleView<(SwiftUI.Button<One.FolderMenuLabel>, SwiftUI.ForEach<Swift.Array<One.FavoriteFolder>, Swift.String, SwiftUI.Button<One.FolderMenuLabel>>)>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>>, SwiftUI.EmptyView>)>>, SwiftUI.InsetGroupedListStyle>>>>, Swift.Optional<SwiftUI.ToolbarItem<(), SwiftUI.Button<SwiftUI.Text>>>>, One.Route, One.RouteDestination>>>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Text>, SwiftUI.Button<SwiftUI.Text>)>>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Text>, SwiftUI.Button<SwiftUI.Text>)>>, SwiftUI.TupleView<(SwiftUI.TextField<SwiftUI.Text>, SwiftUI.Button<SwiftUI.Text>, SwiftUI.Button<SwiftUI.Text>)>, SwiftUI.Text>, SwiftUI.TupleView<(SwiftUI.TextField<SwiftUI.Text>, SwiftUI.Button<SwiftUI.Text>, SwiftUI.Button<SwiftUI.Text>)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.FolderMenuLabel: SwiftUI.View {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>, SwiftUI.Text>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.FavoriteButton: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE5alert_11isPresented7actionsQrAA18LocalizedStringKeyV_AA7BindingVySbGqd__yXEtAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE9menuStyleyQrqd__AA04MenuE0Rd__lF", 0) __<SwiftUI.Group<SwiftUI._ConditionalContent<SwiftUI.Menu<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._ScaleEffect>, SwiftUI._AnimationModifier<Swift.Bool>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.TupleView<(SwiftUI.Button<One.FolderMenuLabel>, SwiftUI.ForEach<Swift.Array<One.FavoriteFolder>, Swift.String, SwiftUI.Button<One.FolderMenuLabel>>, SwiftUI.Divider, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, Swift.Optional<SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>>)>>, SwiftUI.Menu<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._ScaleEffect>, SwiftUI._AnimationModifier<Swift.Bool>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.TupleView<(SwiftUI.Button<One.FolderMenuLabel>, SwiftUI.ForEach<Swift.Array<One.FavoriteFolder>, Swift.String, SwiftUI.Button<One.FolderMenuLabel>>, SwiftUI.Divider, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, Swift.Optional<SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>>)>>>>, SwiftUI.BorderlessButtonMenuStyle>, SwiftUI.TupleView<(SwiftUI.TextField<SwiftUI.Text>, SwiftUI.Button<SwiftUI.Text>, SwiftUI.Button<SwiftUI.Text>)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.FollowListView: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE29navigationBarTitleDisplayModeyQrAA010NavigationE4ItemV0fgH0OF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15navigationTitleyQrAA18LocalizedStringKeyVF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE9listStyleyQrqd__AA04ListE0Rd__lF", 0) __<SwiftUI.List<Swift.Never, SwiftUI.TupleView<(Swift.Optional<SwiftUI.Section<SwiftUI.EmptyView, One.SearchField, SwiftUI.EmptyView>>, SwiftUI.Section<SwiftUI.EmptyView, SwiftUI._ConditionalContent<SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<One.EmptyHint, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>>, SwiftUI.ForEach<Swift.Array<One.FollowedActor>, Swift.Int, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE12swipeActions4edge15allowsFullSwipe7contentQrAA14HorizontalEdgeO_Sbqd__yXEtAaBRd__lF", 0) __<SwiftUI.NavigationLink<One.PerformerRow, Swift.Never>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>>>>, Swift.Optional<SwiftUI.Text>>)>>, SwiftUI.InsetGroupedListStyle>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.FollowedActor: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.FollowedActor: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.FollowedActor: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.FollowedActor: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.FollowedActor: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.FollowStore: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.FollowedActor.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.FollowedActor.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.FollowedActor.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.FollowedActor.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.FollowedActor.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.GateStore: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.GateView: SwiftUI.View {
    typealias Body = accessor function at 31612

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.HLSError: Foundation.LocalizedError {
    var errorDescription: Swift.String? {
        get
    }
    var failureReason: Swift.String? {
        get
    }
    var helpAnchor: Swift.String? {
        get
    }
    var recoverySuggestion: Swift.String? {
        get
    }
}
extension One.HLSError: Swift.Error {
    var _code: Swift.Int {
        get
    }
    var _domain: Swift.String {
        get
    }
    var _userInfo: Swift.AnyObject? {
        get
    }

    func _getEmbeddedNSError() -> Swift.AnyObject?
}
extension One.HomeModel: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.HomeView: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE5sheet11isPresented9onDismiss7contentQrAA7BindingVySbG_yycSgqd__yctAaBRd__lF", 0) __<SwiftUI.ModifiedContent<accessor function at 31612, SwiftUI._ValueActionModifier<Swift.String>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE19presentationDetentsyQrShyAA18PresentationDetentVGF", 0) __<SwiftUI.NavigationStack<SwiftUI.NavigationPath, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7toolbar7contentQrqd__yXE_tAA14ToolbarContentRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE29navigationBarTitleDisplayModeyQrAA010NavigationE4ItemV0fgH0OF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15navigationTitleyQrAA18LocalizedStringKeyVF", 0) __<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15datePickerStyleyQrqd__AA04DateeF0Rd__lF", 0) __<SwiftUI.DatePicker<SwiftUI.Text>, SwiftUI.GraphicalDatePickerStyle>, SwiftUI._PaddingLayout>>>, SwiftUI.TupleToolbarContent<(SwiftUI.ToolbarItem<(), SwiftUI.Button<SwiftUI.Text>>, SwiftUI.ToolbarItem<(), SwiftUI.Button<SwiftUI.Text>>)>>>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.HomeDayPage: SwiftUI.View {
    typealias Body = accessor function at 31612

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.DayHeader: SwiftUI.View {
    typealias Body = SwiftUI.ViewThatFits<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, One.ScaledFont>, SwiftUI.Text, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.AccessibilityAttachmentModifier>)>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FixedSizeLayout>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FixedSizeLayout>?)>>, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, One.ScaledFont>, SwiftUI.Text, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.AccessibilityAttachmentModifier>)>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FixedSizeLayout>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FixedSizeLayout>?)>>)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.DailyCardView: SwiftUI.View {
    typealias Body = SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.NavigationLink<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Group<SwiftUI._ConditionalContent<One.FoldSplit<SwiftUI._ConditionalContent<One.HeroImage, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<One.HeroImage, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>, SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FixedSizeLayout>>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<CoreGraphics.CGFloat>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FixedSizeLayout>, SwiftUI._FlexFrameLayout>>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FixedSizeLayout>>)>>, SwiftUI._PaddingLayout>>, SwiftUI.VStack<SwiftUI.TupleView<(Swift.Optional<SwiftUI._ConditionalContent<One.HeroImage, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<One.HeroImage, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>>, SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FixedSizeLayout>>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<CoreGraphics.CGFloat>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FixedSizeLayout>, SwiftUI._FlexFrameLayout>>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._FixedSizeLayout>>)>>, SwiftUI._PaddingLayout>)>>>>, SwiftUI._FlexFrameLayout>, SwiftUI._BackgroundStyleModifier<SwiftUI.Color>>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, Swift.Never>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE5sheet11isPresented9onDismiss7contentQrAA7BindingVySbG_yycSgqd__yctAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ViewThatFits<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE20accessibilityElement8childrenQrAA26AccessibilityChildBehaviorV_tF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Text)>>, SwiftUI._FixedSizeLayout>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.AnyShapeStyle>>>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Spacer, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE20accessibilityElement8childrenQrAA26AccessibilityChildBehaviorV_tF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Text)>>, SwiftUI._FixedSizeLayout>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.AnyShapeStyle>>>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE20accessibilityElement8childrenQrAA26AccessibilityChildBehaviorV_tF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Text)>>, SwiftUI._FixedSizeLayout>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.AnyShapeStyle>>>, SwiftUI.AccessibilityAttachmentModifier>)>>, SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE20accessibilityElement8childrenQrAA26AccessibilityChildBehaviorV_tF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Text)>>, SwiftUI._FixedSizeLayout>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.AnyShapeStyle>>>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE20accessibilityElement8childrenQrAA26AccessibilityChildBehaviorV_tF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Text)>>, SwiftUI._FixedSizeLayout>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.AnyShapeStyle>>>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE20accessibilityElement8childrenQrAA26AccessibilityChildBehaviorV_tF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Text)>>, SwiftUI._FixedSizeLayout>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.AnyShapeStyle>>>, SwiftUI.AccessibilityAttachmentModifier>)>>, SwiftUI._FlexFrameLayout>)>>, SwiftUI._PaddingLayout>, One.CommentsSheet>, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE20accessibilityElement8childrenQrAA26AccessibilityChildBehaviorV_tF", 0) __<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.ModifiedContent<SwiftUI.Text, One.ScaledFont>)>>>, SwiftUI.AccessibilityAttachmentModifier>?)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.HeroImage: SwiftUI.View {
    typealias Body = accessor function at 44012

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.CappedAspectLayout: SwiftUI.Animatable {
    typealias AnimatableData = SwiftUI.EmptyAnimatableData

    var animatableData: Self.AnimatableData {
        get
        set
    }

    static func _makeAnimatable(value: inout SwiftUI._GraphValue<Self>, inputs: SwiftUI._GraphInputs)
}
extension One.CappedAspectLayout: SwiftUI.Layout {
    typealias Cache = ()

    func makeCache(subviews: SwiftUI.LayoutSubviews) -> Self.Cache
    func updateCache(_: inout Self.Cache, subviews: SwiftUI.LayoutSubviews)
    func spacing(subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> SwiftUI.ViewSpacing
    func sizeThatFits(proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> __C.CGSize
    func placeSubviews(in: __C.CGRect, proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache)
    func explicitAlignment(of: SwiftUI.HorizontalAlignment, in: __C.CGRect, proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> CoreGraphics.CGFloat?
    func explicitAlignment(of: SwiftUI.VerticalAlignment, in: __C.CGRect, proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> CoreGraphics.CGFloat?

    static var layoutProperties: SwiftUI.LayoutProperties {
        get
    }

    static func _makeLayoutView(root: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewOutputs
}
extension One.ViewerItem: Swift.Identifiable {
    typealias ID = Foundation.UUID

    var id: Self.ID {
        get
    }
}
extension One.ViewerCenter: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.ImageLoader: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.DownloadFailure: Foundation.LocalizedError {
    var errorDescription: Swift.String? {
        get
    }
    var failureReason: Swift.String? {
        get
    }
    var helpAnchor: Swift.String? {
        get
    }
    var recoverySuggestion: Swift.String? {
        get
    }
}
extension One.DownloadFailure: Swift.Error {
    var _code: Swift.Int {
        get
    }
    var _domain: Swift.String {
        get
    }
    var _userInfo: Swift.AnyObject? {
        get
    }

    func _getEmbeddedNSError() -> Swift.AnyObject?
}
extension One.LineMenu: SwiftUI.View {
    typealias Body = SwiftUI.Menu<A, SwiftUI.TupleView<(SwiftUI.Button<One.FolderMenuLabel>, SwiftUI.ForEach<[One.PlayLine], Swift.String, SwiftUI.Button<One.FolderMenuLabel>>, SwiftUI.Divider, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>?, SwiftUI.ModifiedContent<SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI._EnvironmentKeyTransformModifier<Swift.Bool>>)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.PlayLine: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.PlayLine: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.PlayLine: Swift.Identifiable {
    typealias ID = Swift.String

    var id: Self.ID {
        get
    }
}
extension One.SearchField: SwiftUI.View {
    typealias Body = SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.AccessibilityAttachmentModifier>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE21disableAutocorrectionyQrSbSgF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE8onSubmit2of_QrAA0E8TriggersV_yyctF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11submitLabelyQrAA06SubmitE0VF", 0) __<SwiftUI.TextField<SwiftUI.Text>>>>, (@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.Text>, SwiftUI.BorderlessButtonStyle>)?, (@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.AccessibilityAttachmentModifier>>, SwiftUI.BorderlessButtonStyle>)?)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.MonthPicker: SwiftUI.View {
    typealias Body = SwiftUI.Picker<SwiftUI.Text, Swift.String, SwiftUI.ForEach<[(label: Swift.String, value: Swift.String)], Swift.String, accessor function at 39380>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.SearchHistoryChips: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.Spacer, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Button<SwiftUI.Text>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI.BorderlessButtonStyle>)>>, SwiftUI.ScrollView<SwiftUI.HStack<SwiftUI.ForEach<[Swift.String], Swift.String, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>>>>>)>>, SwiftUI._PaddingLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.FilterPanel: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<A>, SwiftUI._PaddingLayout>, SwiftUI._FlexFrameLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.RoundedRectangle, SwiftUI.Color>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ArticleGrid: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.LazyVGrid<SwiftUI.ForEach<[One.Article], Swift.Int, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.NavigationLink<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.ArticleListItem, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>, Swift.Never>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>>>, SwiftUI._GeometryActionModifier<CoreGraphics.CGFloat>>, One.GeometryValueReader<One.FoldGap?>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.LayoutToggleButton: SwiftUI.View {
    typealias Body = SwiftUI.Button<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE10labelStyleyQrqd__AA05LabelE0Rd__lF", 0) __<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>, SwiftUI.IconOnlyLabelStyle>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ArticleListItem: SwiftUI.View {
    typealias Body = SwiftUI._ConditionalContent<One.ArticleCard, One.ArticleRow>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ListPage: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.ListPage: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.ListLayout: Swift.Identifiable {
    typealias ID = Swift.String

    var id: Self.ID {
        get
    }
}
extension One.ListLayout: Swift.CaseIterable {
    typealias AllCases = [One.ListLayout]

    static var allCases: Self.AllCases {
        get
    }
}
extension One.ListLayout: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.ListLayout: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.ListLayout: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.LocalPlayerView: SwiftUI.View {
    typealias Body = accessor function at 31612

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.StorageBar: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.GeometryReader<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ForEach<Swift.Range<Swift.Int>, Swift.Int, SwiftUI.ModifiedContent<SwiftUI._ShapeView<SwiftUI.Rectangle, SwiftUI.Color>, SwiftUI._FrameLayout>?>, SwiftUI.Spacer)>>>, SwiftUI._FrameLayout>, SwiftUI._BackgroundStyleModifier<SwiftUI.Color>>, SwiftUI._ClipEffect<SwiftUI.Capsule>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.SectionLabel: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.GlassDivider: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI._ShapeView<SwiftUI.Rectangle, SwiftUI.Color>, SwiftUI._FrameLayout>, SwiftUI._PaddingLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.MeBackground: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ZStack<SwiftUI.TupleView<(SwiftUI.LinearGradient, SwiftUI.RadialGradient, SwiftUI.RadialGradient)>>, SwiftUI._SafeAreaRegionsIgnoringLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.GlassCard: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<A, SwiftUI._PaddingLayout>, SwiftUI._FlexFrameLayout>, SwiftUI._BackgroundModifier<One.GlassShape>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.GlassTile: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, One.ScaledFont>, SwiftUI._FrameLayout>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI._OverlayModifier<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._OffsetEffect>?>>, SwiftUI.Text)>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FlexFrameLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<One.GlassShape>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.MeListPage: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE18toolbarColorScheme_3forQrAA0eF0OSg_AA16ToolbarPlacementVdtF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE29navigationBarTitleDisplayModeyQrAA010NavigationE4ItemV0fgH0OF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15navigationTitleyQrqd__SyRd__lF", 0) __<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE23scrollContentBackgroundyQrAA10VisibilityOF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE9listStyleyQrqd__AA04ListE0Rd__lF", 0) __<SwiftUI.List<Swift.Never, A>, SwiftUI.InsetGroupedListStyle>>, SwiftUI._BackgroundModifier<One.MeBackground>>, Swift.String>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.GlassRow: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, One.ScaledFont>, SwiftUI._FrameLayout>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.Text, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>?, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Font?>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.AccessibilityAttachmentModifier>)>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.GlassShape: SwiftUI.View {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI._ShapeView<SwiftUI.RoundedRectangle, SwiftUI.Color>, SwiftUI._OverlayModifier<SwiftUI._ShapeView<SwiftUI._StrokedShape<SwiftUI.RoundedRectangle._Inset>, SwiftUI.Color>>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI._ShapeView<SwiftUI.RoundedRectangle, SwiftUI.Material>, SwiftUI._OverlayModifier<SwiftUI._ShapeView<SwiftUI.RoundedRectangle, SwiftUI.Color>>>, SwiftUI._OverlayModifier<SwiftUI._ShapeView<SwiftUI._StrokedShape<SwiftUI.RoundedRectangle._Inset>, SwiftUI.Color>>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.MeModel: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.MeView: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<accessor function at 31612, SwiftUI._ValueActionModifier<[One.DownloadItem]>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ResolvedMedia: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.MemberAccountService: Swift.Actor {
    var unownedExecutor: Swift.UnownedSerialExecutor {
        get
    }
}
extension One.MiniRadioInset: SwiftUI.ViewModifier {
    typealias Body = SwiftUI.SubscriptionView<Combine.AnyPublisher<Swift.Bool, Swift.Never>, SwiftUI.ModifiedContent<SwiftUI._ViewModifier_Content<One.MiniRadioInset>, SwiftUI._InsetViewModifier<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.MiniRadioBar, SwiftUI._FrameLayout>, One.FloatingBarBackground>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._TraitWritingModifier<SwiftUI.TransitionTraitKey>>?>>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.MiniRadioBar: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, SwiftUI.AccessibilityAttachmentModifier>?, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE20accessibilityElement8childrenQrAA26AccessibilityChildBehaviorV_tF", 0) __<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>>)>>, SwiftUI._FlexFrameLayout>>, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>?)>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.FloatingBarBackground: SwiftUI.ViewModifier {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.AnyView, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI._ViewModifier_Content<One.FloatingBarBackground>, SwiftUI._InsettableBackgroundShapeModifier<SwiftUI.Material, SwiftUI.RoundedRectangle>>, SwiftUI._ShadowEffect>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.Article: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.Article: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.Article: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.Article: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.Article: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.Performer: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.Performer: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.Performer: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.Performer: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.Performer: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.ContentSort: Swift.Identifiable {
    typealias ID = Swift.String

    var id: Self.ID {
        get
    }
}
extension One.ContentSort: Swift.CaseIterable {
    typealias AllCases = [One.ContentSort]

    static var allCases: Self.AllCases {
        get
    }
}
extension One.ContentSort: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.ContentSort: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.ContentSort: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.ActorNav: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.ActorNav: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.ActorNav: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.DailyCard: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.DailyCard: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.DailyCard: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.MemberAccount: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.MemberAccount: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.MemberAccount: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.DemandTag: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.DemandTag: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.DemandTag: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.MemberAccount.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.MemberAccount.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.MemberAccount.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.MemberAccount.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.MemberAccount.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.Performer.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.Performer.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.Performer.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.Performer.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.Performer.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.Article.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.Article.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.Article.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.Article.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.Article.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.Route: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.Route: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.OfficialSiteScanner: Swift.Actor {
    var unownedExecutor: Swift.UnownedSerialExecutor {
        get
    }
}
extension One.DiscoveryTab: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.DiscoveryTab: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.DiscoveryTab: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.OneApp: SwiftUI.App {
    typealias Body = SwiftUI.WindowGroup<One.RootView>

    init()

    var body: Self.Body {
        get
    }
}
extension One.AccountInfo: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.AccountInfo: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.AccountInfo: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.OneSession: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.OneSession: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.OneUser: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.OneUser: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.OneUser: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.OneSession.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.OneSession.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.OneSession.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.OneSession.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.OneSession.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.AccountInfo.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.AccountInfo.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.AccountInfo.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.AccountInfo.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.AccountInfo.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.OneError: Foundation.LocalizedError {
    var errorDescription: Swift.String? {
        get
    }
    var failureReason: Swift.String? {
        get
    }
    var helpAnchor: Swift.String? {
        get
    }
    var recoverySuggestion: Swift.String? {
        get
    }
}
extension One.OneError: Swift.Error {
    var _code: Swift.Int {
        get
    }
    var _domain: Swift.String {
        get
    }
    var _userInfo: Swift.AnyObject? {
        get
    }

    func _getEmbeddedNSError() -> Swift.AnyObject?
}
extension One.OneUser.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.OneUser.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.OneUser.CodingKeys: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.OneUser.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.OneUser.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.OneUser.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.PhotoViewer: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE9statusBar6hiddenQrSb_tF", 0) __<SwiftUI.ZStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Color, SwiftUI._SafeAreaRegionsIgnoringLayout>, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE03tabC5StyleyQrqd__AA03TabcE0Rd__lF", 0) __<SwiftUI.TabView<Swift.Int, SwiftUI.ForEach<Swift.Array<(offset: Swift.Int, element: Swift.String)>, Swift.Int, accessor function at 39380>>, SwiftUI.PageTabViewStyle>, SwiftUI._SafeAreaRegionsIgnoringLayout>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, One.ScaledFont>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>, SwiftUI.AccessibilityAttachmentModifier>>, SwiftUI.Spacer, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>>, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.Color, SwiftUI._FrameLayout>)>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>>, SwiftUI._ConditionalContent<SwiftUI.AnyView, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI._EnvironmentKeyTransformModifier<Swift.Bool>>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI._EnvironmentKeyTransformModifier<Swift.Bool>>>)>>, SwiftUI.BorderedButtonStyle>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Color>>>>)>>, SwiftUI._PaddingLayout>)>>, One.OcclusionAvoider>, SwiftUI._OpacityEffect>, SwiftUI._AnimationModifier<Swift.Bool>>)>>>, SwiftUI._PreferenceWritingModifier<SwiftUI.PreferredColorSchemeKey>>, SwiftUI._ValueActionModifier<Swift.Int>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ZoomableImage: SwiftUI.View {
    typealias Body = accessor function at 44012

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ZoomingImageView: SwiftUI.View {
    typealias Body = Swift.Never

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ZoomingImageView: SwiftUI.UIViewRepresentable {
    typealias UIViewType = One.ZoomingScrollView
    typealias Coordinator = ()

    func makeUIView(context: SwiftUI.UIViewRepresentableContext<Self>) -> Self.UIViewType
    func updateUIView(_: Self.UIViewType, context: SwiftUI.UIViewRepresentableContext<Self>)
    func makeCoordinator() -> Self.Coordinator
    func _identifiedViewTree(in: Self.UIViewType) -> SwiftUI._IdentifiedViewTree
    func sizeThatFits(_: SwiftUI.ProposedViewSize, uiView: Self.UIViewType, context: SwiftUI.UIViewRepresentableContext<Self>) -> __C.CGSize?
    func _overrideSizeThatFits(_: inout __C.CGSize, in: SwiftUI._ProposedSize, uiView: Self.UIViewType)
    func _overrideLayoutTraits(_: inout SwiftUI._LayoutTraits, for: Self.UIViewType)

    static func dismantleUIView(_: Self.UIViewType, coordinator: Self.Coordinator)
    static func _modifyBridgedViewInputs(_: inout SwiftUI._ViewInputs)
    static func _layoutOptions(_: Self.UIViewType) -> SwiftUI._PlatformViewRepresentableLayoutOptions
}
extension One.PlayLines: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.PrivacyShield.Mode: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.PrivacyShield.Mode: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.ProgressStore.Entry: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.ProgressStore.Entry: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.ProgressStore.Entry.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.ProgressStore.Entry.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.ProgressStore.Entry.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.ProgressStore.Entry.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.ProgressStore.Entry.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}
extension One.RadioPlayer.Status: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.RadioPlayer.Status: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.RadioPlayer: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.RadioPlayerBar: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI._ConditionalContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11contextMenu9menuItemsQrqd__yXE_tAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._FrameLayout>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, SwiftUI.Button<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>?, SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>?, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FixedSizeLayout>?)>>, SwiftUI._FlexFrameLayout>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, One.ScaledFont>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>, SwiftUI.AccessibilityAttachmentModifier>>, SwiftUI.BorderlessButtonStyle>)>>, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.Slider<SwiftUI.EmptyView, SwiftUI.EmptyView>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.ContentTransition>>, SwiftUI._AnimationModifier<Swift.Int>>, SwiftUI.Spacer, SwiftUI.Text)>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Font?>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>?)>>, SwiftUI._PaddingLayout>, SwiftUI._AppearanceActionModifier>, SwiftUI._AppearanceActionModifier>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.RemoteConfigService: Swift.Actor {
    var unownedExecutor: Swift.UnownedSerialExecutor {
        get
    }
}
extension One.RemoteImage: SwiftUI.View {
    typealias Body = accessor function at 44012

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.NaturalRemoteImage: SwiftUI.View {
    typealias Body = accessor function at 44012

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.RootView: SwiftUI.View {
    typealias Body = accessor function at 31612

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.MainTabView: SwiftUI.View {
    typealias Body = SwiftUI.SubscriptionView<Combine.AnyPublisher<Swift.Bool, Swift.Never>, SwiftUI.Group<SwiftUI._ConditionalContent<SwiftUI.AnyView, SwiftUI.TabView<Swift.Int, SwiftUI.TupleView<(@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7tabItemyQrqd__yXEAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.HomeView, One.MiniRadioInset>, One.TabBarBackgroundBeforeGlass>, SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7tabItemyQrqd__yXEAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.DiscoverView, One.MiniRadioInset>, One.TabBarBackgroundBeforeGlass>, SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7tabItemyQrqd__yXEAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.VodView, One.MiniRadioInset>, One.TabBarBackgroundBeforeGlass>, SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7tabItemyQrqd__yXEAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.FavoritesView, One.MiniRadioInset>, One.TabBarBackgroundBeforeGlass>, SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7tabItemyQrqd__yXEAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.MeView, One.MiniRadioInset>, One.TabBarBackgroundBeforeGlass>, SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>>)>>>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.TabBarBackgroundBeforeGlass: SwiftUI.ViewModifier {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI.AnyView, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE17toolbarBackground_3forQrAA10VisibilityO_AA16ToolbarPlacementVdtF", 0) __<SwiftUI._ViewModifier_Content<One.TabBarBackgroundBeforeGlass>>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.GlassTabBar: SwiftUI.ViewModifier {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI._ConditionalContent<SwiftUI.AnyView, SwiftUI.AnyView>, SwiftUI._ViewModifier_Content<One.GlassTabBar>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.RadioAccessory: SwiftUI.View {
    typealias Body = One.MiniRadioBar

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.RouteDestination: SwiftUI.View {
    typealias Body = SwiftUI._ConditionalContent<SwiftUI._ConditionalContent<SwiftUI._ConditionalContent<One.DetailView, One.SeriesView>, SwiftUI._ConditionalContent<One.ActorView, One.SearchView>>, One.FollowListView>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.ScaledFont: SwiftUI.ViewModifier {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI._ViewModifier_Content<One.ScaledFont>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Font?>>

    func body(content: SwiftUI._ViewModifier_Content<Self>) -> Self.Body

    static func _makeView(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(modifier: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs, body: @escaping (SwiftUI._Graph, SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs, body: (_: SwiftUI._ViewListCountInputs) -> Swift.Int?) -> Swift.Int?
}
extension One.SearchHistoryStore: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.SearchDateFilter: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.SearchModel: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.SearchEntryButton: SwiftUI.View {
    typealias Body = SwiftUI.NavigationLink<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE10labelStyleyQrqd__AA05LabelE0Rd__lF", 0) __<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>, SwiftUI.IconOnlyLabelStyle>, Swift.Never>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.SearchView: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE18confirmationDialog_11isPresented15titleVisibility7actionsQrAA18LocalizedStringKeyV_AA7BindingVySbGAA0I0Oqd__yXEtAaBRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE5sheet11isPresented9onDismiss7contentQrAA7BindingVySbG_yycSgqd__yctAaBRd__lF", 0) __<SwiftUI.ModifiedContent<accessor function at 44012, SwiftUI._ValueActionModifier<Swift.String>>, One.SearchFilterSheet>, SwiftUI.TupleView<(SwiftUI.Button<SwiftUI.Text>, SwiftUI.Button<SwiftUI.Text>)>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.SearchScope: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.SearchScope: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.SearchScope: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.SearchGroupHeader: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI._ConditionalContent<SwiftUI.VStack<SwiftUI.TupleView<(One.ArticleThumb, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>, SwiftUI._ConditionalContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._FixedSizeLayout>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>>)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._FixedSizeLayout>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>>)>>>)>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._RotationEffect>, SwiftUI._PaddingLayout>, SwiftUI.AccessibilityAttachmentModifier>)>>, SwiftUI.HStack<SwiftUI.TupleView<(One.ArticleThumb, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.TextAlignment>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>, SwiftUI._ConditionalContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._FixedSizeLayout>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>>)>>, SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._FixedSizeLayout>, Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<Swift.Int>>>>)>>>)>>, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._RotationEffect>, SwiftUI._PaddingLayout>, SwiftUI.AccessibilityAttachmentModifier>)>>>, SwiftUI._PaddingLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.SearchEpisodeRow: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>?, One.ArticleMeta)>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.SearchGroup: Swift.Identifiable {
    typealias ID = Swift.Int

    var id: Self.ID {
        get
    }
}
extension One.SearchFilterSheet: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE19presentationDetentsyQrShyAA18PresentationDetentVGF", 0) __<SwiftUI.NavigationStack<SwiftUI.NavigationPath, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7toolbar7contentQrqd__yXE_tAA14ToolbarContentRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE29navigationBarTitleDisplayModeyQrAA010NavigationE4ItemV0fgH0OF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15navigationTitleyQrAA18LocalizedStringKeyVF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE9listStyleyQrqd__AA04ListE0Rd__lF", 0) __<SwiftUI.List<Swift.Never, SwiftUI.TupleView<(SwiftUI.Section<SwiftUI.Text, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11pickerStyleyQrqd__AA06PickerE0Rd__lF", 0) __<SwiftUI.Picker<SwiftUI.Text, One.ContentSort, SwiftUI.ForEach<Swift.Array<One.ContentSort>, Swift.String, accessor function at 39380>>, SwiftUI.SegmentedPickerStyle>, SwiftUI.EmptyView>, SwiftUI.Section<SwiftUI.Text, SwiftUI.TupleView<(SwiftUI.Picker<SwiftUI.Text, Swift.Optional<Swift.Int>, SwiftUI.TupleView<(accessor function at 39380, SwiftUI.ForEach<Swift.Array<Swift.Int>, Swift.Int, accessor function at 39380>)>>, Swift.Optional<SwiftUI.Picker<SwiftUI.Text, Swift.Optional<Swift.Int>, SwiftUI.TupleView<(accessor function at 39380, SwiftUI.ForEach<Swift.ClosedRange<Swift.Int>, Swift.Int, accessor function at 39380>)>>>)>, SwiftUI.Text>)>>, SwiftUI.InsetGroupedListStyle>>>, SwiftUI.TupleToolbarContent<(SwiftUI.ToolbarItem<(), SwiftUI.Button<SwiftUI.Text>>, SwiftUI.ToolbarItem<(), SwiftUI.Button<SwiftUI.Text>>)>>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.SeriesModel: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.SeriesView: SwiftUI.View {
    typealias Body = accessor function at 31612

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.SubtitleCue: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.TagChips: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI._VariadicView.Tree<SwiftUI._LayoutRoot<One.FlowLayout>, SwiftUI.ForEach<[One.DetailTag], Swift.String, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.NavigationLink<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE20accessibilityElement8childrenQrAA26AccessibilityChildBehaviorV_tF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.HStack<SwiftUI.TupleView<(Swift.Optional<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, One.ScaledFont>, SwiftUI.AccessibilityAttachmentModifier>>, SwiftUI.Text)>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.AccessibilityAttachmentModifier>, Swift.Never>, SwiftUI.PlainButtonStyle>>>, SwiftUI._FlexFrameLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.FlowLayout: SwiftUI.Animatable {
    typealias AnimatableData = SwiftUI.EmptyAnimatableData

    var animatableData: Self.AnimatableData {
        get
        set
    }

    static func _makeAnimatable(value: inout SwiftUI._GraphValue<Self>, inputs: SwiftUI._GraphInputs)
}
extension One.FlowLayout: SwiftUI.Layout {
    typealias Cache = ()

    func makeCache(subviews: SwiftUI.LayoutSubviews) -> Self.Cache
    func updateCache(_: inout Self.Cache, subviews: SwiftUI.LayoutSubviews)
    func spacing(subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> SwiftUI.ViewSpacing
    func sizeThatFits(proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> __C.CGSize
    func placeSubviews(in: __C.CGRect, proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache)
    func explicitAlignment(of: SwiftUI.HorizontalAlignment, in: __C.CGRect, proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> CoreGraphics.CGFloat?
    func explicitAlignment(of: SwiftUI.VerticalAlignment, in: __C.CGRect, proposal: SwiftUI.ProposedViewSize, subviews: SwiftUI.LayoutSubviews, cache: inout Self.Cache) -> CoreGraphics.CGFloat?

    static var layoutProperties: SwiftUI.LayoutProperties {
        get
    }

    static func _makeLayoutView(root: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs, body: (SwiftUI._Graph, SwiftUI._ViewInputs) -> SwiftUI._ViewListOutputs) -> SwiftUI._ViewOutputs
}
extension One.ToastCenter: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.ToastOverlay: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.SubscriptionView<Combine.AnyPublisher<Swift.Bool, Swift.Never>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._PaddingLayout>, SwiftUI._TraitWritingModifier<SwiftUI.TransitionTraitKey>>?)>>, SwiftUI._AnimationModifier<Swift.String?>>, SwiftUI._AllowsHitTestingModifier>>, One.SideBarsReader>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.InterceptionMonitor: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.AmbientBackground: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ZStack<SwiftUI.TupleView<(SwiftUI.Color, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<One.RemoteImage, SwiftUI._ScaleEffect>, SwiftUI._OpacityEffect>?, SwiftUI.LinearGradient)>>, SwiftUI._SafeAreaRegionsIgnoringLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.VideoDetailPage: SwiftUI.View {
    typealias Body = accessor function at 44012

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.DownloadIconButton: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._FlexFrameLayout>, SwiftUI._ContentShapeModifier<SwiftUI.Rectangle>>>, SwiftUI.PlainButtonStyle>, SwiftUI.AccessibilityAttachmentModifier>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.DownloadCard: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._ConditionalContent<One.DownloadItemRow, SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Label<SwiftUI.Text, SwiftUI.Image>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<SwiftUI.Font>>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>>, SwiftUI.PlainButtonStyle>, SwiftUI._EnvironmentKeyTransformModifier<Swift.Bool>>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>)>>, SwiftUI._PaddingLayout>, SwiftUI._FlexFrameLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.RoundedRectangle, SwiftUI.Color>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.EpisodeCard: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ZStack<SwiftUI.TupleView<(One.RemoteImage, SwiftUI.LinearGradient)>>, SwiftUI._FrameLayout>, SwiftUI._OverlayModifier<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._BackgroundModifier<SwiftUI._ShapeView<SwiftUI.Capsule, SwiftUI.Color>>>, SwiftUI._PaddingLayout>>>, SwiftUI._OverlayModifier<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Image, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Font?>>, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>?>>, SwiftUI._OverlayModifier<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ProgressView<SwiftUI.EmptyView, SwiftUI.EmptyView>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.Color?>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>?>>, SwiftUI._ClipEffect<SwiftUI.RoundedRectangle>>, SwiftUI._OverlayModifier<SwiftUI._ShapeView<SwiftUI._StrokedShape<SwiftUI.RoundedRectangle._Inset>, SwiftUI.Color>>>, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>, SwiftUI._FlexFrameLayout>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._EnvironmentKeyWritingModifier<Swift.Int?>>?)>>, SwiftUI._FrameLayout>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.EpisodesSheet: SwiftUI.View {
    typealias Body = SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE19presentationDetentsyQrShyAA18PresentationDetentVGF", 0) __<SwiftUI.NavigationStack<SwiftUI.NavigationPath, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7toolbar7contentQrqd__yXE_tAA14ToolbarContentRd__lF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE29navigationBarTitleDisplayModeyQrAA010NavigationE4ItemV0fgH0OF", 0) __<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE15navigationTitleyQrAA18LocalizedStringKeyVF", 0) __<SwiftUI.ScrollViewReader<SwiftUI.ModifiedContent<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE9listStyleyQrqd__AA04ListE0Rd__lF", 0) __<SwiftUI.List<Swift.Never, SwiftUI.ForEach<Swift.Array<One.CollectionEpisode>, Swift.Int, SwiftUI.IDView<@_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE11buttonStyleyQrqd__AA015PrimitiveButtonE0Rd__lF", 0) __<SwiftUI.Button<One.EpisodeRow>, SwiftUI.PlainButtonStyle>, Swift.Int>>>, SwiftUI.PlainListStyle>, SwiftUI._AppearanceActionModifier>>>>, SwiftUI.ToolbarItem<(), SwiftUI.Button<SwiftUI.Text>>>>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.ColorScheme>>, SwiftUI._PreferenceWritingModifier<SwiftUI.PreferredColorSchemeKey>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.VideoPlayerCard: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE5sheet11isPresented9onDismiss7contentQrAA7BindingVySbG_yycSgqd__yctAaBRd__lF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<accessor function at 31612, SwiftUI._AppearanceActionModifier>, SwiftUI._ValueActionModifier<Swift.Optional<Swift.String>>>, SwiftUI._ValueActionModifier<Swift.String>>, One.SubtitleStyleSheet>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.SubtitleStyleSheet: SwiftUI.View {
    typealias Body = @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE19presentationDetentsyQrShyAA18PresentationDetentVGF", 0) __<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.NavigationStack<SwiftUI.NavigationPath, @_opaqueReturnTypeOf("$s7SwiftUI4ViewPAAE7toolbar7contentQrqd__yXE_tAA14ToolbarContentRd__lF", 0) __<One.MeListPage<SwiftUI.TupleView<(SwiftUI.Section<SwiftUI.EmptyView, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ZStack<SwiftUI.TupleView<(SwiftUI._ShapeView<SwiftUI.RoundedRectangle, SwiftUI.Color>, SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.Color>>, SwiftUI._PaddingLayout>, SwiftUI._PaddingLayout>, SwiftUI._InsettableBackgroundShapeModifier<SwiftUI.Color, SwiftUI.RoundedRectangle>>)>>, SwiftUI._FrameLayout>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowInsetsTraitKey>>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>, SwiftUI.EmptyView>, SwiftUI.ModifiedContent<SwiftUI.Section<SwiftUI.EmptyView, SwiftUI.TupleView<(SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Text, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, SwiftUI.Slider<SwiftUI.Text, SwiftUI.Text>)>>, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Text, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, SwiftUI.Slider<SwiftUI.Text, SwiftUI.Text>)>>, SwiftUI.VStack<SwiftUI.TupleView<(SwiftUI.HStack<SwiftUI.TupleView<(SwiftUI.Text, SwiftUI.Spacer, SwiftUI.ModifiedContent<SwiftUI.Text, SwiftUI._ForegroundStyleModifier<SwiftUI.HierarchicalShapeStyle>>)>>, SwiftUI.Slider<SwiftUI.Text, SwiftUI.Text>)>>)>, SwiftUI.Text>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>, SwiftUI.ModifiedContent<SwiftUI.Section<SwiftUI.EmptyView, SwiftUI.Button<SwiftUI.Text>, SwiftUI.EmptyView>, SwiftUI._TraitWritingModifier<SwiftUI.ListRowBackgroundTraitKey>>)>>, SwiftUI.ToolbarItem<(), SwiftUI.Button<SwiftUI.Text>>>>, SwiftUI._EnvironmentKeyWritingModifier<SwiftUI.ColorScheme>>, SwiftUI._PreferenceWritingModifier<SwiftUI.PreferredColorSchemeKey>>>

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.VideoPlayerModel.Source: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.VideoPlayerModel.Source: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.VideoPlayerModel: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.VideoSurface: SwiftUI.View {
    typealias Body = Swift.Never

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.VideoSurface: SwiftUI.UIViewControllerRepresentable {
    typealias UIViewControllerType = __C.AVPlayerViewController
    typealias Coordinator = One.VideoSurface.Coordinator

    func makeUIViewController(context: SwiftUI.UIViewControllerRepresentableContext<Self>) -> Self.UIViewControllerType
    func updateUIViewController(_: Self.UIViewControllerType, context: SwiftUI.UIViewControllerRepresentableContext<Self>)
    func makeCoordinator() -> Self.Coordinator
    func sizeThatFits(_: SwiftUI.ProposedViewSize, uiViewController: Self.UIViewControllerType, context: SwiftUI.UIViewControllerRepresentableContext<Self>) -> __C.CGSize?
    func _identifiedViewTree(in: Self.UIViewControllerType) -> SwiftUI._IdentifiedViewTree

    static func dismantleUIViewController(_: Self.UIViewControllerType, coordinator: Self.Coordinator)
    static func _layoutOptions(_: Self.UIViewControllerType) -> SwiftUI._PlatformViewRepresentableLayoutOptions
}
extension One.VodModel: Combine.ObservableObject {
    typealias ObjectWillChangePublisher = Combine.ObservableObjectPublisher

    var objectWillChange: Self.ObjectWillChangePublisher {
        get
    }
}
extension One.VodView: SwiftUI.View {
    typealias Body = accessor function at 44012

    var body: Self.Body {
        get
    }

    static func _makeView(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewInputs) -> SwiftUI._ViewOutputs
    static func _makeViewList(view: SwiftUI._GraphValue<Self>, inputs: SwiftUI._ViewListInputs) -> SwiftUI._ViewListOutputs
    static func _viewListCount(inputs: SwiftUI._ViewListCountInputs) -> Swift.Int?
}
extension One.WebDAVConfig: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.WebDAVConfig: Swift.Encodable {
    func encode(to: Swift.Encoder) throws
}
extension One.WebDAVConfig: Swift.Decodable {
    init(from: Swift.Decoder) throws
}
extension One.WebDAVError: Foundation.LocalizedError {
    var errorDescription: Swift.String? {
        get
    }
    var failureReason: Swift.String? {
        get
    }
    var helpAnchor: Swift.String? {
        get
    }
    var recoverySuggestion: Swift.String? {
        get
    }
}
extension One.WebDAVError: Swift.Error {
    var _code: Swift.Int {
        get
    }
    var _domain: Swift.String {
        get
    }
    var _userInfo: Swift.AnyObject? {
        get
    }

    func _getEmbeddedNSError() -> Swift.AnyObject?
}
extension One.WebDAVConfig.CodingKeys: Swift.CustomStringConvertible {
    var description: Swift.String {
        get
    }
}
extension One.WebDAVConfig.CodingKeys: Swift.CustomDebugStringConvertible {
    var debugDescription: Swift.String {
        get
    }
}
extension One.WebDAVConfig.CodingKeys: Swift.RawRepresentable {
    typealias RawValue = Swift.String

    init?(rawValue: Self.RawValue)

    var rawValue: Self.RawValue {
        get
    }
}
extension One.WebDAVConfig.CodingKeys: Swift.Hashable {
    var hashValue: Swift.Int {
        get
    }

    func hash(into: inout Swift.Hasher)
    func _rawHashValue(seed: Swift.Int) -> Swift.Int
}
extension One.WebDAVConfig.CodingKeys: Swift.Equatable {
    static func == (_: Self, _: Self) -> Swift.Bool
}
extension One.WebDAVConfig.CodingKeys: Swift.CodingKey {
    init?(stringValue: Swift.String)
    init?(intValue: Swift.Int)

    var intValue: Swift.Int? {
        get
    }
    var stringValue: Swift.String {
        get
    }
}

