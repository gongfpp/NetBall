import AppKit
import Foundation

/// 图表速率统一使用字节/秒；时间戳来自实际采样时刻。
struct PanelChartSample: Equatable {
    let at: Date
    let rx: Double
    let tx: Double
}

struct PanelChartModel {
    static let maximumGap: TimeInterval = 7

    let samples: [PanelChartSample]
    let start: Date
    let end: Date
    let duration: TimeInterval
    let maxValue: Double
    let tickValues: [Double]
    let unitDivisor: Double
    let unitLabel: String
    let segments: [[PanelChartSample]]
    let peak: PanelChartSample?

    init(samples input: [PanelChartSample], end requestedEnd: Date, duration requestedDuration: TimeInterval = 60) {
        let endSeconds = requestedEnd.timeIntervalSinceReferenceDate
        let safeEnd = endSeconds.isFinite ? requestedEnd : Date(timeIntervalSinceReferenceDate: 0)
        let candidateDuration = requestedDuration.isFinite && requestedDuration > 0 ? requestedDuration : 60
        // 极端输入也不能让窗口边界变成无穷大。
        let safeDuration = (safeEnd.timeIntervalSinceReferenceDate - candidateDuration).isFinite ? candidateDuration : 60
        self.end = safeEnd
        self.duration = safeDuration
        self.start = safeEnd.addingTimeInterval(-safeDuration)

        // 同一时刻只保留最后一次观测，不把重复采样连成竖线。
        var byTime: [Date: PanelChartSample] = [:]
        for sample in input where sample.at.timeIntervalSinceReferenceDate.isFinite && sample.at >= start && sample.at <= safeEnd {
            byTime[sample.at] = PanelChartSample(at: sample.at,
                                                rx: Self.clean(sample.rx),
                                                tx: Self.clean(sample.tx))
        }
        let ordered = byTime.values.sorted { $0.at < $1.at }
        self.samples = ordered
        self.peak = ordered.max {
            max($0.rx, $0.tx) < max($1.rx, $1.tx)
        }
        let maximumRate = ordered.reduce(0.0) { max($0, max($1.rx, $1.tx)) }
        let units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"]
        var divisor = 1.0
        var unitIndex = 0
        while unitIndex < units.count - 1 && maximumRate / divisor >= 1024 {
            divisor *= 1024
            unitIndex += 1
        }
        self.unitDivisor = divisor
        self.unitLabel = units[unitIndex]
        // 先确定显示单位，再取友好刻度，避免换算后轴标签变成零碎小数。
        let candidateScale = Self.axisScale(for: maximumRate / divisor) * divisor
        let scale = candidateScale.isFinite && candidateScale >= maximumRate ? candidateScale : maximumRate
        self.maxValue = scale
        self.tickValues = (0...4).map { scale * (Double($0) / 4) }

        var groups: [[PanelChartSample]] = []
        for sample in ordered {
            if let last = groups.last?.last, sample.at.timeIntervalSince(last.at) <= Self.maximumGap {
                groups[groups.count - 1].append(sample)
            } else {
                groups.append([sample])
            }
        }
        self.segments = groups
    }

    /// 返回绘图区横向比例，绝不使用样本序号代替时间。
    func pointX(for sample: PanelChartSample) -> Double {
        let elapsed = sample.at.timeIntervalSince(start)
        guard elapsed.isFinite else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    /// 停采空档没有可命中的实时数据；边界之外的指针按绘图区边界处理。
    func nearest(at normalizedX: Double) -> PanelChartSample? {
        guard normalizedX.isFinite else { return nil }
        let target = start.addingTimeInterval(min(1, max(0, normalizedX)) * duration)
        guard let nearest = samples.min(by: {
            abs($0.at.timeIntervalSince(target)) < abs($1.at.timeIntervalSince(target))
        }), abs(nearest.at.timeIntervalSince(target)) <= Self.maximumGap else { return nil }
        return nearest
    }

    private static func clean(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }

    private static func axisScale(for peak: Double) -> Double {
        guard peak > 1 else { return 1 }
        let rawStep = peak / 4
        let magnitude = pow(10, floor(log10(rawStep)))
        let fraction = rawStep / magnitude
        let rounded: Double
        switch fraction {
        case ...1: rounded = 1
        case ...2: rounded = 2
        case ...5: rounded = 5
        default: rounded = 10
        }
        let axis = rounded * magnitude * 4
        // 超大但有限的速率不能经刻度取整后溢出。
        return axis.isFinite && axis >= peak ? axis : peak
    }
}

/// 仅供主线程使用；缓存正结果和缺失结果，绘制时不反复访问磁盘。
final class PanelIconCache {
    typealias Loader = (String) -> NSImage?

