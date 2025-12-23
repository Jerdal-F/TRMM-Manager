import Foundation

struct AgentCustomField: Identifiable, Decodable {
    let id: Int
    let field: Int
    let agent: Int
    let value: String

    private enum CodingKeys: String, CodingKey { case id, field, agent, value }

    init(id: Int, field: Int, agent: Int, value: String) {
        self.id = id
        self.field = field
        self.agent = agent
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        field = try c.decode(Int.self, forKey: .field)
        agent = try c.decode(Int.self, forKey: .agent)

        if let direct = try c.decodeIfPresent(String.self, forKey: .value) {
            value = direct
        } else if let intValue = try? c.decode(Int.self, forKey: .value) {
            value = String(intValue)
        } else if let doubleValue = try? c.decode(Double.self, forKey: .value) {
            value = String(doubleValue)
        } else if let boolValue = try? c.decode(Bool.self, forKey: .value) {
            value = String(boolValue)
        } else {
            value = ""
        }
    }
}
