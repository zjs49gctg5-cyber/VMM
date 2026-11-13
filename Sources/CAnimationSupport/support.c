#include "VMMAnimationSupport.h"
#include <sandbox.h>
#include <sys/resource.h>
#include <libproc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int vmm_isolate_worker(const char *output_path, char *error, size_t capacity) {
    struct rlimit cpu = {6, 7}, file = {8*1024*1024, 8*1024*1024}, core = {0,0};
    if (setrlimit(RLIMIT_CPU,&cpu) || setrlimit(RLIMIT_FSIZE,&file) || setrlimit(RLIMIT_CORE,&core)) {
        snprintf(error,capacity,"Worker resource limits could not be set.");return -1;
    }
    char canonical[4097];
    if (!realpath(output_path,canonical)) {snprintf(error,capacity,"Worker output path could not be resolved.");return -1;}
    output_path=canonical;
    size_t length = strlen(output_path);
    if (length>4096) return -1;
    char escaped[8193];size_t j=0;
    for (size_t i=0;i<length;i++) {if (output_path[i]=='"' || output_path[i]=='\\') escaped[j++]='\\';escaped[j++]=output_path[i];}
    escaped[j]=0;
    char *profile=NULL;
    if (asprintf(&profile,"(version 1)(deny default)(allow sysctl-read)(allow mach-lookup)(allow file-read-metadata)(allow file-read-data (subpath \"/System/Library\") (subpath \"/usr/lib\") (literal \"/dev/urandom\"))(allow file-write-data (literal \"%s\"))",escaped)<0) return -1;
    char *message=NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    int result=sandbox_init(profile,0,&message);
    if (result) snprintf(error,capacity,"%s",message ? message:"Worker sandbox could not be enabled.");
    sandbox_free_error(message);
#pragma clang diagnostic pop
    free(profile);return result;
}
uint64_t vmm_worker_memory(int pid) {
    struct rusage_info_v2 usage;
    if (proc_pid_rusage(pid,RUSAGE_INFO_V2,(rusage_info_t *)&usage)) return 0;
    return usage.ri_phys_footprint;
}
