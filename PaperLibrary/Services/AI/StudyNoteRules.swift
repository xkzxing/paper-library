import Foundation

enum StudyNoteError: LocalizedError {
    case missingPDF
    case invalidOutline(String)
    case outlineRecognitionFailed(initial: String, corrected: String, lite: String)
    case invalidPart(Int)
    case invalidResponse
    case cacheFailure(String)
    case httpStatus(Int, String)
    case budgetExceeded

    var errorDescription: String? {
        switch self {
        case .missingPDF: return "这条文献没有可用的首选 PDF。"
        case let .invalidOutline(diagnostic):
            return "模型返回的章节目录无法识别。\n\(diagnostic)"
        case let .outlineRecognitionFailed(initial, corrected, lite):
            return "模型返回的章节目录无法识别。\n初次目录校验：\(initial)\n格式修正后校验：\(corrected)\n轻量模型识别：\(lite)"
        case let .invalidPart(number): return "第 \(number) 部分的格式不符合要求。"
        case .invalidResponse: return "模型没有返回可用的精读笔记内容。"
        case let .cacheFailure(message): return "PDF 缓存失败：\(message)"
        case let .httpStatus(code, message): return "Gemini 请求失败（\(code)）：\(message)"
        case .budgetExceeded: return "本月 AI 预算已经用完，未开始生成精读笔记。"
        }
    }
}

enum StudyNoteNetworkRetryPolicy {
    /// 首次请求之外再重试三次。较长的间隔给短暂断网和服务端限流留出恢复时间。
    static let retryDelays = [2, 5, 12]

    static func isTransient(_ error: Error) -> Bool {
        if case let StudyNoteError.httpStatus(code, _) = error {
            return code == 408 || code == 429 || (500...599).contains(code)
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .secureConnectionFailed,
             .cannotLoadFromNetwork:
            return true
        default:
            return false
        }
    }
}

struct StudyNoteResumeContext: Sendable, Equatable {
    let outline: String
    let completedParts: Int
    let totalParts: Int
    let existingDraft: String
}

struct StudyNoteUsage: Sendable {
    enum BillingSource: Sendable, Equatable {
        case studyNote
        case lite
    }

    let inputTokens: Int
    let outputTokens: Int
    let totalTokens: Int
    let cachedInputTokens: Int
    /// 显式缓存的令牌数乘以最长保存小时数，用于保守估算缓存存储费用。
    let cacheStorageTokenHours: Double
    let billingSource: BillingSource

    init(
        inputTokens: Int,
        outputTokens: Int,
        totalTokens: Int,
        cachedInputTokens: Int = 0,
        cacheStorageTokenHours: Double = 0,
        billingSource: BillingSource = .studyNote
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cachedInputTokens = min(max(cachedInputTokens, 0), max(inputTokens, 0))
        self.cacheStorageTokenHours = max(cacheStorageTokenHours, 0)
        self.billingSource = billingSource
    }
}

struct StudyNotePricing {
    static let largeContextThreshold = 200_000

    let liteInput: Double
    let liteCachedInput: Double
    let liteOutput: Double
    let regularInput: Double
    let regularCachedInput: Double
    let regularOutput: Double
    let largeInput: Double
    let largeCachedInput: Double
    let largeOutput: Double
    let cacheStoragePerMillionTokenHours: Double

    func estimatedCostUSD(for usage: StudyNoteUsage) -> Double {
        let cached = min(max(usage.cachedInputTokens, 0), max(usage.inputTokens, 0))
        let uncached = max(usage.inputTokens - cached, 0)
        let rates: (input: Double, cached: Double, output: Double)
        switch usage.billingSource {
        case .lite:
            rates = (liteInput, liteCachedInput, liteOutput)
        case .studyNote:
            rates = usage.inputTokens > Self.largeContextThreshold
                ? (largeInput, largeCachedInput, largeOutput)
                : (regularInput, regularCachedInput, regularOutput)
        }
        return Double(uncached) / 1_000_000 * rates.input
            + Double(cached) / 1_000_000 * rates.cached
            + Double(usage.outputTokens) / 1_000_000 * rates.output
            + usage.cacheStorageTokenHours / 1_000_000 * cacheStoragePerMillionTokenHours
    }
}

/// 每三部分提高一次思考提示强度；某部分因正文抢跑而重试成功时，从它使用的
/// 更高强度重新开始计数。
struct StudyNoteThinkingSchedule {
    private(set) var strength = 0
    private var completedAtCurrentStrength = 0

    mutating func strengthForNextPart() -> Int {
        if completedAtCurrentStrength >= 3, strength < 5 {
            strength += 1
            completedAtCurrentStrength = 0
        }
        return strength
    }

    mutating func registerSuccessfulPart(using usedStrength: Int) {
        let clampedStrength = min(max(usedStrength, 0), 5)
        if clampedStrength != strength {
            strength = clampedStrength
            completedAtCurrentStrength = 0
        }
        completedAtCurrentStrength += 1
    }
}
