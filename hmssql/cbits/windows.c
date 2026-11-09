/* The calls that block, for the non-threaded runtime on Windows.
 *
 * Without -threaded a safe foreign call stops every Haskell thread, so
 * hmssql runs these through GHC's asyncDoProc instead: each is a function
 * of one pointer, run on a worker thread of the default I/O manager while
 * the scheduler goes on (Hmssql.Connection.Backend.Windows, "On a worker").
 * An exception to the Haskell thread only abandons the request, and the
 * function runs on, so every request owns what the function uses and
 * signals its own event, `done`, as the last thing the function does with
 * it.  Nothing here is used with the threaded runtime.
 *
 * Each request starts with that event, so that one function,
 * hmssql_await_done, waits for any of them. */

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include "HsFFI.h"

static HANDLE new_event(void)
{
    /* Manual-reset, not signaled. */
    return CreateEventW(NULL, TRUE, FALSE, NULL);
}

/* Wait for the request's `done` event.  The first field of every request. */
HsInt hmssql_await_done(void *request)
{
    return (HsInt)WaitForSingleObject(*(HANDLE *)request, INFINITE);
}

/* ------------------------------------------------------------------------
 * The wait for a pending overlapped operation.
 *
 * The operation is started by the Haskell thread; this waits for its event,
 * or for `cancel`, and on `cancel` cancels the operation and waits for it
 * to end, since its buffer and OVERLAPPED belong to the caller.  A wait
 * that a worker begins only after the caller was interrupted finds
 * `cancel` set and does the same.  One per direction of a handle, reused:
 * the caller holds that direction's lock until `done`. */

typedef struct {
    HANDLE done;
    HANDLE cancel;
    HANDLE file;
    OVERLAPPED *ov;
    HANDLE event;
} hmssql_wait;

hmssql_wait *hmssql_wait_new(HANDLE file, OVERLAPPED *ov, HANDLE event)
{
    hmssql_wait *w = calloc(1, sizeof *w);
    if (w == NULL) return NULL;
    w->done = new_event();
    w->cancel = new_event();
    if (w->done == NULL || w->cancel == NULL) {
        if (w->done != NULL) CloseHandle(w->done);
        if (w->cancel != NULL) CloseHandle(w->cancel);
        free(w);
        return NULL;
    }
    w->file = file;
    w->ov = ov;
    w->event = event;
    return w;
}

void hmssql_wait_free(hmssql_wait *w)
{
    CloseHandle(w->done);
    CloseHandle(w->cancel);
    free(w);
}

void hmssql_wait_reset(hmssql_wait *w)
{
    ResetEvent(w->done);
    ResetEvent(w->cancel);
}

void hmssql_wait_cancel(hmssql_wait *w)
{
    SetEvent(w->cancel);
}

/* 0 once the operation has ended, or what a wait returned otherwise. */
HsInt hmssql_wait_operation(void *p)
{
    hmssql_wait *w = p;
    HANDLE events[2];
    DWORD r;
    events[0] = w->event;
    events[1] = w->cancel;
    r = WaitForMultipleObjects(2, events, FALSE, INFINITE);
    if (r == WAIT_OBJECT_0 + 1) {
        CancelIoEx(w->file, w->ov);
        r = WaitForSingleObject(w->event, INFINITE);
    }
    SetEvent(w->done);
    return r == WAIT_OBJECT_0 ? 0 : (HsInt)(r == WAIT_FAILED ? GetLastError() : r);
}

/* ------------------------------------------------------------------------
 * A name lookup: getaddrinfo, with copies of its arguments. */

typedef struct {
    HANDLE done;
    char *node;
    char *service;
    struct addrinfo hints;
    struct addrinfo *result;
    int error;
} hmssql_lookup;

