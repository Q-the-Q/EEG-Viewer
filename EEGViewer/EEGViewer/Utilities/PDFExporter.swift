// PDFExporter.swift
// Generates a multi-page PDF clinical report from qEEG analysis results.
// Supports 1-3 recordings for comparison mode.
// Renders all 4 frequency bands (Delta, Theta, Alpha, Beta) for coherence and asymmetry.

import SwiftUI
import UIKit

struct PDFExporter {

    // MARK: - Page Constants

    private static let pageWidth: CGFloat = 612   // US Letter
    private static let pageHeight: CGFloat = 792
    private static let margin: CGFloat = 40
    private static let contentWidth: CGFloat = 612 - 80  // 532

    // MARK: - Pre-rendered Images for one recording

    private struct BandImage {
        let bandName: String
        let freqRange: String
        let image: UIImage
    }

    private struct RecordingImages {
        let index: Int
        let filename: String
        let results: QEEGResults
        let spectraImage: UIImage?
        let topoImage: UIImage?
        let coherenceImages: [BandImage]
        let asymmetryImages: [BandImage]
    }

    // MARK: - Public Entry Point

    /// Generate a complete qEEG analysis PDF report.
    /// Must be called from the main actor (uses ImageRenderer for chart snapshots).
    @MainActor
    static func generateReport(
        allResults: [(index: Int, filename: String, results: QEEGResults)],
        edfData: EDFData
    ) -> Data {
        // Phase 1: Pre-render all chart images on main actor
        let regions = ["Frontal", "Central", "Posterior"]
        var globalPeak: Float = 0
        for entry in allResults {
            for region in regions {
                let chs = Constants.regionMap[region] ?? []
                let peak = SpectraChartView.peakAmplitude(results: entry.results, channels: chs)
                globalPeak = max(globalPeak, peak)
            }
        }
        let sharedMaxY = globalPeak + 0.2

        let recordings = allResults.map { entry in
            // Render coherence and asymmetry for ALL 4 bands
            var cohImages = [BandImage]()
            var asymImages = [BandImage]()
            for band in Constants.freqBands {
                let range = "\(Int(band.low))-\(Int(band.high)) Hz"
                if let img = renderCoherenceImage(results: entry.results, band: band.name) {
                    cohImages.append(BandImage(bandName: band.name, freqRange: range, image: img))
                }
                if let img = renderAsymmetryImage(results: entry.results, band: band.name) {
                    asymImages.append(BandImage(bandName: band.name, freqRange: range, image: img))
                }
            }

            return RecordingImages(
                index: entry.index,
                filename: entry.filename,
                results: entry.results,
                spectraImage: renderSpectraImage(results: entry.results, sharedMaxY: sharedMaxY),
                topoImage: renderTopoImage(results: entry.results),
                coherenceImages: cohImages,
                asymmetryImages: asymImages
            )
        }

        // Phase 2: Compose PDF (no main actor requirement)
        return composePDF(recordings: recordings, edfData: edfData)
    }

    // MARK: - PDF Composition (nonisolated)

