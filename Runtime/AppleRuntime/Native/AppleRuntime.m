#import <Foundation/Foundation.h>
#include <signal.h>
#include <setjmp.h>
#include <jni.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <os/proc.h>
#include <TargetConditionals.h>

// Called from the app's plugin worker threads (several at once for searches), never the UI thread.
// Only VM startup needs a lock; each later call attaches its own thread.
static pthread_mutex_t startLock = PTHREAD_MUTEX_INITIALIZER;

// MARK: - 崩溃隔离（JVM 崩了不带走 App）
//
// 内嵌 JVM 是 OpenJDK 的 **Zero** 端口（`--with-jvm-variants=zero`，见 `Scripts/build-apple-jvm.sh`）。
// Zero 没有 `os::Posix::ucontext_get_pc`（`os_cpu/bsd_zero/os_bsd_zero.cpp:91` 直接
// `ShouldNotCall()`），于是它对任何被接管的信号都只能 abort；再加上自举期
// （`System.<clinit>` → `ZeroInterpreter::main_loop` 的空指针）会直接 `os::abort()`，
// 而 `abortHook` 又把 abort 转成真的 `abort()` —— 进程当场消失，用户看到的就是**闪退**。
//
// 能做的不是「不崩」（那是运行库的事，2026-11-16 试过 4 次都没修好），
// 而是**崩了只让这一次请求失败**：把 JVM 的创建/调用整段包在 `sigsetjmp` 里，
// abortHook 不走 `abort()` 而是 `siglongjmp` 回这里，App 继续活着，
// 并把这条源标记为「运行时起不来」，下次不再拿用户的点击去撞它。
//
// ⛔ 隔离只在**插件工作线程**上做（本文件顶部注释已写明调用方从不上主线程）：
// `siglongjmp` 跨线程是未定义行为，所以下面用 TLS 记「本线程有没有装过跳点」。
// ⛔ 跳回去之后 JVM 内部已经是坏状态，**不能再用**；`runtimeBroken` 一旦为真，
//    后续请求一律直接返回错误，不再碰 VM。
static __thread sigjmp_buf *tlsAbortJump = NULL;
static BOOL runtimeBroken = NO;

/// JVM 要 abort 时：有跳点就跳回去（隔离），没有才真的 abort（保持原有崩溃可见性）。
static void abortIsolated(void) {
    if (tlsAbortJump) siglongjmp(*tlsAbortJump, 1);
    abort();
}

/// `SIGABRT` 的兜底：Zero 有些路径绕开 abortHook 直接 raise，也必须被接住。
static void abortSignalHandler(int signo) {
    (void)signo;
    if (tlsAbortJump) siglongjmp(*tlsAbortJump, 2);
    // 没装跳点：还原默认行为，让崩溃照常被系统记录。
    signal(SIGABRT, SIG_DFL);
    raise(SIGABRT);
}
static JavaVM *runtimeVM;
static jclass bootstrap;
static jmethodID requestMethod;
static BOOL failed;
static char *errorResponse(NSDictionary *envelope) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:NULL];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    const char *utf8 = text.UTF8String;
    return utf8 ? strdup(utf8) : NULL;
}
static char *failure(const char *message) { return errorResponse(@{@"error": @(message)}); }
static char *requestFailure(const char *message) { return errorResponse(@{@"error": @(message), @"errorCode": @"embedded_request"}); }
char *TVAppleRuntimeRequest(const char *resourcePath, const char *requestJSON);

// Java strings can hold unpaired UTF-16 surrogates (a plugin cutting text inside an emoji), which
// have no UTF-8 form: strdup(NULL) crashed TestFlight build 29 while returning a search response.
// Replace them with U+FFFD, as the Mac host replaces them with '?', so the rest still shows.
static NSString *stringFromJava(const jchar *characters, jsize length) {
    unichar *copy = malloc(((size_t)length + 1) * sizeof(unichar));
    if (!copy) return nil;
    for (jsize i = 0; i < length; i++) {
        unichar c = characters[i];
        if (CFStringIsSurrogateHighCharacter(c) && i + 1 < length && CFStringIsSurrogateLowCharacter(characters[i + 1])) {
            copy[i] = c; copy[i + 1] = characters[i + 1]; i++;
        } else copy[i] = CFStringIsSurrogateHighCharacter(c) || CFStringIsSurrogateLowCharacter(c) ? 0xFFFD : c;
    }
    return [[NSString alloc] initWithCharactersNoCopy:copy length:(NSUInteger)length freeWhenDone:YES];
}

