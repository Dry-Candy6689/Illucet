#include "IllucetAria2.h"
#include <aria2/aria2.h>
#include <mutex>
#include <sstream>

struct IllucetAria2Session { aria2::Session *session; };

IllucetAria2Session *illucet_aria2_create(const char *caCertificate) {
    static std::once_flag once;
    static int initialized = -1;
    try {
        if (!caCertificate) return nullptr;
        std::call_once(once, [] { initialized = aria2::libraryInit(); });
        if (initialized != 0) return nullptr;
        aria2::SessionConfig config;
        config.keepRunning = true;
        config.useSignalHandler = false;
        aria2::KeyVals options = {
            {"no-conf", "true"},
            {"quiet", "true"}, {"show-console-readout", "false"},
            {"summary-interval", "0"}, {"download-result", "hide"},
            {"enable-rpc", "false"}, {"no-netrc", "true"},
            {"auto-save-interval", "0"}, {"force-save", "false"},
            {"max-download-result", "1024"}, {"max-concurrent-downloads", "128"},
            {"check-certificate", "true"}, {"max-tries", "1"},
            {"connect-timeout", "15"}, {"timeout", "30"}
        };
        options.emplace_back("ca-certificate", caCertificate);
        auto session = aria2::sessionNew(options, config);
        return session ? new IllucetAria2Session{session} : nullptr;
    } catch (...) { return nullptr; }
}

int32_t illucet_aria2_add(IllucetAria2Session *owner, const char *url,
                        const char *directory, const char *headers,
                        int64_t speedLimit, uint64_t *identifier) {
    if (!owner || !url || !directory || !headers || !identifier) return -1;
    try {
        aria2::KeyVals options = {
            {"dir", directory}, {"out", "payload"}, {"file-allocation", "none"},
            {"auto-file-renaming", "false"}, {"allow-overwrite", "false"},
            {"continue", "false"}, {"remove-control-file", "true"},
            {"split", "4"}, {"max-connection-per-server", "4"}, {"min-split-size", "1M"},
            {"max-download-limit", std::to_string(speedLimit > 0 ? speedLimit : 0)}
        };
        std::istringstream input(headers);
        std::string line;
        while (std::getline(input, line)) if (!line.empty()) options.emplace_back("header", line);
        return aria2::addUri(owner->session, identifier, {url}, options);
    } catch (...) { return -1; }
}

int32_t illucet_aria2_poll(IllucetAria2Session *owner) {
    if (!owner) return -1;
    try { return aria2::run(owner->session, aria2::RUN_ONCE); }
    catch (...) { return -1; }
}

IllucetAria2Snapshot illucet_aria2_snapshot(IllucetAria2Session *owner, uint64_t identifier) {
    IllucetAria2Snapshot value{2, -1, 0, 0};
    if (!owner) return value;
    try {
        auto handle = aria2::getDownloadHandle(owner->session, identifier);
        if (!handle) return value;
        auto status = handle->getStatus();
        value.state = status == aria2::DOWNLOAD_COMPLETE ? 1
            : status == aria2::DOWNLOAD_ERROR ? 2 : status == aria2::DOWNLOAD_REMOVED ? 3 : 0;
        value.errorCode = handle->getErrorCode();
        value.completedBytes = handle->getCompletedLength();
        value.totalBytes = handle->getTotalLength();
        aria2::deleteDownloadHandle(handle);
    } catch (...) { }
    return value;
}

void illucet_aria2_cancel(IllucetAria2Session *owner, uint64_t identifier) {
    if (!owner) return;
    try { aria2::removeDownload(owner->session, identifier, true); } catch (...) { }
}

void illucet_aria2_close(IllucetAria2Session *owner) {
    if (!owner) return;
    try {
        aria2::shutdown(owner->session, true);
        while (aria2::run(owner->session, aria2::RUN_ONCE) > 0) { }
        aria2::sessionFinal(owner->session);
    } catch (...) { }
    delete owner;
}

const char *illucet_aria2_version(void) { return "1.37.0"; }
