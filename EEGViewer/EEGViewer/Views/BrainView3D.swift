// BrainView3D.swift
// 3D brain visualization with real MRI-derived cortex mesh.
// Uses FreeSurfer pial surface meshes (Brainder.org, CC BY-SA 3.0) loaded via ModelIO.
// Transparent outer cortex with segmented inner brain regions that light up per electrode.
// Region colors blend smoothly between neighbors via per-vertex inverse-distance weighting.
// Meshes are decimated via vertex clustering for performance (~300k → ~40k inner, ~12k outer).

import SwiftUI
import SceneKit
import SceneKit.ModelIO
import ModelIO
import Combine

/// Hashable 3D grid cell key for vertex clustering decimation.
private struct GridCell: Hashable {
    let x: Int32, y: Int32, z: Int32
}

struct BrainView3D: View {
    let edfData: EDFData
    @ObservedObject var annotationStore: AnnotationStore

    // Scene state
    @State private var scene = SCNScene()
    @State private var leftHemiNode: SCNNode?
    @State private var rightHemiNode: SCNNode?
    @State private var brainParentNode: SCNNode?

    // Region mesh state (per-vertex color blending)
    @State private var regionMeshNode: SCNNode?
    @State private var regionVertexSource: SCNGeometrySource?
    @State private var regionNormalSource: SCNGeometrySource?
    @State private var regionFaceElement: SCNGeometryElement?
    @State private var regionVertexCount: Int = 0
    @State private var vertexBlendWeights: [[(idx: Int, weight: Float)]] = []
    @State private var electrodeNames: [String] = []

    // Data state
    @State private var isProcessing = true
    @State private var bandPowerData: [String: [[Float]]] = [:]
    @State private var epochTimes: [Float] = []
    @State private var lastEpochIdx: Int = -1

    // Control state
    @State private var currentTime: Float = 0
    @State private var selectedBand: BandSelection = .alpha
    @State private var isPlaying = false
    @State private var speed: Float = 1.0
    @State private var timer: AnyCancellable?
    @State private var applyAnnotations = true
    @State private var notchEnabled = true
    @State private var notchFreq: Float = 60.0

    // Fixed region appearance
    private let regionBrightness: Float = 0.2
    private let regionOpacity: Float = 0.10

    enum BandSelection: String, CaseIterable {
        case all = "All"
        case delta = "Delta"
        case theta = "Theta"
        case alpha = "Alpha"
        case beta = "Beta"
    }

    // MARK: - Shaders

    /// Ultra-subtle Fresnel rim glow for outer cortex shell.
    /// Uses .constant lighting so scene lights don't interfere — only edges glow faintly blue.
    private static let fresnelShader = """
    #pragma transparent
    #pragma body
    float NdotV = dot(_surface.normal, normalize(_surface.view));
    NdotV = clamp(NdotV, 0.0, 1.0);
    float fresnel = pow(1.0 - NdotV, 4.0);
    vec3 rimColor = vec3(0.20, 0.30, 0.60);
    _output.color.rgb = rimColor * fresnel * 0.12;
    _output.color.a = fresnel * 0.008;
    """

    /// Surface shader for inner regions: moves vertex colors from diffuse into emission
    /// so .constant lighting model renders them without scene light interference.
    private static let vertexColorEmissionShader = """
    #pragma body
    _surface.emission = _surface.diffuse;
    _surface.diffuse = float4(0.0, 0.0, 0.0, 0.0);
    """

    // MARK: - Connectivity map

    private static let connections: [(String, String)] = [
        ("Fp1", "Fp2"), ("F3", "F4"), ("C3", "C4"), ("P3", "P4"), ("O1", "O2"),
        ("F7", "F8"), ("T7", "T8"), ("P7", "P8"),
        ("Fp1", "F3"), ("F3", "C3"), ("C3", "P3"), ("P3", "O1"),
        ("Fp1", "F7"), ("F7", "T7"), ("T7", "P7"), ("P7", "O1"),
        ("Fp2", "F4"), ("F4", "C4"), ("C4", "P4"), ("P4", "O2"),
        ("Fp2", "F8"), ("F8", "T8"), ("T8", "P8"), ("P8", "O2"),
        ("Fz", "Cz"), ("Cz", "Pz"),
        ("F3", "Fz"), ("Fz", "F4"), ("C3", "Cz"), ("Cz", "C4"),
        ("P3", "Pz"), ("Pz", "P4"),
    ]

    // MARK: - Brain mesh constants

    private static let brainScale: Float = 0.004
    private static let brainCenterFS = simd_float3(-0.4, -14.9, 0.7)

    /// Decimation targets (vertex counts per combined mesh)
    private static let innerMeshTarget = 40_000
    private static let outerMeshTarget = 12_000

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            if isProcessing {
                ProgressView("Building 3D brain model...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(red: 0.03, green: 0.03, blue: 0.06))
                    .foregroundColor(.white)
            } else {
                SceneView(
                    scene: scene,
                    options: [.allowsCameraControl]
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()
                controlsBar
            }
        }
        .background(Color(red: 0.03, green: 0.03, blue: 0.06))
        .task { await processAndBuild() }
        .onDisappear { timer?.cancel() }
        .onChange(of: selectedBand) { _ in
            lastEpochIdx = -1
            updateColors()
        }
        .onChange(of: currentTime) { _ in updateColors() }
    }

