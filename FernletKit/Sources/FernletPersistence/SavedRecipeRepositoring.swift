import FernletDomainModel

@MainActor
public protocol SavedRecipeRepositoring {
    func load() -> [RecipeDefinition]
    func loadAsync() async -> [RecipeDefinition]
    @discardableResult func save(_ recipes: [RecipeDefinition]) -> Bool
}
