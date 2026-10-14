import AppKit
import CoreGraphics

// Варианты иконки Znaika (рисует все шесть + «Сравнение.png»):
//   swiftc -O scripts/app_icons.swift -o /tmp/app_icons && /tmp/app_icons <папка>
// Выбрана «1 Волна в текст» (2026-10-13); размеры для AppIcon.appiconset —
//   for s in 16 32 64 128 256 512 1024; do sips -z $s $s "<папка>/1 Волна в текст.png" --out app_icon_$s.png; done
//
// Иконки Znaika по сетке macOS: холст 1024, «плитка» 824×824 с отступом 100, скругление ~185,
// мягкая тень снизу. Каждый вариант рисуется в координатах плитки (0…824, y вверх).

let size = 1024
let tile: CGFloat = 824
let inset: CGFloat = 100
let radius: CGFloat = 185

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
  CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
          blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
  CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

func roundedRect(_ r: CGRect, _ rad: CGFloat) -> CGPath {
  CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
}

/// Плитка с фоном-градиентом сверху вниз, тенью и тонким бликом по краю.
func drawTile(_ ctx: CGContext, top: CGColor, bottom: CGColor, content: (CGContext) -> Void) {
  let rect = CGRect(x: inset, y: inset - 10, width: tile, height: tile)
  let path = roundedRect(rect, radius)
  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
  ctx.addPath(path)
  ctx.setFillColor(bottom)
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(path)
  ctx.clip()
  ctx.drawLinearGradient(gradient([top, bottom]), start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: [])
  ctx.translateBy(x: rect.minX, y: rect.minY)
  content(ctx)
  ctx.restoreGState()

  // Блик по краю.
  ctx.saveGState()
  ctx.addPath(roundedRect(rect.insetBy(dx: 1.5, dy: 1.5), radius - 1.5))
  ctx.setStrokeColor(color(0xffffff, 0.18))
  ctx.setLineWidth(3)
  ctx.strokePath()
  ctx.restoreGState()
}

/// Столбики волны: высоты в долях, по центру по вертикали.
func bars(_ ctx: CGContext, x: CGFloat, centerY: CGFloat, width: CGFloat, gap: CGFloat, heights: [CGFloat], maxH: CGFloat,
          fill: (Int) -> CGColor) {
  for (i, h) in heights.enumerated() {
    let barH = max(width, h * maxH)
    let r = CGRect(x: x + CGFloat(i) * (width + gap), y: centerY - barH / 2, width: width, height: barH)
    ctx.addPath(roundedRect(r, width / 2))
    ctx.setFillColor(fill(i))
    ctx.fillPath()
  }
}

func line(_ ctx: CGContext, _ r: CGRect, _ c: CGColor) {
  ctx.addPath(roundedRect(r, r.height / 2))
  ctx.setFillColor(c)
  ctx.fillPath()
}

func bubble(_ ctx: CGContext, _ r: CGRect, rad: CGFloat, tailLeft: Bool) -> CGPath {
  let p = CGMutablePath()
  p.addPath(roundedRect(r, rad))
  // Хвостик снизу.
  // Хвостик — как в «Сообщениях»: широкое основание, кончик уходит вниз и наружу.
  let tx = tailLeft ? r.minX + rad * 0.7 : r.maxX - rad * 0.7
  let dir: CGFloat = tailLeft ? -1 : 1
  p.move(to: CGPoint(x: tx + 70 * dir * -1, y: r.minY + 30))
  p.addLine(to: CGPoint(x: tx + 60 * dir, y: r.minY + 30))
  p.addQuadCurve(to: CGPoint(x: tx - 10 * dir * -1 + 30 * dir, y: r.minY - 80), control: CGPoint(x: tx + 40 * dir, y: r.minY - 30))
  p.addQuadCurve(to: CGPoint(x: tx + 70 * dir * -1, y: r.minY + 30), control: CGPoint(x: tx - 10 * dir, y: r.minY - 30))
  p.closeSubpath()
  return p
}

// MARK: варианты

/// 1. «Волна → текст»: звуковая волна слева переходит в строки заметок справа.
func waveToText(_ ctx: CGContext) {
  drawTile(ctx, top: color(0x2B2F45), bottom: color(0x14161F)) { ctx in
    // Волна (7 столбиков, 7×36 + 6×22 = 384) и строки (до 170) — группа шириной 600 по центру.
    let heights: [CGFloat] = [0.3, 0.62, 0.95, 0.55, 1.0, 0.68, 0.38]
    bars(ctx, x: 112, centerY: 412, width: 36, gap: 22, heights: heights, maxH: 380) { i in
      let t = CGFloat(i) / 6
      return CGColor(srgbRed: 0.25 + 0.45 * t, green: 0.85 - 0.45 * t, blue: 0.95, alpha: 1)
    }
    // Строки заметок — по центру относительно волны.
    let x: CGFloat = 542
    let widths: [CGFloat] = [170, 130, 170, 96]
    for (i, w) in widths.enumerated() {
      line(ctx, CGRect(x: x, y: 507 - CGFloat(i) * 70, width: w, height: 32), color(0xffffff, i == 0 ? 0.95 : 0.7))
    }
  }
}

