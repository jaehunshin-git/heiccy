import SwiftUI
import ConverterKit

/// 메뉴 막대의 우클릭 메뉴에서 여는 별도 설정 창의 내용이다.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("변환 형식") {
                    Picker("형식", selection: $model.settings.options.outputFormat) {
                        Text("JPEG").tag("jpeg")
                        Text("PNG").tag("png")
                    }.pickerStyle(.segmented)
                    if model.settings.options.outputFormat == "jpeg" {
                        jpegSettings
                    } else {
                        pngSettings
                    }
                }
                Section("메타데이터") {
                    Picker("정책", selection: $model.settings.options.metadata) {
                        Text("모두 보존").tag("preserve")
                        Text("안전 보존").tag("safe")
                        Text("제거").tag("strip")
                    }
                    Text("안전 보존은 GPS·XMP 정보를 제외합니다. 모두 보존은 가능한 원본 메타데이터를 유지하고, 제거는 메타데이터를 제외합니다.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Text("변경 사항은 자동으로 저장됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("기본값 복원") { model.resetConversionOptions() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHint("변환 형식, 품질, 압축, 메타데이터를 기본값으로 복원합니다.")
            }.padding(16)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 390)
    }

    private var jpegSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("JPEG 품질", selection: $model.settings.options.qualityPreset) {
                ForEach(QualityPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }.pickerStyle(.segmented)
            Text("품질 \(model.settings.options.jpegQuality) · Low 60 / Medium 80 / High 90 / Raw 100")
                .font(.caption).foregroundStyle(.secondary)
            Text("Raw도 손실 JPEG입니다. 품질 수치는 백분율이 아닙니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var pngSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("PNG 압축", selection: $model.settings.options.pngCompressionPreset) {
                ForEach(PNGCompressionPreset.displayOrder) { preset in
                    Text(preset.label).tag(preset)
                }
            }.pickerStyle(.segmented)
            Text("압축 \(model.settings.options.pngCompression) · 화질은 같고 변환 시간과 파일 크기가 달라집니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("네이티브 HDR PNG에는 이 압축 설정이 적용되지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