static char *performRequest(JNIEnv *env, const char *requestJSON) {
    NSString *requestText = requestJSON ? [[NSString alloc] initWithUTF8String:requestJSON] : nil;
    if (!requestText || requestText.length > INT_MAX) return requestFailure("The plugin request contains invalid text.");
    NSUInteger length = requestText.length;
    unichar *characters = malloc((length + 1) * sizeof(unichar));
    if (!characters) return requestFailure("Not enough memory to prepare the plugin request.");
    [requestText getCharacters:characters range:NSMakeRange(0,length)];
    jstring input=(*env)->NewString(env,(const jchar *)characters,(jsize)length);
    free(characters);
    if (!input) {
        if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); }
        return requestFailure("Could not prepare the embedded plugin request. See diagnostic logs.");
    }
    jstring output=(jstring)(*env)->CallStaticObjectMethod(env,bootstrap,requestMethod,input);
    (*env)->DeleteLocalRef(env,input);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env);
        if (output) (*env)->DeleteLocalRef(env,output);
        return requestFailure("The embedded plugin request failed. See diagnostic logs.");
    }
    if (!output) return requestFailure("The plugin returned no response.");
    jsize outputLength=(*env)->GetStringLength(env,output);
    const jchar *outputCharacters=(*env)->GetStringChars(env,output,NULL);
    char *result;
    if (outputCharacters) {
        NSString *text=stringFromJava(outputCharacters,outputLength);
        const char *utf8=text.UTF8String;
        result=utf8 ? strdup(utf8) : requestFailure("Could not convert the plugin response to UTF-8.");
        (*env)->ReleaseStringChars(env,output,outputCharacters);
    } else {
        if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); }
        result=requestFailure("Could not read the embedded plugin response. See diagnostic logs.");
    }
    (*env)->DeleteLocalRef(env,output);
    return result;
}

// The Java heap is sized from what this process may still use, not fixed: iOS kills an app over
// its memory limit, and the limit differs by device. Native code (interpreter, plugins' guard
// libraries, video) needs the rest, so the heap gets about a third, between 384 MB and 1 GB.
static NSString *heapLimit(void) {
    unsigned long long available = 0;
#if (TARGET_OS_IOS || TARGET_OS_TV) && !TARGET_OS_SIMULATOR
    // Simulators report no limit; they fall back to a share of the Mac's memory below.
    if (@available(iOS 13.0, tvOS 13.0, *)) available = os_proc_available_memory();
#endif
    if (available == 0) available = NSProcessInfo.processInfo.physicalMemory / 4;
    unsigned long long megabytes = available / 3 / (1024 * 1024);
    if (megabytes < 384) megabytes = 384;
    if (megabytes > 1024) megabytes = 1024;
    return [NSString stringWithFormat:@"-Xmx%llum", megabytes];
}

// A fatal JVM error (a native allocation that failed, say) ends the app with _exit(1), and a plugin's
// System.exit with exit(): neither leaves a crash log or a MetricKit report, so the app just vanishes
// (issue #159). The JVM calls these hooks first; abort() instead, so the crash is reported with its stack.
// The JVM log (embedded-jvm.log) has the fatal error's message.
static void abortHook(void) {
    fprintf(stderr, "The Java runtime hit a fatal error\n");
    abortIsolated();
}
static void exitHook(jint code) {
    fprintf(stderr, "Java code called exit(%d)\n", (int)code);
    abortIsolated();
}
// Native code linked with the runtime can call exit() too: Unicorn did when it could not reserve its
// translation buffer on a 3 GB iPad (issue #563), and the app vanished without a report. iOS and tvOS apps
// never exit by themselves, so once the runtime runs, an exit() is a failure: abort() to report its stack.
// An iPad app on a Mac does exit when quit, so it is left alone there.
#if TARGET_OS_IOS || TARGET_OS_TV
static void nativeExitHook(void) {
    fprintf(stderr, "Native code called exit()\n");
    abort();
}
#endif

