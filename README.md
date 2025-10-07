# Ikyo 게임 엔진

Swift로 작성된 멀티플랫폼 게임 엔진으로, Vulkan과 Metal 그래픽스 API를 지원합니다.

## 아키텍처

Ikyo는 현대 엔진 설계 트렌드와 반대되는 **모놀리식 아키텍처**를 채택했습니다. 엔진과 게임 로직이 완전히 통합되어 하나의 실행파일로 컴파일되며, 엔진과 게임은 문자 그대로 같은 것입니다.

### 주요 특징

- **Swift 기반**: 성능과 안전성을 위한 Swift 구현 -> 성능 크리티컬한 부분은 C로 대체
- **멀티플랫폼**: Vulkan 지원
- **ECS**: ECS 기반 DOD 설계로 성능 확보

### 설계 철학

모듈형 구조가 주류인 현재와는 달리, **직관적인 단순함**을 추구합니다. 복잡한 모듈 간 의존성 대신 통합된 구조를 통해:

- 직관적인 개발 워크플로 제공
- 엔진-게임 간 통신 오버헤드 제거
- 간소화된 빌드 및 배포 과정
- 명확하고 단일한 코드베이스 관리

시대를 역행하는 선택이지만, 개발자가 엔진의 동작을 쉽게 이해하고 수정할 수 있는 직관성을 최우선으로 고려했습니다.

## 렌더링 파이프라인
```mermaid
graph TD

A[G-Buffer: SVO-DDA 레이마칭 (Primary visibility)] --> A1[Sparse Voxel Octree traversal]
A --> A2[3D-DDA로 복셀 순회]
A --> A3[Normal, Material ID, Depth 추출]

B[GI: SVOGI Cone Tracing] --> B1[난반사 간접광]
B --> B2[Ambient occlusion]

C[거울 반사: SVO-DDA 레이마칭] --> C1[반사 벡터 방향으로 레이마칭]
C --> C2[1-2 바운스 제한]
C --> C3[SVO 계층 구조로 빠른 순회]

D[Glossy 반사: Cone Tracing (추가 최적화)] --> D1[완전 거울이 아닌 경우 cone으로 근사]
D --> D2[Roughness에 따라 cone angle 조정]

E[투명/굴절: SVO-DDA 레이마칭] --> E1[굴절 벡터 계산 후 레이마칭]
E --> E2[Beer's law로 감쇠 계산]
E --> E3[복셀 밀도로 볼륨 표현 가능]

F[그림자: SVO-DDA 레이마칭] --> F1[광원 방향으로 레이마칭]
F --> F2[Early termination (첫 hit에서 중단)]
F --> F3[Soft shadow는 cone tracing 활용]

A --- B --- C --- D --- E --- F
```
