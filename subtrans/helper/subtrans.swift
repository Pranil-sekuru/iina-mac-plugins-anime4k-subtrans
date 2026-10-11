// subtrans: turn a video's DVD bitmap subtitles into a translated .srt, fully on-device.
//   subtrans <video> <out.srt> [--to en] [--track N] [--keep-source out.src.srt]
// Pipeline: ffprobe dumps the SPU packets -> decode RLE bitmaps -> Vision OCR -> Translation -> SRT.
import CoreGraphics
import Foundation
import Translation
import Vision

struct Cue { var start: Double; var end: Double; var text: String }

let t0 = Date()
func log(_ msg: String) { FileHandle.standardError.write(String(format: "[%5.1fs] %@\n", Date().timeIntervalSince(t0), msg).data(using: .utf8)!) }

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

func run(_ args: [String]) -> Data {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { fail("cannot run ffprobe: \(error)") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return data
}

// ffprobe -show_data prints a hexdump: "00000000: 1642 1623 0000 ...  ascii"
func hexdump(_ s: String) -> [UInt8] {
    var bytes: [UInt8] = []
    for line in s.split(separator: "\n") {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let rest = line[line.index(after: colon)...]
        let hex = rest.components(separatedBy: "  ").first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        var digits = Array(hex.replacingOccurrences(of: " ", with: ""))
        if digits.count % 2 == 1 { digits.removeLast() }
        var i = 0
        while i < digits.count {
            if let b = UInt8(String(digits[i...i + 1]), radix: 16) { bytes.append(b) }
            i += 2
        }
    }
    return bytes
}

struct SPU {
    var start = 0.0, end: Double? = nil
    var x1 = 0, x2 = 0, y1 = 0, y2 = 0
    var color = [0, 1, 2, 3], alpha = [0, 15, 15, 15]
    var top = 0, bottom = 0
}

func u16(_ b: [UInt8], _ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) << 8 | Int(b[i + 1]) : 0 }

func parseSPU(_ b: [UInt8]) -> SPU? {
    guard b.count > 4 else { return nil }
    var spu = SPU()
    var off = u16(b, 2)
    var seen = Set<Int>()
    while off + 4 <= b.count, !seen.contains(off) {
        seen.insert(off)
        let delay = Double(u16(b, off)) * 1024 / 90000
        let next = u16(b, off + 2)
        var i = off + 4
        loop: while i < b.count {
            switch b[i] {
            case 0x00: i += 1
            case 0x01: spu.start = delay; i += 1
            case 0x02: spu.end = delay; i += 1
            case 0x03:
                guard i + 2 < b.count else { break loop }
                spu.color = [Int(b[i + 2] & 0xf), Int(b[i + 2] >> 4), Int(b[i + 1] & 0xf), Int(b[i + 1] >> 4)]
                i += 3
            case 0x04:
                guard i + 2 < b.count else { break loop }
                spu.alpha = [Int(b[i + 2] & 0xf), Int(b[i + 2] >> 4), Int(b[i + 1] & 0xf), Int(b[i + 1] >> 4)]
                i += 3
            case 0x05:
                guard i + 6 < b.count else { break loop }
                spu.x1 = Int(b[i + 1]) << 4 | Int(b[i + 2]) >> 4
                spu.x2 = Int(b[i + 2] & 0xf) << 8 | Int(b[i + 3])
                spu.y1 = Int(b[i + 4]) << 4 | Int(b[i + 5]) >> 4
                spu.y2 = Int(b[i + 5] & 0xf) << 8 | Int(b[i + 6])
                i += 7
            case 0x06:
                spu.top = u16(b, i + 1); spu.bottom = u16(b, i + 3)
                i += 5
            default: break loop  // 0xff end, or unknown
            }
        }
        if next == off { break }
        off = next
    }
    return spu.x2 > spu.x1 && spu.y2 > spu.y1 ? spu : nil
}

