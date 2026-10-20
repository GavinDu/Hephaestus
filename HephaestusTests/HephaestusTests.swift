import Foundation
import Testing
@testable import Hephaestus

struct HephaestusTests {
    @Test func decodesCanonicalGamePackage() throws {
        let json = """
        {
          "packageVersion":"2.0",
          "gameId":"fixture-game",
          "ir":{
            "irVersion":"1.0",
            "game":{"id":"fixture-game","title":"Fixture","entryScene":"main","orientation":"portrait"},
            "assets":[],
            "scenes":[{"id":"main","entities":[
              {"id":"player","kind":"player","position":[195,650],"size":[60,60],"components":["movement","collider"]},
              {"id":"pickup","kind":"pickup","position":[195,600],"size":[24,24],"components":["collectible","collider"]}
            ]}],
            "inputBindings":[{"action":"move","input":"drag"}],
            "rules":[{"id":"collect","when":{"event":"collected","source":"player","target":"pickup"},"actions":[
              {"type":"add_score","target":"player","value":1},
              {"type":"destroy_entity","target":"pickup"}
            ]}],
            "metadata":{"tags":["test"]}
          },
          "assets":[]
        }
        """.data(using: .utf8)!
        let package = try JSONDecoder().decode(GamePackageResponse.self, from: json)
        #expect(package.packageVersion == "2.0")
        #expect(package.ir.game.entryScene == "main")
        #expect(package.ir.scenes[0].entities.count == 2)
    }

    @MainActor
    @Test func runtimeCollectsPickupAndAppliesActions() throws {
        let json = """
        {
          "irVersion":"1.0",
          "game":{"id":"fixture-game","title":"Fixture","entryScene":"main","orientation":"portrait"},
          "assets":[],
          "scenes":[{"id":"main","entities":[
            {"id":"player","kind":"player","position":[100,100],"size":[40,40],"components":["movement","collider"]},
            {"id":"pickup","kind":"pickup","position":[200,100],"size":[20,20],"components":["collectible","collider"]}
          ]}],
          "inputBindings":[{"action":"move","input":"drag"}],
          "rules":[{"id":"collect","when":{"event":"collected","source":"player","target":"pickup"},"actions":[
            {"type":"add_score","target":"player","value":1},
            {"type":"destroy_entity","target":"pickup"}
          ]}]
        }
        """.data(using: .utf8)!
        let doc = try JSONDecoder().decode(GameIRDocument.self, from: json)
        let runtime = try GameIRRuntime(document: doc)
        runtime.movePlayer(to: CGPoint(x: 200, y: 100))
        #expect(runtime.score == 1)
        #expect(runtime.destroyedIDs.contains("pickup"))
    }

    @Test func rejectsUnknownIRVersion() throws {
        let json = """
        {"irVersion":"9.0","game":{"id":"g","title":"G","entryScene":"main","orientation":"portrait"},
         "assets":[],"scenes":[{"id":"main","entities":[]}],"inputBindings":[],"rules":[]}
        """.data(using: .utf8)!
        let doc = try JSONDecoder().decode(GameIRDocument.self, from: json)
        #expect(throws: GameIRRuntime.RuntimeError.self) { try GameIRRuntime(document: doc) }
    }
}