    // MARK: - Controls

    private var controlsBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Button {
                    togglePlayback()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .foregroundColor(.white)
                        .frame(width: 32)
                }

                VStack(spacing: 2) {
                    Text("Speed: \(speed, specifier: "%.1f")x")
                        .font(.caption2).foregroundColor(.gray)
                    Slider(value: $speed, in: 0.5...4.0, step: 0.5)
                        .frame(width: 80)
                        .tint(.blue)
                }

                VStack(spacing: 2) {
                    let curMin = Int(currentTime) / 60
                    let curSec = Int(currentTime) % 60
                    let totMin = Int(edfData.duration) / 60
                    let totSec = Int(edfData.duration) % 60
                    Text(String(format: "%02d:%02d / %02d:%02d", curMin, curSec, totMin, totSec))
                        .font(.caption2.monospacedDigit()).foregroundColor(.gray)
                    Slider(value: $currentTime, in: 0...max(0.01, edfData.duration - 2.0))
                        .frame(minWidth: 200)
                        .tint(.blue)
                }

                Picker("Band", selection: $selectedBand) {
                    ForEach(BandSelection.allCases, id: \.self) { band in
                        Text(band.rawValue).tag(band)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 300)

                HStack(spacing: 4) {
                    Text("-3").font(.caption2).foregroundColor(.gray)
                    LinearGradient(
                        colors: [.cyan, .blue, .black,
                                 Color(red: 0.8, green: 0, blue: 0.8), .red, .yellow],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: 100, height: 12)
                    .cornerRadius(3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.gray.opacity(0.5), lineWidth: 0.5)
                    )
                    Text("+3").font(.caption2).foregroundColor(.gray)
                    Text("Z-score").font(.caption2).foregroundColor(.gray.opacity(0.6))
                }

                // Annotation filter toggle
                Button {
                    applyAnnotations.toggle()
                    Task { await processAndBuild() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: applyAnnotations ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                        let count = annotationStore.excludedTimeRanges().count
                        Text(applyAnnotations && count > 0 ? "\(count) excluded" : "No filter")
                    }
                    .font(.caption)
                    .foregroundColor(applyAnnotations ? .orange : .gray)
                }

                // Notch filter
                HStack(spacing: 6) {
                    Button {
                        notchEnabled.toggle()
                        Task { await processAndBuild() }
                    } label: {
                        Image(systemName: notchEnabled ? "waveform.slash" : "waveform")
                            .font(.caption)
                            .foregroundColor(notchEnabled ? .cyan : .gray)
                    }
                    if notchEnabled {
                        Picker("Notch", selection: $notchFreq) {
                            ForEach([Float(50), 55, 60, 65], id: \.self) { hz in
                                Text("\(Int(hz)) Hz").tag(hz)
                            }
                        }
                        .pickerStyle(.menu)
                        .tint(.cyan)
                        .onChange(of: notchFreq) { _ in
                            Task { await processAndBuild() }
                        }
                    } else {
                        Text("Notch off")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(red: 0.06, green: 0.06, blue: 0.10))
    }

    // MARK: - Data Processing

