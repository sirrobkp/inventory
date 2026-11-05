import Flutter
import Foundation
import Security

/// Same contract as the Android plugin: "sign" (SHA1withRSA, Base64) and "serial" (hex).
public class KiboSignerPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "kibo/signer", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(KiboSignerPlugin(), channel: channel)
  }

  private func fail(_ msg: String) -> NSError {
    return NSError(domain: "KiboSigner", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let a = call.arguments as? [String: Any],
          let path = a["path"] as? String,
          let pw = a["password"] as? String else {
      result(FlutterError(code: "ARGS", message: "Missing arguments", details: nil))
      return
    }
    do {
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      var items: CFArray?
      let status = SecPKCS12Import(data as CFData, [kSecImportExportPassphrase as String: pw] as CFDictionary, &items)
      guard status == errSecSuccess,
            let arr = items as? [[String: Any]],
            let first = arr.first,
            let identityRef = first[kSecImportItemIdentity as String] else {
        throw fail("Cannot open certificate (wrong password?) status \(status)")
      }
      let identity = identityRef as! SecIdentity

      switch call.method {
      case "sign":
        var keyRef: SecKey?
        SecIdentityCopyPrivateKey(identity, &keyRef)
        guard let key = keyRef, let text = a["data"] as? String else { throw fail("No private key / data") }
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA1, Data(text.utf8) as CFData, &err) else {
          throw (err!.takeRetainedValue() as Error)
        }
        result((sig as Data).base64EncodedString())
      case "serial":
        var certRef: SecCertificate?
        SecIdentityCopyCertificate(identity, &certRef)
        guard let cert = certRef, let serial = SecCertificateCopySerialNumberData(cert, nil) as Data? else {
          throw fail("No certificate serial")
        }
        let hex = serial.map { String(format: "%02X", $0) }.joined()
        result(String(hex.drop(while: { $0 == "0" })))
      default:
        result(FlutterMethodNotImplemented)
      }
    } catch {
      result(FlutterError(code: "SIGN_ERROR", message: error.localizedDescription, details: nil))
    }
  }
}