    private final class Entry: NSObject {
        let image: NSImage?
        init(_ image: NSImage?) { self.image = image }
    }

    private let cache = NSCache<NSString, Entry>()
    private let loader: Loader

    /// 注入的加载器替代磁盘与系统图标读取，便于完全内存化的自检。
    init(loader: Loader? = nil) {
        self.loader = loader ?? Self.loadApplicationIcon
        cache.countLimit = 128
    }

    func image(for path: String?) -> NSImage? {
        guard let path, !path.isEmpty, (path as NSString).isAbsolutePath else { return nil }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let key = url.path as NSString
        if let entry = cache.object(forKey: key) { return entry.image }
        let image = loader(url.path)
        cache.setObject(Entry(image), forKey: key)
        return image
    }

    private static func loadApplicationIcon(_ path: String) -> NSImage? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let bundle = Bundle(url: URL(fileURLWithPath: path)),
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }
}

/// 返回失败说明；不启动应用、不查网络、不创建测试文件。
enum PanelPresentationTests {
    static func run() -> [String] {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.000001 }
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        func sample(_ secondsAgo: Double, _ rx: Double = 10, _ tx: Double = 20) -> PanelChartSample {
            PanelChartSample(at: end.addingTimeInterval(-secondsAgo), rx: rx, tx: tx)
        }

        let empty = PanelChartModel(samples: [], end: end)
        check(empty.samples.isEmpty && empty.segments.isEmpty && empty.peak == nil, "空窗口不能生成虚构样本")
        check(empty.maxValue == 1 && empty.tickValues == [0, 0.25, 0.5, 0.75, 1], "空窗口仍需有效坐标轴")
        check(empty.nearest(at: 0.5) == nil, "空窗口不得命中")

        let single = PanelChartModel(samples: [sample(30)], end: end)
        check(near(single.pointX(for: sample(30)), 0.5), "单点按真实时间定位")
        check(single.segments.count == 1 && single.segments[0].count == 1, "单点不得伪造连续线")
        check(single.nearest(at: 0.5) == single.samples.first && single.nearest(at: 1) == nil, "单点命中范围不能延伸到停采空白区")

        let irregular = PanelChartModel(samples: [sample(0), sample(61), sample(59), sample(52), sample(44.9), sample(-1)], end: end)
        check(irregular.samples.count == 4, "只保留最近60秒，排除未来样本")
        check(near(irregular.pointX(for: sample(59)), 1.0 / 60), "不规则采样不能以点数代替时间")
        check(irregular.segments.map(\.count) == [2, 1, 1], "恰好7秒可连线，超过7秒必须断线")
        check(irregular.nearest(at: 0.6) == nil, "长空档不能命中陈旧样本")
        check(irregular.nearest(at: .nan) == nil && irregular.nearest(at: .infinity) == nil, "拒绝非有限指针位置")

        let repeated = PanelChartModel(samples: [sample(10, 1, 2), sample(10, 8, 9), sample(10, 3, 4)], end: end)
        check(repeated.samples == [sample(10, 3, 4)], "同时间戳保留输入最后一条")
        let paused = PanelChartModel(samples: [sample(61), sample(600)], end: end)
        check(paused.samples.isEmpty && paused.nearest(at: 1) == nil, "长期暂停后清空过期曲线")