    private func processAndBuild() async {
        isProcessing = true

        let eegData = edfData.eegData
        let channels = edfData.channelNames
        let sfreq = edfData.sfreq
        let exclusions = applyAnnotations ? annotationStore.excludedTimeRanges() : []
        let badChannels = applyAnnotations ? annotationStore.badChannelIndices : []
        let useNotch = notchEnabled
        let notchHz = notchFreq
        let eegFiltered = exclusions.isEmpty ? eegData : SignalProcessor.applyExclusions(eegData, sfreq: sfreq, exclusions: exclusions)

        let (powerData, times) = await Task.detached(priority: .userInitiated) {
            // Interpolate bad channels before average reference to prevent noise spreading
            let interpolated = SignalProcessor.interpolateBadChannels(eegFiltered, channels: channels, badChannelIndices: badChannels)
            let referenced = SignalProcessor.averageReference(interpolated)
            var filtered = referenced.map { SignalProcessor.highpassFilter($0, sfreq: sfreq, cutoff: 1.0) }

            // Apply notch filter to remove power line noise
            if useNotch {
                filtered = filtered.map { SignalProcessor.notchFilter($0, sfreq: sfreq, centerFreq: notchHz) }
            }

            let decimFactor = max(1, Int(sfreq / 50.0))
            let decimSfreq = sfreq / Float(decimFactor)
            let decimated = filtered.map { SignalProcessor.decimate($0, factor: decimFactor, sfreq: sfreq) }

            guard !decimated.isEmpty else { return ([String: [[Float]]](), [Float]()) }
            let nSamples = decimated[0].count
            let epochLen = Int(2.0 * decimSfreq)
            let epochStep = Int(0.5 * decimSfreq)
            let nEpochs = max(1, (nSamples - epochLen) / epochStep + 1)

            var times = [Float]()
            for e in 0..<nEpochs {
                times.append(Float(e * epochStep) / decimSfreq)
            }

            var allBandPower: [String: [[Float]]] = [:]
            let bands: [(name: String, low: Float, high: Float)] = [
                ("Delta", 1.0, 4.0), ("Theta", 4.0, 8.0),
                ("Alpha", 8.0, 13.0), ("Beta", 13.0, 25.0)
            ]

            for band in bands {
                var channelEpochs = [[Float]]()
                for chIdx in 0..<decimated.count {
                    let bandFiltered = SignalProcessor.bandpassFilter(
                        decimated[chIdx], sfreq: decimSfreq,
                        lowCut: band.low, highCut: band.high)
                    var epochs = [Float]()
                    for e in 0..<nEpochs {
                        let start = e * epochStep
                        let end = min(start + epochLen, nSamples)
                        var sumSq: Float = 0
                        for i in start..<end { sumSq += bandFiltered[i] * bandFiltered[i] }
                        epochs.append(sqrtf(sumSq / Float(end - start)) * 1e6)
                    }
                    channelEpochs.append(epochs)
                }
                allBandPower[band.name] = channelEpochs
            }

            var allPower = [[Float]]()
            for chIdx in 0..<decimated.count {
                var epochs = [Float]()
                for e in 0..<nEpochs {
                    var total: Float = 0
                    for band in bands {
                        if let bp = allBandPower[band.name] {
                            let v = bp[chIdx][e]; total += v * v
                        }
                    }
                    epochs.append(sqrtf(total))
                }
                allPower.append(epochs)
            }
            allBandPower["All"] = allPower

            return (allBandPower, times)
        }.value

        self.bandPowerData = powerData
        self.epochTimes = times

        // Load mesh assets once (shared by outer shell and inner regions)
        let lhAsset = Bundle.main.url(forResource: "lh.pial", withExtension: "obj")
            .map { MDLAsset(url: $0) }
        let rhAsset = Bundle.main.url(forResource: "rh.pial", withExtension: "obj")
            .map { MDLAsset(url: $0) }

        // Phase 1: Build scene with decimated outer shell (fast → visible immediately)
        buildScene(lhAsset: lhAsset, rhAsset: rhAsset)
        isProcessing = false

        // Phase 2: Build inner region mesh (heavier computation, appears shortly after)
        if let lh = lhAsset, let rh = rhAsset,
           let regionNode = buildRegionMesh(lhAsset: lh, rhAsset: rh) {
            brainParentNode?.addChildNode(regionNode)
        }
        updateColors()
    }

    // MARK: - 3D Brain Scene

    private func buildScene(lhAsset: MDLAsset?, rhAsset: MDLAsset?) {
        scene = SCNScene()
        scene.background.contents = UIColor(red: 0.03, green: 0.03, blue: 0.06, alpha: 1.0)

        let brainParent = SCNNode()

        // 1. Outer transparent cortex shell (decimated, ultra-subtle Fresnel only)
        if let asset = lhAsset, let leftMesh = buildCortexShell(from: asset) {
            brainParent.addChildNode(leftMesh)
            self.leftHemiNode = leftMesh
        } else {
            let fallback = createFallbackHemisphere(isLeft: true)
            brainParent.addChildNode(fallback)
            self.leftHemiNode = fallback
        }

        if let asset = rhAsset, let rightMesh = buildCortexShell(from: asset) {
            brainParent.addChildNode(rightMesh)
            self.rightHemiNode = rightMesh
        } else {
            let fallback = createFallbackHemisphere(isLeft: false)
            brainParent.addChildNode(fallback)
            self.rightHemiNode = fallback
        }

        // Brain stem (constant lighting — no light amplification)
        let stemGeom = SCNCapsule(capRadius: 0.05, height: 0.12)
        let stemMat = SCNMaterial()
        stemMat.lightingModel = .constant
        stemMat.emission.contents = UIColor(red: 0.06, green: 0.05, blue: 0.08, alpha: 1.0)
        stemMat.transparency = 0.35
        stemMat.isDoubleSided = true
        stemGeom.materials = [stemMat]
        let stemNode = SCNNode(geometry: stemGeom)
        stemNode.position = SCNVector3(0, -0.32, -0.08)
        brainParent.addChildNode(stemNode)

        // Connectivity lines (decorative)
        addConnectivityLines(to: brainParent)

        // Save reference for adding inner mesh later
        self.brainParentNode = brainParent
        scene.rootNode.addChildNode(brainParent)

        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.fieldOfView = 38
        cameraNode.camera?.wantsHDR = true
        cameraNode.camera?.bloomIntensity = 0.4
        cameraNode.camera?.bloomThreshold = 1.5
        cameraNode.position = SCNVector3(0, 0.25, 1.4)
        cameraNode.look(at: SCNVector3(0, 0.05, 0))
        scene.rootNode.addChildNode(cameraNode)

        // Lights (ambient + soft directional for connectivity line aesthetics)
        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.intensity = 80
        ambientLight.light?.color = UIColor(red: 0.5, green: 0.6, blue: 1.0, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)

        let dirLight = SCNNode()
        dirLight.light = SCNLight()
        dirLight.light?.type = .directional
        dirLight.light?.intensity = 150
        dirLight.light?.color = UIColor(red: 0.8, green: 0.85, blue: 1.0, alpha: 1.0)
        dirLight.position = SCNVector3(0.5, 1.5, 2.0)
        dirLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(dirLight)

        let fillLight = SCNNode()
        fillLight.light = SCNLight()
        fillLight.light?.type = .directional
        fillLight.light?.intensity = 60
        fillLight.light?.color = UIColor(red: 0.4, green: 0.5, blue: 0.8, alpha: 1.0)
        fillLight.position = SCNVector3(-0.5, -1.0, 1.0)
        fillLight.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(fillLight)
    }

