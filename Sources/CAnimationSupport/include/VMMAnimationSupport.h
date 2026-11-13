#include <stddef.h>
#include <stdint.h>
int vmm_isolate_worker(const char *output_path, char *error, size_t capacity);
uint64_t vmm_worker_memory(int pid);
