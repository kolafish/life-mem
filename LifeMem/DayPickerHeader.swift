import SwiftUI

struct DayPickerHeader: View {
    let days: [RouteReviewDay]
    @Binding var selection: Date

    var body: some View {
        Menu {
            Picker("日期", selection: $selection) {
                ForEach(days) { item in
                    Text(item.date, format: .dateTime.year().month().day()).tag(item.date)
                }
            }
        } label: {
            Label("切换日期", systemImage: "calendar")
        }
    }
}
