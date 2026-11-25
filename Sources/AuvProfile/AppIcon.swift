import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum AppIcon {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func writeIconset(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let specs: [(String, Int)] = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]
        var cache: [Int: Data] = [:]
        for (name, pixels) in specs {
            let data: Data
            if let cached = cache[pixels] {
                data = cached
            } else {
                let rendered = try pngData(pixels: pixels)
                cache[pixels] = rendered
                data = rendered
            }
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    static func pngData(pixels: Int) throws -> Data {
        guard let ctx = CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.coderInvalidValue)
        }

        let scale = CGFloat(pixels) / 512.0
        ctx.translateBy(x: 0, y: CGFloat(pixels))
        ctx.scaleBy(x: scale, y: -scale)

        drawLayeredIdentityStack(in: ctx, scale: scale)

        guard let cgImage = ctx.makeImage() else {
            throw CocoaError(.coderInvalidValue)
        }
        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            mutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CocoaError(.coderInvalidValue)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw CocoaError(.coderInvalidValue)
        }
        return mutableData as Data
    }

    private static func drawLayeredIdentityStack(in ctx: CGContext, scale: CGFloat) {
        let squircleRect = CGRect(x: 32, y: 32, width: 448, height: 448)
        let squirclePath = CGPath(roundedRect: squircleRect, cornerWidth: 102, cornerHeight: 102, transform: nil)

        // 1. Base Squircle Drop Shadow & Fill
        ctx.saveGState()
        setShadow(ctx, scale: scale, dy: 10, blur: 22, color: rgba(0, 0, 0, 0.42))
        ctx.addPath(squirclePath)
        ctx.setFillColor(rgba(15, 23, 42, 1))
        ctx.fillPath()
        ctx.restoreGState()

        // Clip to Squircle
        ctx.saveGState()
        ctx.addPath(squirclePath)
        ctx.clip()

        // Base linear gradient
        fillLinearGradient(
            ctx,
            in: squirclePath,
            start: CGPoint(x: 32, y: 32),
            end: CGPoint(x: 480, y: 480),
            stops: [
                (0.0, rgba(15, 23, 42, 1)),
                (0.5, rgba(30, 27, 75, 1)),
                (1.0, rgba(9, 13, 22, 1)),
            ]
        )

        // Ambient radial glows
        drawRadialGlow(ctx, center: CGPoint(x: 120, y: 110), radius: 210, color: rgba(56, 189, 248, 0.45))
        drawRadialGlow(ctx, center: CGPoint(x: 400, y: 400), radius: 220, color: rgba(99, 102, 241, 0.45))

        // 2. Back Card 1 (Claude Amber/Orange Profile)
        ctx.saveGState()
        ctx.translateBy(x: 256, y: 245)
        ctx.rotate(by: -8 * .pi / 180)
        ctx.translateBy(x: -256, y: -245)

        let amberRect = CGRect(x: 118, y: 96, width: 276, height: 175)
        let amberPath = CGPath(roundedRect: amberRect, cornerWidth: 32, cornerHeight: 32, transform: nil)
        ctx.saveGState()
        setShadow(ctx, scale: scale, dy: 8, blur: 16, color: rgba(2, 6, 23, 0.45))
        ctx.addPath(amberPath)
        ctx.setFillColor(rgba(245, 158, 11, 1))
        ctx.fillPath()
        ctx.restoreGState()

        fillLinearGradient(
            ctx,
            in: amberPath,
            start: CGPoint(x: 118, y: 96),
            end: CGPoint(x: 394, y: 271),
            stops: [
                (0.0, rgba(245, 158, 11, 1)),
                (1.0, rgba(217, 119, 6, 1)),
            ]
        )
        strokePath(ctx, path: amberPath, color: rgba(253, 230, 138, 0.5), width: 2.5)
        fillCircle(ctx, center: CGPoint(x: 162, y: 134), radius: 11, color: rgba(255, 251, 235, 0.85))
        fillRoundedRect(ctx, rect: CGRect(x: 184, y: 127, width: 86, height: 14), radius: 7, color: rgba(255, 251, 235, 0.85))
        ctx.restoreGState()

        // 3. Middle Card 2 (Codex Emerald/Teal Profile)
        ctx.saveGState()
        ctx.translateBy(x: 256, y: 260)
        ctx.rotate(by: 6 * .pi / 180)
        ctx.translateBy(x: -256, y: -260)

        let emeraldRect = CGRect(x: 110, y: 138, width: 292, height: 182)
        let emeraldPath = CGPath(roundedRect: emeraldRect, cornerWidth: 34, cornerHeight: 34, transform: nil)
        ctx.saveGState()
        setShadow(ctx, scale: scale, dy: 8, blur: 18, color: rgba(2, 6, 23, 0.5))
        ctx.addPath(emeraldPath)
        ctx.setFillColor(rgba(16, 185, 129, 1))
        ctx.fillPath()
        ctx.restoreGState()

        fillLinearGradient(
            ctx,
            in: emeraldPath,
            start: CGPoint(x: 110, y: 138),
            end: CGPoint(x: 402, y: 320),
            stops: [
                (0.0, rgba(16, 185, 129, 1)),
                (1.0, rgba(5, 150, 105, 1)),
            ]
        )
        strokePath(ctx, path: emeraldPath, color: rgba(167, 243, 208, 0.55), width: 2.5)
        fillCircle(ctx, center: CGPoint(x: 156, y: 176), radius: 11, color: rgba(236, 253, 245, 0.9))
        fillRoundedRect(ctx, rect: CGRect(x: 178, y: 169, width: 95, height: 14), radius: 7, color: rgba(236, 253, 245, 0.9))
        ctx.restoreGState()

        // 4. Front Main Active Profile Card
        let frontRect = CGRect(x: 96, y: 178, width: 320, height: 222)
        let frontPath = CGPath(roundedRect: frontRect, cornerWidth: 38, cornerHeight: 38, transform: nil)
        ctx.saveGState()
        setShadow(ctx, scale: scale, dy: 12, blur: 22, color: rgba(2, 6, 23, 0.6))
        ctx.addPath(frontPath)
        ctx.setFillColor(rgba(30, 41, 59, 1))
        ctx.fillPath()
        ctx.restoreGState()

        fillLinearGradient(
            ctx,
            in: frontPath,
            start: CGPoint(x: 96, y: 178),
            end: CGPoint(x: 390, y: 400),
            stops: [
                (0.0, rgba(30, 41, 59, 1)),
                (1.0, rgba(15, 23, 42, 1)),
            ]
        )
        strokeGradientPath(
            ctx,
            path: frontPath,
            width: 3.5,
            start: CGPoint(x: 256, y: 178),
            end: CGPoint(x: 256, y: 400),
            stops: [
                (0.0, rgba(255, 255, 255, 0.65)),
                (1.0, rgba(148, 163, 184, 0.2)),
            ]
        )

        // Avatar Badge inside Front Card
        let badgeRect = CGRect(x: 128, y: 218, width: 82, height: 82)
        let badgePath = CGPath(roundedRect: badgeRect, cornerWidth: 22, cornerHeight: 22, transform: nil)
        fillLinearGradient(
            ctx,
            in: badgePath,
            start: CGPoint(x: 128, y: 218),
            end: CGPoint(x: 210, y: 300),
            stops: [
                (0.0, rgba(59, 130, 246, 1)),
                (1.0, rgba(79, 70, 229, 1)),
            ]
        )
        strokePath(ctx, path: badgePath, color: rgba(147, 197, 253, 0.5), width: 2)

        // User Silhouette inside Badge
        fillCircle(ctx, center: CGPoint(x: 169, y: 248), radius: 15, color: rgba(255, 255, 255, 1))
        let shoulders = CGMutablePath()
        shoulders.move(to: CGPoint(x: 146, y: 284))
        shoulders.addQuadCurve(to: CGPoint(x: 192, y: 284), control: CGPoint(x: 169, y: 262))
        ctx.saveGState()
        ctx.addPath(shoulders)
        ctx.setStrokeColor(rgba(255, 255, 255, 1))
        ctx.setLineWidth(11)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()

        // Active Status Pill
        let pillRect = CGRect(x: 228, y: 222, width: 82, height: 24)
        let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        fillRoundedRect(ctx, rect: pillRect, radius: 12, color: rgba(16, 185, 129, 0.22))
        strokePath(ctx, path: pillPath, color: rgba(52, 211, 153, 1), width: 2)
        fillCircle(ctx, center: CGPoint(x: 244, y: 234), radius: 5.5, color: rgba(52, 211, 153, 1))
        fillRoundedRect(ctx, rect: CGRect(x: 256, y: 230, width: 40, height: 8), radius: 4, color: rgba(167, 243, 208, 1))

        // CLI Prompt Symbol >_
        let chevron = CGMutablePath()
        chevron.move(to: CGPoint(x: 234, y: 270))
        chevron.addLine(to: CGPoint(x: 254, y: 285))
        chevron.addLine(to: CGPoint(x: 234, y: 300))
        ctx.saveGState()
        ctx.addPath(chevron)
        ctx.setStrokeColor(rgba(255, 255, 255, 1))
        ctx.setLineWidth(11)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.strokePath()
        ctx.restoreGState()

        let underscore = CGMutablePath()
        underscore.move(to: CGPoint(x: 266, y: 300))
        underscore.addLine(to: CGPoint(x: 298, y: 300))
        ctx.saveGState()
        ctx.addPath(underscore)
        ctx.setStrokeColor(rgba(56, 189, 248, 1))
        ctx.setLineWidth(11)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.restoreGState()

        // Bottom Config Track Bars
        fillRoundedRect(ctx, rect: CGRect(x: 128, y: 328, width: 256, height: 13), radius: 6.5, color: rgba(255, 255, 255, 0.18))
        let activeBarPath = CGPath(roundedRect: CGRect(x: 128, y: 328, width: 170, height: 13), cornerWidth: 6.5, cornerHeight: 6.5, transform: nil)
        fillLinearGradient(
            ctx,
            in: activeBarPath,
            start: CGPoint(x: 128, y: 328),
            end: CGPoint(x: 298, y: 328),
            stops: [
                (0.0, rgba(56, 189, 248, 1)),
                (0.5, rgba(129, 140, 248, 1)),
                (1.0, rgba(52, 211, 153, 1)),
            ]
        )
        fillRoundedRect(ctx, rect: CGRect(x: 128, y: 353, width: 180, height: 11), radius: 5.5, color: rgba(255, 255, 255, 0.12))

        ctx.restoreGState() // End Squircle Clip

        // 5. Outer Squircle Glass Rim Light
        strokeGradientPath(
            ctx,
            path: squirclePath,
            width: 5,
            start: CGPoint(x: 256, y: 32),
            end: CGPoint(x: 256, y: 480),
            stops: [
                (0.0, rgba(255, 255, 255, 0.45)),
                (0.5, rgba(255, 255, 255, 0.12)),
                (1.0, rgba(0, 0, 0, 0.45)),
            ]
        )
    }

    private static func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat) -> CGColor {
        CGColor(colorSpace: colorSpace, components: [r / 255.0, g / 255.0, b / 255.0, a])!
    }

    private static func setShadow(_ ctx: CGContext, scale: CGFloat, dy: CGFloat, blur: CGFloat, color: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * scale), blur: blur * scale, color: color)
    }

    private static func fillLinearGradient(
        _ ctx: CGContext,
        in path: CGPath,
        start: CGPoint,
        end: CGPoint,
        stops: [(CGFloat, CGColor)]
    ) {
        let colors = stops.map(\.1) as CFArray
        var locations = stops.map(\.0)
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: &locations) else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func drawRadialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
        let transparent = color.copy(alpha: 0)!
        let colors = [color, transparent] as CFArray
        var locations: [CGFloat] = [0.0, 1.0]
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: &locations) else { return }
        ctx.saveGState()
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 8, endCenter: center, endRadius: radius, options: [])
        ctx.restoreGState()
    }

    private static func strokePath(_ ctx: CGContext, path: CGPath, color: CGColor, width: CGFloat) {
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setStrokeColor(color)
        ctx.setLineWidth(width)
        ctx.strokePath()
        ctx.restoreGState()
    }

    private static func strokeGradientPath(
        _ ctx: CGContext,
        path: CGPath,
        width: CGFloat,
        start: CGPoint,
        end: CGPoint,
        stops: [(CGFloat, CGColor)]
    ) {
        let colors = stops.map(\.1) as CFArray
        var locations = stops.map(\.0)
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: &locations) else { return }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setLineWidth(width)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }

    private static func fillCircle(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.setFillColor(color)
        ctx.fillEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.restoreGState()
    }

    private static func fillRoundedRect(_ ctx: CGContext, rect: CGRect, radius: CGFloat, color: CGColor) {
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(color)
        ctx.fillPath()
        ctx.restoreGState()
    }
}
