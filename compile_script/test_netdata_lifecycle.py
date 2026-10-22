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
#define _GNU_SOURCE
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>
#include <errno.h>
#include <stdarg.h>
#include <syslog.h>
#include <unistd.h>
#define unlikely(x) (x)
#define likely(x) (x)
#define __maybe_unused __attribute__((unused))
#define internal_error(...) ((void)0)
static void mock_log(const char *fmt,...) { (void)fmt; }
#define info(...) mock_log(__VA_ARGS__)
#define error(...) mock_log(__VA_ARGS__)
#define worker_unregister() ((void)0)
#define METADATA_CMD_Q_MAX_SIZE 2
#define METADATA_FLAG_SHUTDOWN 1
#define METADATA_FLAG_SCANNING_HOSTS 2
#define UV_EBUSY -16
#define UV_ECANCELED -125
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
struct metadata_cmd { enum metadata_opcode opcode; const void *param[2]; struct completion *completion; int *result; };
struct metadata_wc {
 struct { unsigned head,tail; struct metadata_cmd cmd_array[2]; } cmd_queue;
 unsigned queue_size, flags; uv_mutex_t cmd_mutex; uv_cond_t cmd_cond; uv_async_t async;
 uv_handle_t timer_req; uv_loop_t *loop; struct completion init_complete;
 int startup_result,shutdown_result,thread;
};
struct scan_metadata_payload { uv_work_t request; struct metadata_wc *wc; struct completion *completion; int max_count; int *result; };
static struct metadata_wc metasync_worker;
static int metadata_queue_ready;
static int metadata_thread_joined;
static int init_failure_stage;
static uv_mutex_t metadata_async_lock;
static int sends, broadcasts, waits, releases, runs, closes, fail_work, fatal_count;
static int close_values[1030], close_length, close_index;
static int lifecycle_mode, pending_closes, persistent_busy, close_error;
static struct metadata_wc *wait_worker;
static uv_work_t *pending_work;
static void (*pending_after)(uv_work_t *,int);
static jmp_buf self_wait_env,exit_env;
static int role,joins,cleanup_calls,self_waits,exit_code,sql_closes,context_closes,openssl_frees,finalizes,incomplete_unlinks;
enum { MAIN_ROLE, WORKER_ROLE };
static void fatal_int(const char *,const char *,unsigned long,const char *,...);
#define fatal_assert(x) do { if (!(x)) fatal_int(__FILE__,__func__,__LINE__,"assertion: " #x); } while (0)
static const char *uv_strerror(int rc) { (void)rc; return "mock UV error"; }
static int uv_thread_join(int *thread) { (void)thread; assert(role==MAIN_ROLE); ++joins; return 0; }
static int uv_mutex_init(uv_mutex_t *m) { m->held=0; return 0; }
static int uv_cond_init(uv_cond_t *c) { *c=0; return 0; }
static int uv_thread_create(int *,void (*)(void *),void *);
#define fatal(...) fatal_int(__FILE__,__func__,__LINE__,__VA_ARGS__)
static void completion_init(struct completion *c) { c->completed=0; }
static void completion_destroy(struct completion *c) { (void)c; }
static void completion_wait_for(struct completion *c);
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

