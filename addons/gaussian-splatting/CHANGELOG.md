# Gaussian Splatting Addon — 变更日志

本文件记录了从 [原始项目](https://github.com/2Retr0/GodotGaussianSplatting) 到当前可复用 addon 的所有修改，以供后来者参考。

## 原始架构

原始项目是单实例设计：

- `util/gaussian_splatting_rasterizer.gd` (`GaussianSplattingRasterizer`, extends Resource) — 单个 PLY 文件对应一套完整 GPU 管线
- `util/ply_file.gd` (`PlyFile`) — PLY 解析器
- `util/render_context.gd` (`RenderingContext`) — RenderingDevice 封装
- `main.gd` 直接创建和管理 rasterizer 实例
- 投影 shader 包含加载动画（ease_out_cubic 淡入 + 缩放 + 位移）
- 显示 shader 无深度输出，`POSITION.z = 1.0` 固定在最远处

---

## 一、GS-Mesh 混合渲染管线

### 目的

使 Gaussian Splatting 能与场景中的常规 3D Mesh 正确遮挡。

### Shader 变更

**投影 shader** (`gsplat_projection.glsl`):
- 新增 `binding 7: SplatDepthsBuffer`
- 主函数末尾写入 `splat_depths[id] = 0.5 - 0.5 * ndc_pos.z`（OpenGL NDC → Godot reverse-Z）

**渲染 shader** (`gsplat_render.glsl`):
- 新增 `binding 5: SplatDepthsBuffer`（只读）+ `binding 6: depth_image`（R32F，可写）
- 新增 shared memory `depth_tile[WORKGROUP_SIZE]`
- Alpha 混合循环中累积加权深度，输出 `final_depth = weighted_depth / opacity`
- Color alpha 输出 `1.0 - t`（实际不透明度）而非固定 1.0

**显示 shader** (`gs_display.gdshader`, 原 `main.gdshader`):
- 新增 `depth_texture` uniform + `FRAG_DISCARD_THRESHOLD` uniform
- `POSITION.z` 从 `1.0` 改为 `0.0`（参与深度测试）
- Fragment 中采样 alpha，低于阈值 discard
- 写入 `DEPTH = texture(depth_texture, SCREEN_UV).r`

---

## 二、Addon 架构重构

### 目的

从单实例 Resource 重构为可复用的 Godot EditorPlugin，支持多实例、编辑器预览、场景节点化。

### 新架构

```
addons/gaussian-splatting/
├── plugin.cfg / plugin.gd          # EditorPlugin：注册 autoload + 自定义类型 + 图标
├── gaussian_splatting_server.gd    # Autoload 单例：共享 GPU 管线、多实例管理
├── gaussian_splatting.gd           # Node3D 场景节点：@export ply_path、异步加载
├── gaussian_splatting_settings_override.gd  # 设置覆盖节点
├── ply_file.gd                     # PLY 解析器（无 class_name）
├── render_context.gd               # RenderingDevice 封装（无 class_name）
├── icons/                          # SVG 图标
└── shaders/                        # 所有 GLSL + gdshader
```

### 关键设计决策

| 决策 | 原因 |
|------|------|
| 移除所有 `class_name` | 避免 addon 与项目全局命名冲突 |
| Server 作为 Autoload | 跨场景持久化，管理共享 GPU 资源 |
| `GaussianSplatting` 作为 Node3D | 可在场景树中放置、通过 Transform 控制位置/旋转/缩放 |
| 多实例共享排序/渲染管线 | 所有 splat 合并排序，保证正确的 alpha blending 和遮挡 |
| `splat_offset` 机制 | 每实例 splat 写入共享 buffer 的不同偏移区域 |
| `@tool` 注解 | 支持编辑器内实时预览 |

### GDScript 类型推断修复

由于 addon 移除了 `class_name`，大量变量变为 Variant 类型，GDScript 的 `:=` 类型推断会失败。统一修复为 `=`：

```gdscript
# 失败：Cannot infer the type of variable
var device := context.device

# 修复
var device = context.device
```

涉及的变量包括：`context.device`、`point_cloud.vertices`、`viewport.size`、`inst.global_basis.orthonormalized()`、所有 `_context.create_*()` 返回值等。

### `create_descriptor_set` 参数类型修复

```gdscript
# 失败：Array does not have the same element type as the expected typed array
func create_descriptor_set(descriptors: Array[Descriptor], ...) -> Descriptor:

# 修复：接受无类型 Array
func create_descriptor_set(descriptors: Array, ...) -> Descriptor:
```

### `render_context.gd` 的 `create()` 修复

```gdscript
# 原始：使用 class_name 引用
var context := RenderingContext.new()

# 修复：通过 load() 自引用
var context = load("res://addons/gaussian-splatting/render_context.gd").new()
```

---

## 三、多实例渲染

### 投影 shader 变更 (`gsplat_projection.glsl`)

```glsl
// Uniform 块新增
layout(std140, binding = 6) uniform Uniforms {
    ...
    uint splat_offset;  // 新增
};

// Buffer 索引偏移
culled_buffer[id + splat_offset] = ...;
splat_depths[id + splat_offset] = ...;
sort_values[...] = id + splat_offset;  // value 存的是全局索引
```

### Server 端逻辑

- 每个实例有独立的 splat buffer、uniform buffer、projection pipeline
- 所有实例的 splat 共享 culled_buffer、sort_keys/values、tile_bounds
- Projection 按实例分别 dispatch（各自的 view matrix）
- Sort / Boundaries / Render 一次性处理所有 splat

---

## 四、场景切换与 GPU 资源生命周期

### 问题

Server 是 autoload（跨场景持久），但 GPU 资源 (RID) 可能在场景切换时失效。直接在主线程释放渲染线程创建的 RID 会报 "Attempted to free invalid ID"。

### 解决方案

- `_teardown_gpu()`: 当所有 GS 实例注销时调用，清空所有 GDScript 端字典，设 `_pending_cleanup = true`
- `_rasterize()` 中检测 `_pending_cleanup`: 在渲染线程上执行 `deletion_queue.flush()`，然后 `queue.clear()`（防 GC PREDELETE 二次释放），再 `_context = null`
- **关键**: `_teardown_gpu` 中不能设 `_context = null`——那会触发 GC → PREDELETE → 在主线程 flush deletion queue → 报错
- `_display_quad.visible` 在无实例时设为 `false`，避免白屏

### Texture2DRD 重建

Teardown 后清空了 `texture_rd_rid`，旧的 Texture2DRD 对象失效。`_rebuild_gpu()` 必须创建全新的 Texture2DRD 并重新绑定到 ShaderMaterial：

```gdscript
_render_texture = Texture2DRD.new()
_depth_texture = Texture2DRD.new()
_display_material.set_shader_parameter('render_texture', _render_texture)
_display_material.set_shader_parameter('depth_texture', _depth_texture)
```

提取为 `_bind_textures()` / `_detach_textures()` 辅助函数避免重复。

---

## 五、SettingsOverride 节点

场景中放置 `GaussianSplattingServerSettingsOverride` 节点，在 Inspector 中调整 `render_scale` / `discard_alpha` / `enable_heatmap` 即可实时生效，无需 reload project。

Server 属性 setter 中的脏检测：
- `render_scale`: clamp [0,1] + 触发 `_needs_resize`
- `discard_alpha`: clamp [0,1] + 直接更新 shader parameter
- `enable_heatmap`: 触发 `_force_redraw`

---

## 六、加载动画移除

原始投影 shader 包含 ease_out_cubic 渐入动画（透明度、缩放、位移），但在脏检测架构下不会自动刷新（需要移动相机才能播放），导致 GS 加载后看不到。

移除的代码：
```glsl
// 已移除
float splat_time = time - splat.time;
float time_factor = ease_out_cubic(clamp(splat_time, 0, 1));
float time_factor_late = ease_out_cubic(clamp(splat_time - 0.35, 0, 1));
float splat_opacity = splat.opacity * time_factor_late*time_factor_late;
float splat_scale = model_scale * mix(2.0, 1.0, time_factor_late);
vec2 image_pos = (...- vec2(1,0.75)*(1.0 - time_factor)) * ...;

// 替换为
float splat_opacity = splat.opacity;
float splat_scale = model_scale;
vec2 image_pos = (ndc_pos.xy + 1.0)*0.5 * (dims - 1);
```

---

## 七、效率优化 (Code Review)

| 优化 | 说明 |
|------|------|
| `discard_alpha` setter 加 early-return | 避免每帧调 `set_shader_parameter` |
| Transform 比较改为 in-place | 消除每帧 Array 分配 + GC |
| `debug_info_enabled` 开关 | GPU readback (`buffer_get_data`) 可按需禁用，避免 pipeline stall |
| `_bind_textures()` / `_detach_textures()` | 3 处重复代码统一 |

---

## 八、新增功能

| 功能 | 说明 |
|------|------|
| `center_at_origin` | GaussianSplatting 节点的 @export 属性，加载后自动居中点云 |
| `SettingsOverride` 节点 | 场景级设置覆盖，Inspector 内可调 |
| 自定义图标 | SVG 图标显示在场景树中 |
| `debug_info_enabled` | 可禁用每帧 GPU readback |
| Depth 输出 | GS 与 Mesh 正确遮挡 |
| Alpha discard | 可调阈值裁剪低透明度区域 |

---

## 使用方法

1. 将 `addons/gaussian-splatting/` 文件夹复制到目标项目
2. **Project → Project Settings → Plugins** 启用 `gaussian-splatting`
3. 场景中添加 `GaussianSplatting` 节点，设置 `ply_path`
4. 可选：添加 `GaussianSplattingServerSettingsOverride` 节点调整参数
