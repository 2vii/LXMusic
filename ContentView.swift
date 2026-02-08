import Foundation
import SwiftUI
import Alamofire
import SwiftyJSON
import Cache
import AVFoundation
import MediaPlayer
import UniformTypeIdentifiers

enum AppTheme: String, Codable, CaseIterable {
    case light, dark
}

enum PlayMode: Int, Codable, CaseIterable {
    case sequence, loop, single, random
}

struct LXSong: Identifiable, Codable, Equatable {
    let id: String
    let name: String?
    let artist: String?
    let album: String?
    let duration: Int?
    let pic: String?
    let isLocal: Bool
    let localPath: String?
    
    static func local(id: String, name: String) -> LXSong {
        LXSong(id: id, name: name, artist: "本地音频", album: "本地文件", duration: nil, pic: nil, isLocal: true, localPath: nil)
    }
}

struct LXSource: Identifiable, Codable, Equatable {
    let id = UUID()
    let name: String
    let searchURL: String
    let playURL: String
    let lyricURL: String
}

struct LXLyricLine: Identifiable {
    let id = UUID()
    let time: TimeInterval
    let text: String
}

struct LXPlaylist: Identifiable, Codable, Equatable {
    let id = UUID()
    let name: String
    var songs: [LXSong]
}

struct LXConfigData: Codable {
    var theme: AppTheme = .dark
    var history: [LXSong] = []
    var playlists: [LXPlaylist] = []
    var sources: [LXSource] = []
    var searchHistory: [String] = []
    var lyricOffsets: [String: Double] = [:]
    var lastSpeed: Float = 1.0
}

class LXConfig: ObservableObject {
    static let shared = LXConfig()
    @Published var data: LXConfigData
    private let key = "LXConfig_Final"
    
    init() {
        self.data = UserDefaults.standard.data(forKey: key)
            .flatMap({ try? JSONDecoder().decode(LXConfigData.self, from: $0) }) ?? LXConfigData()
        if data.sources.isEmpty {
            data.sources = [LXSource(name: "默认320k源", searchURL: "https://api.injahow.cn/meting/api?server=netease&type=search&keywords=", playURL: "https://api.injahow.cn/meting/api?server=netease&type=url&id=&quality=320", lyricURL: "https://api.injahow.cn/meting/api?server=netease&type=lyric&id=")]
        }
    }
    
    func save() {
        guard let d = try? JSONEncoder().encode(data) else { return }
        UserDefaults.standard.set(d, forKey: key)
    }
    
    func addToHistory(_ s: LXSong) {
        data.history.removeAll { $0.id == s.id }
        data.history.insert(s, at: 0)
        if data.history.count > 200 {
            data.history = Array(data.history.prefix(200))
        }
        save()
    }
    
    func toggleFavorite(_ s: LXSong) {
        if let i = data.playlists.firstIndex(where: { $0.name == "我喜欢" }) {
            if data.playlists[i].songs.contains(s) {
                data.playlists[i].songs.removeAll { $0.id == s.id }
            } else {
                data.playlists[i].songs.insert(s, at: 0)
            }
        } else {
            data.playlists.insert(LXPlaylist(name: "我喜欢", songs: [s]), at: 0)
        }
        save()
    }
    
    func isFavorite(_ s: LXSong) -> Bool {
        data.playlists.first(where: { $0.name == "我喜欢" })?.songs.contains(where: { $0.id == s.id }) ?? false
    }
}

class LXSourceManager: ObservableObject {
    static let shared = LXSourceManager()
    @Published var current: LXSource?
    init() {
        current = LXConfig.shared.data.sources.first
    }
}

class LXAPI {
    static let shared = LXAPI()
    func search(keyword: String, src: LXSource, completion: @escaping ([LXSong]) -> Void) {
        let u = src.searchURL + keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        AF.request(u).responseData { r in
            guard let d = r.data, let j = try? JSON(d) else {
                completion([])
                return
            }
            let songs = j["data"].arrayValue.map {
                LXSong(id: $0["id"].stringValue, name: $0["name"].string, artist: $0["artist"].string, album: $0["album"].string, duration: $0["duration"].int, pic: $0["pic"].string, isLocal: false, localPath: nil)
            }
            completion(songs)
        }
    }
    
    func getPlayURL(id: String, src: LXSource, completion: @escaping (String?) -> Void) {
        let u = src.playURL.replacingOccurrences(of: "&quality=320", with: "") + id + "&quality=320"
        AF.request(u).responseData { r in
            guard let d = r.data, let j = try? JSON(d) else {
                completion(nil)
                return
            }
            completion(j["url"].string ?? j["data"]["url"].string)
        }
    }
    
    func getLyric(id: String, src: LXSource, completion: @escaping (String?) -> Void) {
        AF.request(src.lyricURL + id).responseString { r in
            completion(r.value)
        }
    }
}

