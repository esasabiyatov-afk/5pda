import SwiftUI
import UIKit

/// Загрузчик картинок с кэшем. AsyncImage в списках отменяет загрузку при
/// переиспользовании ячеек и не умеет повторять запрос — поэтому свой.
final class ImageLoader: @unchecked Sendable {
    static let shared = ImageLoader()

    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]
    private let lock = NSLock()
    private let session: URLSession

    private init() {
        cache.totalCostLimit = 120 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept": "image/avif,image/webp,image/png,image/jpeg,image/gif,image/*;q=0.8,*/*;q=0.5",
        ]
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    /// Загружает картинки заранее, но ждёт не дольше `timeout` — чтобы страница
    /// появлялась уже с картинками, а не «дорисовывалась» на глазах.
    func prefetch(_ urls: [URL], timeout: TimeInterval = 3) async {
        let unique = Array(Set(urls)).filter { cached($0) == nil }
        guard !unique.isEmpty else { return }
        // Загрузки идут в отдельных задачах (их не прерываем — всё попадёт в кэш),
        // а здесь ждём, пока закончатся все или выйдет время.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock(); private var n = 0
            func inc() { lock.lock(); n += 1; lock.unlock() }
            var value: Int { lock.lock(); defer { lock.unlock() }; return n }
        }
        let done = Counter()
        let list = Array(unique.prefix(40))
        for u in list { Task.detached(priority: .userInitiated) { _ = await self.load(u); done.inc() } }
        let deadline = Date().addingTimeInterval(timeout)
        while done.value < list.count, Date() < deadline {
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }

    /// Адреса картинок в BB-тексте (img, вложения) и аватары.
    static func imageURLs(bb: String, attachments: [Attachment]) -> [URL] {
        var out = attachments.filter(\.isImage).compactMap { PDAAPI.absoluteURL($0.url) }
        let re = try? NSRegularExpression(pattern: #"\[img[^\]]*\]\s*([^\[\s]+)\s*\[/img\]"#, options: .caseInsensitive)
        let ns = bb as NSString
        re?.enumerateMatches(in: bb, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m = m, let u = PDAAPI.absoluteURL(ns.substring(with: m.range(at: 1))) { out.append(u) }
        }
        return out
    }

    func clear() {
        cache.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    func load(_ url: URL) async -> UIImage? {
        if let img = cached(url) { return img }
        lock.lock()
        let task: Task<UIImage?, Never>
        if let existing = inFlight[url] {
            task = existing
        } else {
            // Не привязан к представлению: прокрутка не отменяет загрузку.
            task = Task.detached(priority: .userInitiated) { [weak self] in
                await self?.fetch(url)
            }
            inFlight[url] = task
        }
        lock.unlock()
        let img = await task.value
        lock.lock(); inFlight[url] = nil; lock.unlock()
        return img
    }

    private func fetch(_ url: URL) async -> UIImage? {
        for candidate in Self.candidates(url) {
            for attempt in 0..<2 {
                var req = URLRequest(url: candidate)
                req.setValue(PDAConfig.siteURL.absoluteString, forHTTPHeaderField: "Referer")
                do {
                    let (data, resp) = try await session.data(for: req)
                    if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { break }
                    guard let img = Self.decode(data) else { break }
                    cache.setObject(img, forKey: url as NSURL, cost: data.count)
                    return img
                } catch {
                    if attempt == 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
                }
            }
        }
        return nil
    }

    /// Сначала исходный адрес, затем тот же по другой схеме.
    private static func candidates(_ url: URL) -> [URL] {
        var result = [url]
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return result }
        c.scheme = url.scheme == "https" ? "http" : "https"
        if let alt = c.url { result.append(alt) }
        return result
    }

    private static func decode(_ data: Data) -> UIImage? {
        guard let img = UIImage(data: data) else { return nil }
        // Ограничиваем размер, чтобы большие скриншоты не съедали память.
        let maxSide: CGFloat = 2048
        let side = max(img.size.width, img.size.height)
        guard side > maxSide else { return img.preparingForDisplay() ?? img }
        let scale = maxSide / side
        let size = CGSize(width: img.size.width * scale, height: img.size.height * scale)
        return img.preparingThumbnail(of: size) ?? img
    }
}

/// Картинка из сети.
struct RemoteImage<Placeholder: View>: View {
    let url: URL?
    var contentMode: ContentMode = .fit
    @ViewBuilder var placeholder: () -> Placeholder
    @State private var image: UIImage?
    @State private var failed = false

    init(url: URL?, contentMode: ContentMode = .fit, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.contentMode = contentMode
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { ImageLoader.shared.cached($0) })
    }

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url = url else { return }
            if let img = ImageLoader.shared.cached(url) { image = img; return }
            image = await ImageLoader.shared.load(url)
            failed = image == nil
        }
    }
}

