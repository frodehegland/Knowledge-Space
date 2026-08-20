//
//  BookletImposer.swift
//
//  Shared between Author (Liquid Author/Publishing/) and Knowledge
//  Space — keep the two copies identical; Author's is canonical.
//
//  Lays a paginated PDF out as a saddle-stitch booklet: landscape
//  sheets, two pages up, in an order such that printing double-sided
//  (flipped on the short edge) and folding the stack in half yields a
//  book that reads front to back. The imposition is pure CoreGraphics/
//  PDFKit and runs on every platform; printing is macOS-only (visionOS
//  cannot print — share or save the imposed PDF there instead).
//

#if canImport(AppKit)
import AppKit
#endif
import CoreText
import PDFKit

enum BookletImposer {

    /// The source document imposed as booklet sheets. The page count is
    /// padded to a multiple of four with blanks so the fold works out.
    /// `footerTitle`, when given, is printed small and gray at the foot
    /// of every page so a paper copy names its source document.
    static func imposed(from source: PDFDocument, footerTitle: String? = nil) -> PDFDocument? {
        guard source.pageCount > 0, let firstPage = source.page(at: 0) else { return nil }

        let srcSize = firstPage.bounds(for: .mediaBox).size
        // Same paper as the source, turned landscape; each half carries
        // one page. For A-series paper the halves scale exactly (A4 → A5).
        let sheetSize = CGSize(width: max(srcSize.width, srcSize.height),
                               height: min(srcSize.width, srcSize.height))
        var sheetRect = CGRect(origin: .zero, size: sheetSize)
        let leftHalf = CGRect(x: 0, y: 0, width: sheetSize.width / 2, height: sheetSize.height)
        let rightHalf = CGRect(x: sheetSize.width / 2, y: 0, width: sheetSize.width / 2, height: sheetSize.height)

        let paddedCount = (source.pageCount + 3) / 4 * 4

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &sheetRect, nil) else { return nil }

        for side in 0..<(paddedCount / 2) {
            // Saddle-stitch order: sides run (N,1), (2,N-1), (N-2,3), (4,N-3)…
            // so consecutive sides are the front and back of one sheet.
            let outer = paddedCount - 1 - side
            let inner = side
            let (leftIndex, rightIndex) = side.isMultiple(of: 2) ? (outer, inner) : (inner, outer)

            context.beginPDFPage(nil)
            draw(pageAt: leftIndex, from: source, into: leftHalf, with: context, footerTitle: footerTitle)
            draw(pageAt: rightIndex, from: source, into: rightHalf, with: context, footerTitle: footerTitle)
            context.endPDFPage()
        }
        context.closePDF()

        return PDFDocument(data: data as Data)
    }

#if os(macOS)
    /// Runs the print panel for an imposed booklet: landscape, borderless,
    /// preset to two-sided with a short-edge flip — the setting a folded
    /// booklet needs — while leaving the panel up for the user to confirm.
    static func runPrintOperation(for booklet: PDFDocument, jobTitle: String, window: NSWindow?) {
        guard let printInfo = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        printInfo.orientation = .landscape
        printInfo.topMargin = 0
        printInfo.bottomMargin = 0
        printInfo.leftMargin = 0
        printInfo.rightMargin = 0
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = true
        PMSetDuplex(OpaquePointer(printInfo.pmPrintSettings()), PMDuplexMode(kPMDuplexTumble))
        printInfo.updateFromPMPrintSettings()

        guard let printOperation = booklet.printOperation(for: printInfo, scalingMode: .pageScaleDownToFit, autoRotate: false) else { return }
        printOperation.jobTitle = jobTitle + " (Booklet)"
        printOperation.showsPrintPanel = true
        if let window {
            printOperation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            printOperation.run()
        }
    }
#endif

    /// One source page scaled to fit its half of the sheet, centered.
    /// Indexes past the end are the blank padding pages.
    private static func draw(pageAt index: Int, from source: PDFDocument, into half: CGRect,
                             with context: CGContext, footerTitle: String?) {
        if index < source.pageCount, let page = source.page(at: index) {
            let bounds = page.bounds(for: .mediaBox)
            let scale = min(half.width / bounds.width, half.height / bounds.height)

            context.saveGState()
            context.translateBy(x: half.minX + (half.width - bounds.width * scale) / 2,
                                y: half.minY + (half.height - bounds.height * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.minX, y: -bounds.minY)
            page.draw(with: .mediaBox, to: context)
            context.restoreGState()

            if let footerTitle, !footerTitle.isEmpty {
                drawFooter(footerTitle, in: half, with: context)
            }
        }
    }

    /// The source document's title, small and gray, at the foot of the
    /// half — below the page's own bottom margin, so a reader (or a
    /// camera) can trace any physical page back to its document.
    /// CoreText, so it draws identically on every platform.
    private static func drawFooter(_ title: String, in half: CGRect, with context: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.system, 6.5, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, 6.5, nil)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 0.55, alpha: 1),
        ] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, title as CFString, attributes) else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))

        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: half.midX - width / 2, y: half.minY + 6)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