    private static func composePDF(recordings: [RecordingImages], edfData: EDFData) -> Data {
        let pageBounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        let multiRecording = recordings.count > 1

        let data = renderer.pdfData { pdfContext in
            var yOffset: CGFloat = margin
            var pageNumber = 1

            func newPage() {
                drawPageNumber(pdfContext.cgContext, page: pageNumber)
                pdfContext.beginPage()
                pageNumber += 1
                yOffset = margin
            }

            func ensureSpace(_ needed: CGFloat) {
                if yOffset + needed > pageHeight - margin {
                    newPage()
                }
            }

            // ── Page 1: Header ──────────────────────────
            pdfContext.beginPage()
            yOffset = drawHeader(pdfContext.cgContext, edfData: edfData, y: yOffset)
            yOffset += 12

            // ── Magnitude Spectra ────────────────────────
            yOffset = drawSectionTitle(pdfContext.cgContext, "Magnitude Spectra", y: yOffset)

            for rec in recordings {
                ensureSpace(230)
                if multiRecording {
                    yOffset = drawRecordingLabel(pdfContext.cgContext, index: rec.index,
                                                  filename: rec.filename, y: yOffset)
                }
                yOffset = drawArtifactStats(pdfContext.cgContext, results: rec.results, y: yOffset)
                if let img = rec.spectraImage {
                    yOffset = drawImage(pdfContext.cgContext, image: img,
                                        maxWidth: contentWidth, maxHeight: 180, y: yOffset)
                }
                yOffset += 8
            }

            // ── Topographic Z-Score Maps ─────────────────
            ensureSpace(200)
            yOffset = drawSectionTitle(pdfContext.cgContext, "Topographic Z-Score Maps", y: yOffset)

            for rec in recordings {
                ensureSpace(180)
                if multiRecording {
                    yOffset = drawRecordingLabel(pdfContext.cgContext, index: rec.index,
                                                  filename: rec.filename, y: yOffset)
                }
                if let img = rec.topoImage {
                    yOffset = drawImage(pdfContext.cgContext, image: img,
                                        maxWidth: contentWidth, maxHeight: 160, y: yOffset)
                }
                yOffset += 8
            }

            // ── Coherence & Asymmetry (all 4 bands) ─────
            // Grouped by band so comparisons are adjacent:
            //   Delta: Recording 1, Recording 2
            //   Theta: Recording 1, Recording 2
            //   ...
            ensureSpace(200)
            yOffset = drawSectionTitle(pdfContext.cgContext, "Coherence & Asymmetry", y: yOffset)

            let bandCount = recordings.first?.coherenceImages.count ?? 0
            for bandIdx in 0..<bandCount {
                // Band label (from first recording — all share the same bands)
                let bandInfo = recordings[0].coherenceImages[bandIdx]
                ensureSpace(30)
                yOffset = drawBandLabel(pdfContext.cgContext, name: bandInfo.bandName,
                                        range: bandInfo.freqRange, y: yOffset)

                for rec in recordings {
                    ensureSpace(210)
                    if multiRecording {
                        yOffset = drawRecordingLabel(pdfContext.cgContext, index: rec.index,
                                                      filename: rec.filename, y: yOffset)
                    }

                    // Coherence + Asymmetry side by side
                    if bandIdx < rec.coherenceImages.count {
                        let coh = rec.coherenceImages[bandIdx]
                        if bandIdx < rec.asymmetryImages.count {
                            let asym = rec.asymmetryImages[bandIdx]
                            yOffset = drawImagePair(pdfContext.cgContext, left: coh.image,
                                                    right: asym.image, maxHeight: 180, y: yOffset)
                        } else {
                            yOffset = drawImage(pdfContext.cgContext, image: coh.image,
                                                maxWidth: contentWidth / 2, maxHeight: 180, y: yOffset)
                        }
                    }
                    yOffset += 4
                }
                yOffset += 8
            }

            // ── Peak Frequencies ─────────────────────────
            ensureSpace(100)
            yOffset = drawSectionTitle(pdfContext.cgContext, "Peak Frequencies", y: yOffset)

            for rec in recordings {
                let tableHeight = CGFloat(rec.results.peakFreqs.count + 1) * 16 + 30
                ensureSpace(tableHeight)
                if multiRecording {
                    yOffset = drawRecordingLabel(pdfContext.cgContext, index: rec.index,
                                                  filename: rec.filename, y: yOffset)
                }
                yOffset = drawPeakFrequencyTable(pdfContext.cgContext, results: rec.results, y: yOffset)
                yOffset += 8
            }

            // Final page number
            drawPageNumber(pdfContext.cgContext, page: pageNumber)
        }

        return data
    }

    // MARK: - Header

