import Foundation
import MLXLMCommon
import MLXNN
import MLX
import MLXVLM

/// E4B checkpoints omit K/V projections in shared-KV layers. This MLXVLM revision
/// still declares optional local projections there, although its forward reuses
/// the source layer's KV state. Remove only those unused declarations before the
/// normal strict weight load. No weights are synthesized or verification skipped.
enum CoverVisionCompatibility {
    static func factory() -> VLMModelFactory {
        let registry = ModelTypeRegistry<LanguageModel>(creators: ["gemma4": { data in
            let config = try JSONDecoder().decode(Gemma4Configuration.self, from: data)
            let model = Gemma4(config)
            let text = config.textConfiguration
            let firstShared = text.hiddenLayers - text.numKVSharedLayers
            guard firstShared > 0, firstShared < text.hiddenLayers else { return model }
            let modules = Dictionary(uniqueKeysWithValues: model.namedModules())
            for index in firstShared..<text.hiddenLayers {
                let path = "language_model.model.layers.\(index).self_attn"
                guard let attention = modules[path] else {
                    throw NSError(domain: "CoverVisionCompatibility", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Shared KV layer missing: " + path])
                }
                let present = Set(attention.children().flattened().map(\.0))
                let unused = ["k_proj", "v_proj", "k_norm", "v_norm"].filter(present.contains)
                let replacements = Dictionary(uniqueKeysWithValues: unused.map {
                    ($0, NestedItem<String, Module>.none)
                })
                try attention.update(modules: ModuleChildren(values: replacements), verify: .noUnusedKeys)
            }
            return model
        }])
        return VLMModelFactory(typeRegistry: registry, processorRegistry: VLMProcessorTypeRegistry.shared,
                               modelRegistry: VLMRegistry.shared)
    }
}
