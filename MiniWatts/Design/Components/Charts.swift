import Charts
import SwiftUI

/// One plotted reading, and the unbroken run of readings it belongs to.
///
/// A rail with no reading for a sample is left out of the chart rather than drawn
/// at zero. A single line through what is left would run straight across each
/// hole as though it had been measured, so every run is a series of its own: the
/// line stops at a missing reading and starts again at the next one.
private nonisolated struct RunPoint<X: Plottable & Hashable>: Identifiable {
    let x: X
    let watts: Double
    let run: Int
    /// The only reading in its run. A line needs two points, so it is drawn as a dot.
    var isAlone = false
    var id: X { x }
}

private nonisolated func runPoints<Sample, X: Plottable & Hashable>(_ samples: [Sample],
                                                                     x: (Sample) -> X,
                                                                     watts: (Sample) -> Double?) -> [RunPoint<X>] {
    var points: [RunPoint<X>] = []
    var run = 0
    var runStart = 0
    var previousLiveDate: Date?
    func close() {
        if points.count - runStart == 1 { points[runStart].isAlone = true }
        runStart = points.count
    }
    for sample in samples {
        if let live = sample as? LiveSample {
            if let previousLiveDate, live.date.timeIntervalSince(previousLiveDate) > 8,
               points.count > runStart {
                close()
                run += 1
            }
            previousLiveDate = live.date
        }
        guard let value = watts(sample), value.isFinite else {
            if points.count > runStart {
                close()
                run += 1
            }
            continue
        }
        points.append(RunPoint(x: x(sample), watts: value, run: run))
    }
    close()
    return points
}

/// The runs of one rail as broken lines. `name` is the series the legend and
/// VoiceOver would give; later runs carry their number so they stay apart.
@ChartContentBuilder
private func runLines<X: Plottable & Hashable>(_ points: [RunPoint<X>],
                                               axis: String,
                                               name: String,
                                               color: Color,
                                               style: StrokeStyle) -> some ChartContent {
    ForEach(points) { point in
        if point.isAlone {
            PointMark(x: .value(axis, point.x),
                      y: .value("Watts", point.watts))
                .symbolSize(style.lineWidth * style.lineWidth * 4)
                .foregroundStyle(color)
        } else {
            LineMark(x: .value(axis, point.x),
                     y: .value("Watts", point.watts),
                     series: .value("Series", point.run == 0 ? name : "\(name) \(point.run + 1)"))
                .foregroundStyle(color)
                .lineStyle(style)
                .interpolationMethod(.monotone)
        }
    }
}

/// The adapter's runs as filled areas under the line.
@ChartContentBuilder
private func runAreas<X: Plottable & Hashable>(_ points: [RunPoint<X>],
                                               axis: String,
                                               topOpacity: Double) -> some ChartContent {
    ForEach(points) { point in
        // Unstacked: these are stretches of one quantity, not parts of a whole.
        AreaMark(x: .value(axis, point.x),
                 y: .value("Watts", point.watts),
                 series: .value("Run", point.run),
                 stacking: .unstacked)
            .foregroundStyle(LinearGradient(colors: [Color.mwAccent.opacity(topOpacity), Color.mwAccent.opacity(0.02)],
                                            startPoint: .top,
                                            endPoint: .bottom))
            .interpolationMethod(.monotone)
    }
}

/// Rolling three-minute view of adapter power against battery power. The area is
/// what comes in; the line is what reaches the cell.
struct LivePowerChart: View {
    let samples: [LiveSample]
    var height: CGFloat = 130

    private var inputPoints: [RunPoint<Date>] { runPoints(samples, x: \.date, watts: \.inputWatts) }
    private var cellPoints: [RunPoint<Date>] {
        runPoints(samples, x: \.date, watts: { ($0.batteryWatts ?? $0.estimatedBatteryWatts).map(abs) })
    }

    private var ceiling: Double {
        let peak = (samples.compactMap(\.inputWatts) + samples.compactMap { $0.batteryWatts ?? $0.estimatedBatteryWatts }.map(abs))
            .filter(\.isFinite).max() ?? 0
        return max(peak * 1.25, 5)
    }

