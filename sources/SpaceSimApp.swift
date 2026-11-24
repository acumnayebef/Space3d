import SwiftUI
import SceneKit
import simd

@main
struct SpaceSimApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .ignoresSafeArea()
                .statusBarHidden(true)
        }
    }
}

final class SpaceSimulationController: ObservableObject {
    let scene = SCNScene()
    let shipNode = SCNNode()
    let cameraNode = SCNNode()
    let sunLightNode = SCNNode()

    // 64-битная позиция корабля в метрах (старт на орбите Земли, высота 600 км)
    var shipPositionMeters = SIMD3<Double>(-UniverseCatalog.au, 0, 6_971_000)
    var shipOrientation = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)

    @Published var speedIndex: Int = 0
    @Published var throttle: Double = 0.0
    @Published var targetBody: CelestialBody = UniverseCatalog.bodies[3] // Земля
    @Published var distanceText: String = "600 км"
    @Published var etaText: String = "Стоп"
    @Published var isThirdPerson: Bool = true

    // Реальные ступени скорости FSD (от маневровой до межзвёздной)
    let speedSteps: [(label: String, mps: Double)] = [
        ("1.5 км/с", 1_500),
        ("11.2 км/с", 11_200),
        ("100 км/с", 100_000),
        ("10 000 км/с", 10_000_000),
        ("1 c", 299_792_458),
        ("100 c", 29_979_245_800),
        ("10 000 c", 2_997_924_580_000),
        ("500 000 c", 149_896_229_000_000)
    ]

    private var bodyNodes: [String: SCNNode] = [:]
    private var lastUpdateTime: TimeInterval = 0

    init() {
        setupScene()
    }

    private func setupScene() {
        scene.background.contents = UIColor.black

        // Освещение от Солнца
        let sunLight = SCNLight()
        sunLight.type = .omni
        sunLight.intensity = 2200
        sunLight.attenuationEndDistance = 1e12
        sunLightNode.light = sunLight
        scene.rootNode.addChildNode(sunLightNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 90
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Создаём 3D-звездолёт (многополигональный корпус + сопла)
        buildShipMesh()
        scene.rootNode.addChildNode(shipNode)

        // Камера
        let cam = SCNCamera()
        cam.zNear = 0.5
        cam.zFar = 1_000_000
        cam.fieldOfView = 65
        cameraNode.camera = cam
        shipNode.addChildNode(cameraNode)
        updateCameraMode()

        // Звёздный фон (3000 процедурных звёзд на небесной сфере)
        buildStarfield()

        // Небесные тела из реального каталога
        for body in UniverseCatalog.bodies {
            let sphere = SCNSphere(radius: 1.0)
            sphere.segmentCount = 64
            let mat = SCNMaterial()
            mat.diffuse.contents = uiColor(from: body.colorHex)
            if body.isStar {
                mat.emission.contents = uiColor(from: body.colorHex)
            } else {
                mat.roughness.contents = 0.75
                mat.metalness.contents = 0.05
            }
            sphere.materials = [mat]

            let node = SCNNode(geometry: sphere)
            scene.rootNode.addChildNode(node)
            bodyNodes[body.id] = node
        }
    }

    private func buildShipMesh() {
        // Основной клиновидный корпус в стиле Elite Dangerous
        let hull = SCNBox(width: 2.8, height: 0.7, length: 6.5, chamferRadius: 0.25)
        let hullMat = SCNMaterial()
        hullMat.diffuse.contents = UIColor(red: 0.16, green: 0.20, blue: 0.27, alpha: 1.0)
        hullMat.metalness.contents = 0.85
        hullMat.roughness.contents = 0.3
        hull.materials = [hullMat]
        let hullNode = SCNNode(geometry: hull)
        shipNode.addChildNode(hullNode)

        // Крылья
        let wings = SCNBox(width: 7.4, height: 0.18, length: 3.2, chamferRadius: 0.08)
        wings.materials = [hullMat]
        let wingsNode = SCNNode(geometry: wings)
        wingsNode.position = SCNVector3(0, -0.1, 1.1)
        shipNode.addChildNode(wingsNode)

        // Фонарь кабины
        let canopy = SCNSphere(radius: 0.65)
        let glassMat = SCNMaterial()
        glassMat.diffuse.contents = UIColor(red: 0.05, green: 0.55, blue: 0.95, alpha: 0.85)
        glassMat.metalness.contents = 0.95
        glassMat.roughness.contents = 0.1
        canopy.materials = [glassMat]
        let canopyNode = SCNNode(geometry: canopy)
        canopyNode.scale = SCNVector3(1.1, 0.55, 2.1)
        canopyNode.position = SCNVector3(0, 0.38, -1.0)
        shipNode.addChildNode(canopyNode)

        // Двигатели
        for xOffset in [-1.1, 1.1] {
            let thruster = SCNCylinder(radius: 0.32, height: 0.6)
            let glowMat = SCNMaterial()
            glowMat.emission.contents = UIColor(red: 0.2, green: 0.8, blue: 1.0, alpha: 1.0)
            thruster.materials = [glowMat]
            let tNode = SCNNode(geometry: thruster)
            tNode.eulerAngles.x = .pi / 2
            tNode.position = SCNVector3(Float(xOffset), 0, 3.2)
            shipNode.addChildNode(tNode)
        }
    }

    private func buildStarfield() {
        let starSphere = SCNSphere(radius: 800_000)
        starSphere.segmentCount = 32
        let mat = SCNMaterial()
        mat.isDoubleSided = true
        mat.emission.contents = generateStarTexture()
        starSphere.materials = [mat]
        let bgNode = SCNNode(geometry: starSphere)
        shipNode.addChildNode(bgNode)
    }

    private func generateStarTexture() -> UIImage {
        let size = CGSize(width: 2048, height: 1024)
        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        for i in 0..<4500 {
            let x = CGFloat((i * 73856093) % 2048)
            let y = CGFloat((i * 19349663) % 1024)
            let r = CGFloat((i % 3) + 1) * 0.7
            let alpha = CGFloat((i % 70) + 30) / 100.0
            ctx.setFillColor(UIColor(white: 1.0, alpha: alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
        }
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    func updateCameraMode() {
        if isThirdPerson {
            cameraNode.position = SCNVector3(0, 3.2, 13.5)
            cameraNode.eulerAngles = SCNVector3(-0.14, 0, 0)
        } else {
            cameraNode.position = SCNVector3(0, 0.55, -1.6)
            cameraNode.eulerAngles = SCNVector3(0, 0, 0)
        }
    }

    func rotateShip(yawDelta: Double, pitchDelta: Double) {
        let qYaw = simd_quatd(angle: -yawDelta, axis: SIMD3(0, 1, 0))
        let qPitch = simd_quatd(angle: -pitchDelta, axis: SIMD3(1, 0, 0))
        shipOrientation = simd_normalize(shipOrientation * qYaw * qPitch)
        shipNode.simdOrientation = simd_quatf(
            ix: Float(shipOrientation.imag.x),
            iy: Float(shipOrientation.imag.y),
            iz: Float(shipOrientation.imag.z),
            r: Float(shipOrientation.real)
        )
    }

    func alignToTarget() {
        let dir = simd_normalize(targetBody.positionMeters - shipPositionMeters)
        let forward = SIMD3<Double>(0, 0, -1)
        let dot = simd_dot(forward, dir)
        if dot < -0.9999 {
            shipOrientation = simd_quatd(angle: .pi, axis: SIMD3(0, 1, 0))
        } else {
            let axis = simd_normalize(simd_cross(forward, dir))
            shipOrientation = simd_quatd(angle: acos(max(-1.0, min(1.0, dot))), axis: axis)
        }
        rotateShip(yawDelta: 0, pitchDelta: 0)
    }

    /// Главный цикл физики 1:1 и Floating Origin
    func stepSimulation(currentTime: TimeInterval) {
        if lastUpdateTime == 0 { lastUpdateTime = currentTime }
        let dt = min(0.05, currentTime - lastUpdateTime)
        lastUpdateTime = currentTime

        let currentSpeed = speedSteps[speedIndex].mps * throttle
        let forwardVec = shipOrientation.act(SIMD3<Double>(0, 0, -1))
        shipPositionMeters += forwardVec * currentSpeed * dt

        // Плавающее начало координат: корабль всегда в (0,0,0), мир сдвигается относительно него
        for body in UniverseCatalog.bodies {
            guard let node = bodyNodes[body.id] else { continue }
            let rel = body.positionMeters - shipPositionMeters
            let dist = simd_length(rel)

            // Логарифмическое сжатие дальних дистанций для отображения в 32-битном z-буфере без потери масштаба 1:1
            let maxRenderDist = 450_000.0
            let scaleFactor = dist > maxRenderDist ? (maxRenderDist / dist) : 1.0
            let renderPos = rel * scaleFactor
            let renderRadius = max(0.35, body.radiusMeters * scaleFactor)

            node.simdPosition = SIMD3<Float>(Float(renderPos.x), Float(renderPos.y), Float(renderPos.z))
            node.simdScale = SIMD3<Float>(repeating: Float(renderRadius))

            if body.id == "sun" {
                sunLightNode.simdPosition = node.simdPosition
            }
        }

        // Телеметрия до выбранной цели
        let targetRel = targetBody.positionMeters - shipPositionMeters
        let surfaceDist = max(0, simd_length(targetRel) - targetBody.radiusMeters)
        DispatchQueue.main.async {
            self.distanceText = Self.formatDistance(surfaceDist)
            if currentSpeed > 1.0 {
                self.etaText = Self.formatTime(surfaceDist / currentSpeed)
            } else {
                self.etaText = "Стоп"
            }
        }
    }

    static func formatDistance(_ meters: Double) -> String {
        if meters < 1_000 { return String(format: "%.0f м", meters) }
        let km = meters / 1_000
        if km < 1_000_000 { return String(format: "%.1f тыс. км", km / 1_000) }
        let au = meters / UniverseCatalog.au
        if au < 10_000 { return String(format: "%.3f а.е.", au) }
        return String(format: "%.2f св. лет", meters / UniverseCatalog.ly)
    }

    static func formatTime(_ sec: Double) -> String {
        if sec < 60 { return String(format: "%.0f сек", sec) }
        if sec < 3600 { return String(format: "%.1f мин", sec / 60) }
        if sec < 86400 { return String(format: "%.1f ч", sec / 3600) }
        return String(format: "%.1f дн.", sec / 86400)
    }

    private func uiColor(from hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1.0
        )
    }
}

struct SceneViewContainer: UIViewRepresentable {
    @ObservedObject var sim: SpaceSimulationController

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = sim.scene
        view.delegate = context.coordinator
        view.isPlaying = true
        view.preferredFramesPerSecond = 60
        view.antialiasingMode = .multisampling2X

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        view.addGestureRecognizer(pan)
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(sim: sim) }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let sim: SpaceSimulationController
        init(sim: SpaceSimulationController) { self.sim = sim }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            sim.stepSimulation(currentTime: time)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            let t = gesture.translation(in: gesture.view)
            sim.rotateShip(yawDelta: Double(t.x) * 0.004, pitchDelta: Double(t.y) * 0.004)
            gesture.setTranslation(.zero, in: gesture.view)
        }
    }
}

