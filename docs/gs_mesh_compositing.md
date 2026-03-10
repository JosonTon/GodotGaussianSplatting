# GS + Mesh 混合渲染方案

> 创建日期：2026-03-10
> 状态：设计阶段
> 前置依赖：2Retr0/GodotGaussianSplatting 已完成 Godot 4.6 移植

## 1. 需求

### 核心目标

在 Godot 4.6 中实现 **Gaussian Splatting 场景与传统 Mesh 的双向深度遮挡**，使 IK puppet（mesh）能够自然地存在于 GS 环境中。

### 典型场景

- GS 教室场景中放置一个角色坐在椅子上
  - 椅子靠背（GS）遮挡角色背部（mesh）→ GS 遮挡 mesh
  - 角色手臂（mesh）遮挡课桌表面（GS）→ mesh 遮挡 GS
  - 桌腿（GS）遮挡角色小腿（mesh）→ GS 遮挡 mesh

### 单向 vs 双向

| 方向 | 含义 | 单向方案 | 双向方案 |
|------|------|----------|----------|
| mesh 遮挡 GS | puppet 挡住背景 | ✅ | ✅ |
| GS 遮挡 mesh | 环境家具挡住 puppet 部分身体 | ❌ | ✅ |

单向方案（只有 mesh 遮挡 GS）实现简单但不够用。CardComics 需要双向遮挡。

---

## 2. 问题本质

### Mesh 渲染管线

```
顶点 → 光栅化 → 片元着色 → Z-buffer depth test
- 不透明渲染，顺序无关
- 每个像素写入精确深度值到 depth buffer
- GPU 硬件加速
```

### GS 渲染管线

```
Gaussian 椭球 → 屏幕投影 → GPU 排序（从后到前）→ tile-based alpha 混合
- 体积渲染，顺序敏感
- 不写入 depth buffer（或无物理意义的深度）
- 依赖排序 + alpha 混合实现正确叠加
```

### 核心矛盾

两种管线产出不同的 buffer：

```
Mesh:  Color + Depth（精确）
GS:    Color + 无 Depth
```

没有 GS 的 depth buffer，mesh 无法知道 GS 的哪些部分应该遮挡自己。

---

## 3. 已探讨的方案

### 方案 A：分层合成 + GS 近似深度（推荐）

**原理**：让 GS 在渲染时输出一张近似深度图，然后与 mesh 的深度逐像素比较合成。

```
Pass 1: 正常渲染所有不透明 Mesh
  → Color_mesh + Depth_mesh

Pass 2: GS tile-based compute shader 渲染
  正常 alpha 混合的同时，记录每个像素的「期望深度」：

  expected_depth[pixel] = Σ (splat_i.depth × splat_i.alpha × transmittance_i)

  或者使用 median depth（transmittance 降到 0.5 时的 splat 深度）。
  → Color_gs + Depth_gs（近似）

Pass 3: 合成 compute shader
  逐像素：
    if Depth_mesh < Depth_gs:
        output = Color_mesh      // mesh 在前
    elif Depth_gs < Depth_mesh:
        output = Color_gs        // GS 在前
    else:
        output = alpha_blend()   // 边界过渡
```

**优点**：
- 实现清晰，各 pass 职责分离
- 与 2Retr0 的 compute shader 架构天然兼容
- NVIDIA 官方 Vulkan 样例验证了可行性

**缺点**：
- 期望深度是近似值，边缘有轻微 artifact
- 多加一个合成 pass 的性能开销

**深度估算方法对比**：

| 方法 | 实现 | 质量 | 适用场景 |
|------|------|------|----------|
| Expected depth（加权平均） | 简单，alpha 混合时累加 | 中等，高 alpha 区域准确 | 通用 |
| Median depth（中位深度） | 记录 transmittance=0.5 时的深度 | 较好，更接近"表面" | 推荐 |
| Threshold depth（阈值截断） | alpha 累积 > 0.95 时取当前深度 | 最简单，边缘差 | 快速验证 |

### 方案 B：GS 渲染时直接做 mesh depth test

**原理**：GS compute shader 在光栅化每个 splat 时，采样 mesh depth buffer 做判断。

