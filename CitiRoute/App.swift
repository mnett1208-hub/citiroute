import SwiftUI
import VisionKit
import MapKit
import AudioToolbox

let yellow = Color(red: 1, green: 0.769, blue: 0)
let ink = Color(red: 0.106, green: 0.106, blue: 0.106)

@main struct CitiRouteApp: App {
    @StateObject var store = Store()
    var body: some Scene { WindowGroup { Root().environmentObject(store) } }
}

struct Root: View {
    @AppStorage("name") private var name = ""
    @State private var splash = true
    var body: some View {
        ZStack {
            if splash { SplashView().transition(.opacity) }
            else if name.isEmpty { Onboarding() }
            else { MainTabs() }
        }
        .animation(.easeInOut(duration: 0.5), value: splash)
        .task { try? await Task.sleep(nanoseconds: 2_200_000_000); splash = false }
    }
}

struct SplashView: View {
    @State private var go = false
    var body: some View {
        ZStack {
            yellow.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "envelope.fill").font(.system(size: 80)).foregroundColor(ink)
                    .scaleEffect(go ? 1 : 0.3).opacity(go ? 1 : 0)
                Text("CitiRoute").font(.system(size: 38, weight: .heavy)).foregroundColor(ink)
                Text("Scannen. Sortieren. Losfahren.").foregroundColor(ink)
                ProgressView(value: go ? 1.0 : 0.0).tint(ink).frame(width: 150).padding(.top, 20)
                    .animation(.linear(duration: 1.9), value: go)
            }
        }.onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) { go = true } }
    }
}

struct Onboarding: View {
    @AppStorage("name") private var name = ""
    @AppStorage("plz") private var plz = ""
    @AppStorage("ort") private var ort = ""
    @State private var n = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text("👋 Willkommen!").font(.system(size: 30, weight: .bold))
            Text("Richte CitiRoute einmalig ein.").foregroundColor(.gray)
            TextField("Wie heißt du?", text: $n).textFieldStyle(.roundedBorder)
            TextField("Standard-PLZ (optional)", text: $plz).textFieldStyle(.roundedBorder).keyboardType(.numberPad)
            TextField("Standard-Ort (optional)", text: $ort).textFieldStyle(.roundedBorder)
            Text("Wird ergänzt, wenn auf dem Brief keine PLZ erkannt wird.").font(.caption).foregroundColor(.gray)
            Button { name = n.trimmingCharacters(in: .whitespaces) } label: { Text("Los geht’s 🚀").bold().frame(maxWidth: .infinity).padding(.vertical, 6) }
                .buttonStyle(.borderedProminent).tint(yellow).foregroundColor(ink).disabled(n.trimmingCharacters(in: .whitespaces).isEmpty)
            Spacer()
        }.padding(24)
    }
}

struct MainTabs: View {
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            ScanView(onDone: { tab = 1 }).tabItem { Label("Scan", systemImage: "camera.viewfinder") }.tag(0)
            RouteView().tabItem { Label("Route", systemImage: "map") }.tag(1)
            SettingsView().tabItem { Label("Einstellungen", systemImage: "gearshape") }.tag(2)
        }.tint(ink)
    }
}

// MARK: Scan

struct ScannerView: UIViewControllerRepresentable {
    var onLines: ([String]) -> Void
    func makeCoordinator() -> Coord { Coord(onLines) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.text()], qualityLevel: .accurate, recognizesMultipleItems: true,
                                           isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true, isGuidanceEnabled: false, isHighlightingEnabled: true)
        context.coordinator.start(vc)
        return vc
    }
    func updateUIViewController(_ vc: DataScannerViewController, context: Context) { context.coordinator.cb = onLines }
    static func dismantleUIViewController(_ vc: DataScannerViewController, coordinator: Coord) { coordinator.stop(vc) }

    final class Coord {
        var cb: ([String]) -> Void
        var timer: Timer?
        init(_ cb: @escaping ([String]) -> Void) { self.cb = cb }
        func start(_ vc: DataScannerViewController) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { try? vc.startScanning() }
            timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self, weak vc] _ in
                guard let self = self, let vc = vc, vc.isScanning else { return }
                var items: [(CGFloat, String)] = []
                for it in vc.recognizedItems { if case .text(let t) = it { items.append((t.bounds.topLeft.y, t.transcript)) } }
                self.cb(items.sorted { $0.0 < $1.0 }.flatMap { $0.1.components(separatedBy: "\n") })
            }
        }
        func stop(_ vc: DataScannerViewController) { timer?.invalidate(); vc.stopScanning() }
    }
}

final class Hold { var last: Addr?; var shown: Addr?; var lastAdded: Addr?; var hits = 0; var misses = 0 }

struct ScanView: View {
    @EnvironmentObject var store: Store
    @AppStorage("plz") private var plz = ""
    @AppStorage("ort") private var ort = ""
    var onDone: () -> Void
    @State private var text = ""
    @State private var msg = ""
    @State private var auto = false
    @State private var hold = Hold()

