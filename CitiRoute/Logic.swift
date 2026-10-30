import Foundation
import CoreLocation

struct Addr: Equatable { var street, nr, plz, ort: String
    var description: String { "\(street) \(nr), \(plz) \(ort)" } }

struct Stop: Codable, Identifiable, Equatable {
    var id = UUID()
    var street: String; var nr: String; var plz: String; var ort: String
    var count = 1
    var lat: Double?; var lng: Double?
    var done = false
}

final class Store: ObservableObject {
    @Published var stops: [Stop] = [] { didSet { save() } }
    init() {
        if let d = UserDefaults.standard.data(forKey: "stops"), let s = try? JSONDecoder().decode([Stop].self, from: d) { stops = s }
    }
    func save() { if let d = try? JSONEncoder().encode(stops) { UserDefaults.standard.set(d, forKey: "stops") } }
    private func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
    func add(_ a: Addr) {
        if let i = stops.firstIndex(where: { norm($0.street) == norm(a.street) && $0.nr == a.nr && $0.plz == a.plz }) {
            stops[i].count += 1; stops[i].done = false
        } else { stops.append(Stop(street: a.street, nr: a.nr, plz: a.plz, ort: a.ort)) }
    }
}

enum Parser {
    static let plzRx = try! NSRegularExpression(pattern: #"^(?:D[-\s]?)?(\d{5})\s+(\p{L}[\p{L}\s.\-/()]{1,40})$"#)
    static let streetRx = try! NSRegularExpression(pattern: #"^(\p{L}[\p{L}\s.\-']{2,40}?)\s+(\d{1,4}\s?[A-Za-z]?(?:\s?[-/]\s?\d{1,4}[A-Za-z]?)?)$"#)
    static let badRx = try! NSRegularExpression(pattern: #"postfach|\btel\b|\bfax\b|seite|kunden|datum|iban|www|@"#, options: .caseInsensitive)

    static func groups(_ rx: NSRegularExpression, _ s: String) -> [String]? {
        let r = NSRange(s.startIndex..., in: s)
        guard let m = rx.firstMatch(in: s, range: r), m.range == r else { return nil }
        return (1..<m.numberOfRanges).compactMap { Range(m.range(at: $0), in: s).map { String(s[$0]) } }
    }
    static func clean(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:"))
    }
    static func street(_ l: String) -> (String, String)? {
        guard let g = groups(streetRx, l), g.count == 2 else { return nil }
        return (g[0].trimmingCharacters(in: .whitespaces), g[1].replacingOccurrences(of: " ", with: "").uppercased())
    }
    /// OCR-Zeilen von oben nach unten -> Empfängeradresse (unterstes Straße+PLZ-Paar)
    static func find(_ lines: [String], defPlz: String, defOrt: String) -> Addr? {
        let ls = lines.map(clean).filter { $0.count >= 4 && badRx.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) == nil }
        for i in ls.indices.reversed() {
            guard let p = groups(plzRx, ls[i]), p.count == 2 else { continue }
            for j in [i - 1, i - 2] where j >= 0 {
                if let s = street(ls[j]) { return Addr(street: s.0, nr: s.1, plz: p[0], ort: p[1].trimmingCharacters(in: .whitespaces)) }
            }
        }
        if !defPlz.isEmpty {
            for i in ls.indices.reversed() { if let s = street(ls[i]) { return Addr(street: s.0, nr: s.1, plz: defPlz, ort: defOrt) } }
        }
        return nil
    }
    static func fromText(_ t: String, defPlz: String, defOrt: String) -> Addr? {
        find(t.components(separatedBy: CharacterSet(charactersIn: ",\n")), defPlz: defPlz, defOrt: defOrt)
    }
}

enum Geo {
    static func find(_ s: Stop) async -> CLLocationCoordinate2D? {
        let q = "\(s.street) \(s.nr), \(s.plz) \(s.ort), Deutschland"
        return try? await CLGeocoder().geocodeAddressString(q).first?.location?.coordinate
    }
}

enum Optimizer {
    static func dist(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
    /// Nearest-Neighbor ab Startpunkt + 2-opt. Stopps ohne Koordinaten kommen ans Ende.
    static func order(_ list: [Stop], start: CLLocationCoordinate2D?) -> [Stop] {
        let ok = list.filter { $0.lat != nil && $0.lng != nil }
        let miss = list.filter { $0.lat == nil || $0.lng == nil }
        if ok.count < 2 { return ok + miss }
        var pts = ok.map { CLLocationCoordinate2D(latitude: $0.lat!, longitude: $0.lng!) }
        var s0 = start
        if s0 == nil {
            let c = CLLocationCoordinate2D(latitude: pts.map { $0.latitude }.reduce(0, +) / Double(pts.count), longitude: pts.map { $0.longitude }.reduce(0, +) / Double(pts.count))
            s0 = pts.max { dist(c, $0) < dist(c, $1) }
        }
        pts.insert(s0!, at: 0)
        let n = pts.count
        func d(_ i: Int, _ j: Int) -> Double { dist(pts[i], pts[j]) }
        var path = [Int](repeating: 0, count: n); var used = [Bool](repeating: false, count: n); used[0] = true
        for k in 1..<n {
            var best = -1; var bd = Double.greatestFiniteMagnitude
            for j in 1..<n where !used[j] { let x = d(path[k - 1], j); if x < bd { bd = x; best = j } }
            path[k] = best; used[best] = true
        }
        var improved = true; var guardN = 0
        while improved && guardN < 50 {
            improved = false; guardN += 1
            if n > 2 { for i in 1..<(n - 1) { for k in (i + 1)..<n {
                let a = path[i - 1], b = path[i], c = path[k]
                let nx = k + 1 < n ? path[k + 1] : -1
                let delta = d(a, c) + (nx >= 0 ? d(b, nx) : 0) - d(a, b) - (nx >= 0 ? d(c, nx) : 0)
                if delta < -1 { path[i...k].reverse(); improved = true }
            } } }
        }
        return (1..<n).map { ok[path[$0] - 1] } + miss
    }
}

final class Loc: NSObject, CLLocationManagerDelegate {
    private let m = CLLocationManager()
    private var cont: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    override init() { super.init(); m.delegate = self }
    @MainActor func get() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { c in
            cont = c
            switch m.authorizationStatus {
            case .notDetermined: m.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
            default: finish(nil)
            }
        }
    }
    private func finish(_ c: CLLocationCoordinate2D?) { cont?.resume(returning: c); cont = nil }
    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        guard cont != nil else { return }
        switch m.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: m.requestLocation()
        case .notDetermined: break
        default: finish(nil)
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations l: [CLLocation]) { finish(l.last?.coordinate) }
    func locationManager(_ m: CLLocationManager, didFailWithError e: Error) { finish(nil) }
}
