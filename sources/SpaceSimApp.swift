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
    let thirdPersonMeshNode = SCNNode()
    let cockpitMeshNode = SCNNode()
    let cameraNode = SCNNode()
    let sunLightNode = SCNNode()
    var exhaustNodes: [SCNNode] = []

    // Старт на орбите Земли: виден терминатор, континенты, облака и Луна вдали
    var shipPositionMeters = SIMD3<Double>(-UniverseCatalog.au + 11_500_000, 3_500_000, 12_500_000)
    var shipOrientation = simd_quatd(angle: 0.65, axis: simd_normalize(SIMD3<Double>(-0.2, 1.0, 0.0)))

    @Published var speedIndex: Int = 0
    @Published var throttle: Double = 0.0
    @Published var targetBody: CelestialBody = UniverseCatalog.bodies[3]
    @Published var distanceText: String = "11.0 тыс. км"
    @Published var etaText: String = "Стоп"
    @Published var isThirdPerson: Bool = true

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
    private var cloudNodes: [String: SCNNode] = [:]
    private var lastUpdateTime: TimeInterval = 0

    init() {
        setupScene()
    }

    private func setupScene() {
        scene.background.contents = UIColor.black

        // Направленный солнечный свет без пересвета белым[span_13](start_span)[span_13](end_span)[span_14](start_span)[span_14](end_span)
        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.intensity = 1350
        sunLight.color = UIColor(red: 1.0, green: 0.98, blue: 0.94, alpha: 1.0)
        sunLightNode.light = sunLight
        scene.rootNode.addChildNode(sunLightNode)

        // Лёгкая подсветка ночной стороны
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 45
        ambient.color = UIColor(red: 0.12, green: 0.16, blue: 0.25, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // Корабль (3-е лицо) и кабина (1-е лицо)
        buildThirdPersonShip()
        buildFirstPersonCockpit()
        shipNode.addChildNode(thirdPersonMeshNode)
        shipNode.addChildNode(cockpitMeshNode)
        scene.rootNode.addChildNode(shipNode)

        let cam = SCNCamera()
        cam.zNear = 0.1
        cam.zFar = 1_200_000
        cam.fieldOfView = 62
        cameraNode.camera = cam
        shipNode.addChildNode(cameraNode)
        updateCameraMode()

        buildStarfield()
        buildCelestialBodies()
    }

    private func buildCelestialBodies() {
        for body in UniverseCatalog.bodies {
            let root = SCNNode()
            let sphere = SCNSphere(radius: 1.0)
            sphere.segmentCount = 96

            let mat = SCNMaterial()
            let tex = generatePlanetTexture(body: body)
            mat.diffuse.contents = tex

            if body.isStar {
                mat.emission.contents = tex
                mat.lightingModel = .constant
            } else {
                mat.lightingModel = .physicallyBased
                mat.roughness.contents = body.id == "earth" ? 0.55 : 0.88
                mat.metalness.contents = 0.02
            }
            sphere.materials = [mat]
            let planetMesh = SCNNode(geometry: sphere)
            root.addChildNode(planetMesh)

            // Слой облаков для планет с атмосферой
            if body.hasAtmosphere && !body.isStar {
                let cloudSphere = SCNSphere(radius: 1.012)
                cloudSphere.segmentCount = 72
                let cloudMat = SCNMaterial()
                cloudMat.diffuse.contents = generateCloudTexture(seed: body.id.hashValue)
                cloudMat.transparent.contents = cloudMat.diffuse.contents
                cloudMat.isDoubleSided = false
                cloudMat.writesToDepthBuffer = false
                cloudSphere.materials = [cloudMat]
                let cloudNode = SCNNode(geometry: cloudSphere)
                root.addChildNode(cloudNode)
                cloudNodes[body.id] = cloudNode

                // Свечение атмосферы по краю диска (Fresnel)
                let atmoSphere = SCNSphere(radius: 1.032)
                atmoSphere.segmentCount = 64
                let atmoMat = SCNMaterial()
                let atmoColor = body.id == "mars"
                    ? UIColor(red: 0.95, green: 0.52, blue: 0.30, alpha: 0.22)
                    : UIColor(red: 0.30, green: 0.65, blue: 1.0, alpha: 0.25)
                atmoMat.diffuse.contents = atmoColor
                atmoMat.emission.contents = atmoColor
                atmoMat.blendMode = .add
                atmoMat.cullMode = .front
                atmoSphere.materials = [atmoMat]
                root.addChildNode(SCNNode(geometry: atmoSphere))
            }

            // Кольца Сатурна / аккреционный диск ЧД
            if body.hasRings {
                let ring = SCNTube(innerRadius: 1.35, outerRadius: 2.35, height: 0.004)
                let ringMat = SCNMaterial()
                ringMat.diffuse.contents = generateRingTexture(isBlackHole: body.id == "sgr_a")
                if body.id == "sgr_a" {
                    ringMat.emission.contents = ringMat.diffuse.contents
                }
                ringMat.isDoubleSided = true
                ring.materials = [ringMat]
                let ringNode = SCNNode(geometry: ring)
                ringNode.eulerAngles = SCNVector3(0.42, 0.1, 0.25)
                root.addChildNode(ringNode)
            }

            scene.rootNode.addChildNode(root)
            bodyNodes[body.id] = root
        }
    }

    private func buildThirdPersonShip() {
        let hullMat = SCNMaterial()
        hullMat.lightingModel = .physicallyBased
        hullMat.diffuse.contents = UIColor(red: 0.18, green: 0.22, blue: 0.29, alpha: 1.0)
        hullMat.metalness.contents = 0.85
        hullMat.roughness.contents = 0.28

        let accentMat = SCNMaterial()
        accentMat.lightingModel = .physicallyBased
        accentMat.diffuse.contents = UIColor(red: 0.88, green: 0.36, blue: 0.12, alpha: 1.0)
        accentMat.metalness.contents = 0.4
        accentMat.roughness.contents = 0.4

        // Фюзеляж
        let hull = SCNBox(width: 2.4, height: 0.65, length: 6.8, chamferRadius: 0.22)
        hull.materials = [hullMat]
        thirdPersonMeshNode.addChildNode(SCNNode(geometry: hull))

        // Носовой обтекатель
        let nose = SCNPyramid(width: 2.3, height: 2.6, length: 0.62)
        nose.materials = [hullMat]
        let noseNode = SCNNode(geometry: nose)
        noseNode.eulerAngles.x = -.pi / 2
        noseNode.position = SCNVector3(0, 0, -3.4)
        thirdPersonMeshNode.addChildNode(noseNode)

        // Дельта-крылья с оранжевыми законцовками
        let wings = SCNBox(width: 7.6, height: 0.14, length: 3.1, chamferRadius: 0.06)
        wings.materials = [hullMat]
        let wingsNode = SCNNode(geometry: wings)
        wingsNode.position = SCNVector3(0, -0.08, 1.2)
        thirdPersonMeshNode.addChildNode(wingsNode)

        let stripe = SCNBox(width: 7.7, height: 0.16, length: 0.45, chamferRadius: 0.04)
        stripe.materials = [accentMat]
        let stripeNode = SCNNode(geometry: stripe)
        stripeNode.position = SCNVector3(0, -0.08, 2.1)
        thirdPersonMeshNode.addChildNode(stripeNode)

        // Фонарь кабины
        let canopy = SCNSphere(radius: 0.6)
        let glassMat = SCNMaterial()
        glassMat.lightingModel = .physicallyBased
        glassMat.diffuse.contents = UIColor(red: 0.04, green: 0.45, blue: 0.85, alpha: 0.9)
        glassMat.metalness.contents = 0.95
        glassMat.roughness.contents = 0.08
        canopy.materials = [glassMat]
        let canopyNode = SCNNode(geometry: canopy)
        canopyNode.scale = SCNVector3(1.05, 0.5, 2.0)
        canopyNode.position = SCNVector3(0, 0.36, -1.1)
        thirdPersonMeshNode.addChildNode(canopyNode)

        // 2 маршевых двигателя с плазменными струями
        exhaustNodes.removeAll()
        for xOffset in [-0.85, 0.85] {
            let nozzle = SCNCylinder(radius: 0.28, height: 0.5)
            nozzle.materials = [hullMat]
            let nNode = SCNNode(geometry: nozzle)
            nNode.eulerAngles.x = .pi / 2
            nNode.position = SCNVector3(Float(xOffset), 0, 3.45)
            thirdPersonMeshNode.addChildNode(nNode)

            let flame = SCNCone(topRadius: 0.02, bottomRadius: 0.24, height: 2.2)
            let flameMat = SCNMaterial()
            flameMat.emission.contents = UIColor(red: 0.25, green: 0.82, blue: 1.0, alpha: 0.95)
            flameMat.blendMode = .add
            flame.materials = [flameMat]
            let fNode = SCNNode(geometry: flame)
            fNode.eulerAngles.x = .pi / 2
            fNode.position = SCNVector3(Float(xOffset), 0, 4.6)
            thirdPersonMeshNode.addChildNode(fNode)
            exhaustNodes.append(fNode)
        }
    }

    private func buildFirstPersonCockpit() {
        let frameMat = SCNMaterial()
        frameMat.lightingModel = .physicallyBased
        frameMat.diffuse.contents = UIColor(red: 0.09, green: 0.11, blue: 0.15, alpha: 1.0)
        frameMat.metalness.contents = 0.8
        frameMat.roughness.contents = 0.35

        let neonMat = SCNMaterial()
        neonMat.emission.contents = UIColor(red: 0.0, green: 0.82, blue: 1.0, alpha: 1.0)

        // Нижняя наклонная торпеда кабины (не перекрывает центр экрана!)[span_15](start_span)[span_15](end_span)
        let dash = SCNBox(width: 2.2, height: 0.35, length: 0.7, chamferRadius: 0.05)
        dash.materials = [frameMat]
        let dashNode = SCNNode(geometry: dash)
        dashNode.position = SCNVector3(0, -0.56, -0.85)
        dashNode.eulerAngles.x = 0.28
        cockpitMeshNode.addChildNode(dashNode)

        // Неоновая окантовка приборной панели
        let trim = SCNBox(width: 1.85, height: 0.015, length: 0.02, chamferRadius: 0.005)
        trim.materials = [neonMat]
        let trimNode = SCNNode(geometry: trim)
        trimNode.position = SCNVector3(0, -0.39, -0.62)
        cockpitMeshNode.addChildNode(trimNode)

        // Левая и правая стойки фонаря кабины
        for side in [-1.0, 1.0] {
            let strut = SCNBox(width: 0.045, height: 1.15, length: 0.045, chamferRadius: 0.01)
            strut.materials = [frameMat]
            let sNode = SCNNode(geometry: strut)
            sNode.position = SCNVector3(Float(side * 0.72), 0.05, -0.75)
            sNode.eulerAngles = SCNVector3(0.22, 0, Float(side * 0.26))
            cockpitMeshNode.addChildNode(sNode)
        }

        // Верхняя перекладина фонаря
        let topBar = SCNBox(width: 1.35, height: 0.04, length: 0.04, chamferRadius: 0.01)
        topBar.materials = [frameMat]
        let topNode = SCNNode(geometry: topBar)
        topNode.position = SCNVector3(0, 0.56, -0.64)
        cockpitMeshNode.addChildNode(topNode)

        // Коллиматорный прицел в центре лобового стекла
        let crosshair = SCNTorus(ringRadius: 0.045, pipeRadius: 0.0025)
        crosshair.materials = [neonMat]
        let chNode = SCNNode(geometry: crosshair)
        chNode.eulerAngles.x = .pi / 2
        chNode.position = SCNVector3(0, 0.02, -0.95)
        cockpitMeshNode.addChildNode(chNode)
    }

    func updateCameraMode() {
        thirdPersonMeshNode.isHidden = !isThirdPerson
        cockpitMeshNode.isHidden = isThirdPerson
        if isThirdPerson {
            cameraNode.position = SCNVector3(0, 2.6, 12.5)
            cameraNode.eulerAngles = SCNVector3(-0.12, 0, 0)
        } else {
            cameraNode.position = SCNVector3(0, 0, 0)
            cameraNode.eulerAngles = SCNVector3(0, 0, 0)
        }
    }

    private func buildStarfield() {
        let starSphere = SCNSphere(radius: 950_000)
        starSphere.segmentCount = 48
        let mat = SCNMaterial()
        mat.isDoubleSided = true
        mat.lightingModel = .constant
        mat.emission.contents = generateStarTexture()
        starSphere.materials = [mat]
        let bgNode = SCNNode(geometry: starSphere)
        shipNode.addChildNode(bgNode)
    }

    private func generateStarTexture() -> UIImage {
        let w = 2048, h = 1024
        UIGraphicsBeginImageContextWithOptions(CGSize(width: w, height: h), true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }
        ctx.setFillColor(UIColor.black.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        // Полоса Млечного Пути
        for i in 0..<2500 {
            let x = CGFloat((i * 48271) % w)
            let spread = sin(Double(x) / Double(w) * .pi * 2.0) * 140.0
            let offset = Double((i * 16807) % 240) - 120.0
            let y = CGFloat(Double(h) * 0.5 + spread + offset * 0.65)
            ctx.setFillColor(UIColor(red: 0.65, green: 0.78, blue: 1.0, alpha: 0.08).cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: 3.5, height: 3.5))
        }

        // Яркие звёзды разного спектрального цвета
        let starColors: [UIColor] = [
            .white,
            UIColor(red: 0.75, green: 0.88, blue: 1.0, alpha: 1.0),
            UIColor(red: 1.0, green: 0.92, blue: 0.75, alpha: 1.0),
            UIColor(red: 1.0, green: 0.72, blue: 0.55, alpha: 1.0)
        ]
        for i in 0..<6000 {
            let x = CGFloat((i * 73856093) % w)
            let y = CGFloat((i * 19349663) % h)
            let r = (i % 14 == 0) ? CGFloat(2.1) : CGFloat(1.1)
            let alpha = CGFloat((i % 75) + 25) / 100.0
            ctx.setFillColor(starColors[i % starColors.count].withAlphaComponent(alpha).cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: r, height: r))
        }
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    private func generatePlanetTexture(body: CelestialBody) -> UIImage {
        let w = 512, h = 256
        UIGraphicsBeginImageContextWithOptions(CGSize(width: w, height: h), true, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }
        let c1 = uiColor(from: body.colorHex)
        let c2 = uiColor(from: body.secondaryHex)
        ctx.setFillColor(c1.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let seed = abs(body.id.hashValue)
        if body.id == "jupiter" || body.id == "saturn" || body.id == "uranus" || body.id == "neptune" {
            // Широтные облачные пояса газовых гигантов
            for row in 0..<32 {
                let y = CGFloat(row) * CGFloat(h) / 32.0
                let bandH = CGFloat(h) / 32.0 + 1
                let mix = ((row + seed) % 3 == 0) ? c2.withAlphaComponent(0.65) : c1.withAlphaComponent(0.75)
                ctx.setFillColor(mix.cgColor)
                ctx.fill(CGRect(x: 0, y: y, width: CGFloat(w), height: bandH))
            }
        } else {
            // Процедурные материки / кратеры / грануляция
            for i in 0..<180 {
                let cx = CGFloat(((i * 97 + seed) % w))
                let cy = CGFloat(((i * 53 + seed * 3) % (h - 36)) + 18)
                let rw = CGFloat(((i * 29) % 58) + 14)
                let rh = CGFloat(((i * 19) % 34) + 10)
                ctx.setFillColor(c2.withAlphaComponent(0.72).cgColor)
                ctx.fillEllipse(in: CGRect(x: cx - rw * 0.5, y: cy - rh * 0.5, width: rw, height: rh))
            }
            // Полярные ледяные шапки для Земли и Марса
            if body.id == "earth" || body.id == "mars" {
                ctx.setFillColor(UIColor(white: 0.96, alpha: 0.92).cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: w, height: 16))
                ctx.fill(CGRect(x: 0, y: h - 16, width: w, height: 16))
            }
        }
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    private func generateCloudTexture(seed: Int) -> UIImage {
        let w = 512, h = 256
        UIGraphicsBeginImageContextWithOptions(CGSize(width: w, height: h), false, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }
        ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        let s = abs(seed)
        for i in 0..<220 {
            let x = CGFloat((i * 131 + s) % w)
            let y = CGFloat((i * 71 + s) % h)
            let rw = CGFloat((i % 46) + 18)
            let rh = CGFloat((i % 14) + 6)
            ctx.setFillColor(UIColor(white: 1.0, alpha: 0.34).cgColor)
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: rw, height: rh))
        }
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
    }

    private func generateRingTexture(isBlackHole: Bool) -> UIImage {
        let size = 256
        UIGraphicsBeginImageContextWithOptions(CGSize(width: size, height: size), false, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return UIImage() }
        let center = CGPoint(x: size / 2, y: size / 2)
        for r in 65..<126 {
            if !isBlackHole && (r == 98 || r == 99 || r == 114) { continue } // Щель Кассини
            let alpha = isBlackHole ? CGFloat(126 - r) / 65.0 : CGFloat((r % 7) + 3) / 14.0
            let col = isBlackHole
                ? UIColor(red: 1.0, green: 0.62, blue: 0.18, alpha: alpha)
                : UIColor(red: 0.88, green: 0.79, blue: 0.60, alpha: alpha)
            ctx.setStrokeColor(col.cgColor)
            ctx.setLineWidth(1.2)
            ctx.addArc(center: center, radius: CGFloat(r), startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.strokePath()
        }
        let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return img
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

    func stepSimulation(currentTime: TimeInterval) {
        if lastUpdateTime == 0 { lastUpdateTime = currentTime }
        let dt = min(0.05, currentTime - lastUpdateTime)
        lastUpdateTime = currentTime

        let currentSpeed = speedSteps[speedIndex].mps * throttle
        let forwardVec = shipOrientation.act(SIMD3<Double>(0, 0, -1))
        shipPositionMeters += forwardVec * currentSpeed * dt

        // Анимация факелов двигателей от тяги
        let flameScale = Float(max(0.05, throttle * (1.0 + Double(speedIndex) * 0.25)))
        for fNode in exhaustNodes {
            fNode.scale = SCNVector3(1.0, flameScale, 1.0)
            fNode.isHidden = throttle <= 0.01
        }

        // Направление солнечного света из центра системы (0,0,0) к позиции корабля
        let sunDir = simd_normalize(shipPositionMeters)
        let fDir = SIMD3<Float>(Float(sunDir.x), Float(sunDir.y), Float(sunDir.z))
        sunLightNode.simdLook(at: fDir, up: SIMD3<Float>(0, 1, 0), localFront: SIMD3<Float>(0, 0, -1))

        // Floating Origin + логарифмическое масштабирование 1:1
        for body in UniverseCatalog.bodies {
            guard let node = bodyNodes[body.id] else { continue }
            let rel = body.positionMeters - shipPositionMeters
            let dist = simd_length(rel)

            let maxRenderDist = 450_000.0
            let scaleFactor = dist > maxRenderDist ? (maxRenderDist / dist) : 1.0
            let renderPos = rel * scaleFactor
            let renderRadius = max(0.35, body.radiusMeters * scaleFactor)

            node.simdPosition = SIMD3<Float>(Float(renderPos.x), Float(renderPos.y), Float(renderPos.z))
            node.simdScale = SIMD3<Float>(repeating: Float(renderRadius))

            if let cNode = cloudNodes[body.id] {
                cNode.eulerAngles.y += Float(dt * 0.015)
            }
        }

        let targetRel = targetBody.positionMeters - shipPositionMeters
        let surfaceDist = max(0, simd_length(targetRel) - targetBody.radiusMeters)
        DispatchQueue.main.async {
            self.distanceText = Self.formatDistance(surfaceDist)
            self.etaText = currentSpeed > 1.0 ? Self.formatTime(surfaceDist / currentSpeed) : "Стоп"
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
                HStack(spacing: 10) {
                    Button(action: { showCatalog.toggle() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "globe.americas.fill")
                            Text("\(sim.targetBody.name) • \(sim.distanceText)")
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.black.opacity(0.68))
                        .overlay(Capsule().stroke(Color.cyan.opacity(0.45), lineWidth: 1))
                        .clipShape(Capsule())
                    }

                    Text("ETA: \(sim.etaText)")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.black.opacity(0.68))
                        .clipShape(Capsule())

                    Spacer()

                    Button("На цель") { sim.alignToTarget() }
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.blue.opacity(0.8))
                        .clipShape(Capsule())

                    Button(sim.isThirdPerson ? "1-е лицо" : "3-е лицо") {
                        sim.isThirdPerson.toggle()
                        sim.updateCameraMode()
                    }
                    .font(.system(size: 12, weight: .bold))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Color.black.opacity(0.68))
                    .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                    .clipShape(Capsule())
                }
                .foregroundColor(.white)
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer()

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
                    .background(Color.black.opacity(0.68))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.2), lineWidth: 1))
                    .cornerRadius(14)

                    Spacer()

                    HStack(spacing: 8) {
                        Button("−") { sim.speedIndex = max(0, sim.speedIndex - 1) }
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Circle())

                        Text(sim.speedSteps[sim.speedIndex].label)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .frame(minWidth: 92)

                        Button("+") { sim.speedIndex = min(sim.speedSteps.count - 1, sim.speedIndex + 1) }
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Circle())

                        Button("СТОП") { sim.throttle = 0 }
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.red.opacity(0.8))
                            .clipShape(Capsule())
                    }
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Color.black.opacity(0.68))
                    .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 1))
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
                .background(Color.black.opacity(0.88))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.cyan.opacity(0.4), lineWidth: 1))
                .cornerRadius(16)
            }
        }
    }
}