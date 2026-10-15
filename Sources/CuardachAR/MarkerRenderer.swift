#if canImport(UIKit) && canImport(ARKit) && os(iOS)
import ARKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CuardachCore
import UIKit

/// Draws printable markers (PRD L4, S5). The pattern alone is the ARKit
/// reference image; the printed sheet adds the element's name and a QR
/// code that opens the experience, so a poster explains itself.
public enum MarkerRenderer {
    /// The detection image: pattern plus a one-cell white quiet zone.
    public static func patternImage(seed: String, pixels: Int = 1024) -> UIImage {
        let p = MarkerPattern(seed: seed)
        let n = p.size + 2
        let cell = CGFloat(pixels) / CGFloat(n)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: pixels, height: pixels), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            UIColor.black.setFill()
            for r in 0..<p.size {
                for c in 0..<p.size where p[r, c] {
                    ctx.fill(CGRect(x: CGFloat(c + 1) * cell, y: CGFloat(r + 1) * cell, width: cell + 0.5, height: cell + 0.5))
                }
            }
        }
    }

    /// The reference image ARKit detects. `physicalWidthM` is the printed
    /// width of the whole image, quiet zone included.
    public static func referenceImage(for anchor: CuardachCore.Anchor, image: UIImage) -> ARReferenceImage? {
        guard let cg = image.cgImage, let w = anchor.physicalWidthM, w > 0 else { return nil }
        let ref = ARReferenceImage(cg, orientation: .up, physicalWidth: CGFloat(w))
        ref.name = anchor.id
        return ref
    }

    public static func qrImage(_ text: String, size: CGFloat) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage else { return nil }
        let scaled = out.transformed(by: CGAffineTransform(scaleX: size / out.extent.width, y: size / out.extent.height))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    public struct Sheet {
        public var element: Element
        public var anchor: CuardachCore.Anchor
        public var markerImage: UIImage

        public init(element: Element, anchor: CuardachCore.Anchor, markerImage: UIImage) {
            self.element = element
            self.anchor = anchor
            self.markerImage = markerImage
        }
    }

    /// One A4 page per marker, pattern at its true printed width.
    public static func pdf(title: String, sheets: [Sheet], shareLink: URL?) -> Data {
        let mmToPt: CGFloat = 72 / 25.4
        let page = CGRect(x: 0, y: 0, width: 210 * mmToPt, height: 297 * mmToPt)
        return UIGraphicsPDFRenderer(bounds: page).pdfData { ctx in
            for s in sheets {
                ctx.beginPage()
                let widthPt = CGFloat(s.anchor.physicalWidthM ?? 0.18) * 1000 * mmToPt
                let x = (page.width - widthPt) / 2
                let top: CGFloat = 30 * mmToPt
                s.markerImage.draw(in: CGRect(x: x, y: top, width: widthPt, height: widthPt))

                let para = NSMutableParagraphStyle()
                para.alignment = .center
                let name = NSAttributedString(string: s.element.label?.title ?? s.element.name, attributes: [
                    .font: UIFont.systemFont(ofSize: 26, weight: .bold), .paragraphStyle: para,
                ])
                let y = top + widthPt + 14 * mmToPt
                name.draw(in: CGRect(x: 20 * mmToPt, y: y, width: page.width - 40 * mmToPt, height: 40))

                let hint = NSAttributedString(
                    string: "Point the \(title) experience at this poster. Print at 100%. Keep it flat and out of glare.",
                    attributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.darkGray, .paragraphStyle: para])
                hint.draw(in: CGRect(x: 20 * mmToPt, y: y + 40, width: page.width - 40 * mmToPt, height: 30))

                if let link = shareLink, let qr = qrImage(link.absoluteString, size: 300) {
                    let q: CGFloat = 32 * mmToPt
                    qr.draw(in: CGRect(x: page.width - q - 15 * mmToPt, y: page.height - q - 15 * mmToPt, width: q, height: q))
                    let scan = NSAttributedString(string: "Scan to open", attributes: [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray])
                    scan.draw(at: CGPoint(x: page.width - q - 15 * mmToPt, y: page.height - 13 * mmToPt))
                }
            }
        }
    }
}
#endif
