#include "KeyiIMECore/RimeEngine.hpp"

#include <algorithm>
#include <filesystem>
#include <mutex>
#include <utility>

#include <rime_api.h>
#include <rime_levers_api.h>

namespace keyi {
namespace {

/// librime keeps global state, so the runtime is process wide and shared by
/// every engine instance. Sessions stay per engine.
class RimeRuntime {
 public:
  static RimeRuntime& Shared(const std::string& shared_data_path,
                             const std::string& user_data_path) {
    static RimeRuntime runtime(shared_data_path, user_data_path);
    return runtime;
  }

  RimeRuntime(const RimeRuntime&) = delete;
  RimeRuntime& operator=(const RimeRuntime&) = delete;

  ~RimeRuntime() {
    if (initialized_) {
      api_->finalize();
    }
  }

  RimeApi* api() const { return api_; }
  bool ready() const { return initialized_; }
  /// Bumped whenever every session was torn down (user dictionary reset);
  /// engines holding an older value recreate their session on next use.
  std::uint64_t generation() const { return generation_; }

  /// Clears a user dictionary in place. The caller holds `mutex()`. librime
  /// keeps the userdb open while any session uses it, so all sessions are
  /// released first; the database is recreated empty on the next key.
  bool ResetUserDictionary(const std::string& dict_name) {
    if (!initialized_) {
      return false;
    }
    api_->cleanup_all_sessions();
    ++generation_;
    std::error_code filesystem_error;
    std::filesystem::remove_all(
        std::filesystem::path(user_data_path_) / (dict_name + ".userdb"),
        filesystem_error);
    return !filesystem_error;
  }
  /// Rebuilds the deployed data after dictionary sources changed in the user
  /// directory. The caller holds `mutex()`. Sessions are released first so no
  /// one reads tables that are being replaced; engines start new ones on their
  /// next key, against the new build.
  bool Redeploy() {
    if (!initialized_) {
      return false;
    }
    api_->cleanup_all_sessions();
    ++generation_;
    const bool started = api_->start_maintenance(True);
    api_->join_maintenance_thread();
    return started;
  }
  const std::string& error_message() const { return error_message_; }
  std::mutex& mutex() { return mutex_; }

 private:
  RimeRuntime(std::string shared_data_path, std::string user_data_path)
      : shared_data_path_(std::move(shared_data_path)),
        user_data_path_(std::move(user_data_path)),
        api_(rime_get_api()) {
    std::error_code filesystem_error;
    std::filesystem::create_directories(user_data_path_, filesystem_error);
    if (filesystem_error) {
      error_message_ =
          "Unable to create the Rime user data directory: " +
          filesystem_error.message();
      return;
    }

    if (api_ == nullptr) {
      error_message_ = "librime did not return an API table";
      return;
    }

    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = shared_data_path_.c_str();
    traits.user_data_dir = user_data_path_.c_str();
    traits.distribution_name = "KEYI输入法";
    traits.distribution_code_name = "keyi_ime";
    traits.distribution_version = "0.1.0";
    traits.app_name = "rime.keyi";
    traits.min_log_level = 2;
    traits.log_dir = "";

    api_->setup(&traits);
    api_->initialize(nullptr);
    api_->start_maintenance(True);
    api_->join_maintenance_thread();
    initialized_ = true;
  }

  std::string shared_data_path_;
  std::string user_data_path_;
  RimeApi* api_ = nullptr;
  bool initialized_ = false;
  std::string error_message_;
  std::mutex mutex_;
  std::uint64_t generation_ = 0;
};

std::string CopyCString(const char* value) {
  return value == nullptr ? std::string() : std::string(value);
}

/// Rime reports the composition caret as a UTF-8 byte offset. The bytes are
/// passed through untouched: decoding them is the bridge's job, because only
/// there is the preedit an NSString whose UTF-16 length the client needs.
std::size_t ClampedByteOffset(const std::string& text, int byte_offset) {
  if (byte_offset <= 0) {
    return 0;
  }
  return std::min(static_cast<std::size_t>(byte_offset), text.size());
}

}  // namespace

struct RimeEngine::Implementation {
  explicit Implementation(std::string shared_data_path,
                          std::string user_data_path,
                          std::string schema_identifier)
      : runtime(RimeRuntime::Shared(shared_data_path, user_data_path)),
        schema(std::move(schema_identifier)) {
    if (!runtime.ready()) {
      error_message = runtime.error_message();
      return;
    }

    std::lock_guard<std::mutex> lock(runtime.mutex());
    generation = runtime.generation();
    session_id = runtime.api()->create_session();
    if (session_id == 0) {
      error_message = "Unable to create a Rime session";
      return;
    }
    if (!runtime.api()->select_schema(session_id, schema.c_str())) {
      error_message = "Unable to select the KEYI Pinyin schema: " + schema;
      runtime.api()->destroy_session(session_id);
      session_id = 0;
    }
  }

