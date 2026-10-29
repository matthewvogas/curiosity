import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Una foto con cuadrícula y coordenadas en píxeles, para que la IA pueda señalar con precisión (como en el
/// simulador). Devuelve el JPEG nuevo y el tamaño de la imagen.
enum ImageGrid {
    static func draw(_ jpeg: Data, step: Int = 64) -> (jpeg: Data, width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CoreGraphics tiene el origen abajo; la IA cuenta desde arriba a la izquierda.
        ctx.setLineWidth(1)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.4))
        for x in stride(from: step, to: w, by: step) {
            ctx.stroke(CGRect(x: CGFloat(x), y: 0, width: 0, height: CGFloat(h)))
            label(ctx, "\(x)", at: CGPoint(x: x + 2, y: h - 15))
        }
        for y in stride(from: step, to: h, by: step) {
            ctx.stroke(CGRect(x: 0, y: CGFloat(h - y), width: CGFloat(w), height: 0))
            label(ctx, "\(y)", at: CGPoint(x: 2, y: h - y - 15))
        }
        guard let out = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data as Data, w, h)
    }

    /// Un número sobre un fondo oscuro (dígitos de 7 segmentos: sin depender de fuentes).
    private static func label(_ ctx: CGContext, _ text: String, at p: CGPoint) {
        let digit: CGFloat = 7, gap: CGFloat = 2
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.6))
        ctx.fill(CGRect(x: p.x, y: p.y, width: CGFloat(text.count) * (digit + gap) + 4, height: 13))
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.4)
        for (i, ch) in text.enumerated() {
            let x = p.x + 2 + CGFloat(i) * (digit + gap), y = p.y + 2, w = digit - 1, h: CGFloat = 9
            // Segmentos: a arriba, b arriba-der, c abajo-der, d abajo, e abajo-izq, f arriba-izq, g medio.
            let on: [Character: String] = ["0": "abcdef", "1": "bc", "2": "abged", "3": "abgcd", "4": "fgbc", "5": "afgcd",
                                           "6": "afgedc", "7": "abc", "8": "abcdefg", "9": "abcdfg"]
            let top = y + h, mid = y + h / 2
            let segs: [Character: (CGPoint, CGPoint)] = [
                "a": (CGPoint(x: x, y: top), CGPoint(x: x + w, y: top)), "b": (CGPoint(x: x + w, y: top), CGPoint(x: x + w, y: mid)),
                "c": (CGPoint(x: x + w, y: mid), CGPoint(x: x + w, y: y)), "d": (CGPoint(x: x, y: y), CGPoint(x: x + w, y: y)),
                "e": (CGPoint(x: x, y: mid), CGPoint(x: x, y: y)), "f": (CGPoint(x: x, y: top), CGPoint(x: x, y: mid)),
                "g": (CGPoint(x: x, y: mid), CGPoint(x: x + w, y: mid)),
            ]
            for s in on[ch] ?? "" { if let (a, b) = segs[s] { ctx.move(to: a); ctx.addLine(to: b) } }
            ctx.strokePath()
        }
    }
}