    private static func drawHeader(_ ctx: CGContext, edfData: EDFData, y: CGFloat) -> CGFloat {
        var yPos = y

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 20),
            .foregroundColor: UIColor.black
        ]
        ("qEEG Analysis Report" as NSString).draw(at: CGPoint(x: margin, y: yPos), withAttributes: titleAttrs)
        yPos += 30

        // Divider
        ctx.setStrokeColor(UIColor.darkGray.cgColor)
        ctx.setLineWidth(1.0)
        ctx.move(to: CGPoint(x: margin, y: yPos))
        ctx.addLine(to: CGPoint(x: pageWidth - margin, y: yPos))
        ctx.strokePath()
        yPos += 10

        let infoAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10),
            .foregroundColor: UIColor.darkGray
        ]

        let info = edfData.patientInfo
        let durMin = Int(edfData.duration) / 60
        let durSec = Int(edfData.duration) % 60
        let eegCount = edfData.eegIndices.count

        let lines = [
            "Patient: \(info.patientID.isEmpty ? "—" : info.patientID)",
            "Recording: \(info.recordingID.isEmpty ? "—" : info.recordingID)",
            "Date: \(info.startDate) \(info.startTime)",
            "Duration: \(String(format: "%02d:%02d", durMin, durSec))  |  Channels: \(eegCount) EEG  |  Sampling: \(Int(edfData.sfreq)) Hz",
        ]

        for line in lines {
            (line as NSString).draw(at: CGPoint(x: margin, y: yPos), withAttributes: infoAttrs)
            yPos += 14
        }

        yPos += 4
        ctx.setStrokeColor(UIColor.lightGray.cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: margin, y: yPos))
        ctx.addLine(to: CGPoint(x: pageWidth - margin, y: yPos))
        ctx.strokePath()
        yPos += 8

        return yPos
    }

    // MARK: - Section Title

    private static func drawSectionTitle(_ ctx: CGContext, _ title: String, y: CGFloat) -> CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 13),
            .foregroundColor: UIColor.black
        ]
        (title as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: attrs)
        return y + 20
    }

    // MARK: - Band Label

    private static func drawBandLabel(_ ctx: CGContext, name: String, range: String, y: CGFloat) -> CGFloat {
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 10),
            .foregroundColor: UIColor.darkGray
        ]
        let rangeAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.gray
        ]
        let nameSize = (name as NSString).size(withAttributes: nameAttrs)
        (name as NSString).draw(at: CGPoint(x: margin + 4, y: y), withAttributes: nameAttrs)
        (" (\(range))" as NSString).draw(at: CGPoint(x: margin + 4 + nameSize.width, y: y + 1), withAttributes: rangeAttrs)
        return y + 16
    }

    // MARK: - Recording Label

    private static func drawRecordingLabel(_ ctx: CGContext, index: Int, filename: String, y: CGFloat) -> CGFloat {
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 11),
            .foregroundColor: UIColor.black
        ]
        let fileAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.gray
        ]
        ("Recording \(index)" as NSString).draw(at: CGPoint(x: margin, y: y), withAttributes: labelAttrs)
        (filename as NSString).draw(at: CGPoint(x: margin + 90, y: y + 1), withAttributes: fileAttrs)
        return y + 16
    }

    // MARK: - Artifact Stats

    private static func drawArtifactStats(_ ctx: CGContext, results: QEEGResults, y: CGFloat) -> CGFloat {
        let stats = results.artifactStats
        let pct = stats.totalEpochs > 0
            ? Float(stats.rejectedEpochs) / Float(stats.totalEpochs) * 100
            : 0

        let text = "Epochs: \(stats.cleanEpochs)/\(stats.totalEpochs) clean (\(String(format: "%.1f", pct))% rejected)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.gray
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: CGPoint(x: pageWidth - margin - size.width, y: y), withAttributes: attrs)
        return y + 14
    }

    // MARK: - Image Drawing

    private static func drawImage(_ ctx: CGContext, image: UIImage, maxWidth: CGFloat, maxHeight: CGFloat, y: CGFloat) -> CGFloat {
        let aspect = image.size.width / image.size.height
        var drawWidth = maxWidth
        var drawHeight = drawWidth / aspect
        if drawHeight > maxHeight {
            drawHeight = maxHeight
            drawWidth = drawHeight * aspect
        }
        let x = margin + (contentWidth - drawWidth) / 2
        image.draw(in: CGRect(x: x, y: y, width: drawWidth, height: drawHeight))
        return y + drawHeight + 4
    }

    private static func drawImagePair(_ ctx: CGContext, left: UIImage, right: UIImage, maxHeight: CGFloat, y: CGFloat) -> CGFloat {
        let halfWidth = (contentWidth - 12) / 2

        let lAspect = left.size.width / left.size.height
        var lWidth = halfWidth; var lHeight = lWidth / lAspect
        if lHeight > maxHeight { lHeight = maxHeight; lWidth = lHeight * lAspect }
        left.draw(in: CGRect(x: margin, y: y, width: lWidth, height: lHeight))

        let rAspect = right.size.width / right.size.height
        var rWidth = halfWidth; var rHeight = rWidth / rAspect
        if rHeight > maxHeight { rHeight = maxHeight; rWidth = rHeight * rAspect }
        right.draw(in: CGRect(x: margin + halfWidth + 12, y: y, width: rWidth, height: rHeight))

        return y + max(lHeight, rHeight) + 4
    }

    // MARK: - Page Number

    private static func drawPageNumber(_ ctx: CGContext, page: Int) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 8),
            .foregroundColor: UIColor.lightGray
        ]
        let text = "Page \(page)"
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(
            at: CGPoint(x: (pageWidth - size.width) / 2, y: pageHeight - 25),
            withAttributes: attrs
        )
    }

    // MARK: - Peak Frequency Table

    private static func drawPeakFrequencyTable(_ ctx: CGContext, results: QEEGResults, y: CGFloat) -> CGFloat {
        var yPos = y

        let headerAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 9),
            .foregroundColor: UIColor.black
        ]
        let cellAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: UIColor.darkGray
        ]

        let col1X = margin
        let col2X = margin + 80
        let col3X = margin + 180
        let rowHeight: CGFloat = 14

        ("Channel" as NSString).draw(at: CGPoint(x: col1X, y: yPos), withAttributes: headerAttrs)
        ("Alpha Peak" as NSString).draw(at: CGPoint(x: col2X, y: yPos), withAttributes: headerAttrs)
        ("Dominant" as NSString).draw(at: CGPoint(x: col3X, y: yPos), withAttributes: headerAttrs)
        yPos += rowHeight + 2

        ctx.setStrokeColor(UIColor.lightGray.cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: col1X, y: yPos))
        ctx.addLine(to: CGPoint(x: col3X + 80, y: yPos))
        ctx.strokePath()
        yPos += 4

        for peak in results.peakFreqs {
            (peak.channel as NSString).draw(at: CGPoint(x: col1X, y: yPos), withAttributes: cellAttrs)
            (String(format: "%.1f Hz", peak.alphaPeak) as NSString).draw(at: CGPoint(x: col2X, y: yPos), withAttributes: cellAttrs)
            (String(format: "%.1f Hz", peak.dominant) as NSString).draw(at: CGPoint(x: col3X, y: yPos), withAttributes: cellAttrs)
            yPos += rowHeight
        }

        return yPos
    }

    // MARK: - Chart Rendering via ImageRenderer (MainActor)

    @MainActor
    private static func renderSpectraImage(results: QEEGResults, sharedMaxY: Float) -> UIImage? {
        let regions = ["Frontal", "Central", "Posterior"]
        let view = HStack(alignment: .top, spacing: 8) {
            ForEach(regions, id: \.self) { region in
                let channelNames = Constants.regionMap[region] ?? []
                SpectraChartView(results: results, region: region,
                                 channels: channelNames, sharedMaxY: sharedMaxY)
                    .frame(width: 220, height: 170)
            }
        }
        .padding(4)
        .background(Color.white)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        return renderer.uiImage
    }

    @MainActor
    private static func renderTopoImage(results: QEEGResults) -> UIImage? {
        let size = 120
        let bands = Constants.freqBands

        var images = [(String, String, CGImage)]()
        for band in bands {
            if let zs = results.zscores[band.name],
               let img = TopoMapRenderer.render(values: zs, channels: results.channels, size: size) {
                images.append((band.name, "\(Int(band.low))-\(Int(band.high)) Hz", img))
            }
        }

        guard !images.isEmpty else { return nil }

        let mapSize = CGFloat(size)
        let spacing: CGFloat = 16
        let totalWidth = CGFloat(images.count) * (mapSize + spacing) - spacing + 60
        let totalHeight = mapSize + 30

        let uiRenderer = UIGraphicsImageRenderer(size: CGSize(width: totalWidth, height: totalHeight))
        return uiRenderer.image { ctx in
            var x: CGFloat = 0
            let labelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.boldSystemFont(ofSize: 9),
                .foregroundColor: UIColor.black
            ]
            let rangeAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 7),
                .foregroundColor: UIColor.gray
            ]

            for (name, range, cgImage) in images {
                let uiImg = UIImage(cgImage: cgImage)
                uiImg.draw(in: CGRect(x: x, y: 0, width: mapSize, height: mapSize))

                let nameSize = (name as NSString).size(withAttributes: labelAttrs)
                (name as NSString).draw(
                    at: CGPoint(x: x + (mapSize - nameSize.width) / 2, y: mapSize + 2),
                    withAttributes: labelAttrs
                )
                let rangeSize = (range as NSString).size(withAttributes: rangeAttrs)
                (range as NSString).draw(
                    at: CGPoint(x: x + (mapSize - rangeSize.width) / 2, y: mapSize + 14),
                    withAttributes: rangeAttrs
                )

                x += mapSize + spacing
            }

            // Simplified color bar
            let barX = x
            let barWidth: CGFloat = 12
            let barHeight = mapSize
            let steps = 50
            for i in 0..<steps {
                let pos = 1.0 - Float(i) / Float(steps - 1)
                let (r, g, b) = ColorMap.neuroSynchronyRGB(at: pos)
                UIColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1).setFill()
                let stepHeight = barHeight / CGFloat(steps)
                UIBezierPath(rect: CGRect(x: barX, y: CGFloat(i) * stepHeight,
                                          width: barWidth, height: stepHeight + 1)).fill()
            }
            let barLabelAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 7),
                .foregroundColor: UIColor.darkGray
            ]
            ("+2.5" as NSString).draw(at: CGPoint(x: barX + barWidth + 2, y: 0), withAttributes: barLabelAttrs)
            ("0" as NSString).draw(at: CGPoint(x: barX + barWidth + 2, y: barHeight / 2 - 4), withAttributes: barLabelAttrs)
            ("-2.5" as NSString).draw(at: CGPoint(x: barX + barWidth + 2, y: barHeight - 10), withAttributes: barLabelAttrs)
        }
    }

    @MainActor
    private static func renderCoherenceImage(results: QEEGResults, band: String) -> UIImage? {
        let view = CoherenceHeatmapView(results: results, selectedBand: band)
            .frame(width: 350, height: 280)
            .background(Color.white)
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        return renderer.uiImage
    }

    @MainActor
    private static func renderAsymmetryImage(results: QEEGResults, band: String) -> UIImage? {
        let view = AsymmetryChartView(results: results, selectedBand: band)
            .frame(width: 300, height: 280)
            .background(Color.white)
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2.0
        return renderer.uiImage
    }
}
