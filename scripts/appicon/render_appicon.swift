import SwiftUI
import AppKit
// Same drawing parameters as VinylDiscView (Build 211, ported from Podium, MIT)
let disc: CGFloat = 234, labelSize: CGFloat = 72
let cover = NSImage(contentsOfFile: "/tmp/icon214/cover3000.jpg")!
struct Grooves: View { var body: some View { Canvas { c, size in
  let side = min(size.width, size.height); let ctr = CGPoint(x: size.width/2, y: size.height/2)
  c.fill(Path(ellipseIn: CGRect(x: ctr.x-side/2, y: ctr.y-side/2, width: side, height: side)), with: .color(Color(white: 0.05)))
  for i in 0..<26 { let r = side/2 - side*(0.05 + CGFloat(i)*0.012); c.stroke(Path(ellipseIn: CGRect(x: ctr.x-r, y: ctr.y-r, width: r*2, height: r*2)), with: .color(.white.opacity(i.isMultiple(of: 5) ? 0.07 : 0.03)), lineWidth: 1) } } } }
struct Disc: View { var body: some View { ZStack {
    ZStack { Grooves()
      Image(nsImage: cover).resizable().scaledToFill().frame(width: labelSize, height: labelSize).clipShape(Circle())
      Circle().fill(Color(red: 0.025, green: 0.03, blue: 0.04)).frame(width: disc*0.022, height: disc*0.022) }.clipShape(Circle())
    Circle().fill(AngularGradient(colors: [.clear, .white.opacity(0.07), .clear, .clear, .white.opacity(0.05), .clear], center: .center, angle: .degrees(-30)))
  }.frame(width: disc, height: disc).shadow(color: .black.opacity(0.55), radius: 26, y: 14) } }
let paper = Color(red: 0xF4/255.0, green: 0xF1/255.0, blue: 0xEE/255.0)
let k: CGFloat = 820 / disc            // disc = 820 px of 1024
let canvasPt = 1024 / k
struct Icon: View { var body: some View { ZStack { paper; Disc().offset(y: -5) }.frame(width: canvasPt, height: canvasPt) } }
@MainActor func png(_ v: some View, scale: CGFloat, _ path: String) { let r = ImageRenderer(content: v); r.scale = scale; r.isOpaque = true
  let rep = NSBitmapImageRep(cgImage: r.cgImage!); try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path)) }
struct Preview: View { let icon: NSImage
  func tile(_ img: NSImage?, _ s: CGFloat) -> some View { Group { if let img { Image(nsImage: img).resizable() } else { Color(white: 0.85).overlay(Text("空白\n(无图标)").font(.system(size: s*0.12)).multilineTextAlignment(.center).foregroundStyle(.secondary)) } }
      .frame(width: s, height: s).clipShape(RoundedRectangle(cornerRadius: s*0.2237, style: .continuous)) }
  var body: some View { HStack(alignment: .top, spacing: 60) {
    VStack(spacing: 14) { tile(nil, 300); Text("Before（Build 213 及之前：AppIcon 无图片）").font(.system(size: 18, weight: .semibold)) }
    VStack(spacing: 14) { tile(icon, 300); HStack(spacing: 24) { tile(icon, 120); tile(icon, 60) }
      Text("After（Build 214：Podium 黑胶 + Nine Track Mind）").font(.system(size: 18, weight: .semibold)) }
  }.padding(50).background(Color.white).foregroundStyle(.black) } }
MainActor.assumeIsolated {
  png(Icon(), scale: k, "/tmp/icon214/AppIcon-1024.png")
  let img = NSImage(contentsOfFile: "/tmp/icon214/AppIcon-1024.png")!
  png(Preview(icon: img), scale: 2, "/tmp/icon214/appicon_213_preview.png"); print("ok")
}
