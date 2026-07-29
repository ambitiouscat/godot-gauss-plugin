# Godot Gauss Plugin

面向 Godot 4 的 Gaussian Splatting（3DGS）插件。当前仓库只保留可直接安装的 `addons/gdgs`，不包含开发仓库中的测试、样例资产、原生构建环境和内部评审材料。

> 当前状态：**Preview**
>
> 插件已经可以用于单个 Gaussian 场景的按需加载与渲染，但尚未达到下述“终极目标”的全部商用验收条件。尤其是 `tileSet.json` 多瓦片流式加载和倾斜模型加载，目前不属于这个独立 `addons` 包的已交付能力。

## 终极目标

本项目的目标是形成一个可商用、可长期维护的 Godot Gaussian Splatting 插件：

- 大文件只在业务明确请求时异步加载，项目启动、场景打开和编辑器扫描均不解析 Gaussian 数据。
- 提供稳定的高质量 Vulkan/Forward+ 渲染，兼顾近景质量、深度遮挡、多节点、多视图和显存安全。
- 支持单文件和大规模分块场景，具备相机选瓦片、LOD/refinement、预算准入、取消、回收和失败保父能力。
- 支持项目内 `res://`、导出 PCK 以及受控远程内容加载。
- 提供碰撞生成、诊断、恶意输入防护、长时间生命周期验证和可追踪的第三方许可证信息。
- 在不破坏 Godot 使用方式的前提下，把复杂的原生空间计算和流式调度封装为稳定的节点 API。

## 为什么高斯与倾斜模型分成两个插件

对外发布时采用两个插件更合适：

1. **Gaussian Splatting 插件**：本仓库，负责 Gaussian 格式、解码、渲染、分页驻留和相关碰撞能力。
2. **Spatial Tiles 插件**：单独发布，负责倾斜摄影、标准 3D Tiles、GLB/B3DM、Mesh 渲染及其材质生命周期。

两者可以在内部复用同一套 Spatial Core（坐标、相机、内容请求、缓存和预算基础设施），以后也可以提供包含两者的组合发行版。这样，纯高斯项目无需安装 Cesium/Mesh 依赖，两个渲染领域也能独立升级和验收。

## 当前版本能力

插件版本为 `3.1.0`，当前独立包包含：

- `.ply`、`.compressed.ply`、`.splat` 和 SOG v2 `.sog` 的运行时解码。
- `GaussianSplatNode.source_path` 显式按需加载；仅赋值、进入场景树或编辑器选中节点不会读取文件正文。
- 异步请求、取消、相同资源共享、卸载和退出场景树后的资源释放。
- 通过 `CompositorEffect` 与普通 Godot 3D 内容合成，并使用场景深度进行遮挡。
- 多个 Gaussian 节点、编辑器预览、调试视图和实例共享。
- 编辑器内生成 `StaticBody3D` Gaussian 碰撞体，可选择 CPU 或独立 GPU 体素化。
- 项目内 `res://` 数据随 PCK 导出；外部绝对路径会被拒绝。

当前独立包**尚未交付**：

- `tileSet.json` 驱动的 39 PLY/大场景相机选瓦片和有界驻留。
- 倾斜摄影、标准 3D Tiles、GLB/B3DM Mesh adapter。
- 随包提供的 Cesium Native / Spatial Core GDExtension。
- KHR Gaussian Splatting、SPZ、移动端或 Compatibility 渲染后端。

这些能力仍在主开发工程中按独立门禁推进，不应把本 Preview 当作最终商用 Edition。

## 环境要求

- Godot `4.4` 或更新版本。
- `Forward Plus` 渲染后端。
- 支持计算着色器的桌面 GPU 与驱动。

Compatibility 和 Mobile 渲染后端暂不支持。

## 安装

1. 下载或克隆本仓库。
2. 将 `addons/gdgs` 完整复制到你的 Godot 项目，最终路径应为 `res://addons/gdgs`。
3. 打开 Godot，进入 `项目 > 项目设置 > 插件`。
4. 启用 `gdgs`。

## 最小使用方式

1. 在场景中添加 `GaussianSplatNode`。
2. 把 `source_path` 设置为项目内路径，例如 `res://assets/scene.ply`。
3. 给 `WorldEnvironment.compositor` 创建 `Compositor`，添加一个 `CompositorEffect`，脚本设为：

   `res://addons/gdgs/runtime/compositor/gaussian_compositor_effect.gd`

4. 在真正需要模型时调用 `request_load()`，不再使用时调用 `unload()`。

```gdscript
@onready var splat: GaussianSplatNode = $GaussianSplatNode

func _ready() -> void:
	splat.source_path = "res://assets/scene.ply"
	splat.load_completed.connect(_on_loaded)
	splat.load_failed.connect(_on_failed)

	var error := splat.request_load()
	if error != OK:
		push_error("Gaussian request rejected: %s" % error_string(error))

func release_gaussian() -> void:
	splat.unload()

func _on_loaded(_resource: GaussianResource) -> void:
	print("Gaussian source is ready")

func _on_failed(_error: int, error_id: String, message: String) -> void:
	push_error("%s: %s" % [error_id, message])
```

如果请求仍在排队或解码，可以调用 `cancel_load()`。

## 避免恢复启动时全量加载

新场景只使用 `source_path`。旧的 `gaussian: GaussianResource` 属性是兼容分支，Godot 加载场景时会立即解析该资源，因此会出现：

```text
Legacy GaussianResource mode loads eagerly with the scene.
Assign source_path to use explicit lazy loading.
```

看到该警告时，应迁移到 `source_path`，并由业务逻辑显式调用 `request_load()`。

## 许可证

本仓库使用 [MIT License](LICENSE)。插件包含或参考了其他 MIT 项目的代码，分发时必须保留 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