    var body: some View {
        ZStack(alignment: .bottom) {
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                ScannerView(onLines: frame).ignoresSafeArea(edges: .top)
            } else {
                Text("Kamera-Scan nicht verfügbar.\nPrüfe unter Einstellungen → CitiRoute den Kamerazugriff.\nAdressen kannst du unten auch eintippen.")
                    .multilineTextAlignment(.center).padding().frame(maxHeight: .infinity)
            }
            VStack(spacing: 10) {
                HStack {
                    Text("📮 \(store.stops.reduce(0) { $0 + $1.count }) Sendungen").bold()
                    Spacer(); Text("Auto"); Toggle("", isOn: $auto).labelsHidden().tint(yellow)
                }
                if !msg.isEmpty { Text(msg).foregroundColor(.green).bold() }
                TextField(text.isEmpty ? "Suche Adresse … (oder tippen)" : "Erkannte Adresse (korrigierbar)", text: $text)
                    .textFieldStyle(.roundedBorder).submitLabel(.done)
                HStack {
                    Button { addManual() } label: { Text("✓ Hinzufügen").bold().frame(maxWidth: .infinity).padding(.vertical, 4) }
                        .buttonStyle(.borderedProminent).tint(yellow).foregroundColor(ink).disabled(text.isEmpty)
                    if !store.stops.isEmpty { Button("Route →", action: onDone).buttonStyle(.bordered).tint(ink) }
                }
            }.padding().background(.regularMaterial).cornerRadius(18).padding(10)
        }
    }

    func commit(_ a: Addr) {
        store.add(a); hold.lastAdded = a; text = ""
        msg = "✓ \(a.street) \(a.nr) hinzugefügt"
        AudioServicesPlaySystemSound(1057)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    func addManual() {
        if let a = Parser.fromText(text, defPlz: plz, defOrt: ort) { commit(a) } else { msg = "Nicht lesbar. Format: Straße 12, 12345 Ort" }
    }
    func frame(_ lines: [String]) {
        guard let a = Parser.find(lines, defPlz: plz, defOrt: ort) else {
            hold.misses += 1
            if hold.misses >= 3 { hold.last = nil; hold.hits = 0; hold.shown = nil; hold.lastAdded = nil }
            return
        }
        hold.misses = 0
        if a == hold.last { hold.hits += 1 } else { hold.last = a; hold.hits = 1 }
        if hold.hits >= 2 {
            if a != hold.shown { hold.shown = a; text = a.description; msg = "" }
            if auto && a != hold.lastAdded { commit(a) }
        }
    }
}

// MARK: Route

final class NumAnn: MKPointAnnotation { var num = 0; var done = false }

struct RouteMap: UIViewRepresentable {
    var stops: [Stop]
    func makeCoordinator() -> Coord { Coord() }
    func makeUIView(context: Context) -> MKMapView { let m = MKMapView(); m.delegate = context.coordinator; m.showsUserLocation = true; return m }
    func updateUIView(_ m: MKMapView, context: Context) {
        m.removeAnnotations(m.annotations.filter { $0 is NumAnn }); m.removeOverlays(m.overlays)
        var pts: [CLLocationCoordinate2D] = []
        for (i, s) in stops.enumerated() {
            guard let la = s.lat, let lo = s.lng else { continue }
            let a = NumAnn(); a.coordinate = CLLocationCoordinate2D(latitude: la, longitude: lo)
            a.title = "\(i + 1). \(s.street) \(s.nr)"; a.num = i + 1; a.done = s.done
            m.addAnnotation(a); pts.append(a.coordinate)
        }
        if pts.count > 1 { m.addOverlay(MKPolyline(coordinates: pts, count: pts.count)) }
        if pts.count != context.coordinator.sig && !pts.isEmpty {
            context.coordinator.sig = pts.count
            var r = MKMapRect.null
            for p in pts { r = r.union(MKMapRect(origin: MKMapPoint(p), size: MKMapSize(width: 1, height: 1))) }
            m.setVisibleMapRect(r, edgePadding: UIEdgeInsets(top: 60, left: 40, bottom: 60, right: 40), animated: true)
        }
    }
    final class Coord: NSObject, MKMapViewDelegate {
        var sig = -1
        func mapView(_ m: MKMapView, viewFor a: MKAnnotation) -> MKAnnotationView? {
            guard let n = a as? NumAnn else { return nil }
            let v = MKMarkerAnnotationView(annotation: n, reuseIdentifier: nil)
            v.glyphText = "\(n.num)"; v.glyphTintColor = .black
            v.markerTintColor = n.done ? .systemGreen : UIColor(red: 1, green: 0.77, blue: 0, alpha: 1)
            return v
        }
        func mapView(_ m: MKMapView, rendererFor o: MKOverlay) -> MKOverlayRenderer {
            let r = MKPolylineRenderer(overlay: o); r.strokeColor = .systemBlue; r.lineWidth = 4; return r
        }
    }
}