    private var axisValues: [Double] { [ceiling, ceiling / 2, 0] }

    var body: some View {
        let input = inputPoints
        return HStack(spacing: 5) {
            Chart {
                ForEach(axisValues, id: \.self) { watts in
                    RuleMark(y: .value("Power grid", watts))
                        .foregroundStyle(Color.mwGrid)
                        .lineStyle(StrokeStyle(lineWidth: 0.7))
                }
                runAreas(input, axis: "Time", topOpacity: 0.45)
                runLines(input, axis: "Time",
                         name: String(localized: "From charger"),
                         color: .mwAccent,
                         style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                runLines(cellPoints, axis: "Time",
                         name: String(localized: "Into battery"),
                         color: .mwBattery,
                         style: StrokeStyle(lineWidth: 1.8))
            }
            .chartYScale(domain: 0...ceiling)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                // Keep the trace and its filled area well clear of the fixed Y-axis gutter.
                plot.padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 6)
            }
            .padding(.trailing, 8)
            .frame(maxWidth: .infinity)
            .clipped()

            // The labels live in a separate fixed-width column, not in the
            // chart's plot or trailing-axis overlay. The trace cannot reach them.
            VStack(spacing: 0) {
                ForEach(Array(axisValues.enumerated()), id: \.offset) { _, watts in
                    Text(verbatim: "\(Int(watts.rounded()))W")
                        .mwMono(size: 9)
                        .foregroundStyle(Color.mwMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if watts != 0 { Spacer(minLength: 0) }
                }
            }
            .frame(width: 44, alignment: .leading)
            .padding(.vertical, 6)
        }
        .chartLegend(.hidden)
        // Animate incoming live samples and changing watt values smoothly.
        .animation(.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.68), value: samples)
        .frame(height: height)
    }
}

/// Power over the length of a finished session, plotted against elapsed time.
struct SessionPowerChart: View {
    let samples: [ChargeSample]
    var height: CGFloat = 150

    private var inputPoints: [RunPoint<TimeInterval>] { runPoints(samples, x: \.offset, watts: \.inputWatts) }
    private var batteryPoints: [RunPoint<TimeInterval>] { runPoints(samples, x: \.offset, watts: \.batteryWatts) }
    private var estimatedBatteryPoints: [RunPoint<TimeInterval>] {
        runPoints(samples, x: \.offset, watts: { $0.estimatedBatteryWatts.map(abs) })
    }

    private var ceiling: Double {
        let peak = (samples.compactMap(\.inputWatts) + samples.compactMap(\.batteryWatts) + samples.compactMap(\.estimatedBatteryWatts).map(abs))
            .filter(\.isFinite).max() ?? 0
        return max(peak * 1.2, 5)
    }