    // MARK: - Build Outer Cortex Shell (decimated)

    private func buildCortexShell(from asset: MDLAsset) -> SCNNode? {
        guard asset.count > 0,
              let mdlMesh = asset.object(at: 0) as? MDLMesh else { return nil }

        mdlMesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.7)

        let scnScene = SCNScene(mdlAsset: asset)
        var meshGeometry: SCNGeometry?
        scnScene.rootNode.enumerateChildNodes { node, stop in
            if let geo = node.geometry { meshGeometry = geo; stop.pointee = true }
        }
        guard let geometry = meshGeometry else { return nil }

        // Decimate the outer shell for performance (each hemisphere ~150k → ~6k vertices)
        let origVerts = extractVertices(from: geometry)
        let origFaces = extractFaces(from: geometry)
        let perHemiTarget = BrainView3D.outerMeshTarget / 2
        let (decVerts, decFaces) = decimateMesh(
            vertices: origVerts, faces: origFaces,
            targetVertexCount: perHemiTarget
        )
        let decNormals = computeVertexNormals(vertices: decVerts, faces: decFaces)

        // Build decimated SCNGeometry
        let scnVerts = decVerts.map { SCNVector3($0.x, $0.y, $0.z) }
        let scnNormals = decNormals.map { SCNVector3($0.x, $0.y, $0.z) }
        let vertexSource = SCNGeometrySource(vertices: scnVerts)
        let normalSource = SCNGeometrySource(normals: scnNormals)

        var flatIdx = [UInt32]()
        flatIdx.reserveCapacity(decFaces.count * 3)
        for f in decFaces {
            flatIdx.append(f.0); flatIdx.append(f.1); flatIdx.append(f.2)
        }
        let idxData = flatIdx.withUnsafeBufferPointer { Data(buffer: $0) }
        let faceElement = SCNGeometryElement(
            data: idxData, primitiveType: .triangles,
            primitiveCount: decFaces.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let decimatedGeometry = SCNGeometry(
            sources: [vertexSource, normalSource], elements: [faceElement]
        )

        // .constant lighting — scene lights have zero effect on this material.
        // Only the Fresnel fragment shader produces a faint blue rim glow.
        // Single-sided: outer shell is convex, back faces are never visible from outside.
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.clear
        material.isDoubleSided = false
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        material.shaderModifiers = [.fragment: BrainView3D.fresnelShader]
        decimatedGeometry.materials = [material]

        let meshNode = SCNNode(geometry: decimatedGeometry)
        let containerNode = SCNNode()
        containerNode.addChildNode(meshNode)
        applyBrainTransform(to: containerNode)
        return containerNode
    }

    // MARK: - Build Segmented Inner Brain (decimated, per-vertex blended regions)

