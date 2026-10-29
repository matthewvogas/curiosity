import Foundation

/// Objetos de la escena diseñados por la IA a partir de una descripción («una rueda de bicicleta», «un
/// escritorio», «un cuchillo de cocina»): piezas simples con medidas y peso del mundo real. La IA responde
/// con la herramienta `build_object` (se le pide que la use: los modelos actuales no aceptan forzarla), así que la
/// respuesta es JSON válido.
enum ObjectDesigner {
    static let system = """
    You design physical objects for a robot physics simulator (MuJoCo). Given a short description, \
    build the object from simple primitive parts with REAL-WORLD dimensions and mass, then call build_object.

    Rules:
    - Units: centimeters, degrees, kilograms. The object's frame: origin at the center of the whole object, z up, \
    x forward, y left. Part positions are relative to that origin.
    - Shapes: box [length x, width y, height z] · sphere [radius] · cylinder [radius, length] · capsule [radius, \
    length of the straight part]. Cylinders and capsules point along z; rotate them with rotation_deg (e.g. [90, 0, 0] \
    makes the axis horizontal along y, like a wheel standing up; [0, 90, 0] lays it along x).
    - Use real sizes for a typical example of the thing (a kitchen knife ≈ 30 cm long, blade 3 cm tall and 0.2 cm \
    thick; a desk ≈ 120 × 60 cm top at 75 cm high; a bicycle wheel ≈ 66 cm diameter). Do not scale things down to \
    robot size: the scene is real scale.
    - Mass: what the real object weighs (steel ≈ 7.8 g/cm³, wood ≈ 0.6, plastic ≈ 1.1, rubber ≈ 1.2), as the total.
    - Use as few parts as needed for the shape to read clearly and to behave right physically: 1 for simple things, \
    up to 16 for complex ones. Parts may overlap. Keep thin parts at least 0.2 cm thick.
    - The object rests in its natural orientation (a desk on its legs, a mug upright, a knife lying flat).
    - Colors: realistic hex colors per part (metal grays, wood browns, black rubber…).
    """

    static let shapes = ["box", "sphere", "cylinder", "capsule"]

    static let tool: [String: Any] = [
        "name": "build_object",
        "description": "Builds the object from primitive parts, in real-world units.",
        "input_schema": [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "Short name, e.g. 'Kitchen knife'."],
                "mass_kg": ["type": "number", "description": "Total real-world mass."],
                "parts": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "shape": ["type": "string", "enum": shapes],
                            "size_cm": ["type": "array", "items": ["type": "number"]],
                            "position_cm": ["type": "array", "items": ["type": "number"], "description": "[x, y, z] from the object's center"],
                            "rotation_deg": ["type": "array", "items": ["type": "number"], "description": "[x, y, z], default [0, 0, 0]"],
                            "color": ["type": "string", "description": "Hex color, e.g. #8b6b4a"],
                        ] as [String: Any],
                        "required": ["shape", "size_cm", "position_cm", "color"],
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
            "required": ["name", "mass_kg", "parts"],
        ] as [String: Any],
    ]

    struct DesignError: LocalizedError {
        var errorDescription: String? { "The AI didn't return a usable object. Try describing it differently." }
    }

    /// El cuerpo de la solicitud a la API para una descripción.
    static func request(description: String, model: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": 16000,
            "system": "\(system)\n\nAnswer only by calling build_object, exactly once.",
            "tools": [tool],
            // Los modelos actuales (Opus 5.5, Sonnet 5.5, Fable 5.1) no aceptan forzar la herramienta: se le pide.
            "tool_choice": ["type": "auto"],
            "messages": [["role": "user", "content": description]],
        ]
    }

    /// La respuesta de la API → la especificación de un objeto para el motor (piezas en metros, `drop`: que el
    /// motor elija un lugar libre y lo suelte), o un error que se pueda leer.
    static func parse(_ response: [String: Any]) throws -> [String: Any] {
        let blocks = response["content"] as? [[String: Any]] ?? []
        let input = blocks.first { $0["type"] as? String == "tool_use" }?["input"] as? [String: Any] ?? [:]
        let parts: [[String: Any]] = (input["parts"] as? [[String: Any]] ?? []).compactMap { p in
            guard let size = numbers(p["size_cm"]), !size.isEmpty else { return nil }
            let shape = (p["shape"] as? String).flatMap { shapes.contains($0) ? $0 : nil } ?? "box"
            let color = (p["color"] as? String).flatMap { isHexColor($0) ? $0 : nil } ?? "#9a9a9f"
            return [
                "shape": shape,
                "size": size.map { max($0, 0.2) / 100 },
                "pos": (numbers(p["position_cm"]) ?? [0, 0, 0]).prefix(3).map { $0 / 100 },
                "euler": Array((numbers(p["rotation_deg"]) ?? [0, 0, 0]).prefix(3)),
                "color": color,
            ]
        }.prefix(24).map { $0 }
        guard let first = parts.first else { throw DesignError() }
        let mass = (input["mass_kg"] as? NSNumber)?.doubleValue ?? .nan
        return [
            "shape": first["shape"] ?? "box",
            "size": first["size"] ?? [0.05],
            "mass": mass.isFinite && mass > 0 ? min(mass, 500) : 1,
            "color": first["color"] ?? "#9a9a9f",
            "yaw": 0,
            "fixed": false,
            "name": (input["name"] as? String).map { String($0.prefix(40)) } ?? "Object",
            "parts": parts,
            "drop": true,
        ]
    }

    private static func numbers(_ value: Any?) -> [Double]? {
        guard let list = value as? [Any] else { return nil }
        let out = list.compactMap { ($0 as? NSNumber)?.doubleValue }
        return out.count == list.count && out.allSatisfy(\.isFinite) ? out : nil
    }

    private static func isHexColor(_ s: String) -> Bool {
        s.count == 7 && s.hasPrefix("#") && s.dropFirst().allSatisfy(\.isHexDigit)
    }
}