    var body: some View {
        let input = inputPoints
        return Chart {
            runAreas(input, axis: "Elapsed", topOpacity: 0.4)
            runLines(input, axis: "Elapsed",
                     name: "From charger",
                     color: .mwAccent,
                     style: StrokeStyle(lineWidth: 1.8))
            runLines(batteryPoints, axis: "Elapsed",
                     name: "Into battery",
                     color: .mwBattery,
                     style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
            runLines(estimatedBatteryPoints, axis: "Elapsed",
                     name: "Estimated cell power",
                     color: .mwLoss,
                     style: StrokeStyle(lineWidth: 1.4, dash: [2, 3]))
            // Shade the stretches where iOS was thermally throttling, which is
            // where the curve usually falls off a cliff.
            ForEach(samples.filter(\.throttled)) { sample in
                RectangleMark(x: .value("Elapsed", sample.offset),
                              yStart: .value("Watts", 0),
                              yEnd: .value("Watts", ceiling),
                              width: .fixed(2))
                    .foregroundStyle(Color.mwDanger.opacity(0.12))
            }
        }
        .chartYScale(domain: 0...ceiling)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.mwGrid)
                AxisValueLabel {
                    if let seconds = value.as(Double.self) {
                        Text(Formatting.duration(seconds)).mwMono(size: 9).foregroundStyle(Color.mwMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Color.mwGrid)
                AxisValueLabel {
                    if let watts = value.as(Double.self) {
                        Text(verbatim: "\(Int(watts))W").mwMono(size: 9).foregroundStyle(Color.mwMuted)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.padding(.horizontal, 10).padding(.vertical, 8)
        }
        .padding(.horizontal, 8)
        .padding(.trailing, 8)
        .frame(height: height)
    }
}

/// Battery percentage and temperature over a session, as two panes on one shared
/// time axis.
///
/// They used to share a Y axis as well, which was wrong: the axis was labelled
/// 0–100 for the percentage, so a 38 °C cell was drawn at the "38 %" gridline, and
/// a whole charge's worth of temperature — thirty-something to forty-something —
/// was squeezed into a tenth of the plot and read as a flat line. Two panes cost a
/// little height and let the temperature have a scale it can actually move on.
struct SessionClimateChart: View {
    let samples: [ChargeSample]
    /// The samples are Celsius; the pane is drawn in this scale, so its axis can be
    /// labelled with plain numbers.
    var unit: TemperatureDisplayUnit = .celsius
    var height: CGFloat = 150

    private var xDomain: ClosedRange<Double> {
        let last = samples.last?.offset ?? 0
        return 0...max(last, 1)
    }

    private var temperatures: [ChargeSample] {
        samples.filter { $0.batteryTemperature != nil }
    }

    private var temperatureDomain: ClosedRange<Double> {
        let values = temperatures.compactMap(\.batteryTemperature).map(unit.value(fromCelsius:))
        guard let low = values.min(), let high = values.max() else {
            return unit.value(fromCelsius: 20)...unit.value(fromCelsius: 45)
        }
        let padding = max((high - low) * 0.2, 1)
        return (low - padding)...(high + padding)
    }

    var body: some View {
        VStack(spacing: 4) {
            Chart(samples) { sample in
                LineMark(x: .value("Elapsed", sample.offset),
                         y: .value("Percent", Double(sample.percent)))
                    .foregroundStyle(Color.mwWireless)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
            .chartXScale(domain: xDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.mwGrid)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(Color.mwGrid)
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(verbatim: "\(Int(number))%").mwMono(size: 9).foregroundStyle(Color.mwMuted)
                        }
                    }
                }
            }
            .frame(height: height * 0.55)

            if temperatures.isEmpty {
                EmptyNote(text: "No cell temperature was recorded for this session.")
            } else {
                Chart(temperatures) { sample in
                    LineMark(x: .value("Elapsed", sample.offset),
                             y: .value("Temperature", unit.value(fromCelsius: sample.batteryTemperature ?? 0)))
                        .foregroundStyle(Color.mwLoss)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                        .interpolationMethod(.monotone)
                }
                .chartYScale(domain: temperatureDomain)
                .chartXScale(domain: xDomain)
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisGridLine().foregroundStyle(Color.mwGrid)
                        AxisValueLabel {
                            if let seconds = value.as(Double.self) {
                                Text(Formatting.duration(seconds)).mwMono(size: 9).foregroundStyle(Color.mwMuted)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Color.mwGrid)
                        AxisValueLabel {
                            if let degrees = value.as(Double.self) {
                                Text(verbatim: String(format: "%.0f°", degrees)).mwMono(size: 9).foregroundStyle(Color.mwMuted)
                            }
                        }
                    }
                }
                .frame(height: height * 0.45)
            }
        }
        .chartLegend(.hidden)
        .clipped()
    }
}

/// Compact inline sparkline, used in the session list.
struct Sparkline: View {
    let values: [Double]
    var tint: Color = .mwAccent

    /// Points actually drawn. A session holds up to 1,500 samples and this is
    /// 26 points tall in a list row, so nearly all of them would land on the same
    /// pixel column. Peak-preserving: each bucket keeps its largest value, so
    /// thinning cannot hide a spike, which plain striding would.
    private static let resolution = 64

