import Core
import Photos
import UIKit

/// Imagem pronta para envio: JPEG reduzido (lado maior <= 1600 px) em base64.
struct EncodedImage {
    let jpeg: Data
    let width: Int
    let height: Int
    let capturedAt: Date?
    let source: ImageSourceKind
    let mime = "image/jpeg"

    var base64: String { jpeg.base64EncodedString() }
}

enum ImageLoaderError: LocalizedError {
    case noPermission
    case noPhoto
    case tooOld(minutes: Int)
    case decodeFailed

    // Frases curtas: tambem sao faladas nos oculos.
    var errorDescription: String? {
        switch self {
        case .noPermission:
            return "Sem permissão para acessar as fotos. Libere o acesso nos Ajustes do iPhone."
        case .noPhoto:
            return "Nenhuma foto encontrada na galeria."
        case .tooOld(let minutes):
            return "A foto mais recente é de \(minutes) minutos atrás. Tire uma nova foto da questão."
        case .decodeFailed:
            return "Não consegui abrir a foto."
        }
    }
}

enum ImageLoader {
    static let maxSide: CGFloat = 1600
    static let jpegQuality: CGFloat = 0.7

    static func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    /// Foto mais recente do Rolo (onde o app Meta AI importa as fotos dos oculos).
    static func latestPhoto(maxAgeMinutes: Int) async throws -> EncodedImage {
        guard await requestAccess() else { throw ImageLoaderError.noPermission }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 1
        guard let asset = PHAsset.fetchAssets(with: options).firstObject else { throw ImageLoaderError.noPhoto }

        if maxAgeMinutes > 0, let created = asset.creationDate {
            let age = Date().timeIntervalSince(created)
            if age > Double(maxAgeMinutes * 60) { throw ImageLoaderError.tooOld(minutes: Int(age / 60)) }
        }
        let image = try await loadImage(asset)
        return try encode(image, source: .photoLibrary, capturedAt: asset.creationDate)
    }

    private static func loadImage(_ asset: PHAsset) async throws -> UIImage {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true  // foto pode estar so no iCloud
        options.deliveryMode = .highQualityFormat
        options.version = .current
        return try await withCheckedThrowingContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                if let data, let image = UIImage(data: data) {
                    cont.resume(returning: image)
                } else {
                    cont.resume(throwing: ImageLoaderError.decodeFailed)
                }
            }
        }
    }

    static func encode(_ image: UIImage, source: ImageSourceKind, capturedAt: Date? = Date()) throws -> EncodedImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { throw ImageLoaderError.decodeFailed }
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        // draw(in:) ja aplica a orientacao da foto.
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = resized.jpegData(compressionQuality: jpegQuality) else { throw ImageLoaderError.decodeFailed }
        return EncodedImage(jpeg: jpeg, width: Int(target.width), height: Int(target.height),
                            capturedAt: capturedAt, source: source)
    }
}
