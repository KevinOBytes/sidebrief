import Foundation

public struct ModelPricing: Sendable {
    public let promptPerMillion: Double
    public let completionPerMillion: Double

    public init(promptPerMillion: Double, completionPerMillion: Double) {
        self.promptPerMillion = promptPerMillion
        self.completionPerMillion = completionPerMillion
    }
}

public struct ModelPricingCalculator: Sendable {
    public static let shared = ModelPricingCalculator()

    /// Pricing catalog per 1,000,000 tokens (USD)
    public static let modelRates: [String: ModelPricing] = [
        // Anthropic Claude 5.x, 4.x & 3.x
        "anthropic/claude-sonnet-5": ModelPricing(promptPerMillion: 3.00, completionPerMillion: 15.00),
        "anthropic/claude-5-sonnet": ModelPricing(promptPerMillion: 3.00, completionPerMillion: 15.00),
        "anthropic/claude-opus-5": ModelPricing(promptPerMillion: 15.00, completionPerMillion: 75.00),
        "anthropic/claude-5-opus": ModelPricing(promptPerMillion: 15.00, completionPerMillion: 75.00),
        "claude-sonnet-5": ModelPricing(promptPerMillion: 3.00, completionPerMillion: 15.00),
        "claude-opus-5": ModelPricing(promptPerMillion: 15.00, completionPerMillion: 75.00),
        "anthropic/claude-sonnet-4.6": ModelPricing(promptPerMillion: 3.00, completionPerMillion: 15.00),
        "anthropic/claude-sonnet-4.5": ModelPricing(promptPerMillion: 3.00, completionPerMillion: 15.00),
        "anthropic/claude-opus-4.6": ModelPricing(promptPerMillion: 15.00, completionPerMillion: 75.00),
        "anthropic/claude-sonnet-latest": ModelPricing(promptPerMillion: 3.00, completionPerMillion: 15.00),
        "anthropic/claude-3.7-sonnet": ModelPricing(promptPerMillion: 3.00, completionPerMillion: 15.00),
        "anthropic/claude-3.5-haiku": ModelPricing(promptPerMillion: 0.80, completionPerMillion: 4.00),
        "anthropic/claude-3.5-sonnet": ModelPricing(promptPerMillion: 3.00, completionPerMillion: 15.00),
        
        // OpenAI Luna & Frontier
        "openai/gpt-5.6-luna-pro": ModelPricing(promptPerMillion: 0.50, completionPerMillion: 2.00),
        "openai/gpt-luna-pro": ModelPricing(promptPerMillion: 0.50, completionPerMillion: 2.00),
        "openai/gpt-5.6-luna": ModelPricing(promptPerMillion: 0.20, completionPerMillion: 1.20),
        "openai/gpt-luna-latest": ModelPricing(promptPerMillion: 0.20, completionPerMillion: 1.20),
        "openai/o3-mini": ModelPricing(promptPerMillion: 1.10, completionPerMillion: 4.40),
        "openai/gpt-4o": ModelPricing(promptPerMillion: 2.50, completionPerMillion: 10.00),
        "openai/gpt-4o-mini": ModelPricing(promptPerMillion: 0.15, completionPerMillion: 0.60),
        "gpt-4o": ModelPricing(promptPerMillion: 2.50, completionPerMillion: 10.00),
        "gpt-4o-mini": ModelPricing(promptPerMillion: 0.15, completionPerMillion: 0.60),
        "o3-mini": ModelPricing(promptPerMillion: 1.10, completionPerMillion: 4.40),
        
        // Google & Open Weights
        "google/gemini-2.0-flash-001": ModelPricing(promptPerMillion: 0.10, completionPerMillion: 0.40),
        "deepseek/deepseek-r1": ModelPricing(promptPerMillion: 0.55, completionPerMillion: 2.19),
        "deepseek/deepseek-chat": ModelPricing(promptPerMillion: 0.14, completionPerMillion: 0.28),
        "meta-llama/llama-3.3-70b-instruct": ModelPricing(promptPerMillion: 0.13, completionPerMillion: 0.40)
    ]

    /// Default fallback rate for unlisted / custom models
    public static let defaultPricing = ModelPricing(promptPerMillion: 1.00, completionPerMillion: 3.00)

    /// ElevenLabs realtime streaming STT cost ($0.01 per audio minute)
    public static let sttCostPerAudioMinute: Double = 0.01

    public init() {}

    /// Calculates estimated cost in USD for prompt tokens, completion tokens, and audio duration.
    public func calculateCost(
        modelId: String,
        promptTokens: Int,
        completionTokens: Int,
        audioDurationSeconds: Double = 0.0
    ) -> Double {
        let pricing = Self.modelRates[modelId] ?? Self.defaultPricing

        let promptCost = (Double(promptTokens) / 1_000_000.0) * pricing.promptPerMillion
        let completionCost = (Double(completionTokens) / 1_000_000.0) * pricing.completionPerMillion
        let sttCost = (audioDurationSeconds / 60.0) * Self.sttCostPerAudioMinute

        return promptCost + completionCost + max(0.0, sttCost)
    }

    /// Calculates LLM cost only.
    public func calculateLLMCost(
        modelId: String,
        promptTokens: Int,
        completionTokens: Int
    ) -> Double {
        let pricing = Self.modelRates[modelId] ?? Self.defaultPricing
        let promptCost = (Double(promptTokens) / 1_000_000.0) * pricing.promptPerMillion
        let completionCost = (Double(completionTokens) / 1_000_000.0) * pricing.completionPerMillion
        return promptCost + completionCost
    }

    /// Calculates STT audio cost only.
    public func calculateSTTCost(audioDurationSeconds: Double) -> Double {
        return (audioDurationSeconds / 60.0) * Self.sttCostPerAudioMinute
    }
}