    private var thinned: [Double] {
        guard values.count > Self.resolution else { return values }
        let bucket = Double(values.count) / Double(Self.resolution)
        return (0..<Self.resolution).compactMap { index in
            let start = Int(Double(index) * bucket)
            let end = max(start + 1, Int(Double(index + 1) * bucket))
            return values[start..<min(end, values.count)].max()
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let points = thinned
            let peak = max(points.max() ?? 1, 0.001)
            Path { path in
                guard points.count > 1 else { return }
                for (index, value) in points.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(points.count - 1)
                    let y = geometry.size.height * (1 - CGFloat(value / peak))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

/// Rolling three-minute view of one hardware temperature zone.
private struct ZoneTemperaturePoint: Identifiable, Equatable {
    let date: Date
    let celsius: Double
    var id: Date { date }
}

struct LiveTemperatureChart: View {
    let samples: [LiveSample]
    var unit: TemperatureDisplayUnit = .celsius
    var height: CGFloat = 110
    var zone: ThermalZone = .battery

    private var points: [ZoneTemperaturePoint] {
        samples.compactMap { sample in
            guard let reading = sample.zoneTemperatures.first(where: { $0.zone == zone }),
                  reading.celsius.isFinite else { return nil }
            return ZoneTemperaturePoint(date: sample.date, celsius: reading.celsius)
        }
    }

    private var domain: ClosedRange<Double> {
        let values = points.map { unit.value(fromCelsius: $0.celsius) }
        guard let low = values.min(), let high = values.max() else {
            return unit.value(fromCelsius: 20)...unit.value(fromCelsius: 50)
        }
        let padding = max((high - low) * 0.3, 1.5)
        return (low - padding)...(high + padding)
    }

    /// Three tick values rendered in a dedicated gutter beside the chart.
    /// Keeping the labels outside Swift Charts' plot prevents the live line
    /// and area fill from ever crossing underneath the temperature text.
    private var axisLabels: [Double] {
        let lower = ceil(domain.lowerBound)
        let upper = floor(domain.upperBound)
        if upper - lower >= 2 {
            return [upper, (lower + upper) / 2, lower]
        }
        let span = domain.upperBound - domain.lowerBound
        return [
            domain.upperBound - span * 0.12,
            (domain.lowerBound + domain.upperBound) / 2,
            domain.lowerBound + span * 0.12
        ]
    }

    var body: some View {
        HStack(spacing: 6) {
            Chart {
                ForEach(axisLabels, id: \.self) { tick in
                    RuleMark(y: .value("Temperature grid", tick))
                        .foregroundStyle(Color.mwGrid)
                        .lineStyle(StrokeStyle(lineWidth: 0.7))
                }
                ForEach(points) { point in
                    AreaMark(x: .value("Time", point.date),
                             y: .value("Temperature", unit.value(fromCelsius: point.celsius)))
                        .foregroundStyle(LinearGradient(colors: [Color.mwLoss.opacity(0.35), Color.mwLoss.opacity(0.02)],
                                                        startPoint: .top,
                                                        endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", point.date),
                             y: .value("Temperature", unit.value(fromCelsius: point.celsius)))
                        .foregroundStyle(Color.mwLoss)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: domain)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartPlotStyle { plot in
                // Reserve a real blank gutter inside the plot bounds. The
                // separate labels must never sit on top of the final data area.
                plot.padding(.leading, 4).padding(.trailing, 26).padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .trailing, spacing: 0) {
                ForEach(0..<axisLabels.count, id: \.self) { index in
                    Text(verbatim: String(format: "%.0f°", axisLabels[index]))
                        .mwMono(size: 9)
                        .foregroundStyle(Color.mwMuted)
                        .frame(maxHeight: .infinity,
                               alignment: index == 0 ? .top : (index == 1 ? .center : .bottom))
                }
            }
            .frame(width: 36, height: height - 12, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .animation(.timingCurve(0.16, 1.0, 0.3, 1.0, duration: 0.68), value: points)
        .frame(height: height)
    }
}