  /// After a user dictionary reset the old session is gone; start a fresh
  /// one with the same schema. The caller holds the runtime mutex.
  void EnsureSession() {
    if (generation == runtime.generation()) {
      return;
    }
    generation = runtime.generation();
    candidate_offset = 0;
    session_id = runtime.api()->create_session();
    if (session_id != 0) {
      runtime.api()->select_schema(session_id, schema.c_str());
    }
  }

  ~Implementation() {
    if (session_id != 0 && runtime.ready() &&
        generation == runtime.generation()) {
      std::lock_guard<std::mutex> lock(runtime.mutex());
      runtime.api()->destroy_session(session_id);
    }
  }

  std::vector<std::string> CandidatesFrom(size_t start, int limit) {
    std::vector<std::string> candidates;
    if (limit <= 0 ||
        !RIME_API_AVAILABLE(runtime.api(), candidate_list_from_index) ||
        !RIME_API_AVAILABLE(runtime.api(), candidate_list_next) ||
        !RIME_API_AVAILABLE(runtime.api(), candidate_list_end)) {
      return candidates;
    }

    RimeCandidateListIterator iterator = {};
    if (!runtime.api()->candidate_list_from_index(
            session_id, &iterator, static_cast<int>(start))) {
      return candidates;
    }
    while (static_cast<int>(candidates.size()) < limit &&
           runtime.api()->candidate_list_next(&iterator)) {
      candidates.push_back(CopyCString(iterator.candidate.text));
    }
    runtime.api()->candidate_list_end(&iterator);
    return candidates;
  }

  int AbsoluteHighlightedIndex() {
    RIME_STRUCT(RimeContext, context);
    if (!runtime.api()->get_context(session_id, &context)) {
      return static_cast<int>(candidate_offset);
    }
    const int absolute_index =
        context.menu.page_no * context.menu.page_size +
        context.menu.highlighted_candidate_index;
    runtime.api()->free_context(&context);
    return std::max(absolute_index, 0);
  }

  bool Highlight(size_t absolute_index) {
    if (!RIME_API_AVAILABLE(runtime.api(), highlight_candidate)) {
      return false;
    }
    return runtime.api()->highlight_candidate(session_id, absolute_index);
  }

  RimeResult Snapshot(bool handled) {
    RimeResult result;
    result.handled = handled;

    RIME_STRUCT(RimeCommit, commit);
    if (runtime.api()->get_commit(session_id, &commit)) {
      result.commit = CopyCString(commit.text);
      runtime.api()->free_commit(&commit);
      candidate_offset = 0;
    }

    RIME_STRUCT(RimeContext, context);
    if (runtime.api()->get_context(session_id, &context)) {
      result.preedit = CopyCString(context.composition.preedit);
      // Keep librime's own unit here so no refinement is lost; the bridge
      // decodes the UTF-8 prefix into an NSString length.
      result.cursor_byte_offset =
          ClampedByteOffset(result.preedit, context.composition.cursor_pos);
      result.has_cursor = true;
      const int absolute_highlight =
          context.menu.page_no * context.menu.page_size +
          context.menu.highlighted_candidate_index;
      runtime.api()->free_context(&context);

      result.candidates = CandidatesFrom(candidate_offset, page_size);
      const int relative_highlight =
          absolute_highlight - static_cast<int>(candidate_offset);
      result.highlighted_candidate_index =
          relative_highlight >= 0 &&
                  relative_highlight <
                      static_cast<int>(result.candidates.size())
              ? relative_highlight
              : (result.candidates.empty() ? -1 : 0);
    }
    return result;
  }

