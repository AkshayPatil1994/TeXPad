// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 TexPad contributors

#include "TexPadGitTransport.h"
#include <git2.h>
#include <git2/sys/errors.h>
#include <git2/sys/transport.h>
#include <stdlib.h>
#include <string.h>

static texpad_http_ops g_ops;

typedef struct {
    git_smart_subtransport_stream base;
    void *handle;
} texpad_stream;

typedef struct {
    git_smart_subtransport base;
} texpad_subtransport;

static int stream_read(git_smart_subtransport_stream *s, char *buffer, size_t buf_size, size_t *bytes_read) {
    texpad_stream *st = (texpad_stream *)s;
    int rc = g_ops.read(st->handle, buffer, buf_size, bytes_read);
    if (rc < 0) {
        const char *m = g_ops.last_error ? g_ops.last_error(st->handle) : NULL;
        git_error_set_str(GIT_ERROR_HTTP, m ? m : "HTTP request failed");
        return -1;
    }
    return 0;
}

static int stream_write(git_smart_subtransport_stream *s, const char *buffer, size_t len) {
    texpad_stream *st = (texpad_stream *)s;
    if (g_ops.write(st->handle, buffer, len) != 0) {
        git_error_set_str(GIT_ERROR_HTTP, "could not buffer request body");
        return -1;
    }
    return 0;
}

static void stream_free(git_smart_subtransport_stream *s) {
    texpad_stream *st = (texpad_stream *)s;
    if (st->handle) g_ops.close(st->handle);
    free(st);
}

static int sub_action(git_smart_subtransport_stream **out, git_smart_subtransport *t, const char *url, git_smart_service_t action) {
    texpad_stream *st = calloc(1, sizeof(texpad_stream));
    if (!st) return -1;
    st->base.subtransport = t;
    st->base.read = stream_read;
    st->base.write = stream_write;
    st->base.free = stream_free;
    st->handle = g_ops.open(g_ops.ctx, url, (int)action);
    if (!st->handle) {
        git_error_set_str(GIT_ERROR_HTTP, "could not start HTTPS request (only https:// URLs are supported)");
        free(st);
        return -1;
    }
    *out = &st->base;
    return 0;
}

static int sub_close(git_smart_subtransport *t) { (void)t; return 0; }
static void sub_free(git_smart_subtransport *t) { free(t); }

static int subtransport_cb(git_smart_subtransport **out, git_transport *owner, void *param) {
    (void)owner; (void)param;
    texpad_subtransport *t = calloc(1, sizeof(texpad_subtransport));
    if (!t) return -1;
    t->base.action = sub_action;
    t->base.close = sub_close;
    t->base.free = sub_free;
    *out = &t->base;
    return 0;
}

static int transport_factory(git_transport **out, git_remote *owner, void *param) {
    (void)param;
    static git_smart_subtransport_definition def = { subtransport_cb, 1 /* stateless RPC, like HTTP */, NULL };
    return git_transport_smart(out, owner, &def);
}

int texpad_git_register_https(const texpad_http_ops *ops) {
    g_ops = *ops;
    return git_transport_register("https", transport_factory, NULL);   /* libgit2 appends "://" itself */
}

int texpad_git_init(void) {
    int rc = git_libgit2_init();
    if (rc < 0) return rc;
    /* The app sandbox's file owner may differ from what git expects; the repository is user-selected anyway. */
    git_libgit2_opts(GIT_OPT_SET_OWNER_VALIDATION, 0);
    /* Verify object hashes while reading (default on, made explicit). */
    git_libgit2_opts(GIT_OPT_ENABLE_STRICT_HASH_VERIFICATION, 1);
    return 0;
}