class LXCache {
    static let shared = LXCache()
    private let s = try! Storage<String, Data>(diskConfig: .init(name: "LXC"), memoryConfig: .init(), transformer: .forData())
    func cache(url: String, data: Data) {
        try? s.setObject(data, forKey: url.md5)
    }
    func get(url: String) -> Data? {
        try? s.object(forKey: url.md5)
    }
    func exists(url: String) -> Bool {
        (try? s.existsObject(forKey: url.md5)) ?? false
    }
    func clear() {
        try? s.removeAll()
    }
}

extension String {
    var md5: String {
        let d = data(using: .utf8)!
        var h = [UInt8](repeating: 0, count: 16)
        d.withUnsafeBytes {
            CC_MD5($0.baseAddress, CC_LONG(d.count), &h)
        }
        return h.map { String(format: "%02x", $0) }.joined()
    }
}

class LocalAudioManager: ObservableObject {
    static let shared = LocalAudioManager()
    @Published var files: [URL] = []
    
    func picker() -> UIDocumentPickerViewController {
        let t: [UTType] = [.mp3, .m4a, .flac, .wav, .audio]
        let p = UIDocumentPickerViewController(forOpeningContentTypes: t, asCopy: true)
        p.allowsMultipleSelection = false
        return p
    }
    
    func importFile(url: URL) {
        _ = url.startAccessingSecurityScopedResource()
        files.append(url)
        url.stopAccessingSecurityScopedResource()
    }
}

struct DocPicker: UIViewControllerRepresentable {
    @Binding var show: Bool
    let onPick: (URL) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let p = LocalAudioManager.shared.picker()
        p.delegate = context.coordinator
        return p
    }
    
    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let p: DocPicker
        init(_ p: DocPicker) {
            self.p = p
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let u = urls.first {
                p.onPick(u)
            }
            p.show = false
        }
        
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            p.show = false
        }
    }
}

extension View {
    func docPicker(show: Binding<Bool>, onPick: @escaping (URL) -> Void) -> some View {
        self.sheet(isPresented: show) {
            DocPicker(show: show, onPick: onPick)
        }
    }
}

class PlayerManager: ObservableObject {
    static let shared = PlayerManager()
    @Published var current: LXSong?
    @Published var progress: Double = 0
    @Published var total: Double = 1
    @Published var isPlaying = false
    @Published var mode: PlayMode = .sequence
    @Published var queue: [LXSong] = []
    @Published var list: [LXSong] = []
    @Published var index = 0
    @Published var speed: Float = 1.0
    @Published var lyricLines: [LXLyricLine] = []
    @Published var lyricIndex = 0
    @Published var sleepRemain = 0
    
    private var player: AVPlayer?
    private var timer: Timer?
    private var sleepTimer: Timer?
    
    init() {
        speed = LXConfig.shared.data.lastSpeed
        setupSession()
        setupRemote()
        setupRoute()
    }
    