  RimeRuntime& runtime;
  std::string schema;
  std::uint64_t generation = 0;
  RimeSessionId session_id = 0;
  std::string error_message;
  int page_size = 9;
  size_t candidate_offset = 0;
};

RimeEngine::RimeEngine(std::string shared_data_path,
                       std::string user_data_path,
                       std::string schema_identifier)
    : implementation_(std::make_unique<Implementation>(
          std::move(shared_data_path), std::move(user_data_path),
          std::move(schema_identifier))) {}

RimeEngine::~RimeEngine() = default;

bool RimeEngine::ready() const {
  return implementation_->session_id != 0;
}

const std::string& RimeEngine::error_message() const {
  return implementation_->error_message;
}

std::string RimeEngine::version() const {
  if (!implementation_->runtime.ready()) {
    return {};
  }
  return CopyCString(implementation_->runtime.api()->get_version());
}

void RimeEngine::SetCandidatePageSize(int page_size) {
  if (!ready()) {
    return;
  }
  std::lock_guard<std::mutex> lock(implementation_->runtime.mutex());
  implementation_->EnsureSession();
  const int clamped_size = std::clamp(page_size, 3, 9);
  if (clamped_size != implementation_->page_size) {
    implementation_->page_size = clamped_size;
    implementation_->candidate_offset = 0;
    implementation_->Highlight(0);
  }
}

RimeResult RimeEngine::ProcessKey(int keycode, int modifiers) {
  if (!ready()) {
    return {};
  }
  std::lock_guard<std::mutex> lock(implementation_->runtime.mutex());
  implementation_->EnsureSession();
  implementation_->candidate_offset = 0;
  const bool handled = implementation_->runtime.api()->process_key(
      implementation_->session_id, keycode, modifiers);
  return implementation_->Snapshot(handled);
}

RimeResult RimeEngine::ChangeCandidatePage(bool backward) {
  if (!ready()) {
    return {};
  }
  std::lock_guard<std::mutex> lock(implementation_->runtime.mutex());
  implementation_->EnsureSession();
  auto& state = *implementation_;
  if (state.CandidatesFrom(state.candidate_offset, 1).empty()) {
    return state.Snapshot(false);
  }

  if (backward) {
    state.candidate_offset = state.candidate_offset > state.page_size
                                 ? state.candidate_offset - state.page_size
                                 : 0;
  } else {
    const size_t next_offset = state.candidate_offset + state.page_size;
    if (!state.CandidatesFrom(next_offset, 1).empty()) {
      state.candidate_offset = next_offset;
    }
  }
  state.Highlight(state.candidate_offset);
  return state.Snapshot(true);
}

RimeResult RimeEngine::SelectVisibleCandidate(int index) {
  if (!ready()) {
    return {};
  }
  std::lock_guard<std::mutex> lock(implementation_->runtime.mutex());
  implementation_->EnsureSession();
  auto& state = *implementation_;
  const auto visible =
      state.CandidatesFrom(state.candidate_offset, state.page_size);
  if (visible.empty()) {
    return state.Snapshot(false);
  }
  if (index < 0 || index >= static_cast<int>(visible.size())) {
    return state.Snapshot(true);
  }
  const bool handled = state.runtime.api()->select_candidate(
      state.session_id, state.candidate_offset + index);
  // Selecting a single-syllable candidate advances Rime to the next segment
  // without committing; that new context starts on its own first page.
  if (handled) {
    state.candidate_offset = 0;
  }
  return state.Snapshot(handled);
}

RimeResult RimeEngine::MoveCandidateHighlight(int delta) {
  if (!ready()) {
    return {};
  }
  std::lock_guard<std::mutex> lock(implementation_->runtime.mutex());
  implementation_->EnsureSession();
  auto& state = *implementation_;
  auto visible = state.CandidatesFrom(state.candidate_offset, state.page_size);
  if (visible.empty()) {
    return state.Snapshot(false);
  }

  const int absolute_highlight = state.AbsoluteHighlightedIndex();
  int relative_highlight =
      absolute_highlight - static_cast<int>(state.candidate_offset);
  if (relative_highlight < 0 ||
      relative_highlight >= static_cast<int>(visible.size())) {
    relative_highlight = 0;
  }

  if (delta > 0) {
    if (relative_highlight + 1 < static_cast<int>(visible.size())) {
      ++relative_highlight;
    } else {
      const size_t next_offset = state.candidate_offset + state.page_size;
      if (!state.CandidatesFrom(next_offset, 1).empty()) {
        state.candidate_offset = next_offset;
        relative_highlight = 0;
      }
    }
  } else if (delta < 0) {
    if (relative_highlight > 0) {
      --relative_highlight;
    } else if (state.candidate_offset > 0) {
      state.candidate_offset = state.candidate_offset > state.page_size
                                   ? state.candidate_offset - state.page_size
                                   : 0;
      visible = state.CandidatesFrom(state.candidate_offset, state.page_size);
      relative_highlight =
          std::max(static_cast<int>(visible.size()) - 1, 0);
    }
  }

  state.Highlight(state.candidate_offset + relative_highlight);
  return state.Snapshot(true);
}

RimeResult RimeEngine::SelectHighlightedCandidate() {
  if (!ready()) {
    return {};
  }
  std::lock_guard<std::mutex> lock(implementation_->runtime.mutex());
  implementation_->EnsureSession();
  auto& state = *implementation_;
  const auto visible =
      state.CandidatesFrom(state.candidate_offset, state.page_size);
  if (visible.empty()) {
    return state.Snapshot(false);
  }
  int relative_highlight = state.AbsoluteHighlightedIndex() -
                           static_cast<int>(state.candidate_offset);
  if (relative_highlight < 0 ||
      relative_highlight >= static_cast<int>(visible.size())) {
    relative_highlight = 0;
  }
  const bool handled = state.runtime.api()->select_candidate(
      state.session_id, state.candidate_offset + relative_highlight);
  if (handled) {
    state.candidate_offset = 0;
  }
  return state.Snapshot(handled);
}

RimeResult RimeEngine::CommitComposition() {
  if (!ready()) {
    return {};
  }
  std::lock_guard<std::mutex> lock(implementation_->runtime.mutex());
  implementation_->EnsureSession();
  auto& state = *implementation_;
  const bool handled =
      state.runtime.api()->commit_composition(state.session_id);
  state.candidate_offset = 0;
  return state.Snapshot(handled);
}

std::string RimeEngine::RawInput() const {
  if (!ready()) {
    return {};
  }
  std::lock_guard<std::mutex> lock(implementation_->runtime.mutex());
  implementation_->EnsureSession();
  const char* input =
      implementation_->runtime.api()->get_input(implementation_->session_id);
  return input == nullptr ? std::string() : std::string(input);
}

void RimeEngine::Clear() {
  if (!ready()) {
    return;
  }
  std::lock_guard<std::mutex> lock(implementation_->runtime.mutex());
  implementation_->EnsureSession();
  implementation_->runtime.api()->clear_composition(
      implementation_->session_id);
  implementation_->candidate_offset = 0;
}

bool RimeEngine::ResetUserDictionary(const std::string& shared_data_path,
                                     const std::string& user_data_path,
                                     const std::string& dict_name) {
  auto& runtime = RimeRuntime::Shared(shared_data_path, user_data_path);
  std::lock_guard<std::mutex> lock(runtime.mutex());
  return runtime.ResetUserDictionary(dict_name);
}

bool RimeEngine::Redeploy(const std::string& shared_data_path,
                          const std::string& user_data_path) {
  auto& runtime = RimeRuntime::Shared(shared_data_path, user_data_path);
  std::lock_guard<std::mutex> lock(runtime.mutex());
  return runtime.Redeploy();
}

int RimeEngine::ExportUserDictionary(const std::string& user_data_path,
                                     const std::string& dict_name,
                                     const std::string& text_file) {
  RimeApi* api = rime_get_api();
  if (api == nullptr) {
    return -1;
  }
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = user_data_path.c_str();
  traits.user_data_dir = user_data_path.c_str();
  traits.distribution_name = "KEYI输入法";
  traits.distribution_code_name = "keyi_ime";
  traits.distribution_version = "0.1.0";
  traits.app_name = "rime.keyi.export";
  traits.min_log_level = 3;
  traits.log_dir = "";
  api->setup(&traits);
  api->initialize(nullptr);
  int exported = -1;
  if (RimeModule* module = api->find_module("levers")) {
    auto* levers = reinterpret_cast<RimeLeversApi*>(module->get_api());
    if (levers != nullptr) {
      exported = levers->export_user_dict(dict_name.c_str(), text_file.c_str());
    }
  }
  api->finalize();
  return exported;
}

}  // namespace keyi