CHAIN_STUBS = r'''
typedef unsigned long long usec_t;
#define USEC_PER_MS 1000
#define USEC_PER_SEC 1000000
#define ENABLE_HTTPS 1
#define SERVICE_MAINTENANCE 1
#define ABILITY_DATA_QUERIES 2
#define ABILITY_WEB_REQUESTS 4
#define ABILITY_STREAMING_CONNECTIONS 8
#define SERVICE_ACLK 16
#define SERVICE_REPLICATION 32
#define SERVICE_EXPORTERS 64
#define SERVICE_ML_TRAINING 128
#define SERVICE_HEALTH 256
#define SERVICE_WEB_SERVER 512
#define SERVICE_COLLECTORS 1024
#define SERVICE_STREAMING 2048
#define SERVICE_ML_PREDICTION 4096
#define SERVICE_CONTEXT 8192
static const char *netdata_configured_varlib_dir="/mock";
static char pidfile[1];
static usec_t now_monotonic_usec(void) { return 1; }
static long now_realtime_sec(void) { return 0; }
static void send_statistics(const char *a,const char *b,const char *c) { (void)a;(void)b;(void)c; }
#define error_log_limit_unlimited() ((void)0)
#define delta_shutdown_time(s) do { (void)(s); (void)last_ut; (void)prev_msg; (void)timeout; } while(0)
#define snprintfz snprintf
#define rename(a,b) ((void)(a),(void)(b),0)
static int mock_unlink(const char *p) { if(strstr(p,".agent_incomplete_shutdown")) ++incomplete_unlinks; return 0; }
#define unlink mock_unlink
static void service_signal_exit(int flags) { (void)flags; }
static bool service_wait_exit(int flags,usec_t time) { (void)flags;(void)time; return true; }
static void rrdhost_cleanup_all(void) {}
static void cancel_main_threads(void) {}
static void rrd_finalize_collection_for_all_hosts(void) { ++finalizes; }
static void sql_close_context_database(void) { assert(joins==1); ++context_closes; }
static void sql_close_database(void) { assert(joins==1); ++sql_closes; }
static void security_clean_openssl(void) { ++openssl_frees; }
static void mock_exit(int code) { exit_code=code; longjmp(exit_env,1); }
#define exit mock_exit
#define LOG_DATE_LENGTH 26
#define NETDATA_THREAD_NAME_MAX 32
#define THREAD_TAG_STREAM_RECEIVER "RECEIVER"
#define THREAD_TAG_STREAM_SENDER "SENDER"
static FILE *stderror;
static int collector_log_syslog;
static const char *program_name="source-mock";
static const char *netdata_thread_tag(void) { return role==WORKER_ROLE ? "METASYNC" : "MAIN"; }
static bool netdata_thread_tag_exists(void) { return true; }
static void os_thread_get_current_name_np(char *out) { *out=0; }
static void log_date(char *out,size_t len,long now) { (void)now; snprintf(out,len,"MOCK"); }
static void log_lock(void) {}
static void log_unlock(void) {}
'''

DISPATCH = r'''
static void completion_wait_for(struct completion *c) {
 if(c->completed) return;
 assert(!metasync_worker.cmd_mutex.held);
 assert(metadata_async_lock.held);
 if(role==WORKER_ROLE) { ++self_waits; longjmp(self_wait_env,1); }
 role=WORKER_ROLE;
 if(c==&metasync_worker.init_complete) {
   struct metadata_cmd cmd=metadata_deq_cmd(&metasync_worker);
   assert(cmd.opcode==METADATA_DATABASE_NOOP);
   teardown(&metasync_worker,metasync_worker.loop);
 } else {
   struct metadata_cmd cmd=metadata_deq_cmd(&metasync_worker);
   assert(cmd.opcode==METADATA_SCAN_HOSTS);
   process_scan(&metasync_worker,metasync_worker.loop,cmd);
   if(pending_work) { pending_after(pending_work,0); pending_work=NULL; }
 }
 role=MAIN_ROLE;
 assert(c->completed==1);
}
'''