        let invalid = PanelChartModel(samples: [sample(0, -.infinity, .nan), sample(1, -1, .infinity),
                                               PanelChartSample(at: Date(timeIntervalSinceReferenceDate: .nan), rx: 1, tx: 1)], end: end)
        check(invalid.samples.count == 2 && invalid.samples.allSatisfy { $0.rx == 0 && $0.tx == 0 }, "清理负数、非有限速率与无效时间戳")
        let invalidWindow = PanelChartModel(samples: [], end: Date(timeIntervalSinceReferenceDate: .nan), duration: .infinity)
        check(invalidWindow.end.timeIntervalSinceReferenceDate.isFinite && invalidWindow.duration == 60, "非法窗口参数必须恢复为有限值")
        check(PanelChartModel(samples: [], end: end, duration: 0).duration == 60, "零时长不得产生除零")
        let boundary = PanelChartModel(samples: [sample(60), sample(0)], end: end)
        check(boundary.samples.count == 2 && boundary.pointX(for: sample(60)) == 0 && boundary.pointX(for: sample(0)) == 1, "窗口左右边界均按真实时间包含")
        let customWindow = PanelChartModel(samples: [sample(60)], end: end, duration: 120)
        check(near(customWindow.pointX(for: sample(60)), 0.5), "自定义时长仍按真实时间定位")

        let high = PanelChartModel(samples: [sample(8, 1024, 8192), sample(0, 7_000_000, 2_000_000)], end: end)
        check(high.maxValue == 8 * 1_048_576 && high.tickValues == [0, 2, 4, 6, 8].map { Double($0) * 1_048_576 }, "上下行在显示单位内使用同一组友好刻度")
        check(high.tickValues.map { $0 / high.unitDivisor } == [0, 2, 4, 6, 8], "显示轴标签不能因字节单位换算变成零碎小数")
        check(high.unitDivisor == 1_048_576 && high.unitLabel == "MB/s", "图表单位按1024进位")
        check(high.peak == sample(0, 7_000_000, 2_000_000), "峰值取可见窗口中单方向最高速率所在样本")
        let huge = PanelChartModel(samples: [sample(0, .greatestFiniteMagnitude, 0)], end: end)
        check(huge.maxValue.isFinite && huge.tickValues.allSatisfy(\.isFinite), "极大峰值不能让坐标轴溢出")
        check(huge.tickValues.last == huge.maxValue, "最高刻度覆盖峰值")

        var loads: [String: Int] = [:]
        let image = NSImage(size: NSSize(width: 16, height: 16))
        let icons = PanelIconCache { path in
            loads[path, default: 0] += 1
            return path == "/Applications/Present.app" ? image : nil
        }
        check(icons.image(for: "/Applications/Present.app") === image, "有效应用返回注入图标")
        check(icons.image(for: "/Applications/./Present.app") === image && loads["/Applications/Present.app"] == 1, "规范化相同路径后复用正缓存")
        check(icons.image(for: "/Applications/Missing.app") == nil && icons.image(for: "/Applications/Missing.app") == nil && loads["/Applications/Missing.app"] == 1, "缺失应用须负缓存")
        for path: String? in [nil, "", "Relative.app", "/tmp/Project.swift", "/tmp/Project", "/tmp/Project.xcodeproj", "/tmp/app.txt"] {
            check(icons.image(for: path) == nil, "普通文件或无效路径不能当作应用")
        }
        check(loads.count == 2, "非应用路径不得调用加载器或查盘")
        // 超出容量后只要求重新加载仍然正确，淘汰顺序由NSCache管理。
        for index in 0..<140 { _ = icons.image(for: "/Applications/Test\(index).app") }
        check(icons.image(for: "/Applications/Present.app") === image, "缓存淘汰后图标仍可重新加载")
        return failures
    }
}
