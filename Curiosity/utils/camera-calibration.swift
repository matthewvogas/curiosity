import Foundation

/// Calibración de una cámara fija respecto del robot, sin patrones ni medidas: la punta de la pinza se pone en
/// varios lugares (su posición 3D sale de la cinemática del robot) y se marca dónde se ve en la imagen. Con 6 o
/// más pares se calcula la proyección de la cámara (DLT, 3×4) y con ella un píxel se convierte en un rayo que
/// corta la mesa. Sirve para cualquier robot y cualquier cámara. Coordenadas de imagen normalizadas (0…1), así
/// no depende del tamaño de cada foto.
enum CameraCalibration {
    struct Pair: Codable, Equatable {
        var point: [Double]   // m, marco de la base del robot
        var pixel: [Double]   // 0…1 (x a la derecha, y hacia abajo)
    }

    /// La proyección (12 números, fila por fila) y su error medio al reproyectar los pares, en fracción del ancho.
    static func solve(_ pairs: [Pair]) -> (matrix: [Double], error: Double)? {
        guard pairs.count >= 6 else { return nil }
        // Normalización de Hartley: centrar y escalar, para que el sistema esté bien condicionado.
        let c3 = (0..<3).map { i in pairs.map { $0.point[i] }.reduce(0, +) / Double(pairs.count) }
        let s3 = sqrt(3) / max(1e-9, pairs.map { p in sqrt((0..<3).map { pow(p.point[$0] - c3[$0], 2) }.reduce(0, +)) }.reduce(0, +) / Double(pairs.count))
        let c2 = (0..<2).map { i in pairs.map { $0.pixel[i] }.reduce(0, +) / Double(pairs.count) }
        let s2 = sqrt(2) / max(1e-9, pairs.map { p in sqrt((0..<2).map { pow(p.pixel[$0] - c2[$0], 2) }.reduce(0, +)) }.reduce(0, +) / Double(pairs.count))

        var ata = [[Double]](repeating: [Double](repeating: 0, count: 12), count: 12)
        for p in pairs {
            let X = (0..<3).map { (p.point[$0] - c3[$0]) * s3 }
            let u = (p.pixel[0] - c2[0]) * s2, v = (p.pixel[1] - c2[1]) * s2
            let rows = [
                [X[0], X[1], X[2], 1, 0, 0, 0, 0, -u * X[0], -u * X[1], -u * X[2], -u],
                [0, 0, 0, 0, X[0], X[1], X[2], 1, -v * X[0], -v * X[1], -v * X[2], -v],
            ]
            for r in rows { for i in 0..<12 { for j in 0..<12 { ata[i][j] += r[i] * r[j] } } }
        }
        let n = smallestEigenvector(ata)
        // Deshacer la normalización: P = T2⁻¹ · Pn · T3.
        let pn = [[n[0], n[1], n[2], n[3]], [n[4], n[5], n[6], n[7]], [n[8], n[9], n[10], n[11]]]
        let t3: [[Double]] = [[s3, 0, 0, -s3 * c3[0]], [0, s3, 0, -s3 * c3[1]], [0, 0, s3, -s3 * c3[2]], [0, 0, 0, 1]]
        let t2inv: [[Double]] = [[1 / s2, 0, c2[0]], [0, 1 / s2, c2[1]], [0, 0, 1]]
        var flat = multiply(t2inv, multiply(pn, t3)).flatMap { $0 }
        // Signo: que los puntos que la cámara ve tengan profundidad positiva (así se sabe qué está delante).
        if depth(flat, pairs[0].point) < 0 { flat = flat.map { -$0 } }
        let error = pairs.map { pair -> Double in
            guard let q = project(flat, pair.point) else { return 1 }
            return hypot(q[0] - pair.pixel[0], q[1] - pair.pixel[1])
        }.reduce(0, +) / Double(pairs.count)
        return (flat, error)
    }

    /// Dónde se ve un punto 3D (0…1), o nil si queda detrás de la cámara.
    static func project(_ m: [Double], _ x: [Double]) -> [Double]? {
        let h = (0..<3).map { r in m[r * 4] * x[0] + m[r * 4 + 1] * x[1] + m[r * 4 + 2] * x[2] + m[r * 4 + 3] }
        guard h[2] > 1e-12 else { return nil }
        return [h[0] / h[2], h[1] / h[2]]
    }

    private static func depth(_ m: [Double], _ x: [Double]) -> Double {
        m[8] * x[0] + m[9] * x[1] + m[10] * x[2] + m[11]
    }

    /// El punto de la mesa (o del plano z = `height`, en m) que se ve en el píxel (0…1).
    static func point(_ m: [Double], pixel: [Double], height: Double) -> [Double]? {
        let M = [[m[0], m[1], m[2]], [m[4], m[5], m[6]], [m[8], m[9], m[10]]]
        guard let inv = invert3(M) else { return nil }
        let p4 = [m[3], m[7], m[11]]
        let center = (0..<3).map { r in -(0..<3).map { inv[r][$0] * p4[$0] }.reduce(0, +) }
        let d = (0..<3).map { r in inv[r][0] * pixel[0] + inv[r][1] * pixel[1] + inv[r][2] }
        guard abs(d[2]) > 1e-9 else { return nil }
        let t = (height - center[2]) / d[2]
        let hit = (0..<3).map { center[$0] + d[$0] * t }
        // Tiene que quedar delante de la cámara (si no, ese píxel no mira la mesa).
        return depth(m, hit) > 0 ? hit : nil
    }

    // MARK: - Álgebra chica

    private static func multiply(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        a.map { row in (0..<b[0].count).map { j in row.indices.map { row[$0] * b[$0][j] }.reduce(0, +) } }
    }

    private static func invert3(_ m: [[Double]]) -> [[Double]]? {
        let det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        guard abs(det) > 1e-15 else { return nil }
        let c: [[Double]] = [
            [m[1][1] * m[2][2] - m[1][2] * m[2][1], m[0][2] * m[2][1] - m[0][1] * m[2][2], m[0][1] * m[1][2] - m[0][2] * m[1][1]],
            [m[1][2] * m[2][0] - m[1][0] * m[2][2], m[0][0] * m[2][2] - m[0][2] * m[2][0], m[0][2] * m[1][0] - m[0][0] * m[1][2]],
            [m[1][0] * m[2][1] - m[1][1] * m[2][0], m[0][1] * m[2][0] - m[0][0] * m[2][1], m[0][0] * m[1][1] - m[0][1] * m[1][0]],
        ]
        return c.map { $0.map { $0 / det } }
    }

    /// El autovector del autovalor más chico de una matriz simétrica (Jacobi).
    private static func smallestEigenvector(_ input: [[Double]]) -> [Double] {
        var a = input
        let n = a.count
        var v = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
        for _ in 0..<100 {
            var off = 0.0
            for i in 0..<n { for j in (i + 1)..<n { off += a[i][j] * a[i][j] } }
            if off < 1e-22 { break }
            for p in 0..<n {
                for q in (p + 1)..<n where abs(a[p][q]) > 1e-300 {
                    let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                    let t = (theta >= 0 ? 1 : -1) / (abs(theta) + sqrt(theta * theta + 1))
                    let c = 1 / sqrt(t * t + 1), s = t * c
                    for k in 0..<n {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }
        let i = (0..<n).min { a[$0][$0] < a[$1][$1] }!
        return (0..<n).map { v[$0][i] }
    }
}
