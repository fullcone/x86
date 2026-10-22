#!/usr/bin/env python3
"""Compile actual patched source fragments against deterministic libuv stubs.

Usage: python3 test_netdata_lifecycle.py path/to/patched/sqlite_metadata.c
No Netdata binary, firmware, libuv runtime, debugger or crash reproduction runs.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile


def function(source, name):
    # Functions selected below contain no braces in string literals/comments.
    start = source.index(name + '(')
    start = source.rfind('\n', 0, start) + 1
    body = source.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


STUBS = r'''
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#define unlikely(x) (x)
#define likely(x) (x)
#define __maybe_unused __attribute__((unused))
#define internal_error(...) ((void)0)
#define info(...) ((void)0)
#define worker_unregister() ((void)0)
#define METADATA_CMD_Q_MAX_SIZE 2
#define METADATA_FLAG_SHUTDOWN 1
#define METADATA_FLAG_SCANNING_HOSTS 2
#define UV_EBUSY -16
#define UV_RUN_NOWAIT 2
#define UV_RUN_DEFAULT 0
enum metadata_opcode { METADATA_DATABASE_NOOP, METADATA_SYNC_SHUTDOWN,
 METADATA_SCAN_HOSTS, METADATA_DEL_DIMENSION, METADATA_STORE_CLAIM_ID,
 METADATA_ADD_HOST_INFO };
typedef struct { int held; } uv_mutex_t;
typedef int uv_cond_t;
typedef struct { int unused; } uv_loop_t;
typedef struct { int closed; } uv_handle_t;
typedef uv_handle_t uv_async_t;
typedef struct { void *data; } uv_work_t;
struct completion { int completed; };
struct metadata_cmd { enum metadata_opcode opcode; const void *param[2]; struct completion *completion; };
struct metadata_wc {
 struct { unsigned head,tail; struct metadata_cmd cmd_array[2]; } cmd_queue;
 unsigned queue_size, flags; uv_mutex_t cmd_mutex; uv_cond_t cmd_cond; uv_async_t async;
 uv_handle_t timer_req; uv_loop_t *loop; struct completion init_complete;
};
struct scan_metadata_payload { uv_work_t request; struct metadata_wc *wc; struct completion *completion; int max_count; };
static struct metadata_wc metasync_worker;
static int metadata_queue_ready;
static int sends, broadcasts, waits, releases, runs, closes, fail_work, fatal_count;
static int close_values[1030], close_length, close_index;
static int lifecycle_mode, pending_closes, persistent_busy, close_error;
static struct metadata_wc *wait_worker;
static uv_work_t *pending_work;
static void (*pending_after)(uv_work_t *,int);
static jmp_buf fatal_env;
#define fatal_assert(x) do { if (!(x)) { ++fatal_count; longjmp(fatal_env, 1); } } while (0)
#define metadata_flag_check(w,f) ((w)->flags & (f))
#define metadata_flag_set(w,f) ((w)->flags |= (f))
#define metadata_flag_clear(w,f) ((w)->flags &= ~(f))
static void uv_mutex_lock(uv_mutex_t *m) { assert(!m->held); m->held=1; }
static void uv_mutex_unlock(uv_mutex_t *m) { assert(m->held); m->held=0; }
static void uv_cond_broadcast(uv_cond_t *c) { (void)c; ++broadcasts; }
static void uv_cond_signal(uv_cond_t *c) { (void)c; }
static void uv_cond_wait(uv_cond_t *c,uv_mutex_t *m) {
 (void)c; assert(m->held); ++waits;
 /* Deterministic interleaving: shutdown and dequeue happen while asleep. */
 assert(wait_worker); wait_worker->flags |= METADATA_FLAG_SHUTDOWN;
 wait_worker->queue_size=0;
}
static int uv_async_send(uv_async_t *a) {
 assert(!a->closed); assert(wait_worker->cmd_mutex.held); ++sends; return 0;
}
static int uv_loop_close(uv_loop_t *l) {
 (void)l; ++closes;
 if(lifecycle_mode) return close_error ? close_error : (pending_closes || persistent_busy ? UV_EBUSY : 0);
 assert(close_length); return close_values[close_index < close_length ? close_index++ : close_length-1];
}
static int uv_run(uv_loop_t *l,int mode) { (void)l; assert(mode==UV_RUN_NOWAIT); ++runs; pending_closes=0; return 0; }
static void uv_close(uv_handle_t *h,void *cb) {
 (void)cb; assert(!h->closed); assert(wait_worker->cmd_mutex.held);
 assert(wait_worker->flags & METADATA_FLAG_SHUTDOWN); h->closed=1; ++pending_closes;
}
static int uv_timer_stop(uv_handle_t *h) { (void)h; return 0; }
static void completion_mark_complete(struct completion *c) { assert(!c->completed); ++c->completed; }
static void *mallocz(size_t n) { return calloc(1,n); }
static void mock_free(void *p) { if(p) { ++releases; free(p); } }
#define freez(x) mock_free((void *)(x))
static void start_metadata_hosts(uv_work_t *r) { (void)r; }
static int uv_queue_work(uv_loop_t *l,uv_work_t *r,void (*work)(uv_work_t *),void (*after)(uv_work_t *,int)) {
 (void)l; (void)work; if(fail_work) return -1; pending_work=r; pending_after=after; return 0;
}
static int unittest_running;
'''

TESTS = r'''
static void reset(struct metadata_wc *w) {
 memset(w,0,sizeof(*w)); wait_worker=w; sends=broadcasts=waits=releases=runs=closes=0;
 close_index=0; close_length=1; close_values[0]=0; fail_work=0; pending_work=NULL;
 lifecycle_mode=pending_closes=persistent_busy=close_error=0;
}
int main(void) {
 static struct metadata_wc w; struct metadata_cmd cmd={.opcode=METADATA_ADD_HOST_INFO}; uv_loop_t loop;
 reset(&w); assert(metadata_close_loop(&loop)==0); assert(closes==1 && runs==0);
 reset(&w); close_length=2; close_values[0]=UV_EBUSY; close_values[1]=0;
 assert(metadata_close_loop(&loop)==0); assert(closes==2 && runs==1 && releases==0);
 reset(&w); close_values[0]=UV_EBUSY;
 assert(metadata_close_loop(&loop)==UV_EBUSY); assert(closes==1024 && runs==1024 && releases==0);
 reset(&w); close_values[0]=-22;
 assert(metadata_close_loop(&loop)==-22); assert(closes==1 && runs==0 && releases==0);

 reset(&w); lifecycle_mode=1; w.loop=mallocz(sizeof(loop));
 teardown(&w,w.loop); assert(closes==2 && runs==1 && releases==1);
 assert(w.loop==NULL && w.init_complete.completed==1 && w.async.closed && w.timer_req.closed);
 reset(&w); lifecycle_mode=1; persistent_busy=1; w.loop=mallocz(sizeof(loop));
 if(!setjmp(fatal_env)) { teardown(&w,w.loop); assert(0); }
 assert(!releases && !w.init_complete.completed && w.loop); free(w.loop);
 reset(&w); lifecycle_mode=1; close_error=-22; w.loop=mallocz(sizeof(loop));
 if(!setjmp(fatal_env)) { teardown(&w,w.loop); assert(0); }
 assert(!releases && !w.init_complete.completed && w.loop); free(w.loop);

 reset(&w); assert(!metadata_enq_cmd(&w,&cmd)); assert(sends==1 && w.queue_size==1);
 cmd.opcode=METADATA_SYNC_SHUTDOWN; assert(!metadata_enq_cmd(&w,&cmd)); assert(sends==2 && broadcasts==1);
 w.async.closed=1; cmd.opcode=METADATA_ADD_HOST_INFO;
 assert(metadata_enq_cmd(&w,&cmd)==1); assert(sends==2 && w.queue_size==1);
 /* Full queue wakes to both a newly free slot and SHUTDOWN: must reject. */
 reset(&w); w.queue_size=METADATA_CMD_Q_MAX_SIZE;
 assert(metadata_enq_cmd(&w,&cmd)==1); assert(waits==1 && !sends && !w.queue_size);
 reset(&w); cmd.opcode=METADATA_SYNC_SHUTDOWN;
 assert(!metadata_enq_cmd_noblock(&w,&cmd)); assert(broadcasts==1 && !sends);
 cmd.opcode=METADATA_ADD_HOST_INFO; assert(metadata_enq_cmd_noblock(&w,&cmd)==1 && !w.queue_size);
 reset(&w); w.queue_size=METADATA_CMD_Q_MAX_SIZE;
 assert(metadata_enq_cmd_noblock(&w,&cmd)==1 && w.queue_size==METADATA_CMD_Q_MAX_SIZE);

 reset(&w); static struct completion completion; cmd.opcode=METADATA_SCAN_HOSTS; cmd.completion=&completion;
 assert(!metadata_enq_cmd(&w,&cmd)); w.flags|=METADATA_FLAG_SCANNING_HOSTS;
 assert(metadata_deq_cmd(&w).opcode==METADATA_DATABASE_NOOP); assert(w.queue_size==1 && !completion.completed);
 w.flags &= ~METADATA_FLAG_SCANNING_HOSTS;
 struct metadata_cmd final=metadata_deq_cmd(&w); assert(final.opcode==METADATA_SCAN_HOSTS && !w.queue_size);
 process_scan(&w,&loop,final); assert(pending_work && !completion.completed);
 assert(w.flags & METADATA_FLAG_SCANNING_HOSTS); pending_after(pending_work,0);
 assert(completion.completed==1 && releases==1 && !(w.flags & METADATA_FLAG_SCANNING_HOSTS));

 reset(&w); completion.completed=0; fail_work=1;
 if (!setjmp(fatal_env)) { process_scan(&w,&loop,final); assert(0 && "unexecuted final scan must fail"); }
 assert(!completion.completed && releases==1 && !(w.flags & METADATA_FLAG_SCANNING_HOSTS));
 /* Normal periodic scan failure does not own a caller completion. */
 reset(&w); fail_work=1; final.completion=NULL; process_scan(&w,&loop,final);
 assert(releases==1 && !(w.flags & METADATA_FLAG_SCANNING_HOSTS));

 reset(&metasync_worker); metadata_queue_ready=0;
 queue_metadata_cmd(METADATA_STORE_CLAIM_ID,mallocz(1),mallocz(1)); assert(releases==2 && !sends);
 metadata_queue_ready=1; metasync_worker.flags=METADATA_FLAG_SHUTDOWN; metasync_worker.async.closed=1;
 queue_metadata_cmd(METADATA_STORE_CLAIM_ID,mallocz(1),mallocz(1)); assert(releases==4 && !sends);
 queue_metadata_cmd(METADATA_DEL_DIMENSION,mallocz(1),NULL); assert(releases==5 && !sends);
 puts("PASS: actual source queue, callback, final-scan and loop-close regression cases");
 return 0;
}
'''


def harness(source):
    functions = '\n\n'.join(function(source, name) for name in (
        'metadata_enq_cmd_noblock', 'metadata_enq_cmd', 'metadata_close_loop', 'metadata_deq_cmd',
        'after_metadata_hosts', 'queue_metadata_cmd'))
    scan = source.split('                case METADATA_SCAN_HOSTS:', 1)[1].split('                case METADATA_MAINTENANCE:', 1)[0]
    scan_function = '''static void process_scan(struct metadata_wc *wc, uv_loop_t *loop, struct metadata_cmd cmd) {
    switch (METADATA_SCAN_HOSTS) { case METADATA_SCAN_HOSTS:
    ''' + scan + ''' }
    if (cmd.completion) completion_mark_complete(cmd.completion);
}
'''
    # Check full-source teardown ordering, not a hand-copied implementation.
    event = function(source, 'metadata_event_loop')
    cleanup = event[event.index('    uv_mutex_lock(&wc->cmd_mutex);'):event.index('error_after_timer_init:')]
    assert cleanup.index('uv_mutex_lock') < cleanup.index('METADATA_FLAG_SHUTDOWN') < cleanup.index('uv_close') < cleanup.index('uv_mutex_unlock')
    assert cleanup.index('fatal_assert(0 == metadata_close_loop(loop))') < cleanup.index('freez(loop)') < cleanup.index('completion_mark_complete')
    assert 'uv_cond_destroy' not in event
    assert '__atomic_store_n(&metadata_queue_ready, 1, __ATOMIC_RELEASE)' in event
    return STUBS + functions + scan_function + '\nstatic void teardown(struct metadata_wc *wc, uv_loop_t *loop) {\n' + cleanup + '\n}\n' + TESTS


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--emit', type=Path, help='Only emit source for a separately selected compiler')
    args = parser.parse_args()
    code = harness(args.source.read_text(encoding='utf8'))
    if args.emit:
        args.emit.write_text(code, encoding='utf8', newline='\n')
    else:
        with tempfile.TemporaryDirectory(prefix='netdata-source-mock-') as directory:
            unit = Path(directory) / 'lifecycle.c'
            binary = Path(directory) / 'lifecycle'
            unit.write_text(code, encoding='utf8')
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(unit), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