extension RemoteImage where Placeholder == AvatarPlaceholder {
    /// Аватар с заглушкой.
    init(avatar url: URL?) {
        self.init(url: url, contentMode: .fill) { AvatarPlaceholder() }
    }
}

struct AvatarPlaceholder: View {
    var body: some View {
        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
    }
}

/// Картинка в тексте поста: загружается, по нажатию открывается на весь экран.
struct PostImage: View {
    let url: URL

    init(url: URL) {
        self.url = url
        _image = State(initialValue: ImageLoader.shared.cached(url))
    }
    @Environment(\.multilineTextAlignment) private var textAlignment
    private var frameAlignment: Alignment {
        textAlignment == .center ? .center : textAlignment == .trailing ? .trailing : .leading
    }
    @AppStorage("load_images") private var loadImages = true
    @State private var manual = false
    @State private var image: UIImage?
    @State private var failed = false
    @State private var fullscreen = false

    var body: some View {
        Group {
            if let image = image {
                // Ширина — не больше собственной, высота строго по пропорциям:
                // иначе в спойлере картинка растягивалась по высоте с пустотой вокруг.
                let ratio = image.size.width / max(image.size.height, 1)
                let maxW = min(image.size.width, 420 * ratio)
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: maxW)
                    .aspectRatio(ratio, contentMode: .fit)
                    .fixedSize(horizontal: false, vertical: true)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { fullscreen = true }
            } else if !loadImages && !manual {
                Button { manual = true; Task { await load() } } label: {
                    Label("Изображение — нажмите, чтобы загрузить", systemImage: "photo").font(.footnote)
                }
                .buttonStyle(.borderless)
            } else if failed {
                Button {
                    failed = false
                    Task { await load() }
                } label: {
                    Label("Не удалось загрузить — нажмите, чтобы повторить", systemImage: "arrow.clockwise")
                        .font(.footnote)
                }
                .buttonStyle(.borderless)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .task(id: url) { if loadImages || manual { await load() } }
        .fullScreenCover(isPresented: $fullscreen) {
            if let image = image { ImageViewer(image: image, url: url) }
        }
    }

    private func load() async {
        if let img = ImageLoader.shared.cached(url) { image = img; return }
        image = await ImageLoader.shared.load(url)
        failed = image == nil
    }
}

/// Полноэкранный просмотр с масштабированием: по центру, вписан в экран,
/// по возможности — оригинал вместо уменьшенного превью.
struct ImageViewer: View {
    let image: UIImage
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var shown: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    /// Превью вложений 4PDA: /static/c/ir500x500/att-…; оригинал — /static/c/img/att-…
    private var fullURL: URL? {
        let s = url.absoluteString
        guard let r = s.range(of: #"/c/ir\d+x\d+/"#, options: .regularExpression) else { return nil }
        return URL(string: s.replacingCharacters(in: r, with: "/c/img/"))
    }

    var body: some View {
        let current = shown ?? image
        GeometryReader { geo in
            Image(uiImage: current)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .gesture(
                    MagnificationGesture()
                        .onChanged { scale = max(1, lastScale * $0) }
                        .onEnded { _ in lastScale = scale; if scale == 1 { offset = .zero; lastOffset = .zero } }
                        .simultaneously(with: DragGesture()
                            .onChanged { v in
                                if scale > 1 {
                                    offset = CGSize(width: lastOffset.width + v.translation.width,
                                                    height: lastOffset.height + v.translation.height)
                                } else {
                                    offset = CGSize(width: 0, height: v.translation.height)
                                }
                            }
                            .onEnded { v in
                                if scale <= 1, abs(v.translation.height) > 120 { dismiss(); return }
                                if scale <= 1 { offset = .zero }
                                lastOffset = offset
                            })
                )
                .onTapGesture(count: 2) {
                    withAnimation {
                        if scale > 1 { scale = 1; offset = .zero } else { scale = 2.5 }
                        lastScale = scale; lastOffset = offset
                    }
                }
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 16) {
                ShareLink(item: Image(uiImage: current), preview: SharePreview(url.lastPathComponent, image: Image(uiImage: current))) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button { dismiss() } label: { Image(systemName: "xmark") }
            }
            .font(.title3.bold())
            .foregroundStyle(.white)
            .padding(12)
            .background(.ultraThinMaterial, in: Capsule())
            .padding()
        }
        .task {
            if let f = fullURL, let big = await ImageLoader.shared.load(f), big.size.width > image.size.width {
                shown = big
            }
        }
    }
}
