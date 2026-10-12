import Foundation
import QuartzCore
import Libmpv

/// CAMetalLayer that mpv renders into (via MoltenVK). Workarounds taken from the MPVKit demo.
final class MPVMetalLayer: CAMetalLayer {
    // MoltenVK sets drawableSize to 1x1 to force-complete presentation, which causes flicker
    // and can leave the size stuck (https://github.com/mpv-player/mpv/pull/13651).
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue }
        }
    }

    // EDR mode only activates when set on the main thread; mpv sets it from its render thread.
    override var wantsExtendedDynamicRangeContent: Bool {
        get { super.wantsExtendedDynamicRangeContent }
        set {
            if Thread.isMainThread {
                super.wantsExtendedDynamicRangeContent = newValue
            } else {
                let layer = UncheckedBox(self)
                DispatchQueue.main.sync { layer.value.setSuperEDR(newValue) }
            }
        }
    }

    private func setSuperEDR(_ value: Bool) { super.wantsExtendedDynamicRangeContent = value }
}

struct UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }

/// Values delivered from mpv's event queue to the main actor.
enum MPVEvent: Sendable {
    enum Value: Sendable {
        case none
        case flag(Bool)
        case double(Double)
        case string(String)
        case tracks([PlayerTrack])
        case chapters([PlayerChapter])
    }
    case property(String, Value)
    case startFile
    case fileLoaded
    case endFile(reason: mpv_end_file_reason.RawValue, error: Int32)
    case shutdown
}

/// Owns the mpv handle. Every libmpv call after initialization happens on `queue`,
/// so destroy can never race with a command or with event draining.
final class MPVCore: @unchecked Sendable {
    let layer = MPVMetalLayer()
    private let queue = DispatchQueue(label: "se.mediaempire.DeStream.mpv", qos: .userInitiated)
    private var mpv: OpaquePointer?
    private var onEvents: (@Sendable ([MPVEvent]) -> Void)?
    private var retainedSelf: Unmanaged<MPVCore>?
    private var baseAspect: Double?
    private var nudgeUp = false

    static let observed: [(String, mpv_format)] = [
        ("time-pos", MPV_FORMAT_DOUBLE),
        ("duration", MPV_FORMAT_DOUBLE),
        ("pause", MPV_FORMAT_FLAG),
        ("paused-for-cache", MPV_FORMAT_FLAG),
        ("eof-reached", MPV_FORMAT_FLAG),
        ("seeking", MPV_FORMAT_FLAG),
        ("volume", MPV_FORMAT_DOUBLE),
        ("mute", MPV_FORMAT_FLAG),
        ("speed", MPV_FORMAT_DOUBLE),
        ("aid", MPV_FORMAT_STRING),
        ("sid", MPV_FORMAT_STRING),
        ("demuxer-cache-time", MPV_FORMAT_DOUBLE),
        ("cache-buffering-state", MPV_FORMAT_DOUBLE),
        ("track-list", MPV_FORMAT_NODE),
        ("chapter-list", MPV_FORMAT_NODE),
    ]