// On a memory warning, idle plugin runtimes and sources are closed and the freed heap returned.
static void watchMemoryPressure(const char *resourcePath) {
    static dispatch_source_t source;
    NSString *resources = @(resourcePath);
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, queue);
    dispatch_source_set_event_handler(source, ^{
        char *result = TVAppleRuntimeRequest(resources.UTF8String, "{\"command\":\"trim\"}");
        free(result);
    });
    dispatch_resume(source);
}

/// 真正的实现。调用前必须已经装好跳点（见下面的 `TVAppleRuntimeRequest`）。
static char *requestInRuntime(const char *resourcePath, const char *requestJSON) {
    @autoreleasepool {
        if (runtimeBroken) return failure("The plugin runtime stopped working on this device. Restart the app to retry.");
        if (failed) return failure("The plugin runtime failed. Restart the app to retry.");
        // 这两个信号要在**创建 VM 之前**忽略。
        //
        // Zero 端口没有 `os::Posix::ucontext_get_pc`（os_cpu/bsd_zero/os_bsd_zero.cpp:91 就是
        // `ShouldNotCall()`），而 JVM 的信号入口第一件事是取 pc。于是任何被它接管的信号都会从
        // 「一个信号」升级成「一个 abort」，崩溃现场连带丢掉（hs_err 只剩 ShouldNotCall）。
        // 原来这两行写在创建成功之后，正好把创建那一段窗口露在外面。
        // 不是 2026-11-16 那次闪退的原因（那次是自举阶段的空指针，见 `JarRuntimeHealth`），
        // 但先忽略仍然是对的：下一次真出问题时 hs_err 才读得懂。
        signal(SIGPIPE, SIG_IGN); signal(SIGXFSZ, SIG_IGN);
        JNIEnv *env = NULL;
        pthread_mutex_lock(&startLock);
        if (!runtimeVM) {
            NSString *root = @(resourcePath);
            NSString *cache = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
            NSString *log = [cache stringByAppendingPathComponent:@"embedded-jvm.log"];
            NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:log error:NULL];
            // Keep the previous log when starting a new one: it holds the last hang or crash.
            if ([attributes fileSize] > 2 * 1024 * 1024) {
                NSString *previous = [cache stringByAppendingPathComponent:@"embedded-jvm.previous.log"];
                [[NSFileManager defaultManager] removeItemAtPath:previous error:NULL];
                [[NSFileManager defaultManager] moveItemAtPath:log toPath:previous error:NULL];
            }
            freopen(log.UTF8String, "a", stderr);
            setbuf(stderr, NULL);
            fprintf(stderr, "Starting on-device Java runtime\n");
            NSString *host = [root stringByAppendingPathComponent:@"JavaHost"];
            NSString *classpath = [host stringByAppendingPathComponent:@"apple-bindings.jar"];
            classpath = [classpath stringByAppendingFormat:@":%@", [host stringByAppendingPathComponent:@"host.jar"]];
            for (NSString *file in [[[NSFileManager defaultManager] contentsOfDirectoryAtPath:[host stringByAppendingPathComponent:@"lib"] error:NULL] sortedArrayUsingSelector:@selector(compare:)]) {
                if ([file.pathExtension isEqualToString:@"jar"]) classpath = [classpath stringByAppendingFormat:@":%@/lib/%@", host, file];
            }
            NSString *heap = heapLimit();
            fprintf(stderr, "Java heap limit %s\n", heap.UTF8String);
            // Shrink the committed heap after collections, so memory freed in Java goes back to iOS.
            // Class metadata gets 128 MB of address space instead of the default 1 GB: a 3 GB device may not have
            // 1 GB free in one piece, and then the JVM can't start ("Could not allocate compressed class space")
            // and ends the app. 30 sources of one FTY jar use about 10 MB.
            NSArray<NSString *> *arguments = @[heap, @"-Xms32m", @"-Xss2m", @"-XX:CompressedClassSpaceSize=128m", @"-XX:+UseSerialGC", @"-XX:MinHeapFreeRatio=10", @"-XX:MaxHeapFreeRatio=30", @"-XX:+DisableAttachMechanism", @"-Xrs",
                @"--add-opens=java.base/java.lang=ALL-UNNAMED", @"--add-opens=java.base/sun.net.www.protocol.jar=ALL-UNNAMED",
                @"--enable-native-access=ALL-UNNAMED",
                @"-Dorg.slf4j.simpleLogger.defaultLogLevel=error",
                // The log names Chinese lines and times; without these it shows "????" and UTC.
                @"-Dstderr.encoding=UTF-8", [@"-Duser.timezone=" stringByAppendingString:NSTimeZone.localTimeZone.name],
                [@"-Djava.home=" stringByAppendingString:[root stringByAppendingPathComponent:@"lib"]],
                [@"-Djava.class.path=" stringByAppendingString:classpath],
                [@"-Djava.io.tmpdir=" stringByAppendingString:NSTemporaryDirectory()]];
            JavaVMOption options[arguments.count + 2];
            for (NSUInteger i=0;i<arguments.count;i++) { options[i].optionString=(char *)arguments[i].UTF8String; options[i].extraInfo=NULL; }
            options[arguments.count]=(JavaVMOption){.optionString="abort",.extraInfo=(void *)abortHook};
            options[arguments.count + 1]=(JavaVMOption){.optionString="exit",.extraInfo=(void *)exitHook};
            JavaVMInitArgs init={.version=JNI_VERSION_1_8,.nOptions=(jint)arguments.count + 2,.options=options,.ignoreUnrecognized=JNI_FALSE};
            jint status=JNI_CreateJavaVM(&runtimeVM,(void **)&env,&init);
            if (status != JNI_OK) { runtimeVM=NULL; failed=YES; pthread_mutex_unlock(&startLock); return failure("Could not start the embedded Java runtime."); }
            // The JVM handles SIGPIPE and SIGXFSZ only to ignore them, but its handler first reads the
            // signal's pc, which Zero cannot do, so it aborts the app instead. A write to a closed
            // socket raises SIGPIPE (the player leaving the media proxy mid-stream); ignore both here
            // so such writes fail with an IOException as on other platforms.
            signal(SIGPIPE, SIG_IGN); signal(SIGXFSZ, SIG_IGN);
#if TARGET_OS_IOS || TARGET_OS_TV
            if (!NSProcessInfo.processInfo.isiOSAppOnMac) atexit(nativeExitHook);
#endif
            jclass local=(*env)->FindClass(env,"tvbox/runtime/AppleBootstrap");
            if (local) { bootstrap=(*env)->NewGlobalRef(env,local); (*env)->DeleteLocalRef(env,local); }
            if (bootstrap) requestMethod=(*env)->GetStaticMethodID(env,bootstrap,"request","(Ljava/lang/String;)Ljava/lang/String;");
            if (requestMethod) watchMemoryPressure(resourcePath);
        }
        pthread_mutex_unlock(&startLock);
        if (!env && (*runtimeVM)->AttachCurrentThread(runtimeVM,(void **)&env,NULL) != JNI_OK) {
            return failure("Could not attach the plugin worker.");
        }
        if ((*env)->ExceptionCheck(env) || !requestMethod) {
            (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); failed=YES;
            return failure("Could not initialize the plugin libraries. See diagnostic logs.");
        }
        char *result=performRequest(env,requestJSON);
        (*runtimeVM)->DetachCurrentThread(runtimeVM);
        return result;
    }
}