struct ContentView: View {
    @StateObject private var sim = SpaceSimulationController()
    @State private var showCatalog = false

    var body: some View {
        ZStack {
            SceneViewContainer(sim: sim)

            VStack {
                // Компактная верхняя панель HUD
                HStack(spacing: 10) {
                    Button(action: { showCatalog.toggle() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "globe.americas.fill")
                            Text("\(sim.targetBody.name) • \(sim.distanceText)")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }

                    Text("ETA: \(sim.etaText)")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())

                    Spacer()

                    Button("На цель") { sim.alignToTarget() }
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(.blue.opacity(0.75))
                        .clipShape(Capsule())

                    Button(sim.isThirdPerson ? "1-е лицо" : "3-е лицо") {
                        sim.isThirdPerson.toggle()
                        sim.updateCameraMode()
                    }
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

                // Нижний блок управления тягой и ступенями FSD
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("ТЯГА: \(Int(sim.throttle * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                        Slider(value: $sim.throttle, in: 0...1)
                            .frame(width: 170)
                            .tint(.cyan)
                    }
                    .padding(10)
                    .background(.ultraThinMaterial)
                    .cornerRadius(14)

                    Spacer()

                    HStack(spacing: 8) {
                        Button("−") { sim.speedIndex = max(0, sim.speedIndex - 1) }
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())

                        Text(sim.speedSteps[sim.speedIndex].label)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .frame(minWidth: 92)

                        Button("+") { sim.speedIndex = min(sim.speedSteps.count - 1, sim.speedIndex + 1) }
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())

                        Button("СТОП") { sim.throttle = 0 }
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.red.opacity(0.75))
                            .clipShape(Capsule())
                    }
                    .foregroundColor(.white)
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }

            if showCatalog {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Астрономический каталог 1:1")
                            .font(.headline)
                        Spacer()
                        Button("Закрыть") { showCatalog = false }
                    }
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(UniverseCatalog.bodies) { body in
                                Button(action: {
                                    sim.targetBody = body
                                    showCatalog = false
                                }) {
                                    HStack {
                                        Text(body.name).bold()
                                        Spacer()
                                        Text(body.type).font(.caption).foregroundColor(.gray)
                                    }
                                    .padding(10)
                                    .background(Color.white.opacity(0.08))
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
                .foregroundColor(.white)
                .padding()
                .frame(maxWidth: 360, maxHeight: 280)
                .background(.ultraThickMaterial)
                .cornerRadius(16)
            }
        }
    }
}