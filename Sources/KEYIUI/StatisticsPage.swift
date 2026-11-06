import Combine
import KEYICore
import SwiftUI

/// 「统计」栏目：今天的四个数（一条），近 7 天柱状图和费用并排，用户词库一行；每日明细可展开。
/// 菜单栏的今日数字和这里读同一份计数。
///
/// 2026-11-05 收紧：所有宽度都按比例分（不再按量出来的宽度写死，窗口窄时右边被裁掉——用户截图），
/// 费用表只列今天用到的和正在用的服务，免费的两种合成一行；改单价时才列出全部。
struct StatisticsPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var stats: StatisticsModel = .shared
    @State private var confirmingClear = false
    @State private var editingPrices = false
    @State private var showingDetails = false

    private static let gap: CGFloat = 10

    /// 设置窗口开着时隔几秒重读一次，输入法刚写的计数能跟上。
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let strings = model.strings
        DetailPage(
            title: strings.statsToday,
            subtitle: Date().formatted(.dateTime.month().day().weekday(.abbreviated).locale(locale(strings))),
            spacing: Self.gap
        ) {
            todayStrip(strings)
            // 图表和费用各占一半、等高：按内容量高后都撑到较高那张。
            HStack(alignment: .top, spacing: Self.gap) {
                weekChart(strings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                costTable(strings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .fixedSize(horizontal: false, vertical: true)
            if editingPrices {
                SettingsGroup { prices(strings) }
                Text(strings.statsPricesNote)
                    .font(.system(size: 11))
                    .foregroundStyle(KEYIPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            userDictionary(strings)
            DisclosureGroup(isExpanded: $showingDetails) {
                SettingsGroup { recentDays(strings) }
                    .padding(.top, 6)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(strings.statsDailyDetails)
                        .font(.system(size: 12, weight: .medium))
                    Text(strings.statisticsDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(KEYIPalette.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .onAppear {
            stats.reload()
            stats.countLearnedWords()
        }
        .onReceive(refresh) { _ in stats.reload() }
        .alert(strings.statsClearTitle, isPresented: $confirmingClear) {
            Button(strings.statsClearConfirm, role: .destructive) { stats.clearDictionary(strings: strings) }
            Button(strings.cancel, role: .cancel) {}
        } message: {
            Text(strings.statsClearMessage(StatisticsModel.backupDirectory.path))
        }
    }

    private func locale(_ strings: InterfaceStrings) -> Locale {
        Locale(identifier: strings.isEnglish ? "en_US" : "zh_CN")
    }

    // MARK: 今天

    /// 四个数放在一张卡里，中间细竖线隔开；数字用主题色，费用用大模型色。
    private func todayStrip(_ strings: InterfaceStrings) -> some View {
        let today = stats.days.first
        let tokens = (today?.inputTokens ?? 0) + (today?.outputTokens ?? 0)
        return HStack(spacing: 0) {
            StatCell(value: (today?.words.hanzi ?? 0).formatted(), label: strings.statsConfirmedHanzi)
            cellDivider
            StatCell(value: (today?.words.translatedWords ?? 0).formatted(), label: strings.statsEnglishWords)
            cellDivider
            StatCell(
                value: tokens.formatted(.number.notation(.compactName).locale(Locale(identifier: "en_US"))),
                label: strings.statsLLMTokens
            )
            cellDivider
            StatCell(value: costText(today?.cost ?? [:]), label: strings.statsEstimatedCost, tint: KEYIPalette.api)
        }
        .fixedSize(horizontal: false, vertical: true)
        .keyiCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings.statsToday)
    }

    private var cellDivider: some View {
        Rectangle().fill(KEYIPalette.line).frame(width: 1).padding(.vertical, 10)
    }

    // MARK: 近 7 天

    private func weekChart(_ strings: InterfaceStrings) -> some View {
        let days = Array(stats.days.reversed())
        let peak = max(days.map(\.words.hanzi).max() ?? 0, 1)
        let average = days.isEmpty ? 0 : days.reduce(0) { $0 + $1.words.hanzi } / days.count
        return Card(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(strings.statsWeekChart)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Text(strings.statsDailyAverage(average.formatted()))
                    .font(.system(size: 11))
                    .foregroundStyle(KEYIPalette.ink2)
            }
            // 柱区跟着卡片长高：卡片和费用表等高，柱子按柱区高度画。
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(days) { day in
                        let isToday = day.id == stats.days.first?.id
                        UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3, style: .continuous)
                            .fill(KEYIPalette.accent.opacity(isToday ? 1 : 0.45))
                            .frame(height: max(geometry.size.height * CGFloat(day.words.hanzi) / CGFloat(peak), 2))
                            .frame(maxWidth: .infinity)
                            .help("\(day.key)：\(day.words.hanzi.formatted())")
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(minHeight: 84, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle().fill(KEYIPalette.line2).frame(height: 1)
            }
            HStack(spacing: 10) {
                ForEach(days) { day in
                    let isToday = day.id == stats.days.first?.id
                    Text(isToday ? strings.statsToday : weekday(day.key, strings))
                        .font(.system(size: 10.5, weight: isToday ? .semibold : .regular))
                        .foregroundStyle(isToday ? KEYIPalette.accentText : KEYIPalette.ink2)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func weekday(_ key: String, _ strings: InterfaceStrings) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: key) else { return String(key.dropFirst(5)) }
        let formatter = DateFormatter()
        formatter.locale = locale(strings)
        formatter.dateFormat = strings.isEnglish ? "EEE" : "EEEEE"
        return formatter.string(from: date)
    }

    // MARK: 费用与单价

    /// 只列今天用到的服务和正在用的那个；没有就只剩免费一行和合计。改单价时下面列出全部。
    private func costTable(_ strings: InterfaceStrings) -> some View {
        let todayKey = stats.days.first?.key ?? ""
        let totals = stats.usage.totals(on: todayKey)
        let shown = APIPriceCatalog.billedProviders.filter { providerID in
            (totals[providerID]?.requests ?? 0) > 0 || providerID == model.cloudProviderInUse
        }
        return Card(spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(strings.statsCostAndPrices)
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button(editingPrices ? strings.statsDoneEditing : strings.statsEditPrices) {
                    withAnimation(.snappy(duration: 0.2)) { editingPrices.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(KEYIPalette.accentText)
            }
            .padding(.bottom, 2)
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 0) {
                GridRow {
                    Text(strings.statsServiceColumn)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    KEYIMixedText.text(strings.statsPerMillionColumn, size: 11)
                        .gridColumnAlignment(.trailing)
                    Text(strings.statsToday).gridColumnAlignment(.trailing)
                }
                .font(.system(size: 11))
                .foregroundStyle(KEYIPalette.ink3)
                .padding(.vertical, 3)
                ForEach(shown, id: \.self) { providerID in
                    let price = stats.price(for: providerID)
                    let cost = price.map { $0.cost(of: totals[providerID] ?? APIUsageTotals()) } ?? 0
                    tableDivider
                    GridRow {
                        KEYIMixedText.text(strings.providerName(providerID), size: 12)
                        Text(price.map(priceText) ?? "—")
                            .foregroundStyle(KEYIPalette.ink2)
                        Text(money(cost, price?.currency ?? .cny))
                            .fontWeight(cost > 0 ? .semibold : .regular)
                    }
                    .padding(.vertical, 5)
                }
                tableDivider
                GridRow {
                    KEYIMixedText.text(strings.statsFreeEngines, size: 12)
                    Text(strings.statsFree).foregroundStyle(KEYIPalette.ink2)
                    Text("—").foregroundStyle(KEYIPalette.ink3)
                }
                .padding(.vertical, 5)
                // 人民币和美元不折算，分币种合计。
                Rectangle().fill(KEYIPalette.line2).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(strings.statsTodayTotal).fontWeight(.semibold)
                    Color.clear.frame(width: 1, height: 1)
                    Text(costText(stats.days.first?.cost ?? [:]))
                        .fontWeight(.semibold)
                        .foregroundStyle(KEYIPalette.api)
                }
                .padding(.vertical, 5)
            }
            .font(.system(size: 12))
            .monospacedDigit()
            .lineLimit(1)
            KEYIMixedText.text(strings.statsCostNote, size: 10.5)
                .foregroundStyle(KEYIPalette.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tableDivider: some View {
        Rectangle().fill(KEYIPalette.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
    }

    private func priceText(_ price: APIPrice) -> String {
        let number = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        let symbol = price.currency.symbol
        return "\(symbol)\(price.inputPerMillion.formatted(number)) / \(symbol)\(price.outputPerMillion.formatted(number))"
    }

    private func money(_ amount: Double, _ currency: APIPrice.Currency) -> String {
        guard amount > 0 else { return "\(currency.symbol)0" }
        let digits = amount < 0.01 ? 4 : 2
        return currency.symbol + amount.formatted(.number.precision(.fractionLength(digits)))
    }

    // MARK: 用户词库

    /// 一行：名称和短注，两个数（主题色），右边导出、清空。详细说明在悬停提示里。
    private func userDictionary(_ strings: InterfaceStrings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(strings.statsUserDictionary)
                            .font(.system(size: 12.5, weight: .semibold))
                        KEYIMixedText.text(
                            stats.inputMethodInstalled ? strings.statsUserDictionaryShort : strings.statsUserDictionaryUnavailable,
                            size: 11
                        )
                        .foregroundStyle(KEYIPalette.ink3)
                        .lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        metric(strings.statsLearnedShort, learnedText, unit: stats.learnedWords.map { $0 >= 0 } == true ? strings.statsWordsUnit : nil)
                        metric(
                            strings.statsPerAppShort,
                            stats.appLearning.map { $0.entries.formatted() } ?? "—",
                            unit: stats.appLearning.map { apps in
                                strings.statsWordsUnit + (apps.apps > 0 ? (strings.isEnglish ? ", " : "，") + strings.statsAppSpread(apps.apps) : "")
                            }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(strings.statsUserDictionaryDetail)
                HStack(spacing: 8) {
                    if stats.dictionaryBusy { ProgressView().controlSize(.small) }
                    Button(strings.statsExport) { stats.exportDictionary(strings: strings) }
                        .buttonStyle(KEYISecondaryButtonStyle())
                    Button(strings.statsClear) { confirmingClear = true }
                        .buttonStyle(KEYISecondaryButtonStyle(destructive: true))
                }
                .disabled(!stats.inputMethodInstalled || stats.dictionaryBusy)
            }
            if let message = stats.dictionaryMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(KEYIPalette.ink2)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .keyiCard()
        .animation(.easeOut(duration: 0.15), value: stats.dictionaryMessage)
    }

    private func metric(_ label: String, _ value: String, unit: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            KEYIMixedText.text(label, size: 11.5)
                .foregroundStyle(KEYIPalette.ink2)
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(KEYIPalette.accentText)
                .monospacedDigit()
            if let unit {
                KEYIMixedText.text(unit, size: 11.5)
                    .foregroundStyle(KEYIPalette.ink3)
            }
        }
    }

    private var learnedText: String {
        switch stats.learnedWords {
        case nil: "…"
        case let count? where count < 0: "—"
        case let count?: count.formatted()
        }
    }

    // MARK: 每日明细

    private func recentDays(_ strings: InterfaceStrings) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 0) {
            GridRow {
                Text(strings.statsDate)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .gridColumnAlignment(.leading)
                Group {
                    Text(strings.statsHanzi)
                    Text(strings.statsTranslatedWords)
                    Text(strings.statsRequests)
                    Text(strings.statsTokens)
                    Text(strings.statsCost)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(.caption)
            .foregroundStyle(KEYIPalette.ink2)
            .padding(.vertical, 8)
            ForEach(stats.days) { day in
                Rectangle().fill(KEYIPalette.line).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text(day.id == stats.days.first?.id ? strings.statsToday : String(day.key.dropFirst(5)))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Group {
                        Text(day.words.hanzi.formatted())
                        Text(day.words.translatedWords.formatted())
                        Text(day.requests.formatted())
                        Text(day.requests == 0 ? "—" : "\(day.inputTokens.formatted()) / \(day.outputTokens.formatted())")
                            .foregroundStyle(KEYIPalette.ink2)
                        Text(costText(day.cost))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .monospacedDigit()
                .padding(.vertical, 7)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 4)
    }

    // MARK: 单价

    private func prices(_ strings: InterfaceStrings) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(APIPriceCatalog.billedProviders.enumerated()), id: \.element) { index, providerID in
                if index > 0 { SettingsDivider() }
                PriceRow(
                    name: strings.providerName(providerID),
                    price: stats.price(for: providerID) ?? APIPrice(inputPerMillion: 0, outputPerMillion: 0, currency: .usd),
                    isDefault: stats.usage.prices[providerID.rawValue] == nil,
                    strings: strings,
                    onChange: { stats.setPrice($0, for: providerID) }
                )
            }
        }
    }

    private func costText(_ cost: [APIPrice.Currency: Double]) -> String {
        let parts = APIPrice.Currency.allCases.compactMap { currency -> String? in
            guard let amount = cost[currency], amount > 0 else { return nil }
            let digits = amount < 0.01 ? 4 : 2
            return currency.symbol + amount.formatted(.number.precision(.fractionLength(digits)))
        }
        // 没有费用时也带货币符号；有两种货币时分开写，不折算。
        return parts.isEmpty ? "¥0" : parts.joined(separator: " + ")
    }
}

/// 次要按钮：比卡片深一档的底加一圈 line-2 细边，暗色下也看得清边界；危险操作用危险色字。
struct KEYISecondaryButtonStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(destructive ? KEYIPalette.danger : KEYIPalette.ink)
            .padding(.horizontal, 11)
            .frame(height: 24)
            .background(
                configuration.isPressed ? KEYIPalette.line2 : KEYIPalette.chip,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(KEYIPalette.line2, lineWidth: 1)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// 统计页的卡片：和设置卡片同一种半透明底。
private struct Card<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .keyiCard()
    }
}

/// 今天的一个数：小标题加主题色大号数字。
private struct StatCell: View {
    let value: String
    let label: String
    var tint: Color = KEYIPalette.accentText

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            KEYIMixedText.text(label, size: 11.5)
                .foregroundStyle(KEYIPalette.ink2)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 21, weight: .semibold))
                .kerning(-0.3)
                .foregroundStyle(tint)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .animation(.snappy, value: value)
        .accessibilityElement(children: .combine)
    }
}

/// 一个服务的单价：输入、输出两个数和货币，改完回车或离开输入框即保存。
private struct PriceRow: View {
    let name: String
    let price: APIPrice
    let isDefault: Bool
    let strings: InterfaceStrings
    let onChange: (APIPrice?) -> Void

    @State private var input: Double = 0
    @State private var output: Double = 0
    @State private var currency: APIPrice.Currency = .cny

    var body: some View {
        SettingsRow(label: name) {
            HStack(spacing: 8) {
                field(strings.statsInput, value: $input)
                field(strings.statsOutput, value: $output)
                Picker("", selection: $currency) {
                    ForEach(APIPrice.Currency.allCases, id: \.self) { Text($0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .onChange(of: currency) { commit() }
                .onChange(of: input) { commit() }
                .onChange(of: output) { commit() }
                Button(strings.statsResetPrice) { onChange(nil) }
                    .disabled(isDefault)
            }
        }
        .onAppear(perform: load)
        .onChange(of: price) { load() }
    }

    private func field(_ title: String, value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(KEYIPalette.ink2)
            TextField(title, value: value, format: .number.precision(.fractionLength(0...4)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
        }
    }

    private func load() {
        input = price.inputPerMillion
        output = price.outputPerMillion
        currency = price.currency
    }

    private func commit() {
        let updated = APIPrice(inputPerMillion: max(input, 0), outputPerMillion: max(output, 0), currency: currency)
        if updated != price { onChange(updated) }
    }
}