/// 2. «Пузырь с волной»: облачко реплики, в нём волна; тёплый оранжево-красный.
func bubbleWave(_ ctx: CGContext) {
  drawTile(ctx, top: color(0xFF8A3D), bottom: color(0xE8344E)) { ctx in
    let r = CGRect(x: 132, y: 240, width: 560, height: 420)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x7A0E1E, 0.35))
    ctx.addPath(bubble(ctx, r, rad: 130, tailLeft: true))
    ctx.setFillColor(color(0xffffff))
    ctx.fillPath()
    ctx.restoreGState()
    let heights: [CGFloat] = [0.3, 0.6, 1.0, 0.7, 0.45, 0.85, 0.5, 0.3]
    let w: CGFloat = 32, gap: CGFloat = 22
    let total = CGFloat(heights.count) * w + CGFloat(heights.count - 1) * gap
    bars(ctx, x: r.midX - total / 2, centerY: r.midY, width: w, gap: gap, heights: heights, maxH: 270) { _ in color(0xEE4A45) }
  }
}

/// 3. «Блокнот и запись»: бумажный лист с кольцами, строки и красная точка записи.
func notebookRec(_ ctx: CGContext) {
  drawTile(ctx, top: color(0x5B8CFF), bottom: color(0x3A4FD8)) { ctx in
    let page = CGRect(x: 170, y: 120, width: 484, height: 600)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0x101860, 0.45))
    ctx.addPath(roundedRect(page, 48))
    ctx.setFillColor(color(0xFFFDF6))
    ctx.fillPath()
    ctx.restoreGState()
    // Кольца сверху.
    for i in 0..<4 {
      let cx = page.minX + 92 + CGFloat(i) * 100
      ctx.addPath(roundedRect(CGRect(x: cx - 14, y: page.maxY - 52, width: 28, height: 96), 14))
      ctx.setFillColor(color(0xC9CED8))
      ctx.fillPath()
    }
    // Строки.
    for i in 0..<5 {
      let w: CGFloat = i == 4 ? 220 : 340
      line(ctx, CGRect(x: page.minX + 64, y: page.maxY - 170 - CGFloat(i) * 72, width: w, height: 22), color(0x9AA6C2, 0.75))
    }
    // Точка записи.
    let dot = CGRect(x: page.maxX - 190, y: page.minY + 40, width: 150, height: 150)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x8A0010, 0.45))
    ctx.addEllipse(in: dot)
    ctx.setFillColor(color(0xFF3B30))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addEllipse(in: dot.insetBy(dx: 22, dy: 22))
    ctx.setStrokeColor(color(0xffffff, 0.9))
    ctx.setLineWidth(10)
    ctx.strokePath()
  }
}

/// 4. «Два голоса»: две реплики — собеседник (слева) и вы (справа), бирюзово-зелёный.
func twoVoices(_ ctx: CGContext) {
  drawTile(ctx, top: color(0x34D1B0), bottom: color(0x118A7E)) { ctx in
    let left = CGRect(x: 110, y: 400, width: 420, height: 260)
    let right = CGRect(x: 300, y: 150, width: 420, height: 230)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0x03443D, 0.35))
    ctx.addPath(bubble(ctx, left, rad: 110, tailLeft: true))
    ctx.setFillColor(color(0xffffff))
    ctx.fillPath()
    ctx.addPath(bubble(ctx, right, rad: 105, tailLeft: false))
    ctx.setFillColor(color(0x0B5E57))
    ctx.fillPath()
    ctx.restoreGState()
    let h1: [CGFloat] = [0.35, 0.8, 0.55, 1.0, 0.6, 0.3]
    bars(ctx, x: left.minX + 92, centerY: left.midY, width: 28, gap: 20, heights: h1, maxH: 160) { _ in color(0x119C8C) }
    for (i, w) in [250.0, 180.0].enumerated() {
      line(ctx, CGRect(x: right.minX + 80, y: right.midY + 18 - CGFloat(i) * 62, width: CGFloat(w), height: 30), color(0xffffff, 0.92))
    }
  }
}

