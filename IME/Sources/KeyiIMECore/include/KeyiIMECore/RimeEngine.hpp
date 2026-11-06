#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace keyi {

struct RimeResult {
  bool handled = false;
  std::string preedit;
  std::vector<std::string> candidates;
  std::optional<std::string> commit;
  int highlighted_candidate_index = -1;
  /// Caret offset inside the composition, as the raw UTF-8 byte offset librime
  /// reports. It is kept in bytes because only a real UTF-8 decode can produce
  /// the UTF-16 length a client's marked-text selection needs; counting code
  /// points would confuse Unicode scalars with grapheme clusters.
  std::size_t cursor_byte_offset = 0;
  /// True when the snapshot carried a composition, so `cursor_byte_offset` is
  /// meaningful.
  bool has_cursor = false;
};

/// Minimal librime wrapper: one engine instance owns exactly one Rime
/// session, so two input method sessions never share composition state.
class RimeEngine {
 public:
  RimeEngine(std::string shared_data_path, std::string user_data_path,
             std::string schema_identifier = "keyi_pinyin");
  ~RimeEngine();

  RimeEngine(const RimeEngine&) = delete;
  RimeEngine& operator=(const RimeEngine&) = delete;

  bool ready() const;
  const std::string& error_message() const;
  std::string version() const;

  void SetCandidatePageSize(int page_size);
  RimeResult ProcessKey(int keycode, int modifiers);
  RimeResult ChangeCandidatePage(bool backward);
  RimeResult MoveCandidateHighlight(int delta);
  RimeResult SelectVisibleCandidate(int index);
  RimeResult SelectHighlightedCandidate();
  /// Commits the whole composition the way librime does: each segment as its
  /// selected (or highlighted) candidate, text with no candidate as typed.
  RimeResult CommitComposition();
  std::string RawInput() const;
  void Clear();

  /// Empties a user dictionary inside the running input method: every
  /// session is released (librime keeps the userdb open while one exists)
  /// and engines quietly start a new session on their next call.
  static bool ResetUserDictionary(const std::string& shared_data_path,
                                  const std::string& user_data_path,
                                  const std::string& dict_name);

  /// Recompiles the dictionaries after the user directory's copies changed.
  /// Live sessions are released and recreated on their next call.
  static bool Redeploy(const std::string& shared_data_path,
                       const std::string& user_data_path);

  /// Exports a user dictionary as text and returns the entry count, or -1.
  /// Initializes librime for this call alone, so it must only run in a
  /// process that has no RimeEngine (the `--export-user-dict` mode), on a
  /// copy of the userdb because the live input method holds its lock.
  static int ExportUserDictionary(const std::string& user_data_path,
                                  const std::string& dict_name,
                                  const std::string& text_file);

 private:
  struct Implementation;
  std::unique_ptr<Implementation> implementation_;
};

}  // namespace keyi