TESTS = r'''
static void reset(struct metadata_wc *w) {
 memset(w,0,sizeof(*w)); wait_worker=w; sends=broadcasts=waits=releases=runs=closes=0;
 close_index=0; close_length=1; close_values[0]=0; fail_work=0; pending_work=NULL;
 lifecycle_mode=pending_closes=persistent_busy=close_error=0;
 metadata_async_lock.held=0; metadata_thread_joined=0; role=MAIN_ROLE;
 joins=cleanup_calls=self_waits=exit_code=sql_closes=context_closes=openssl_frees=finalizes=incomplete_unlinks=fatal_count=0;
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
 teardown(&w,w.loop);
 assert(!releases && w.init_complete.completed==1 && w.shutdown_result==UV_EBUSY && w.loop && !fatal_count); free(w.loop);
 reset(&w); lifecycle_mode=1; close_error=-22; w.loop=mallocz(sizeof(loop));
 teardown(&w,w.loop);
 assert(!releases && w.init_complete.completed==1 && w.shutdown_result==-22 && w.loop && !fatal_count); free(w.loop);

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
 static int scan_result; final.result=&scan_result;
 process_scan(&w,&loop,final);
 assert(completion.completed==1 && scan_result==-1 && !fatal_count && releases==1 && !(w.flags & METADATA_FLAG_SCANNING_HOSTS));
 reset(&w); completion.completed=0; scan_result=0;
 process_scan(&w,&loop,final); assert(!completion.completed && pending_work);
 pending_after(pending_work,UV_ECANCELED);
 assert(completion.completed==1 && scan_result==UV_ECANCELED && releases==1);
 /* Normal periodic scan failure does not own a caller completion. */
 reset(&w); fail_work=1; final.completion=NULL; process_scan(&w,&loop,final);
 assert(releases==1 && !(w.flags & METADATA_FLAG_SCANNING_HOSTS));

 reset(&metasync_worker); metadata_queue_ready=0;
 queue_metadata_cmd(METADATA_STORE_CLAIM_ID,mallocz(1),mallocz(1)); assert(releases==2 && !sends);
 metadata_queue_ready=1; metasync_worker.flags=METADATA_FLAG_SHUTDOWN; metasync_worker.async.closed=1;
 queue_metadata_cmd(METADATA_STORE_CLAIM_ID,mallocz(1),mallocz(1)); assert(releases==4 && !sends);
 queue_metadata_cmd(METADATA_DEL_DIMENSION,mallocz(1),NULL); assert(releases==5 && !sends);

 /* Run the actual daemon cleanup body through actual metadata APIs. */
 reset(&metasync_worker); metadata_queue_ready=1; lifecycle_mode=1;
 metasync_worker.loop=mallocz(sizeof(loop)); fail_work=1;
 if(!setjmp(exit_env)) netdata_cleanup_and_exit(0);
 assert(exit_code==1 && finalizes==1 && joins==1 && sql_closes==1 && context_closes==1);
 assert(openssl_frees==1 && incomplete_unlinks==1 && !fatal_count && !self_waits && cleanup_calls==1);
 reset(&metasync_worker); metadata_queue_ready=1; lifecycle_mode=1;
 metasync_worker.loop=mallocz(sizeof(loop));
 if(!setjmp(exit_env)) netdata_cleanup_and_exit(0);
 assert(exit_code==0 && finalizes==1 && joins==1 && sql_closes==1 && !fatal_count);
 assert(metadata_sync_shutdown()==0 && joins==1);
 static int sends_before; sends_before=sends;
 assert(metadata_sync_shutdown_prepare()==UV_ECANCELED && sends==sends_before && !self_waits);
 reset(&metasync_worker); metadata_queue_ready=1; lifecycle_mode=1;
 metasync_worker.loop=mallocz(sizeof(loop));
 if(!setjmp(exit_env)) netdata_cleanup_and_exit(1);
 assert(exit_code==1 && finalizes==0 && joins==1 && sql_closes==1 && !fatal_count);
 reset(&metasync_worker); metadata_queue_ready=1; lifecycle_mode=1; persistent_busy=1;
 metasync_worker.loop=mallocz(sizeof(loop));
 if(!setjmp(exit_env)) netdata_cleanup_and_exit(0);
 assert(exit_code==1 && joins==1 && !sql_closes && !context_closes && !openssl_frees && !incomplete_unlinks);
 assert(metasync_worker.loop && !fatal_count && !self_waits && cleanup_calls==1); free(metasync_worker.loop);

 /* Negative control executes actual fatal_int -> actual cleanup. Detect its
  * self-wait instead of hanging or manufacturing a real process crash. */
 reset(&metasync_worker); metadata_queue_ready=1; lifecycle_mode=1; role=WORKER_ROLE;
 metasync_worker.loop=mallocz(sizeof(loop));
 if(!setjmp(self_wait_env)) { fatal_int(__FILE__,__func__,__LINE__,"expected negative control"); assert(0); }
 assert(fatal_count==1 && cleanup_calls==1 && self_waits==1 && !sql_closes); free(metasync_worker.loop);
 /* Actual startup caller joins the failed worker before entering fatal cleanup.
  * All three worker init error labels execute without worker-side fatal. */
 for(init_failure_stage=1;init_failure_stage<=3;++init_failure_stage) {
   reset(&metasync_worker); metadata_queue_ready=0; lifecycle_mode=1;
   if(!setjmp(exit_env)) metadata_sync_init();
   assert(exit_code==1 && joins==1 && cleanup_calls==1 && fatal_count==1 && !self_waits);
   assert(metasync_worker.startup_result==-12 && !metadata_queue_ready && sql_closes==1);
 }
 puts("PASS: actual source lifecycle, startup, fatal/cleanup negative control and error propagation cases");
 return 0;
}
'''