    private func buildRegionMesh(lhAsset: MDLAsset, rhAsset: MDLAsset) -> SCNNode? {
        let lhScene = SCNScene(mdlAsset: lhAsset)
        let rhScene = SCNScene(mdlAsset: rhAsset)

        var lhGeometry: SCNGeometry?
        var rhGeometry: SCNGeometry?
        lhScene.rootNode.enumerateChildNodes { node, stop in
            if let geo = node.geometry { lhGeometry = geo; stop.pointee = true }
        }
        rhScene.rootNode.enumerateChildNodes { node, stop in
            if let geo = node.geometry { rhGeometry = geo; stop.pointee = true }
        }

        guard let lhGeo = lhGeometry, let rhGeo = rhGeometry else { return nil }

        // Extract full-resolution vertices and faces
        let lhVertsOrig = extractVertices(from: lhGeo)
        let rhVertsOrig = extractVertices(from: rhGeo)
        let lhFacesOrig = extractFaces(from: lhGeo)
        let rhFacesOrig = extractFaces(from: rhGeo)

        guard !lhVertsOrig.isEmpty, !rhVertsOrig.isEmpty else { return nil }

        // Combine hemispheres
        let lhCount = UInt32(lhVertsOrig.count)
        let allVertsOrig = lhVertsOrig + rhVertsOrig
        var allFacesOrig = lhFacesOrig
        for face in rhFacesOrig {
            allFacesOrig.append((face.0 + lhCount, face.1 + lhCount, face.2 + lhCount))
        }

        // Decimate combined mesh (~300k → ~40k vertices)
        let (allVerts, allFaces) = decimateMesh(
            vertices: allVertsOrig, faces: allFacesOrig,
            targetVertexCount: BrainView3D.innerMeshTarget
        )

        // Get electrode positions in SceneKit space
        let channels = edfData.eegChannelNames
        var electrodeInfo: [(name: String, pos: SCNVector3)] = []
        for ch in channels {
            if let pos2D = Constants.electrodePositions2D[ch] {
                let pos3D = project2Dto3D(x: pos2D.x, y: pos2D.y, depth: 0.85)
                electrodeInfo.append((ch, pos3D))
            }
        }
        guard !electrodeInfo.isEmpty else { return nil }

        let s = BrainView3D.brainScale
        let cx = BrainView3D.brainCenterFS.x
        let cy = BrainView3D.brainCenterFS.y
        let cz = BrainView3D.brainCenterFS.z

        // Per-vertex blend weights: top 3 nearest electrodes, inverse distance squared.
        // Now operates on ~40k decimated vertices instead of ~300k — ~7.5× faster.
        var blendWeights = [[(idx: Int, weight: Float)]]()
        blendWeights.reserveCapacity(allVerts.count)

        for vi in 0..<allVerts.count {
            let v = allVerts[vi]
            let sx = (v.x - cx) * s
            let sy = (v.z - cz) * s + 0.05
            let sz = -(v.y - cy) * s

            var distances = [(Int, Float)]()
            distances.reserveCapacity(electrodeInfo.count)
            for (ei, info) in electrodeInfo.enumerated() {
                let dx = sx - info.pos.x
                let dy = sy - info.pos.y
                let dz = sz - info.pos.z
                distances.append((ei, sqrtf(dx * dx + dy * dy + dz * dz)))
            }
            distances.sort { $0.1 < $1.1 }

            let topK = min(3, distances.count)
            var weights = [(idx: Int, weight: Float)]()
            var totalWeight: Float = 0
            for k in 0..<topK {
                let d = max(distances[k].1, 0.001)
                let w = 1.0 / (d * d)
                weights.append((idx: distances[k].0, weight: w))
                totalWeight += w
            }
            for k in 0..<weights.count {
                weights[k].weight /= totalWeight
            }
            blendWeights.append(weights)
        }

        self.electrodeNames = electrodeInfo.map { $0.name }
        self.vertexBlendWeights = blendWeights

        // Build vertex data in FreeSurfer space (transform applied via parent node)
        let fsVerts: [SCNVector3] = allVerts.map { SCNVector3($0.x, $0.y, $0.z) }

        // Compute vertex normals on decimated mesh
        let normalsSimd = computeVertexNormals(vertices: allVerts, faces: allFaces)
        let normals: [SCNVector3] = normalsSimd.map { SCNVector3($0.x, $0.y, $0.z) }

        // Store reusable geometry sources
        let vertexSource = SCNGeometrySource(vertices: fsVerts)
        let normalSource = SCNGeometrySource(normals: normals)

        var flatIndices = [UInt32]()
        flatIndices.reserveCapacity(allFaces.count * 3)
        for face in allFaces {
            flatIndices.append(face.0)
            flatIndices.append(face.1)
            flatIndices.append(face.2)
        }
        let faceData = flatIndices.withUnsafeBufferPointer { Data(buffer: $0) }
        let faceElement = SCNGeometryElement(
            data: faceData,
            primitiveType: .triangles,
            primitiveCount: allFaces.count,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        self.regionVertexSource = vertexSource
        self.regionNormalSource = normalSource
        self.regionFaceElement = faceElement
        self.regionVertexCount = fsVerts.count

        // Initial geometry with dark vertex colors
        let vertCount = fsVerts.count
        var colorArray = [Float](repeating: 0, count: vertCount * 4)
        for vi in 0..<vertCount {
            colorArray[vi * 4 + 0] = 0.08
            colorArray[vi * 4 + 1] = 0.08
            colorArray[vi * 4 + 2] = 0.12
            colorArray[vi * 4 + 3] = 1.0
        }
        let colorData = colorArray.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: vertCount,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 4
        )

        let geometry = SCNGeometry(sources: [vertexSource, normalSource, colorSource], elements: [faceElement])
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.white
        mat.shaderModifiers = [.surface: BrainView3D.vertexColorEmissionShader]
        mat.transparency = CGFloat(regionOpacity)
        mat.blendMode = .alpha
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        geometry.materials = [mat]

        let meshNode = SCNNode(geometry: geometry)
        meshNode.scale = SCNVector3(0.98, 0.98, 0.98)

        let containerNode = SCNNode()
        containerNode.addChildNode(meshNode)
        applyBrainTransform(to: containerNode)

        self.regionMeshNode = meshNode

        return containerNode
    }

    // MARK: - Geometry Data Extraction