    init?() {
        guard let handle = mpv_create() else { return nil }
        layer.framebufferOnly = true
        // Until mpv re-renders at a new size, scale the last frame instead of stretching it.
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)

        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
        let options: [(String, String)] = [
            ("vo", "gpu-next"),
            ("gpu-api", "vulkan"),
            ("gpu-context", "moltenvk"),
            ("hwdec", "videotoolbox"),
            ("keep-open", "yes"),
            ("idle", "yes"),
            ("cache", "yes"),
            ("demuxer-max-bytes", "150MiB"),
            ("demuxer-max-back-bytes", "50MiB"),
            ("network-timeout", "30"),
            ("user-agent", "DeStream/1.0"),
            ("stream-lavf-o", "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5"),
            ("ytdl", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("subs-match-os-language", "yes"),
            ("subs-fallback", "yes"),
            ("sub-ass-override", "no"),
            ("audio-file-auto", "no"),
            // If the output device vanishes during an audio reload, keep the clock running instead of dropping the audio track.
            ("audio-fallback-to-null", "yes"),
            ("sub-auto", "no"),
            ("osc", "no"),
            ("load-stats-overlay", "no"),
            ("load-console", "no"),
            ("load-auto-profiles", "no"),
            ("load-select", "no"),
            ("load-positioning", "no"),
            ("load-commands", "no"),
        ]
        for (name, value) in options { mpv_set_option_string(handle, name, value) }
        #if DEBUG
        mpv_request_log_messages(handle, "warn")
        #endif

        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            return nil
        }
        for (name, format) in Self.observed { mpv_observe_property(handle, 0, name, format) }
        mpv = handle
    }

    /// Installs the event sink and starts delivering events.
    func start(onEvents: @escaping @Sendable ([MPVEvent]) -> Void) {
        queue.async { [self] in
            guard let mpv, retainedSelf == nil else { return }
            self.onEvents = onEvents
            let unmanaged = Unmanaged.passRetained(self)
            retainedSelf = unmanaged
            mpv_set_wakeup_callback(mpv, { ctx in
                guard let ctx else { return }
                Unmanaged<MPVCore>.fromOpaque(ctx).takeUnretainedValue().scheduleDrain()
            }, unmanaged.toOpaque())
            drain()
        }
    }

    func command(_ args: [String]) {
        queue.async { [self] in
            guard let mpv else { return }
            var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
            cargs.append(nil)
            defer { for p in cargs { free(UnsafeMutablePointer(mutating: p)) } }
            let rc = mpv_command(mpv, &cargs)
            #if DEBUG
            if rc < 0 { print("[mpv] command \(args.first ?? "") failed: \(String(cString: mpv_error_string(rc)))") }
            #endif
        }
    }

    /// For commands that may block on the network (e.g. `sub-add` with a URL), so the queue keeps draining events.
    func commandAsync(_ args: [String]) {
        queue.async { [self] in
            guard let mpv else { return }
            var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) }
            cargs.append(nil)
            defer { for p in cargs { free(UnsafeMutablePointer(mutating: p)) } }
            mpv_command_async(mpv, 0, &cargs)
        }
    }

    func set(_ property: String, _ value: String) {
        queue.async { [self] in
            guard let mpv else { return }
            mpv_set_property_string(mpv, property, value)
        }
    }

    /// MPVKit's MoltenVK context only reads the layer's drawable size when the video output reconfigures,
    /// so force a reconfigure by nudging the aspect override by a sub-pixel amount.
    func refreshVideoSize() {
        queue.async { [self] in
            guard let mpv else { return }
            if baseAspect == nil {
                // Aspect of the full (uncropped) frame, which is what the override replaces.
                var w: Int64 = 0, h: Int64 = 0, par = 1.0
                guard mpv_get_property(mpv, "video-params/w", MPV_FORMAT_INT64, &w) >= 0,
                      mpv_get_property(mpv, "video-params/h", MPV_FORMAT_INT64, &h) >= 0, w > 0, h > 0 else { return }
                mpv_get_property(mpv, "video-params/par", MPV_FORMAT_DOUBLE, &par)
                baseAspect = Double(w) * (par > 0 ? par : 1) / Double(h)
            }
            guard let baseAspect else { return }
            nudgeUp.toggle()
            mpv_set_property_string(mpv, "video-aspect-override", String(baseAspect * (nudgeUp ? 1 + 1e-6 : 1 - 1e-6)))
        }
    }

    /// Clears the override from `refreshVideoSize` so the next file uses its own aspect ratio.
    func resetVideoSize() {
        queue.async { [self] in
            guard let mpv else { return }
            baseAspect = nil
            mpv_set_property_string(mpv, "video-aspect-override", "no")
        }
    }

    /// Asynchronously terminates mpv. The layer stays alive (owned by self) until mpv has released it.
    func destroy() {
        queue.async { [self] in
            guard let handle = mpv else { return }
            mpv_set_wakeup_callback(handle, nil, nil)
            mpv = nil
            onEvents = nil
            mpv_terminate_destroy(handle)
            retainedSelf?.release()
            retainedSelf = nil
        }
    }

    private func scheduleDrain() {
        queue.async { [self] in drain() }
    }

    private func drain() {
        guard let mpv else { return }
        var batch: [MPVEvent] = []
        while let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
            let e = event.pointee
            switch e.event_id {
            case MPV_EVENT_PROPERTY_CHANGE:
                guard let prop = e.data?.assumingMemoryBound(to: mpv_event_property.self).pointee else { continue }
                batch.append(.property(String(cString: prop.name), Self.value(of: prop)))
            case MPV_EVENT_START_FILE:
                batch.append(.startFile)
            case MPV_EVENT_FILE_LOADED:
                batch.append(.fileLoaded)
            case MPV_EVENT_END_FILE:
                if let end = e.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee {
                    batch.append(.endFile(reason: end.reason.rawValue, error: end.error))
                }
            case MPV_EVENT_SHUTDOWN:
                batch.append(.shutdown)
            case MPV_EVENT_LOG_MESSAGE:
                #if DEBUG
                if let msg = e.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee {
                    let text = String(cString: msg.text).replacingOccurrences(of: #"[a-z]+://\S+"#, with: "<url>", options: .regularExpression)
                    print("[mpv/\(String(cString: msg.prefix))] \(String(cString: msg.level)): \(text)", terminator: "")
                }
                #endif
            default:
                break
            }
        }
        if !batch.isEmpty { onEvents?(batch) }
    }

    private static func value(of prop: mpv_event_property) -> MPVEvent.Value {
        guard let data = prop.data else { return .none }
        switch prop.format {
        case MPV_FORMAT_FLAG: return .flag(data.assumingMemoryBound(to: Int32.self).pointee != 0)
        case MPV_FORMAT_DOUBLE: return .double(data.assumingMemoryBound(to: Double.self).pointee)
        case MPV_FORMAT_STRING:
            guard let cstr = data.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee else { return .none }
            return .string(String(cString: cstr))
        case MPV_FORMAT_NODE:
            let node = data.assumingMemoryBound(to: mpv_node.self).pointee
            if String(cString: prop.name) == "chapter-list" { return .chapters(chapters(from: node)) }
            return .tracks(tracks(from: node))
        default: return .none
        }
    }

    private static func chapters(from node: mpv_node) -> [PlayerChapter] {
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list?.pointee else { return [] }
        var result: [PlayerChapter] = []
        for i in 0..<Int(list.num) {
            let item = list.values[i]
            guard item.format == MPV_FORMAT_NODE_MAP, let map = item.u.list?.pointee else { continue }
            var title: String?
            var time: Double?
            for j in 0..<Int(map.num) {
                guard let key = map.keys[j] else { continue }
                let value = map.values[j]
                switch String(cString: key) {
                case "title" where value.format == MPV_FORMAT_STRING: title = value.u.string.map { String(cString: $0) }
                case "time" where value.format == MPV_FORMAT_DOUBLE: time = value.u.double_
                case "time" where value.format == MPV_FORMAT_INT64: time = Double(value.u.int64)
                default: break
                }
            }
            if let time { result.append(PlayerChapter(title: title, time: time)) }
        }
        return result
    }

    private static func tracks(from node: mpv_node) -> [PlayerTrack] {
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list?.pointee else { return [] }
        var result: [PlayerTrack] = []
        for i in 0..<Int(list.num) {
            let item = list.values[i]
            guard item.format == MPV_FORMAT_NODE_MAP, let map = item.u.list?.pointee else { continue }
            var fields: [String: mpv_node] = [:]
            for j in 0..<Int(map.num) {
                guard let key = map.keys[j] else { continue }
                fields[String(cString: key)] = map.values[j]
            }
            func string(_ k: String) -> String? {
                guard let n = fields[k], n.format == MPV_FORMAT_STRING, let s = n.u.string else { return nil }
                return String(cString: s)
            }
            func int(_ k: String) -> Int? {
                guard let n = fields[k], n.format == MPV_FORMAT_INT64 else { return nil }
                return Int(n.u.int64)
            }
            func flag(_ k: String) -> Bool {
                guard let n = fields[k], n.format == MPV_FORMAT_FLAG else { return false }
                return n.u.flag != 0
            }
            let kind: PlayerTrack.Kind
            switch string("type") {
            case "audio": kind = .audio
            case "sub": kind = .subtitle
            default: continue
            }
            guard let id = int("id") else { continue }
            var channels: String?
            if let count = int("demux-channel-count") {
                channels = switch count { case 1: "Mono"; case 2: "Stereo"; case 6: "5.1"; case 8: "7.1"; default: "\(count) ch" }
            }
            result.append(PlayerTrack(
                id: id, kind: kind, title: string("title"), language: string("lang"),
                codec: string("codec"), channels: kind == .audio ? channels : nil,
                isDefault: flag("default"), isForced: flag("forced"), isExternal: flag("external"), isSelected: flag("selected")
            ))
        }
        return result
    }
}
