// The recognizer for this Mac. macOS 26: SpeechAnalyzer with SpeechTranscriber. macOS 13 to 15:
// SFSpeechRecognizer. There is no setting.
import Speech

func pickRecognizer() async throws -> Recognizer {
  if #available(macOS 26.0, *), SpeechTranscriber.isAvailable {
    return try await AnalyzerRecognizer.pick()
  }
  return try SFRecognizer.pick()
}
