#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputcontextproperty.h>
#include <fcitx/instance.h>
#include <fcitx-utils/capabilityflags.h>
#include <fcitx-utils/key.h>

#include <algorithm>
#include <cerrno>
#include <cctype>
#include <chrono>
#include <cstdlib>
#include <ctime>
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {

constexpr const char *secureMarker = "\x01secure";

struct ExpansionState : public fcitx::InputContextProperty {
    bool active = false;
    std::string candidate;
    fcitx::KeySym suppressedRelease = FcitxKey_None;

    void reset() {
        active = false;
        candidate.clear();
    }
};

struct RuntimeConfig {
    bool enabled = true;
    char prefix = ';';
    std::vector<std::string> excludedPrograms;
    std::unordered_map<std::string, std::string> entries;
};

std::filesystem::path configDirectory() {
    if (const char *xdg = std::getenv("XDG_CONFIG_HOME"); xdg && *xdg) {
        return std::filesystem::path(xdg) / "omaspansion";
    }
    if (const char *home = std::getenv("HOME"); home && *home) {
        return std::filesystem::path(home) / ".config" / "omaspansion";
    }
    return {};
}

std::filesystem::path helperPath() {
    if (const char *xdg = std::getenv("XDG_CONFIG_HOME"); xdg && *xdg) {
        return std::filesystem::path(xdg) / "omarchy" / "plugins" /
               "brandon.omaspansion" / "bin" / "omaspansion";
    }
    if (const char *home = std::getenv("HOME"); home && *home) {
        return std::filesystem::path(home) / ".config" / "omarchy" / "plugins" /
               "brandon.omaspansion" / "bin" / "omaspansion";
    }
    return {};
}

bool launchSecureExpansion(const std::string &key, const char *mode) {
    const auto helper = helperPath();
    if (helper.empty()) {
        return false;
    }

    const auto child = fork();
    if (child < 0) {
        return false;
    }
    if (child == 0) {
        const auto worker = fork();
        if (worker < 0) {
            _exit(127);
        }
        if (worker > 0) {
            _exit(0);
        }

        setsid();
        const int nullFd = open("/dev/null", O_RDWR);
        if (nullFd >= 0) {
            dup2(nullFd, STDIN_FILENO);
            dup2(nullFd, STDOUT_FILENO);
            dup2(nullFd, STDERR_FILENO);
            if (nullFd > STDERR_FILENO) {
                close(nullFd);
            }
        }
        execl(helper.c_str(), helper.c_str(), mode, key.c_str(),
              static_cast<char *>(nullptr));
        _exit(127);
    }

    int status = 0;
    pid_t waited = -1;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    return waited == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

std::string trim(std::string value) {
    const auto first = value.find_first_not_of(" \t\r\n");
    if (first == std::string::npos) {
        return {};
    }
    const auto last = value.find_last_not_of(" \t\r\n");
    return value.substr(first, last - first + 1);
}

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

void replaceAll(std::string &value, const std::string &needle,
                const std::string &replacement) {
    std::size_t position = 0;
    while ((position = value.find(needle, position)) != std::string::npos) {
        value.replace(position, needle.size(), replacement);
        position += replacement.size();
    }
}

std::string formattedTime(std::chrono::system_clock::time_point point,
                          const char *format) {
    const std::time_t raw = std::chrono::system_clock::to_time_t(point);
    std::tm local{};
    localtime_r(&raw, &local);
    char output[64]{};
    std::strftime(output, sizeof(output), format, &local);
    return output;
}

std::size_t utf8Length(const std::string &value) {
    return static_cast<std::size_t>(std::count_if(
        value.begin(), value.end(), [](unsigned char c) { return (c & 0xc0) != 0x80; }));
}

struct RenderedValue {
    std::string text;
    std::size_t cursor = 0;
};

RenderedValue render(std::string value) {
    const auto now = std::chrono::system_clock::now();
    replaceAll(value, "{{date}}", formattedTime(now, "%m/%d/%Y"));
    replaceAll(value, "{{date_dashed_plus4h}}",
               formattedTime(now + std::chrono::hours(4), "%Y-%m-%d-"));
    replaceAll(value, "{{date_compact_plus4h}}",
               formattedTime(now + std::chrono::hours(4), "%Y%m%d"));

    constexpr const char *marker = "$|$";
    const auto markerPosition = value.find(marker);
    if (markerPosition == std::string::npos) {
        return {value, utf8Length(value)};
    }
    value.erase(markerPosition, 3);
    return {value, utf8Length(value.substr(0, markerPosition))};
}

class TypedExpander final : public fcitx::AddonInstance {
public:
    explicit TypedExpander(fcitx::AddonManager *manager)
        : instance_(manager->instance()) {
        instance_->inputContextManager().registerProperty(
            "omaspansionTypedExpansion", &stateFactory_);
        keyWatcher_ = instance_->watchEvent(
            fcitx::EventType::InputContextKeyEvent,
            fcitx::EventWatcherPhase::PreInputMethod,
            [this](fcitx::Event &event) { handleKey(static_cast<fcitx::KeyEvent &>(event)); });
        resetWatcher_ = instance_->watchEvent(
            fcitx::EventType::InputContextReset,
            fcitx::EventWatcherPhase::PreInputMethod,
            [this](fcitx::Event &event) {
                auto &contextEvent = static_cast<fcitx::InputContextEvent &>(event);
                contextEvent.inputContext()->propertyFor(&stateFactory_)->reset();
            });
    }

private:
    bool loadConfig(RuntimeConfig &config) const {
        const auto directory = configDirectory();
        if (directory.empty()) {
            return false;
        }

        std::ifstream runtime(directory / "typed-runtime.conf");
        std::string line;
        if (!std::getline(runtime, line)) {
            return false;
        }
        config.enabled = trim(line) == "1";
        if (!std::getline(runtime, line) || line.size() != 1 ||
            std::isalnum(static_cast<unsigned char>(line[0])) ||
            std::isspace(static_cast<unsigned char>(line[0]))) {
            return false;
        }
        config.prefix = line[0];

        std::ifstream excluded(directory / "typed-excluded-programs.txt");
        while (std::getline(excluded, line)) {
            line = lower(trim(line));
            if (!line.empty()) {
                config.excludedPrograms.push_back(std::move(line));
            }
        }

        std::ifstream data(directory / "typed-entries.dat", std::ios::binary);
        std::string contents((std::istreambuf_iterator<char>(data)),
                             std::istreambuf_iterator<char>());
        std::size_t position = 0;
        while (position < contents.size()) {
            const auto keyEnd = contents.find('\0', position);
            if (keyEnd == std::string::npos) {
                return false;
            }
            const auto valueEnd = contents.find('\0', keyEnd + 1);
            if (valueEnd == std::string::npos) {
                return false;
            }
            const auto key = contents.substr(position, keyEnd - position);
            const auto value = contents.substr(keyEnd + 1, valueEnd - keyEnd - 1);
            if (!key.empty()) {
                config.entries.emplace(key, value);
            }
            position = valueEnd + 1;
        }
        return true;
    }

    static bool excluded(const RuntimeConfig &config,
                         const fcitx::InputContext *inputContext) {
        const auto program = lower(inputContext->program());
        if (program.empty()) {
            return false;
        }
        return std::any_of(config.excludedPrograms.begin(),
                           config.excludedPrograms.end(),
                           [&program](const std::string &pattern) {
                               return program == pattern || program.find(pattern) != std::string::npos;
                           });
    }

    static bool hasPrefix(const RuntimeConfig &config, const std::string &candidate) {
        return std::any_of(config.entries.begin(), config.entries.end(),
                           [&candidate](const auto &entry) {
                               return entry.first.compare(0, candidate.size(), candidate) == 0;
                           });
    }

    static bool printableAscii(const fcitx::Key &key, char &character) {
        const auto blocked = fcitx::KeyStates{fcitx::KeyState::Ctrl} |
                             fcitx::KeyState::Alt | fcitx::KeyState::Super |
                             fcitx::KeyState::Super2 | fcitx::KeyState::Hyper |
                             fcitx::KeyState::Meta;
        if (key.states().testAny(blocked)) {
            return false;
        }
        const auto symbol = key.sym();
        if (symbol < 0x20 || symbol > 0x7e) {
            return false;
        }
        character = static_cast<char>(symbol);
        return true;
    }

    static void eraseCommittedTrigger(fcitx::InputContext *inputContext,
                                      std::size_t count) {
        for (std::size_t index = 0; index < count; ++index) {
            inputContext->forwardKey(fcitx::Key(FcitxKey_BackSpace), false);
            inputContext->forwardKey(fcitx::Key(FcitxKey_BackSpace), true);
        }
    }

    static void commitExpansion(fcitx::InputContext *inputContext,
                                const std::string &rawValue) {
        const auto value = render(rawValue);
        if (inputContext->capabilityFlags().test(
                fcitx::CapabilityFlag::CommitStringWithCursor)) {
            inputContext->commitStringWithCursor(value.text, value.cursor);
            return;
        }

        inputContext->commitString(value.text);
        const auto length = utf8Length(value.text);
        for (std::size_t index = value.cursor; index < length; ++index) {
            inputContext->forwardKey(fcitx::Key(FcitxKey_Left), false);
            inputContext->forwardKey(fcitx::Key(FcitxKey_Left), true);
        }
    }

    void handleKey(fcitx::KeyEvent &event) {
        auto *inputContext = event.inputContext();
        auto *state = inputContext->propertyFor(&stateFactory_);

        if (event.isRelease()) {
            if (state->suppressedRelease != FcitxKey_None &&
                event.key().sym() == state->suppressedRelease) {
                state->suppressedRelease = FcitxKey_None;
                event.filterAndAccept();
            }
            return;
        }

        RuntimeConfig config;
        if (!loadConfig(config) || !config.enabled || excluded(config, inputContext)) {
            state->reset();
            return;
        }

        if (event.key().sym() == FcitxKey_BackSpace) {
            if (state->active) {
                if (state->candidate.empty()) {
                    state->reset();
                } else {
                    state->candidate.pop_back();
                }
            }
            return;
        }

        char character = '\0';
        if (!printableAscii(event.key(), character)) {
            state->reset();
            return;
        }

        if (!state->active) {
            if (character == config.prefix) {
                state->active = true;
                state->candidate.clear();
            }
            return;
        }

        if (character == config.prefix) {
            state->candidate.clear();
            return;
        }

        state->candidate.push_back(character);
        const auto exact = config.entries.find(state->candidate);
        if (exact != config.entries.end()) {
            state->suppressedRelease = event.key().sym();
            event.filterAndAccept();
            eraseCommittedTrigger(inputContext, 1 + state->candidate.size() - 1);
            if (exact->second == secureMarker) {
                launchSecureExpansion(exact->first, "run-typed-secure");
            } else {
                commitExpansion(inputContext, exact->second);
            }
            state->reset();
            return;
        }

        if (!hasPrefix(config, state->candidate)) {
            state->reset();
        }
    }

    fcitx::Instance *instance_;
    fcitx::SimpleInputContextPropertyFactory<ExpansionState> stateFactory_;
    std::unique_ptr<fcitx::HandlerTableEntry<fcitx::EventHandler>> keyWatcher_;
    std::unique_ptr<fcitx::HandlerTableEntry<fcitx::EventHandler>> resetWatcher_;
};

class TypedExpanderFactory final : public fcitx::AddonFactory {
public:
    fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
        return new TypedExpander(manager);
    }
};

} // namespace

FCITX_ADDON_FACTORY(TypedExpanderFactory);
