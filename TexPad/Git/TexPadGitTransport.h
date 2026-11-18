// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors
//
// Glue that lets libgit2 speak "https://" through Swift (URLSession) instead of an in-library TLS stack.
// libgit2 is built without HTTPS/SSH; every smart-HTTP request goes through these callbacks.

#ifndef TEXPAD_GIT_TRANSPORT_H
#define TEXPAD_GIT_TRANSPORT_H

#include <stddef.h>

typedef struct texpad_http_ops {
    void *ctx;
    /// Starts one smart-protocol request. `service` is git_smart_service_t (1 upload-pack ls, 2 upload-pack,
    /// 3 receive-pack ls, 4 receive-pack). Returns an opaque stream handle, or NULL on failure.
    void *(*open)(void *ctx, const char *url, int service);
    /// Appends request-body bytes. Returns 0 on success.
    int (*write)(void *stream, const char *buf, size_t len);
    /// Blocks until response bytes are available. 0 on success (`*bytes_read` == 0 means end of response), < 0 on error.
    int (*read)(void *stream, char *buf, size_t size, size_t *bytes_read);
    /// Message for the last failure on this stream (valid until close).
    const char *(*last_error)(void *stream);
    /// Releases the stream.
    void (*close)(void *stream);
} texpad_http_ops;

/// Installs the callbacks and registers them as libgit2's transport for "https://" URLs. Returns 0 on success.
int texpad_git_register_https(const texpad_http_ops *ops);

/// Initialises libgit2 once and applies TexPad's safety options (variadic libgit2 calls can't be made from Swift).
int texpad_git_init(void);

#endif
