#pragma once

#include <cctype>
#include <cstddef>
#include <string>

namespace omaspansion {

class CandidateTracker {
public:
    static constexpr std::size_t maxCandidateLength = 256;

    bool active() const { return active_; }
    const std::string &candidate() const { return candidate_; }

    void reset() {
        active_ = false;
        candidate_.clear();
    }

    void backspace() {
        if (!active_) {
            return;
        }
        if (candidate_.empty()) {
            reset();
        } else {
            candidate_.pop_back();
        }
    }

    bool type(char prefix, char character) {
        if (!active_) {
            if (character == prefix) {
                active_ = true;
                candidate_.clear();
            }
            return false;
        }

        if (character == prefix) {
            candidate_.clear();
            return false;
        }

        if (std::isspace(static_cast<unsigned char>(character)) ||
            candidate_.size() >= maxCandidateLength) {
            reset();
            return false;
        }

        candidate_.push_back(character);
        return true;
    }

private:
    bool active_ = false;
    std::string candidate_;
};

} // namespace omaspansion