```
Pass 1: 渲染 Mesh → Depth_mesh

Pass 2: GS 渲染时：
  对每个 splat 的每个覆盖像素：
    if splat.depth > Depth_mesh[pixel]:
        skip（被 mesh 遮挡）
    else:
        正常 alpha 混合

  同时输出 GS depth → Depth_gs

Pass 3: 再次渲染 Mesh（或合成 pass）：
  对每个 mesh 像素：
    if Depth_mesh[pixel] > Depth_gs[pixel]:
        使用 GS 颜色（被 GS 遮挡）
```

**优点**：
- Pass 2 中 mesh→GS 遮挡更精确（逐 splat 判断）

**缺点**：
- 需要修改 GS 核心 compute shader 的光栅化循环
- 仍需要额外 pass 处理 GS→mesh 遮挡
- 与方案 A 本质相同，只是合并了部分逻辑

### 方案 C：统一排序（理论最优，不推荐实现）

把 mesh 三角形和 GS splat 放入同一排序队列，统一 back-to-front alpha 混合。

**不推荐原因**：
- 实现极其复杂
- 放弃硬件 depth test 的性能优势
- 仅在研究论文中出现（UniMGS, arXiv 2601.19233）
- 无引擎级开源实现

### 方案 D：Mesh 转 GS（不适用）

将 mesh 离线转为 GS 表示，全场景 GS 渲染。

**不适用原因**：
- IK puppet 是实时动画，无法转为静态 GS
- 动态 GS（4D-GS）仍在研究阶段

---

## 4. 推荐方案详细设计

### 选择方案 A：分层合成 + Median Depth

理由：
1. 与 2Retr0 的 compute shader 管线改动最小
2. 各 pass 解耦，便于调试
3. NVIDIA 官方 Vulkan 样例和 Unity aras-p 项目验证了可行性
4. median depth 质量满足漫画参考图需求

### Godot 实现架构

```
CompositorEffect（注入点：EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT）
│
├── 从 render_scene_buffers 获取：
│   ├── scene_color（mesh 颜色，已渲染完不透明物体）
│   └── scene_depth（mesh 深度，精确）
│
├── GS Compute Shader Pipeline（基于 2Retr0）：
│   ├── projection pass    → 投影 + 视锥剔除
│   ├── sorting pass       → GPU radix sort
│   ├── rasterization pass → tile-based alpha 混合
│   │   [新增] 同时输出 gs_depth（median depth）
│   └── 输出：gs_color (RGBA) + gs_depth (R32F)
│
└── Compositing Compute Shader [新增]：
    ├── 输入：scene_color, scene_depth, gs_color, gs_depth
    ├── 逐像素比较 scene_depth vs gs_depth
    ├── 深度更小者胜出，边界 alpha 混合
    └── 输出：final_color → 写回 scene_color
```

### 需要修改的 Shader

**1. 光栅化 shader（修改）**

在 2Retr0 的 tile-based rasterization compute shader 中，每个 tile 已经在做 back-to-front alpha 混合。需要在该循环中新增：

```glsl
// 原有逻辑
float transmittance = 1.0;
vec3 color = vec3(0.0);

// 新增：深度追踪
float depth_accumulator = 0.0;
bool median_found = false;
float median_depth = far_plane;

for (int i = 0; i < splat_count; i++) {
    float alpha = splat[i].alpha;
    float depth = splat[i].depth;

    // 原有 alpha 混合
    color += transmittance * alpha * splat[i].color;
    transmittance *= (1.0 - alpha);

    // 新增：median depth（transmittance 首次降到 0.5 以下）
    if (!median_found && transmittance < 0.5) {
        median_depth = depth;
        median_found = true;
    }

    if (transmittance < 0.001) break;
}

// 写入 gs_depth texture
imageStore(gs_depth_image, pixel_coord, vec4(median_depth, 0, 0, 0));
```

**2. 合成 shader（新增）**