// 2-bit RLE, nibble-coded, interlaced: top field = even rows, bottom field = odd rows.
func decodeRLE(_ b: [UInt8], spu: SPU) -> (w: Int, h: Int, px: [UInt8]) {
    let w = spu.x2 - spu.x1 + 1, h = spu.y2 - spu.y1 + 1
    var px = [UInt8](repeating: 0, count: w * h)
    for (field, start) in [(0, spu.top), (1, spu.bottom)] {
        var nib = start * 2
        func next() -> Int {
            let byte = nib / 2 < b.count ? Int(b[nib / 2]) : 0
            let v = nib % 2 == 0 ? byte >> 4 : byte & 0xf
            nib += 1
            return v
        }
        var y = field
        while y < h {
            var x = 0
            while x < w {
                var v = next()
                if v < 0x4 { v = v << 4 | next()
                    if v < 0x10 { v = v << 4 | next()
                        if v < 0x40 { v = v << 4 | next() } } }
                let c = UInt8(v & 3)
                var run = v >> 2
                if run == 0 { run = w - x }
                for k in x..<min(w, x + run) { px[y * w + k] = c }
                x += run
            }
            if nib % 2 == 1 { nib += 1 }
            y += 2
        }
    }
    return (w, h, px)
}

// Composite onto black with the stream palette, 2x upscaled with padding (helps Vision on small glyphs).
func render(_ d: (w: Int, h: Int, px: [UInt8]), spu: SPU, palette: [(Double, Double, Double)]) -> CGImage? {
    let s = 2, pad = 16
    let W = d.w * s + pad * 2, H = d.h * s + pad * 2
    var rgba = [UInt8](repeating: 0, count: W * H * 4)
    for i in stride(from: 3, to: rgba.count, by: 4) { rgba[i] = 255 }
    for y in 0..<d.h {
        for x in 0..<d.w {
            let c = Int(d.px[y * d.w + x])
            let a = Double(spu.alpha[c]) / 15
            if a == 0 { continue }
            let col = palette[spu.color[c] % palette.count]
            for dy in 0..<s { for dx in 0..<s {
                let o = ((pad + y * s + dy) * W + pad + x * s + dx) * 4
                rgba[o] = UInt8(col.0 * a * 255); rgba[o + 1] = UInt8(col.1 * a * 255); rgba[o + 2] = UInt8(col.2 * a * 255)
            } }
        }
    }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
    return CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: cs,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

func ocr(_ img: CGImage, lang: String) -> String {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = [lang]
    req.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: img).perform([req])
    let obs = (req.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
    return obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

func wrap(_ s: String, width: Int = 42) -> String {
    guard s.count > width else { return s }
    let words = s.split(separator: " ")
    var best = s, bestDiff = Int.max, left = ""
    for (i, w) in words.enumerated() where i < words.count - 1 {
        left += (left.isEmpty ? "" : " ") + w
        let right = words[(i + 1)...].joined(separator: " ")
        let diff = abs(left.count - right.count)
        if diff < bestDiff { bestDiff = diff; best = left + "\n" + right }
    }
    return best
}

func ts(_ t: Double) -> String {
    let ms = Int((t * 1000).rounded())
    return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
}

func writeSRT(_ cues: [Cue], to path: String) {
    var out = ""
    for (i, c) in cues.enumerated() { out += "\(i + 1)\n\(ts(c.start)) --> \(ts(c.end))\n\(c.text)\n\n" }
    do { try out.write(toFile: path, atomically: true, encoding: .utf8) } catch { fail("cannot write \(path): \(error)") }
}

@main struct SubTrans {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        func opt(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            defer { args.removeSubrange(i...i + 1) }
            return args[i + 1]
        }
        let target = opt("--to") ?? "en"
        let trackArg = opt("--track")
        let keepSource = opt("--keep-source")
        let from = Double(opt("--from") ?? "0") ?? 0
        guard args.count == 2 else {
            fail("usage: subtrans <video> <out.srt> [--to en] [--track N] [--from SECONDS] [--keep-source src.srt]")
        }
        let (video, outPath) = (args[0], args[1])
        if FileManager.default.fileExists(atPath: outPath + ".done") { print("cached \(outPath)"); return }

        // pick the bitmap subtitle track
        let info = try? JSONSerialization.jsonObject(with: run(["-v", "error", "-select_streams", "s", "-show_streams",
                                                               "-show_data", "-of", "json", video])) as? [String: Any]
        let streams = (info?["streams"] as? [[String: Any]] ?? []).filter { ($0["codec_name"] as? String) == "dvd_subtitle" }
        guard !streams.isEmpty else { fail("no DVD bitmap subtitle track") }
        let n = Int(trackArg ?? "0") ?? 0
        guard n < streams.count else { fail("track \(n) not found (\(streams.count) bitmap tracks)") }
        let st = streams[n]
        let srcLang = ((st["tags"] as? [String: Any])?["language"] as? String) ?? "spa"
        let iso = ["spa": "es", "eng": "en", "fre": "fr", "fra": "fr", "ger": "de", "deu": "de", "ita": "it", "por": "pt",
                   "jpn": "ja", "chi": "zh", "zho": "zh", "kor": "ko", "rus": "ru", "dut": "nl", "nld": "nl"][srcLang] ?? srcLang
        let extra = String(decoding: hexdump(st["extradata"] as? String ?? ""), as: UTF8.self)
        var palette: [(Double, Double, Double)] = (0..<16).map { _ in (1.0, 1.0, 1.0) }
        if let line = extra.split(separator: "\n").first(where: { $0.hasPrefix("palette:") }) {
            palette = line.dropFirst(8).split(separator: ",").compactMap {
                guard let v = Int($0.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
                return (Double(v >> 16 & 255) / 255, Double(v >> 8 & 255) / 255, Double(v & 255) / 255)
            }
        }

        let pk = try? JSONSerialization.jsonObject(with: run(["-v", "error", "-select_streams", "s:\(n)", "-show_packets",
                                                             "-show_data", "-of", "json", video])) as? [String: Any]
        let packets = pk?["packets"] as? [[String: Any]] ?? []
        log("\(packets.count) subtitle images (\(iso) -> \(target)), starting at \(Int(from))s")

        // Work in playback order from the current position, then wrap around to the start.
        // The .srt is rewritten after every line, so the player can reload it while we're still going.
        let pts = packets.map { Double($0["pts_time"] as? String ?? "") ?? 0 }
        let order = packets.indices.filter { pts[$0] + 10 >= from } + packets.indices.filter { pts[$0] + 10 < from }
        let session = TranslationSession(installedSource: Locale.Language(identifier: iso),
                                         target: Locale.Language(identifier: target))
        var done: [Int: Cue] = [:], source: [Int: Cue] = [:]
        func flush() {
            writeSRT(done.keys.sorted().map { done[$0]! }, to: outPath)
            if let keepSource { writeSRT(source.keys.sorted().map { source[$0]! }, to: keepSource) }
        }
        for i in order {
            let p = packets[i]
            let bytes = hexdump(p["data"] as? String ?? "")
            guard let spu = parseSPU(bytes), let img = render(decodeRLE(bytes, spu: spu), spu: spu, palette: palette) else { continue }
            // drop stray glyphs Vision sometimes reads from outline specks
            let text = ocr(img, lang: iso).split(separator: "\n")
                .filter { $0.filter(\.isLetter).count >= 2 || $0.contains(where: \.isNumber) }.joined(separator: "\n")
            if text.isEmpty { continue }
            let nextPts = i + 1 < packets.count ? pts[i + 1] : nil
            let dur = Double(p["duration_time"] as? String ?? "")
            let end = spu.end.map { pts[i] + $0 } ?? dur.map { pts[i] + $0 } ?? nextPts ?? pts[i] + 3
            var cue = Cue(start: pts[i] + spu.start, end: max(end, pts[i] + spu.start + 0.5), text: text)
            source[i] = cue
            do {
                cue.text = wrap(try await session.translate(text.replacingOccurrences(of: "\n", with: " ")).targetText)
            } catch {
                fail("translation failed (\(iso)->\(target)): \(error). Install the language in System Settings > General > Language & Region > Translation Languages.")
            }
            done[i] = cue
            flush()
            print("progress \(done.count)/\(packets.count) at \(Int(cue.start))s")
            fflush(stdout)
        }
        flush()
        FileManager.default.createFile(atPath: outPath + ".done", contents: nil)
        log("done: \(done.count) lines")
        print("done \(outPath)")
    }
}