/// 5. «Микрофон-ручка»: микрофон, у которого вместо ножки — перо; фиолетовый градиент.
func micPen(_ ctx: CGContext) {
  drawTile(ctx, top: color(0xA35BFF), bottom: color(0x5B2DD6)) { ctx in
    let cx: CGFloat = 412
    // Головка микрофона.
    let head = CGRect(x: cx - 120, y: 380, width: 240, height: 330)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x220A60, 0.45))
    ctx.addPath(roundedRect(head, 120))
    ctx.setFillColor(color(0xffffff))
    ctx.fillPath()
    // Перо.
    let nib = CGMutablePath()
    nib.move(to: CGPoint(x: cx - 78, y: 360))
    nib.addLine(to: CGPoint(x: cx + 78, y: 360))
    nib.addLine(to: CGPoint(x: cx + 30, y: 170))
    nib.addLine(to: CGPoint(x: cx, y: 110))
    nib.addLine(to: CGPoint(x: cx - 30, y: 170))
    nib.closeSubpath()
    ctx.addPath(nib)
    ctx.fillPath()
    ctx.restoreGState()
    // Прорезь пера и решётка микрофона.
    line(ctx, CGRect(x: cx - 6, y: 170, width: 12, height: 130), color(0x6A3BE0))
    ctx.addEllipse(in: CGRect(x: cx - 16, y: 270, width: 32, height: 32))
    ctx.setFillColor(color(0x6A3BE0))
    ctx.fillPath()
    for i in 0..<3 {
      line(ctx, CGRect(x: cx - 70, y: 600 - CGFloat(i) * 56, width: 140, height: 22), color(0x8C5BF0, 0.55))
    }
  }
}

/// 6. «Волна-кольцо»: круговая звуковая волна вокруг точки записи; светлый, по-эппловски.
func ringWave(_ ctx: CGContext) {
  drawTile(ctx, top: color(0xFFFFFF), bottom: color(0xE4E8F0)) { ctx in
    let c = CGPoint(x: 412, y: 412)
    let n = 48
    for i in 0..<n {
      let a = CGFloat(i) / CGFloat(n) * .pi * 2
      // Неровная, но без перекоса волна: сумма гармоник, как у живого голоса.
      let v = 0.55 + 0.25 * sin(a * 5 + 0.3) + 0.15 * sin(a * 11 + 1.7) + 0.1 * sin(a * 17)
      let h = 36 + 120 * max(0, min(1, v))
      let inner: CGFloat = 200
      ctx.saveGState()
      ctx.translateBy(x: c.x, y: c.y)
      ctx.rotate(by: a)
      let t = CGFloat(i) / CGFloat(n)
      ctx.addPath(roundedRect(CGRect(x: inner, y: -9, width: h, height: 18), 9))
      ctx.setFillColor(CGColor(srgbRed: 0.35 + 0.4 * t, green: 0.45 - 0.2 * t, blue: 1.0 - 0.15 * t, alpha: 1))
      ctx.fillPath()
      ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x8A0010, 0.35))
    ctx.addEllipse(in: CGRect(x: c.x - 120, y: c.y - 120, width: 240, height: 240))
    ctx.setFillColor(color(0xFF3B30))
    ctx.fillPath()
    ctx.restoreGState()
  }
}

func render(_ name: String, _ draw: (CGContext) -> Void, to dir: URL) -> NSImage {
  let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  draw(ctx)
  let image = ctx.makeImage()!
  let rep = NSBitmapImageRep(cgImage: image)
  try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name).png"))
  return NSImage(cgImage: image, size: NSSize(width: size, height: size))
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
let variants: [(String, (CGContext) -> Void)] = [
  ("1 Волна в текст", waveToText),
  ("2 Реплика с волной", bubbleWave),
  ("3 Блокнот и запись", notebookRec),
  ("4 Два голоса", twoVoices),
  ("5 Микрофон-перо", micPen),
  ("6 Кольцо-волна", ringWave),
]
var images: [(String, NSImage)] = []
for (name, draw) in variants {
  images.append((name, render(name, draw, to: out)))
}

// Сравнение: каждая в 256, 64 и 32 px (как в Dock, Finder и списках).
let cell: CGFloat = 400
let sheet = NSImage(size: NSSize(width: cell * 3, height: cell * 2))
sheet.lockFocus()
NSColor(white: 0.93, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: cell * 3, height: cell * 2).fill()
for (i, (name, img)) in images.enumerated() {
  let col = CGFloat(i % 3), row = CGFloat(1 - i / 3)
  let ox = col * cell, oy = row * cell
  img.draw(in: NSRect(x: ox + 20, y: oy + 90, width: 256, height: 256))
  img.draw(in: NSRect(x: ox + 290, y: oy + 200, width: 64, height: 64))
  img.draw(in: NSRect(x: ox + 306, y: oy + 140, width: 32, height: 32))
  (name as NSString).draw(at: NSPoint(x: ox + 24, y: oy + 40),
                          withAttributes: [.font: NSFont.systemFont(ofSize: 22, weight: .medium), .foregroundColor: NSColor.black])
}
sheet.unlockFocus()
let tiff = sheet.tiffRepresentation!
try! NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
  .write(to: out.appendingPathComponent("Сравнение.png"))
print("ok")
