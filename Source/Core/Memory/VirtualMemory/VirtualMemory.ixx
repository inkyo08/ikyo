export module Memory:VirtualMemory;

export namespace Memory::VirtualMemory {
  // size는 시스템 페이지 크기에 맞춰 올림 처리
  // 반환되는 범위는 항상 시스템 페이지 크기에 따라 정렬되므로, alignment를 별도로 설정해야하는 경우는 거의 없음
  void* reserve(size_t size, size_t alignment = 0);

  // base는 이전에 reserve 호출 후 반환된 값만 사용
  // 예약할 때 사용했던 size와 alignment값을 동일하게 전달해야함
  void unreserve(void* base, size_t size, size_t alignment = 0);

  // base는 시스템 페이지 크기에 맞춰서 아래쪽으로 정렬되고, 무조건 이전에 예약한 영역 안에 있어야 함
  // base, base + size 범위랑 겹치는 모든 페이지가 매핑 또는 언매핑됨
  void map(void* base, size_t size);
  void unmap(void* base, size_t size);
}