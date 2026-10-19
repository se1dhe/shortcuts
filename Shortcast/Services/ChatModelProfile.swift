import Foundation

/// Per-model decoding configuration for the MLX text models Shortcast loads
/// directly (currently just Qwen 3.5 9B, the "Director" that finds viral
/// moments). Adapted from Hermes-Jarvis, trimmed to what Shortcast needs.
///
/// MLX `GenerateParameters` defaults are generic; each model family has its
/// own vendor-recommended sampling that materially affects quality and memory.
struct SamplingConfig: Sendable {
    var temperature: Float
    var topP: Float
    /// 0 disables top-k.
    var topK: Int
    /// 0 disables min-p.
    var minP: Float
    /// nil → no repetition penalty.
    var repetitionPenalty: Float?
    /// Hard cap on generated tokens.
    var maxTokens: Int
    /// nil → unbounded (full) KV cache; set to bound memory. It is a rotation
    /// point, not a context window: once prompt + generated tokens pass it the
    /// cache silently drops everything except the first 4 tokens.
    var maxKVSize: Int?
    /// nil → no KV quantization.
    var kvBits: Int?
}

struct ChatModelProfile: Sendable {
    /// HuggingFace repo id for the main model.
    let modelID: String
    /// Display name shown in UI.
    let displayName: String

    enum FactoryKind { case llm, vlm }
    /// LLM for text-only models; VLM for multimodal packages (Qwen 3.5 9B only
    /// exists in vision-language form on HF, so it loads via VLMModelFactory).
    let factoryKind: FactoryKind

    /// How the weights get turned into a `ModelContainer`. Both paths produce a
    /// container that drives the same `ChatSession` text generation — they only
    /// differ in how the architecture is registered/loaded.
    enum Loader {
        /// Standard mlx-swift-lm factory (Qwen 3.5 ships as a VLM package).
        case vlm
        /// Gemma 4 — register the custom "gemma4" type (text-only) via the
        /// vendored Gemma4Swift package, then load with its tokenizer loader.
        case gemma4Text
    }
    let loader: Loader

    /// Vendor-recommended decoding parameters.
    let sampling: SamplingConfig

    /// Qwen 3.5 9B — best multilingual reasoning in the small-model tier. Loads
    /// as a VLM. Note `maxKVSize` is a ROTATION cap, not a context window: past
    /// it the cache keeps 4 leading tokens and drops the middle of the film.
    static let qwen35_9b = ChatModelProfile(
        modelID: "mlx-community/Qwen3.5-9B-MLX-4bit",
        displayName: "Qwen 3.5 9B",
        factoryKind: .vlm,
        loader: .vlm,
        // Qwen3 non-thinking recommended sampling (temp 0.7 / topP 0.8 / topK 20).
        // Thinking is forced OFF via additionalContext, so these are correct.
        // maxTokens bumped from Hermes' 1536 → 4096: the clips JSON for a long
        // video can be long and must not truncate.
        // KV 8192 → 16384, measured from the downloaded config.json: 32 layers
        // but `full_attention_interval: 4`, so only 8 layers hold a KV cache (the
        // 24 linear-attention layers use a constant MambaCache); 4 KV heads × 256
        // head_dim × 2 (K+V) × 8 layers × 2 bytes (bf16 — mlx-swift-lm's
        // `maybeQuantizeKVCache` skips RotatingKVCache, so `kvBits` is inert
        // here) = 32 KB/token. 16384 tokens ≈ 512 MB on an 18 GB machine already
        // carrying 5.6 GB of 4-bit weights — the old 8192 truncated every film
        // over ~12k transcript chars, and 32768 (1 GB) would buy nothing: the
        // worst measured corpus (Blade Runner 2049, 36k chars ≈ 9.7k tokens) plus
        // the generation cap fits inside 16384 with room to spare.
        sampling: SamplingConfig(
            temperature: 0.7, topP: 0.8, topK: 20, minP: 0,
            repetitionPenalty: nil, maxTokens: 4096,
            maxKVSize: 16384, kvBits: 8))

    /// Gemma 4 12B — Google's new dense 12B (text+vision). We feed it the
    /// transcript text only, so it runs as a text LLM through the same
    /// `ChatSession` path as Qwen, via the vendored Gemma4Swift registration.
    /// The default Director: stronger writing than Qwen at a similar footprint.
    static let gemma12B = ChatModelProfile(
        modelID: "mlx-community/gemma-4-12B-it-4bit",
        displayName: "Gemma 4 12B",
        factoryKind: .llm,
        loader: .gemma4Text,
        // Moderate temperature + a repetition penalty. We need strict JSON, but
        // the two failure modes pull opposite ways: too high (≥0.6) and the
        // manual fp32 attention's slight logit perturbation mis-samples a
        // structural token and breaks the JSON; too low (≤0.2) and it falls into
        // a repetition loop (e.g. spamming the same hashtags) that eats the whole
        // token budget. 0.35 sits between them, and repetitionPenalty kills the
        // loops directly. KV cache is unquantized (kvBits nil): the 12B's
        // full-attention layers use a 512 head dim that overflows the
        // fused/quantized SDPA Metal kernel, so we fall back to a manual
        // matmul+softmax attention on a plain cache.
        sampling: SamplingConfig(
            temperature: 0.35, topP: 0.9, topK: 30, minP: 0,
            repetitionPenalty: 1.1, maxTokens: 4096,
            maxKVSize: nil, kvBits: nil))
}