```glsl
#[compute]
#version 450

layout(set = 0, binding = 0) uniform sampler2D scene_color;
layout(set = 0, binding = 1) uniform sampler2D scene_depth;
layout(set = 0, binding = 2) uniform sampler2D gs_color;
layout(set = 0, binding = 3) uniform sampler2D gs_depth;
layout(set = 0, binding = 4, rgba16f) uniform writeonly image2D output_color;

layout(push_constant) uniform Params {
    vec2 resolution;
    float depth_blend_range;  // 深度接近时的 alpha 混合范围
};

void main() {
    ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
    vec2 uv = (vec2(pixel) + 0.5) / resolution;

    vec4 mesh_col = texture(scene_color, uv);
    float mesh_d = texture(scene_depth, uv).r;
    vec4 gs_col = texture(gs_color, uv);
    float gs_d = texture(gs_depth, uv).r;

    // 线性化深度（Godot 使用 reverse-Z）
    // ... 深度线性化代码 ...

    float depth_diff = mesh_d_linear - gs_d_linear;

    vec4 final_color;
    if (abs(depth_diff) < depth_blend_range) {
        // 深度接近：alpha 混合平滑过渡
        float t = (depth_diff / depth_blend_range) * 0.5 + 0.5;
        final_color = mix(gs_col, mesh_col, t);
    } else if (depth_diff > 0.0) {
        // GS 更近 → GS 颜色（GS 遮挡 mesh）
        final_color = gs_col;
    } else {
        // Mesh 更近 → mesh 颜色（mesh 遮挡 GS）
        final_color = mesh_col;
    }

    imageStore(output_color, pixel, final_color);
}
```

### 注意事项

1. **Godot Reverse-Z**：Godot 使用反向 Z（近平面=1.0, 远平面=0.0），深度比较时需注意方向
2. **深度纹理 Y 轴翻转**：已知 Godot bug（issue #90148），采样 `scene_depth` 时可能需要翻转 UV.y
3. **GS 无 splat 区域**：gs_depth 应初始化为远平面值，这样无 GS 的区域自动显示 mesh

---

## 5. 已有参考实现

| 项目 | 引擎 | 双向遮挡 | 参考价值 |
|------|------|----------|----------|
| [aras-p/UnityGaussianSplatting](https://github.com/aras-p/UnityGaussianSplatting) | Unity | 单向（mesh→GS） | 了解 Z-test 集成方式 |
| [wuyize25/gsplat-unity](https://github.com/wuyize25/gsplat-unity) | Unity | 双向（渲染队列插入） | 排序策略参考 |
| [nvpro-samples/vk_gaussian_splatting](https://github.com/nvpro-samples/vk_gaussian_splatting) | Vulkan | 双向（2025.8+） | **最佳参考**，深度合成 shader 可直接移植 |
| [xverse-engine/XScene-UEPlugin](https://github.com/xverse-engine/XScene-UEPlugin) | UE5 | depth-aware blending | 架构参考 |

**重点参考 NVIDIA Vulkan 样例**（Apache 2.0），其深度合成逻辑最直接、最干净。

---

## 6. 实施计划

### 阶段 1：在独立项目中实现（当前）

前置：2Retr0 方案已完成 Godot 4.6 移植 ✅

- [ ] 在光栅化 shader 中新增 median depth 输出
- [ ] 编写合成 compute shader
- [ ] 创建测试场景：简单 mesh（立方体/球体）+ GS 环境
- [ ] 验证双向遮挡效果
- [ ] 调优 depth_blend_range 参数
- [ ] 性能测试（目标：60+ FPS）

### 阶段 2：整理为 Addon

- [ ] 解耦为独立 Godot addon（`addons/gaussian_splatting/`）
- [ ] 提供 GaussianSplattingRenderer 节点（封装 CompositorEffect）
- [ ] 提供 .ply 加载器（ResourceFormatLoader）
- [ ] 配置项：渲染质量、深度混合范围、是否启用深度合成
- [ ] 编写 addon 使用文档

### 阶段 3：集成到 CardComics

- [ ] 将 addon 部署到 `cardcomics/addons/gaussian_splatting/`
- [ ] 集成到 World3DContainer / FrameLayer 体系
- [ ] 与 IK puppet 场景联合测试
- [ ] 与 outline_compositor_effect 叠加测试

---

## 7. 已知风险

| 风险 | 严重度 | 对策 |
|------|--------|------|
| Median depth 在边缘不精确 | 中 | 调整 depth_blend_range + 后处理平滑 |
| 两个 CompositorEffect 冲突 | 中 | 确认 GS 与 outline effect 的执行顺序 |
| Godot depth texture bug #90148 | 低 | UV.y 翻转 workaround |
| 性能不足（大场景 + 合成 pass） | 中 | LOD + 分辨率缩放 + 异步排序 |
