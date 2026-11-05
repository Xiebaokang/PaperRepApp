// Run from the repository root: swift ios/scripts/generate-icon.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let sourceURL = URL(fileURLWithPath: "build/icon.png")
let targetURL = URL(fileURLWithPath: "ios/PaperRep/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("Cannot render app icon") }
context.setFillColor(CGColor(red: 0.94, green: 0.96, blue: 0.94, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
guard let rendered = context.makeImage(), let destination = CGImageDestinationCreateWithURL(targetURL as CFURL, UTType.png.identifier as CFString, 1, nil) else { fatalError("Cannot save app icon") }
CGImageDestinationAddImage(destination, rendered, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Cannot finalize app icon") }
