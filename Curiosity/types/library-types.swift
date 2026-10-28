import Foundation

/// Un robot de la biblioteca de MuJoCo Menagerie (catálogo incluido en la app).
struct LibraryRobot: Identifiable, Decodable, Hashable {
    let id: String          // <carpeta>/<modelo>
    let name: String
    let category: String
    let xml: String         // ruta del MJCF dentro del repositorio
    let image: String?      // vista previa dentro del repositorio
    let files: [String]     // todo lo que hay que descargar
}

struct LibraryCatalog: Decodable {
    let source: String      // repositorio en GitHub
    let commit: String      // versión fija: el catálogo y los archivos siempre coinciden
    let robots: [LibraryRobot]
}
