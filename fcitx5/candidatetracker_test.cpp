#include "candidatetracker.h"

#include <cassert>
#include <string>

using omaspansion::CandidateTracker;

void type(CandidateTracker &tracker, const std::string &value) {
    for (const char character : value) {
        tracker.type(';', character);
    }
}

int main() {
    CandidateTracker tracker;

    type(tracker, ";1cutkye");
    assert(tracker.active());
    assert(tracker.candidate() == "1cutkye");
    tracker.backspace();
    tracker.backspace();
    type(tracker, "ey");
    assert(tracker.candidate() == "1cutkey");

    tracker.reset();
    type(tracker, ";almost-wrong,");
    tracker.backspace();
    assert(tracker.candidate() == "almost-wrong");

    tracker.type(';', ' ');
    assert(!tracker.active());
    assert(tracker.candidate().empty());

    type(tracker, ";first;second");
    assert(tracker.active());
    assert(tracker.candidate() == "second");

    tracker.reset();
    type(tracker, ";");
    tracker.backspace();
    assert(!tracker.active());
}
