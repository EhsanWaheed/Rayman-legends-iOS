// Crops the launcher art to a square for the app icon: square_icon.swift <in.png> <out.png>
// A portrait box cover is cut from its top (the logo and the characters' faces), a landscape one from its centre.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(1) }
let side = min(image.width, image.height)
let x = (image.width - side) / 2
let y = image.height > image.width ? 0 : (image.height - side) / 2
guard let square = image.cropping(to: CGRect(x: x, y: y, width: side, height: side)),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, square, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