    /// Extract vertex positions from an SCNGeometry's vertex source.
    /// Validates that vertex components are Float32 before reading.
    private func extractVertices(from geometry: SCNGeometry) -> [simd_float3] {
        guard let source = geometry.sources(for: .vertex).first else { return [] }

        guard source.bytesPerComponent == 4, source.componentsPerVector >= 3 else {
            print("BrainView3D: unexpected vertex format — \(source.bytesPerComponent) bytes/component")
            return []
        }

        let count = source.vectorCount
        let stride = source.dataStride
        let offset = source.dataOffset
        let data = source.data

        var vertices = [simd_float3]()
        vertices.reserveCapacity(count)

        data.withUnsafeBytes { rawBuffer in
            let basePtr = rawBuffer.baseAddress!
            for i in 0..<count {
                let byteOffset = i * stride + offset
                guard byteOffset + 12 <= rawBuffer.count else { break }
                let ptr = basePtr.advanced(by: byteOffset).assumingMemoryBound(to: Float.self)
                vertices.append(simd_float3(ptr[0], ptr[1], ptr[2]))
            }
        }

        return vertices
    }

    /// Extract triangle face indices from all geometry elements.
    private func extractFaces(from geometry: SCNGeometry) -> [(UInt32, UInt32, UInt32)] {
        var faces = [(UInt32, UInt32, UInt32)]()

        for element in geometry.elements {
            guard element.primitiveType == .triangles else { continue }
            let primitiveCount = element.primitiveCount
            let bpi = element.bytesPerIndex
            let data = element.data
            faces.reserveCapacity(faces.count + primitiveCount)

            data.withUnsafeBytes { rawBuffer in
                let basePtr = rawBuffer.baseAddress!
                for i in 0..<primitiveCount {
                    let a: UInt32
                    let b: UInt32
                    let c: UInt32
                    if bpi == 4 {
                        let byteOffset = i * 3 * 4
                        guard byteOffset + 12 <= rawBuffer.count else { break }
                        let ptr = basePtr.advanced(by: byteOffset).assumingMemoryBound(to: UInt32.self)
                        a = ptr[0]; b = ptr[1]; c = ptr[2]
                    } else if bpi == 2 {
                        let byteOffset = i * 3 * 2
                        guard byteOffset + 6 <= rawBuffer.count else { break }
                        let ptr = basePtr.advanced(by: byteOffset).assumingMemoryBound(to: UInt16.self)
                        a = UInt32(ptr[0]); b = UInt32(ptr[1]); c = UInt32(ptr[2])
                    } else {
                        continue
                    }
                    faces.append((a, b, c))
                }
            }
        }

        return faces
    }

    // MARK: - Mesh Decimation (Vertex Clustering)

    /// Reduces vertex count via grid-based vertex clustering.
    /// Divides bounding box into a 3D grid, merges all vertices in each cell to their average,
    /// and remaps face indices (removing degenerate triangles where 2+ vertices collapsed).
    private func decimateMesh(
        vertices: [simd_float3],
        faces: [(UInt32, UInt32, UInt32)],
        targetVertexCount: Int
    ) -> (vertices: [simd_float3], faces: [(UInt32, UInt32, UInt32)]) {
        guard vertices.count > targetVertexCount, !vertices.isEmpty else {
            return (vertices, faces)
        }

        // Compute bounding box
        var minB = vertices[0], maxB = vertices[0]
        for v in vertices {
            minB = simd_min(minB, v)
            maxB = simd_max(maxB, v)
        }

        // Approximate surface area from face triangles for accurate cell sizing.
        // A brain mesh is a 2D manifold in 3D space — volume-based cellSize would
        // be wrong because vertices lie on the surface, not throughout the volume.
        var surfaceArea: Float = 0
        for face in faces {
            let i0 = Int(face.0), i1 = Int(face.1), i2 = Int(face.2)
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }
            let cross = simd_cross(vertices[i1] - vertices[i0], vertices[i2] - vertices[i0])
            surfaceArea += simd_length(cross) * 0.5
        }
        let cellSize = sqrtf(max(surfaceArea, 0.001) / Float(targetVertexCount))

        // Map each vertex to a grid cell
        var cellMap: [GridCell: [Int]] = [:]
        cellMap.reserveCapacity(targetVertexCount)
        var vertexCellKey = [GridCell]()
        vertexCellKey.reserveCapacity(vertices.count)

        for (i, v) in vertices.enumerated() {
            let cell = GridCell(
                x: Int32(floorf((v.x - minB.x) / cellSize)),
                y: Int32(floorf((v.y - minB.y) / cellSize)),
                z: Int32(floorf((v.z - minB.z) / cellSize))
            )
            cellMap[cell, default: []].append(i)
            vertexCellKey.append(cell)
        }

        // Average vertices per cell → new vertex positions
        var cellToNewIdx: [GridCell: UInt32] = [:]
        cellToNewIdx.reserveCapacity(cellMap.count)
        var newVerts = [simd_float3]()
        newVerts.reserveCapacity(cellMap.count)

        for (cell, indices) in cellMap {
            cellToNewIdx[cell] = UInt32(newVerts.count)
            var sum = simd_float3(0, 0, 0)
            for i in indices { sum += vertices[i] }
            newVerts.append(sum / Float(indices.count))
        }