let locator = Loc()

struct RouteView: View {
    @EnvironmentObject var store: Store
    @State private var busy = false
    @State private var info = ""
    var next: Stop? { store.stops.first { !$0.done && $0.lat != nil } }

    var body: some View {
        VStack(spacing: 0) {
            RouteMap(stops: store.stops).frame(height: 300)
            if busy { ProgressView().padding(.top, 6) }
            if !info.isEmpty { Text(info).font(.footnote).padding(.top, 4) }
            HStack {
                Button { Task { await optimize() } } label: { Text("🧭 Optimieren").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(yellow).foregroundColor(ink).disabled(busy || store.stops.isEmpty)
                Button { if let n = next { navigate(n) } } label: { Text("▶ Navi").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(ink).disabled(next == nil)
                Button { googleRoute(store.stops.filter { !$0.done }) } label: { Text("🗺 Google").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(ink).disabled(next == nil)
            }.padding(10)
            if store.stops.isEmpty { Spacer(); Text("Noch keine Sendungen.\nErst im Tab „Scan“ erfassen.").multilineTextAlignment(.center).foregroundColor(.gray); Spacer() }
            else {
                List {
                    ForEach(Array(store.stops.enumerated()), id: \.element.id) { i, s in
                        HStack(spacing: 12) {
                            Text(s.done ? "✓" : "\(i + 1)").bold().frame(width: 30, height: 30)
                                .background(s.done ? Color.green : yellow).foregroundColor(s.done ? .white : ink).clipShape(Circle())
                            VStack(alignment: .leading) {
                                Text("\(s.street) \(s.nr)" + (s.count > 1 ? "  ×\(s.count)" : "")).fontWeight(.semibold)
                                Text(s.lat == nil ? "⚠ \(s.plz) \(s.ort) · noch keine Position" : "\(s.plz) \(s.ort)").font(.caption).foregroundColor(.gray)
                            }
                        }.contentShape(Rectangle()).onTapGesture { store.stops[i].done.toggle() }
                    }.onDelete { store.stops.remove(atOffsets: $0) }
                }.listStyle(.plain)
            }
        }
    }

    @MainActor func optimize() async {
        busy = true; info = "Standort wird ermittelt …"
        let loc = await locator.get()
        var n = 0
        for i in store.stops.indices where store.stops[i].lat == nil {
            n += 1; info = "Adresse \(n) wird gesucht …"
            if let c = await Geo.find(store.stops[i]) { store.stops[i].lat = c.latitude; store.stops[i].lng = c.longitude }
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        let sorted = Optimizer.order(store.stops.filter { !$0.done }, start: loc)
        store.stops = store.stops.filter { $0.done } + sorted
        let miss = store.stops.filter { $0.lat == nil }.count
        info = miss > 0 ? "⚠ \(miss) Adresse(n) nicht gefunden – bitte prüfen" : "✓ Route optimiert"
        busy = false
    }

    func navigate(_ s: Stop) {
        guard let la = s.lat, let lo = s.lng else { return }
        let it = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: la, longitude: lo)))
        it.name = "\(s.street) \(s.nr)"
        it.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
    }
    func googleRoute(_ list: [Stop]) {
        let l = Array(list.filter { $0.lat != nil && $0.lng != nil }.prefix(10))
        guard let last = l.last else { return }
        let pt = { (s: Stop) in "\(s.lat!),\(s.lng!)" }
        var url = "https://www.google.com/maps/dir/?api=1&travelmode=driving&destination=\(pt(last))"
        let wp = l.dropLast().map(pt).joined(separator: "|")
        if !wp.isEmpty, let e = wp.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { url += "&waypoints=\(e)" }
        if let u = URL(string: url) { UIApplication.shared.open(u) }
    }
}

// MARK: Einstellungen

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @AppStorage("name") private var name = ""
    @AppStorage("plz") private var plz = ""
    @AppStorage("ort") private var ort = ""
    @State private var ask = false
    var body: some View {
        NavigationView {
            Form {
                Section("Profil") {
                    TextField("Name", text: $name)
                    TextField("Standard-PLZ", text: $plz).keyboardType(.numberPad)
                    TextField("Standard-Ort", text: $ort)
                }
                Section {
                    Button("Alle Haken zurücksetzen") { for i in store.stops.indices { store.stops[i].done = false } }
                    Button("Alle Sendungen löschen", role: .destructive) { ask = true }
                }
            }.navigationTitle("Einstellungen")
        }.alert("Alles löschen?", isPresented: $ask) {
            Button("Löschen", role: .destructive) { store.stops = [] }
            Button("Abbrechen", role: .cancel) {}
        }
    }
}
