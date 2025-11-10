#ifndef IKYO_VIRTUALMEMORY_H
#define IKYO_VIRTUALMEMORY_H

#include <stddef.h>

void VM_Initialize();

void* VM_Reserve(size_t reserveSize, size_t alignment);
void VM_Unreserve(void* base, size_t reservedSize, size_t alignment);

void VM_MapPages(void* base, size_t size);
void VM_UnmapPages(void* base, size_t size);

#endif //IKYO_VIRTUALMEMORY_H