    func setupSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    
    func setupRemote() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { _ in
            self.play()
            return .success
        }
        c.pauseCommand.addTarget { _ in
            self.pause()
            return .success
        }
        c.nextCommand.addTarget { _ in
            self.next()
            return .success
        }
        c.previousCommand.addTarget { _ in
            self.prev()
            return .success
        }
    }
    
    func setupRoute() {
        NotificationCenter.default.addObserver(self, selector: #selector(routeChange), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    
    @objc func routeChange(n: Notification) {
        guard let r = n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt else { return }
        if r == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
            pause()
        }
    }
    
    func playList(_ l: [LXSong], i: Int) {
        list = l
        index = i
        queue.removeAll()
        playNow()
    }
    
    func playNow() {
        guard index < list.count else { return }
        let s = list[index]
        current = s
        LXConfig.shared.addToHistory(s)
        loadLyric()
        if s.isLocal, let p = s.localPath, let u = URL(string: p) {
            player = AVPlayer(url: u)
        } else {
            guard let src = LXSourceManager.shared.current else { return }
            LXAPI.shared.getPlayURL(id: s.id, src: src) { u in
                guard let u = u, let url = URL(string: u) else { return }
                self.player = AVPlayer(url: url)
                self.player?.rate = self.speed
                self.play()
                self.startTimer()
                self.updateLock()
            }
        }
    }
    
    func playLocal(url: URL) -> LXSong {
        let name = url.deletingPathExtension().lastPathComponent
        let s = LXSong.local(id: UUID().uuidString, name: name)
        current = s
        player = AVPlayer(url: url)
        player?.rate = speed
        play()
        startTimer()
        updateLock()
        return s
    }
    
    func play() {
        isPlaying = true
        player?.play()
    }
    
    func pause() {
        isPlaying = false
        player?.pause()
    }
    
    func next() {
        if !queue.isEmpty {
            let n = queue.removeFirst()
            list.insert(n, at: index+1)
        }
        switch mode {
        case .sequence:
            index += 1
        case .loop:
            index = (index + 1) % list.count
        case .single:
            break
        case .random:
            index = .random(in: 0..<list.count)
        }
        if index >= list.count {
            pause()
            return
        }
        playNow()
    }
    
    func prev() {
        index = max(0, index-1)
        playNow()
    }
    
    func addQueue(_ s: LXSong) {
        queue.append(s)
    }
    
    func setSpeed(_ v: Float) {
        speed = v
        player?.rate = v
        LXConfig.shared.data.lastSpeed = v
        LXConfig.shared.save()
    }
    
    func startTimer() {
        timer?.invalidate()
        timer = .scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            guard let c = self.player?.currentTime().seconds, let t = self.player?.currentItem?.duration.seconds, t.isNormal else { return }
            DispatchQueue.main.async {
                self.progress = c
                self.total = t
                self.syncLyric(c + LXConfig.shared.data.lyricOffsets[self.current?.id ?? ""] ?? 0)
            }
        }
    }
    
    func loadLyric() {
        lyricLines.removeAll()
        lyricIndex = 0
        guard let s = current, !s.isLocal, let src = LXSourceManager.shared.current else { return }
        LXAPI.shared.getLyric(id: s.id, src: src) { t in
            guard let t = t else { return }
            self.lyricLines = self.parse(t)
        }
    }
    
    func parse(_ t: String) -> [LXLyricLine] {
        var l = [LXLyricLine]()
        t.components(separatedBy: .newlines).forEach { line in
            guard line.starts(with: "[") else { return }
            let p = line.components(separatedBy: "]")
            guard let time = p.first?.dropFirst() else { return }
            let text = p.dropFirst().joined()
            let ms = time.components(separatedBy: ":")
            guard let m = Double(ms.first ?? "0"), let s = Double(ms.last ?? "0") else { return }
            l.append(LXLyricLine(time: m*60+s, text: text))
        }
        return l
    }
    
    func syncLyric(_ t: Double) {
        for (i, line) in lyricLines.enumerated() {
            if i < lyricLines.count-1, t >= line.time, t < lyricLines[i+1].time {
                lyricIndex = i
                break
            }
        }
    }
    
    func updateLock() {
        guard let s = current else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: s.name ?? "", MPMediaItemPropertyArtist: s.artist ?? ""]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    func sleep(min: Int) {
        stopSleep()
        sleepRemain = min * 60
        sleepTimer = .scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            self.sleepRemain -= 1
            if self.sleepRemain <= 0 {
                self.pause()
                self.stopSleep()
            }
        }
    }
    
    func stopSleep() {
        sleepTimer?.invalidate()
        sleepRemain = 0
    }
}

struct ContentView: View {
    @EnvironmentObject var cfg: LXConfig
    @EnvironmentObject var pm: PlayerManager
    @State private var search = ""
    @State private var songs: [LXSong] = []
    @State private var showPicker = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                cfg.data.theme == .dark ? Color.black : Color.white
                List {
                    if !cfg.data.history.isEmpty {
                        Section("最近播放") {
                            ForEach(cfg.data.history.prefix(15)) { s in
                                row(s)
                            }
                        }
                    }
                    if let fav = cfg.data.playlists.first(where: { $0.name == "我喜欢" }), !fav.songs.isEmpty {
                        Section("我喜欢") {
                            ForEach(fav.songs) { s in
                                row(s)
                            }
                        }
                    }
                    Section("本地音乐") {
                        Button("导入音频") {
                            showPicker = true
                        }
                        ForEach(LocalAudioManager.shared.files, id: \.self) { u in
                            Text(u.deletingPathExtension().lastPathComponent)
                                .foregroundColor(.primary)
                                .onTapGesture {
                                    _ = pm.playLocal(url: u)
                                }
                        }
                    }
                    if !songs.isEmpty {
                        Section("搜索结果") {
                            ForEach(songs) { s in
                                row(s)
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .searchable(text: $search)
            .onSubmit(of: .search) {
                guard let src = LXSourceManager.shared.current else { return }
                LXAPI.shared.search(keyword: search, src: src) { songs in
                    DispatchQueue.main.async {
                        self.songs = songs
                    }
                }
            }
            .navigationTitle("音乐")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(action: {
                            cfg.data.theme = .dark
                            cfg.save()
                        }) {
                            Text("纯黑模式")
                        }
                        Button(action: {
                            cfg.data.theme = .light
                            cfg.save()
                        }) {
                            Text("纯白模式")
                        }
                        Button(action: {
                            LXCache.shared.clear()
                        }) {
                            Text("清理缓存")
                        }
                    } label: {
                        Image(systemName: "gear")
                    }
                }
            }
            .docPicker(show: $showPicker) { u in
                LocalAudioManager.shared.importFile(url: u)
            }
        }
    }
    
    func row(_ s: LXSong) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(s.name ?? "-")
                Text(s.artist ?? "-")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(action: {
                cfg.toggleFavorite(s)
            }) {
                Image(systemName: cfg.isFavorite(s) ? "heart.fill" : "heart")
            }
        }
        .foregroundColor(.primary)
        .onTapGesture {
            pm.playList([s], i: 0)
        }
    }
}

@main
struct LXMusicApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(LXConfig.shared)
                .environmentObject(PlayerManager.shared)
                .environmentObject(LXSourceManager.shared)
        }
    }
}