        // Remap face indices, skip degenerate triangles
        var newFaces = [(UInt32, UInt32, UInt32)]()
        newFaces.reserveCapacity(faces.count)
        let vertCount = vertexCellKey.count
        for face in faces {
            let i0 = Int(face.0), i1 = Int(face.1), i2 = Int(face.2)
            guard i0 < vertCount, i1 < vertCount, i2 < vertCount else { continue }
            let c0 = vertexCellKey[i0]
            let c1 = vertexCellKey[i1]
            let c2 = vertexCellKey[i2]
            guard let n0 = cellToNewIdx[c0],
                  let n1 = cellToNewIdx[c1],
                  let n2 = cellToNewIdx[c2] else { continue }
            // Skip degenerate: two or more vertices collapsed to same cell
            if n0 != n1 && n1 != n2 && n0 != n2 {
                newFaces.append((n0, n1, n2))
            }
        }

        return (newVerts, newFaces)
    }

    /// Compute per-vertex normals from face normals (area-weighted average).
    private func computeVertexNormals(
        vertices: [simd_float3],
        faces: [(UInt32, UInt32, UInt32)]
    ) -> [simd_float3] {
        var normals = [simd_float3](repeating: .zero, count: vertices.count)
        for face in faces {
            let i0 = Int(face.0), i1 = Int(face.1), i2 = Int(face.2)
            guard i0 < vertices.count, i1 < vertices.count, i2 < vertices.count else { continue }
            let v0 = vertices[i0], v1 = vertices[i1], v2 = vertices[i2]
            let faceNormal = simd_cross(v1 - v0, v2 - v0)
            normals[i0] += faceNormal
            normals[i1] += faceNormal
            normals[i2] += faceNormal
        }
        return normals.map { n in
            let len = simd_length(n)
            return len > 0 ? n / len : simd_float3(0, 1, 0)
        }
    }

    // MARK: - Brain Coordinate Transform

    private func applyBrainTransform(to node: SCNNode) {
        let s = BrainView3D.brainScale
        let cx = BrainView3D.brainCenterFS.x
        let cy = BrainView3D.brainCenterFS.y
        let cz = BrainView3D.brainCenterFS.z

        var transform = SCNMatrix4Identity
        transform.m11 = s;  transform.m12 = 0;  transform.m13 = 0;  transform.m14 = 0
        transform.m21 = 0;  transform.m22 = 0;  transform.m23 = -s; transform.m24 = 0
        transform.m31 = 0;  transform.m32 = s;  transform.m33 = 0;  transform.m34 = 0
        transform.m41 = -cx * s
        transform.m42 = -cz * s + 0.05
        transform.m43 = cy * s
        transform.m44 = 1
        node.transform = transform
    }

    private func createFallbackHemisphere(isLeft: Bool) -> SCNNode {
        let sphere = SCNSphere(radius: 0.38)
        sphere.segmentCount = 64
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.clear
        material.isDoubleSided = true
        material.blendMode = .alpha
        material.writesToDepthBuffer = false
        material.shaderModifiers = [.fragment: BrainView3D.fresnelShader]
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.scale = SCNVector3(0.56, 0.50, 0.62)
        node.position = SCNVector3(isLeft ? -0.11 : 0.11, 0.05, 0)
        return node
    }

    // MARK: - Connectivity Lines

    private func addConnectivityLines(to parent: SCNNode) {
        for (ch1, ch2) in BrainView3D.connections {
            guard let p1 = Constants.electrodePositions2D[ch1],
                  let p2 = Constants.electrodePositions2D[ch2] else { continue }
            let pos1 = project2Dto3D(x: p1.x, y: p1.y, depth: 0.70)
            let pos2 = project2Dto3D(x: p2.x, y: p2.y, depth: 0.70)
            let mid = SCNVector3(
                (pos1.x + pos2.x) / 2 * 0.85,
                (pos1.y + pos2.y) / 2 * 0.90,
                (pos1.z + pos2.z) / 2 * 0.85
            )
            if let seg1 = createTractSegment(from: pos1, to: mid) { parent.addChildNode(seg1) }
            if let seg2 = createTractSegment(from: mid, to: pos2) { parent.addChildNode(seg2) }
        }
    }

    private func createTractSegment(from p1: SCNVector3, to p2: SCNVector3) -> SCNNode? {
        let dx = p2.x - p1.x, dy = p2.y - p1.y, dz = p2.z - p1.z
        let length = sqrtf(dx * dx + dy * dy + dz * dz)
        guard length > 0.001 else { return nil }
        let cylinder = SCNCylinder(radius: 0.003, height: CGFloat(length))
        let mat = SCNMaterial()
        mat.diffuse.contents = UIColor.clear
        mat.emission.contents = UIColor(red: 0.75, green: 0.60, blue: 0.20, alpha: 1.0)
        mat.emission.intensity = 0.25
        mat.transparency = 0.25
        mat.blendMode = .add
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        cylinder.materials = [mat]
        let node = SCNNode(geometry: cylinder)
        node.position = SCNVector3((p1.x + p2.x) / 2, (p1.y + p2.y) / 2, (p1.z + p2.z) / 2)
        let yAxis = simd_float3(0, 1, 0)
        let direction = simd_normalize(simd_float3(dx, dy, dz))
        let dot = simd_dot(yAxis, direction)
        if abs(dot) < 0.999 {
            let cross = simd_cross(yAxis, direction)
            node.simdRotation = simd_float4(cross.x, cross.y, cross.z, acos(max(-1, min(1, dot))))
        } else if dot < 0 { node.eulerAngles.z = .pi }
        return node
    }

    // MARK: - 2D to 3D Projection

    private func project2Dto3D(x: Float, y: Float, depth: Float = 0.95) -> SCNVector3 {
        let headRadius: Float = 0.095
        let brainRadius: Float = 0.5
        let r2D = sqrtf(x * x + y * y)
        let theta = Float.pi / 2 * min(r2D / headRadius, 1.0)
        let phi = atan2(x, y)
        let x3D = brainRadius * sin(theta) * sin(phi) * 0.56 * depth
        let y3D = brainRadius * cos(theta) * 0.50 * depth + 0.05
        let z3D = brainRadius * sin(theta) * cos(phi) * 0.62 * depth
        return SCNVector3(x3D, y3D, z3D)
    }

    // MARK: - Color Update (per-vertex blended)

    private func updateColors() {
        let channels = edfData.eegChannelNames
        let bandKey = selectedBand.rawValue
        guard let powerData = bandPowerData[bandKey], !epochTimes.isEmpty else { return }
        guard regionVertexCount > 0,
              let meshNode = regionMeshNode,
              let vertexSource = regionVertexSource,
              let normalSource = regionNormalSource,
              let faceElement = regionFaceElement else { return }

        var epochIdx = 0
        for (i, t) in epochTimes.enumerated() {
            if t <= currentTime { epochIdx = i } else { break }
        }
        if epochIdx == lastEpochIdx { return }
        lastEpochIdx = epochIdx

        var values = [Float]()
        for chIdx in 0..<min(channels.count, powerData.count) {
            if epochIdx < powerData[chIdx].count { values.append(powerData[chIdx][epochIdx]) }
        }
        guard !values.isEmpty else { return }

        let mean = values.reduce(0, +) / Float(values.count)
        var variance: Float = 0
        for v in values { variance += (v - mean) * (v - mean) }
        let std = sqrtf(variance / Float(values.count))

        let zscores: [Float] = std > 0.001
            ? values.map { ($0 - mean) / std }
            : [Float](repeating: 0, count: values.count)

        // Per-electrode colors from Z-scores
        var channelIndexMap = [String: Int]()
        for (chIdx, ch) in channels.enumerated() {
            channelIndexMap[ch] = chIdx
        }

        var electrodeColors = [(r: Float, g: Float, b: Float)]()
        electrodeColors.reserveCapacity(electrodeNames.count)
        for name in electrodeNames {
            if let chIdx = channelIndexMap[name], chIdx < zscores.count {
                let zscore = zscores[chIdx]
                let pos = ColorMap.zscoreToPosition(zscore)
                let (r, g, b) = ColorMap.eegColorMapRGB(at: pos)
                let absZ = min(abs(zscore), 3.0)
                let intensity: Float = 0.3 + absZ * 0.7
                electrodeColors.append((r * intensity, g * intensity, b * intensity))
            } else {
                electrodeColors.append((0.08, 0.08, 0.12))
            }
        }

        // Blend per-vertex colors using precomputed weights
        let vertCount = regionVertexCount
        var colorArray = [Float](repeating: 0, count: vertCount * 4)
        let bright = regionBrightness

        for vi in 0..<vertCount {
            var r: Float = 0, g: Float = 0, b: Float = 0
            for (eIdx, weight) in vertexBlendWeights[vi] {
                guard eIdx < electrodeColors.count else { continue }
                let c = electrodeColors[eIdx]
                r += c.r * weight
                g += c.g * weight
                b += c.b * weight
            }
            colorArray[vi * 4 + 0] = min(r * bright, 1.0)
            colorArray[vi * 4 + 1] = min(g * bright, 1.0)
            colorArray[vi * 4 + 2] = min(b * bright, 1.0)
            colorArray[vi * 4 + 3] = 1.0
        }

        // Build new color source (reuse stored vertex/normal/face data)
        let colorData = colorArray.withUnsafeBufferPointer { Data(buffer: $0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: vertCount,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<Float>.size * 4
        )

        let geometry = SCNGeometry(
            sources: [vertexSource, normalSource, colorSource],
            elements: [faceElement]
        )
        let mat = SCNMaterial()
        mat.lightingModel = .constant
        mat.diffuse.contents = UIColor.white
        mat.shaderModifiers = [.surface: BrainView3D.vertexColorEmissionShader]
        mat.transparency = CGFloat(regionOpacity)
        mat.blendMode = .alpha
        mat.isDoubleSided = true
        mat.writesToDepthBuffer = false
        geometry.materials = [mat]

        meshNode.geometry = geometry
    }

    // MARK: - Playback

    private func togglePlayback() {
        if isPlaying {
            isPlaying = false
            timer?.cancel()
            timer = nil
        } else {
            isPlaying = true
            timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common)
                .autoconnect()
                .sink { _ in
                    let maxTime = max(0.01, edfData.duration - 2.0)
                    currentTime += Float(1.0 / 30.0) * speed
                    if currentTime >= maxTime { currentTime = 0 }
                }
        }
    }
}
