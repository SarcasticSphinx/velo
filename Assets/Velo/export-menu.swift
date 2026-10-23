import AppKit
// Simplified native wave mark for legible macOS template icons.
for size in [14,16,18,24,28,32,36,48] {
 let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
 NSGraphicsContext.saveGraphicsState()
 NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
 let scale = CGFloat(size)/100
 let transform = AffineTransform(scale: scale)
 let path = NSBezierPath()
 path.move(to: NSPoint(x: 3, y: 48))
 path.curve(to: NSPoint(x: 40,y: 86), controlPoint1: NSPoint(x: 24,y: 48), controlPoint2: NSPoint(x: 28,y: 86))
 path.curve(to: NSPoint(x: 61,y: 34), controlPoint1: NSPoint(x: 53,y: 86), controlPoint2: NSPoint(x: 51,y: 34))
 path.curve(to: NSPoint(x: 78,y: 63), controlPoint1: NSPoint(x: 68,y: 34), controlPoint2: NSPoint(x: 67,y: 63))
 path.curve(to: NSPoint(x: 97,y: 31), controlPoint1: NSPoint(x: 88,y: 63), controlPoint2: NSPoint(x: 88,y: 35))
 path.curve(to: NSPoint(x: 76,y: 39), controlPoint1: NSPoint(x: 87,y: 30), controlPoint2: NSPoint(x: 84,y: 45))
 path.curve(to: NSPoint(x: 57,y: 14), controlPoint1: NSPoint(x: 68,y: 34), controlPoint2: NSPoint(x: 69,y: 14))
 path.curve(to: NSPoint(x: 31,y: 51), controlPoint1: NSPoint(x: 43,y: 14), controlPoint2: NSPoint(x: 44,y: 51))
 path.curve(to: NSPoint(x: 3,y: 48), controlPoint1: NSPoint(x: 20,y: 51), controlPoint2: NSPoint(x: 18,y: 35))
 path.close(); path.transform(using: transform)
 NSColor.black.setFill(); path.fill()
 NSGraphicsContext.restoreGraphicsState()
 try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Assets/Velo/MenuBar-\(size).png"))
}