def harness(source, main_source, log_source):
    functions = '\n\n'.join(function(source, name) for name in (
        'metadata_init_cmd_queue', 'metadata_enq_cmd_noblock', 'metadata_enq_cmd', 'metadata_close_loop', 'metadata_deq_cmd',
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
    assert cleanup.index('wc->shutdown_result = metadata_close_loop(loop)') < cleanup.index('if (wc->shutdown_result == 0)') < cleanup.index('freez(loop)') < cleanup.index('completion_mark_complete')
    assert 'uv_cond_destroy' not in event
    assert '__atomic_store_n(&metadata_queue_ready, 1, __ATOMIC_RELEASE)' in event
    assert 'fatal(' not in event[event.index('error_after_timer_init:'):]
    import re
    assert not re.search(r'\bstruct metadata_cmd cmd;',source)
    init_errors=event[event.index('error_after_timer_init:'):event.rfind('}')]
    init_worker='''static void metadata_event_loop(void *arg) {
    struct metadata_wc *wc=arg;
    int ret=-12;
    uv_loop_t *loop=wc->loop=mallocz(sizeof(uv_loop_t));
    if(init_failure_stage==1) goto error_after_timer_init;
    if(init_failure_stage==2) goto error_after_async_init;
    goto error_after_loop_init;
    '''+init_errors+'\n}\n'
    create='''static int uv_thread_create(int *thread,void (*start)(void *),void *arg) {
    (void)thread; role=WORKER_ROLE; start(arg); role=MAIN_ROLE; return 0;
    }\n'''
    init=function(source,'metadata_sync_init')
    api='\n'.join(function(source,name) for name in ('metadata_sync_shutdown_prepare','metadata_sync_shutdown'))
    main=function(main_source,'netdata_cleanup_and_exit').replace('{', '{\n    ++cleanup_calls;',1)
    fatal=function(log_source,'fatal_int').replace('void fatal_int','static void fatal_int',1).replace('{','{\n    ++fatal_count;',1)
    return STUBS + CHAIN_STUBS + functions + scan_function + '\nstatic void teardown(struct metadata_wc *wc, uv_loop_t *loop) {\n' + cleanup + '\n}\n' + DISPATCH + api + main + fatal + init_worker + create + init + TESTS


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--emit', type=Path, help='Only emit source for a separately selected compiler')
    parser.add_argument('--main-source', type=Path)
    parser.add_argument('--log-source', type=Path)
    args = parser.parse_args()
    tree=args.source.resolve().parents[2]
    main_source=args.main_source or tree/'daemon/main.c'
    log_source=args.log_source or tree/'libnetdata/log/log.c'
    code = harness(args.source.read_text(encoding='utf8'),main_source.read_text(encoding='utf8'),log_source.read_text(encoding='utf8'))
    if args.emit:
        args.emit.write_text(code, encoding='utf8', newline='\n')
    else:
        with tempfile.TemporaryDirectory(prefix='netdata-source-mock-') as directory:
            unit = Path(directory) / 'lifecycle.c'
            binary = Path(directory) / 'lifecycle'
            unit.write_text(code, encoding='utf8')
            subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', str(unit), '-o', str(binary)], check=True)
            subprocess.run([str(binary)], check=True)