// MARK: - 入口（崩溃隔离包装）

char *TVAppleRuntimeRequest(const char *resourcePath, const char *requestJSON) {
    // SIGABRT 兜底只需要装一次；装成本线程的跳点之前它不会改变任何行为
    // （handler 里 `tlsAbortJump == NULL` 时还原默认并重新 raise）。
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        signal(SIGABRT, abortSignalHandler);
    });

    sigjmp_buf jump;
    sigjmp_buf *previous = tlsAbortJump;
    tlsAbortJump = &jump;
    int jumped = sigsetjmp(jump, 1);
    if (jumped != 0) {
        // 从 JVM 的 abort 里跳回来了。VM 内部已经不可信：
        // 标记坏掉，让后续请求立刻短路，别再一次次拿用户的点击去撞它。
        tlsAbortJump = previous;
        runtimeBroken = YES;
        failed = YES;
        fprintf(stderr, "The Java runtime aborted (jump %d); marking it broken for this launch.\n", jumped);
        return failure("The plugin runtime crashed on this device. Sources that need it are unavailable until the app restarts.");
    }
    char *result = requestInRuntime(resourcePath, requestJSON);
    tlsAbortJump = previous;
    return result;
}

/// 供 Swift 侧查询「运行时这一版能不能用」。`JarRuntimeHealth` 用它决定闸位。
BOOL TVAppleRuntimeIsBroken(void) { return runtimeBroken; }