hmssql_lookup *hmssql_lookup_new(const char *node, const char *service, const struct addrinfo *hints)
{
    hmssql_lookup *l = calloc(1, sizeof *l);
    if (l == NULL) return NULL;
    l->done = new_event();
    l->node = node ? _strdup(node) : NULL;
    l->service = service ? _strdup(service) : NULL;
    if (l->done == NULL || (node && !l->node) || (service && !l->service)) {
        if (l->done != NULL) CloseHandle(l->done);
        free(l->node);
        free(l->service);
        free(l);
        return NULL;
    }
    l->hints = *hints;
    return l;
}

HsInt hmssql_lookup_run(void *p)
{
    hmssql_lookup *l = p;
    l->error = getaddrinfo(l->node, l->service, &l->hints, &l->result);
    SetEvent(l->done);
    return 0;
}

int hmssql_lookup_error(hmssql_lookup *l) { return l->error; }
struct addrinfo *hmssql_lookup_result(hmssql_lookup *l) { return l->result; }
struct addrinfo *hmssql_addrinfo_next(struct addrinfo *ai) { return ai->ai_next; }

void hmssql_lookup_free(hmssql_lookup *l)
{
    if (l->result != NULL) freeaddrinfo(l->result);
    CloseHandle(l->done);
    free(l->node);
    free(l->service);
    free(l);
}

/* ------------------------------------------------------------------------
 * A connect of a socket the caller made, to a copy of the address. */

typedef struct {
    HANDLE done;
    SOCKET socket;
    int length;
    int error;
    struct sockaddr_storage address;
} hmssql_connect;

hmssql_connect *hmssql_connect_new(SOCKET s, const struct sockaddr *address, int length)
{
    hmssql_connect *c;
    if (length < 0 || length > (int)sizeof c->address) return NULL;
    c = calloc(1, sizeof *c);
    if (c == NULL) return NULL;
    c->done = new_event();
    if (c->done == NULL) { free(c); return NULL; }
    c->socket = s;
    c->length = length;
    memcpy(&c->address, address, length);
    return c;
}

HsInt hmssql_connect_run(void *p)
{
    hmssql_connect *c = p;
    c->error = connect(c->socket, (struct sockaddr *)&c->address, c->length) == 0 ? 0 : WSAGetLastError();
    SetEvent(c->done);
    return 0;
}

int hmssql_connect_error(hmssql_connect *c) { return c->error; }

void hmssql_connect_free(hmssql_connect *c)
{
    CloseHandle(c->done);
    free(c);
}

/* ------------------------------------------------------------------------
 * The open of a named pipe's client end: CreateFileW, which waits for the
 * network when the pipe is on another machine. */

typedef struct {
    HANDLE done;
    wchar_t *path;
    DWORD access;
    DWORD flags;
    HANDLE result;
    DWORD error;
} hmssql_open;

hmssql_open *hmssql_open_new(const wchar_t *path, DWORD access, DWORD flags)
{
    hmssql_open *o = calloc(1, sizeof *o);
    if (o == NULL) return NULL;
    o->done = new_event();
    o->path = _wcsdup(path);
    if (o->done == NULL || o->path == NULL) {
        if (o->done != NULL) CloseHandle(o->done);
        free(o->path);
        free(o);
        return NULL;
    }
    o->access = access;
    o->flags = flags;
    o->result = INVALID_HANDLE_VALUE;
    return o;
}

HsInt hmssql_open_run(void *p)
{
    hmssql_open *o = p;
    o->result = CreateFileW(o->path, o->access, 0, NULL, OPEN_EXISTING, o->flags, NULL);
    o->error = o->result == INVALID_HANDLE_VALUE ? GetLastError() : 0;
    SetEvent(o->done);
    return 0;
}

HANDLE hmssql_open_result(hmssql_open *o) { return o->result; }
DWORD hmssql_open_error(hmssql_open *o) { return o->error; }

/* Free the request, and close the handle it opened unless `keep`. */
void hmssql_open_free(hmssql_open *o, int keep)
{
    if (!keep && o->result != INVALID_HANDLE_VALUE) CloseHandle(o->result);
    CloseHandle(o->done);
    free(o->path);
    free(o);
}
