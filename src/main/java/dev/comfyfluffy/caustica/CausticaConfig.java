package dev.comfyfluffy.caustica;

import com.electronwill.nightconfig.core.CommentedConfig;
import com.electronwill.nightconfig.core.file.CommentedFileConfig;
import com.electronwill.nightconfig.core.file.FileNotFoundAction;
import com.electronwill.nightconfig.toml.TomlFormat;
import java.nio.file.Path;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.function.DoubleUnaryOperator;
import java.util.function.IntUnaryOperator;
import java.util.function.UnaryOperator;
import net.fabricmc.loader.api.FabricLoader;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Central mutable runtime configuration. Each setting resolves its value, in order of precedence, from a
 * {@code -Dcaustica.*} system property, then the {@code config/caustica.toml} file, then a hardcoded
 * default. The settings UI and any other code call the same {@code set(...)} methods, and {@link #save()}
 * writes the current values back to the TOML file.
 *
 * <p>The system property namespace ({@code caustica.rt.foo}) and the TOML layout are independent: the file
 * uses real nested tables (e.g. {@code [omm]} with a {@code subdivision} key) grouped for readability, while
 * the property namespace stays flat and dotted for convenient one-off {@code -D} overrides.
 */
public final class CausticaConfig {
    private static final Logger LOGGER = LoggerFactory.getLogger("Caustica");
    private static final List<RuntimeSetting<?>> SETTINGS = new CopyOnWriteArrayList<>();

    private static final Path CONFIG_PATH = resolveConfigPath();
    private static final CommentedFileConfig FILE = loadFile(CONFIG_PATH);

    private CausticaConfig() {
    }

    public static List<RuntimeSetting<?>> settings() {
        return List.copyOf(SETTINGS);
    }

    public static Path configPath() {
        return CONFIG_PATH;
    }

    public static void reloadFromSystemProperties() {
        for (RuntimeSetting<?> setting : SETTINGS) {
            setting.reloadFromSystemProperties();
        }
    }

    /**
     * Forces every settings holder to class-initialize so all settings are registered (and have applied
     * their file values). Call before {@link #save()} to write a complete file, and once at startup so the
     * file round-trips the full surface even for settings the renderer has not touched yet.
     */
    public static void ensureRegistered() {
        @SuppressWarnings("unused")
        Object[] touch = {
            Rt.ENABLED, Rt.Composite.SPP, Rt.Composite.MAX_BOUNCES, Rt.Terrain.ASYNC_DISPATCH_PER_PASS, Rt.Omm.ENABLED,
            Rt.Entities.ENABLED, Rt.Entities.GLOW_ENABLED, Rt.EntityTextures.MAX_TEXTURES, Rt.DlssRr.ENABLED, Rt.Fg.ENABLED,
            Rt.Reflex.ENABLED, Rt.Exposure.MODE, Rt.FrameStats.ENABLED,
            Rt.Clouds.ENABLED, Rt.Clouds.QUALITY, Rt.Clouds.COVERAGE, Rt.Clouds.DETAIL,
            Rt.Composite.PLANAR_CLOUDS, Rt.Composite.CLOUD_QUALITY,
            Rt.Composite.CLOUD_COVERAGE, Rt.Composite.CLOUD_DENSITY, Rt.Composite.CLOUD_SPEED,
            Rt.Hdr.ENABLED, Ngx.PATH,
        };
    }

    /** Writes the default config file if it does not exist yet. */
    public static void saveIfMissing() {
        ensureRegistered();
        if (FILE.valueMap().isEmpty()) {
            save();
        }
    }

    /** Serializes all registered settings to the TOML config file. */
    public static synchronized void save() {
        ensureRegistered();
        writeComments();
        for (RuntimeSetting<?> setting : SETTINGS) {
            setting.writeToFile(FILE);
        }
        FILE.save();
    }

    private static void writeComments() {
        FILE.setComment("enabled",
                " Caustica RT renderer configuration.\n"
                        + " A matching -Dcaustica.* system property overrides the value below.\n"
                        + " Caustica 光追渲染器配置；同名的 -Dcaustica.* 系统属性优先级更高，会覆盖下面的值。");
        FILE.setComment("composite",
                " Per-frame compositing and look: depth of field, parallax, sampling, water, fog, light\n"
                        + " shafts and the volumetric cloud layer.\n"
                        + " 逐帧合成与观感：景深、视差、采样、水、雾、体积光与体积云。");
        FILE.setComment("clouds",
                " Volumetric cloud layer (clouds.slang): a lit, ray-marched deck above the world that casts\n"
                        + " on the ground below it and appears in reflections and refractions. quality is a\n"
                        + " CEILING on steps and detail rather than an override - off switches the layer off, and\n"
                        + " every other preset caps the settings underneath it.\n"
                        + " 体积云：世界之上受光的步进云层，会在其下方的地面投下阴影，并出现在反射与折射中。\n"
                        + " quality 是步数与细节的上限而非覆盖值：off 关闭云层，其余档位在其下各设置之上再取上限。");
        FILE.setComment("clouds.enabled", " 主开关。Master switch for the layer.");
        FILE.setComment("clouds.quality", " 质量档位：off / low / medium / high / ultra。Quality preset, in cap order.");
        FILE.setComment("clouds.coverage", " 0.0-1.0，云层占据天空的比例。Sky fraction the deck fills.");
        FILE.setComment("clouds.density", " 0.0-2.0，云的光学厚度倍率。Density scale on the layer's extinction.");
        FILE.setComment("clouds.base-altitude",
                " 云层底部的世界 Y 高度（方块，绝对坐标）。World Y of the deck's base, in absolute blocks.");
        FILE.setComment("clouds.thickness", " 云层厚度（方块）。Deck thickness in blocks.");
        FILE.setComment("clouds.detail", " 0.0-1.0，侵蚀场啃入云体的程度。How far erosion carves into the body.");
        FILE.setComment("clouds.steps",
                " 视线步进上限；质量档会在此基础上再取较小者。View-march step cap; the preset caps it further.");
        FILE.setComment("clouds.wind-speed", " 云层水平漂移速度（方块/秒）。Horizontal drift speed of the deck.");
        FILE.setComment("clouds.weather-response",
                " 0.0-2.0，降雨与雷暴对云量、厚度和密度的影响强度。How hard weather drives the layer.");
        FILE.setComment("clouds.lightning",
                " 0.0-1.0，雷暴闪电从云层内部照亮云体的强度。Thunderstorm emission inside the deck.");
        FILE.setComment("clouds.jitter",
                " 0.0-1.0，步进起点的逐像素抖动，交给降噪器收敛。Per-ray march-start jitter.");
        FILE.setComment("terrain",
                " Render-thread terrain work is bounded by dispatch/result counts per streaming pass.\n"
                        + " Buffer fill and BLAS/OMM preparation run on workers. max-inflight-sections bounds\n"
                        + " the complete snapshot -> worker -> GPU build -> publication lifecycle.\n"
                        + " 渲染线程的地形工作按每次流式处理的派发/结果数量限流；缓冲填充与 BLAS/OMM 准备在\n"
                        + " 工作线程上进行，max-inflight-sections 限制 快照 -> 工作线程 -> GPU 构建 -> 发布 的完整生命周期。");
        FILE.setComment("omm",
                " Opacity micromaps: accelerate cutout foliage. subdivision is the micro-map resolution per axis.\n"
                        + " 不透明度微图：加速镂空植被。subdivision 是每个轴的微图分辨率。");
        FILE.setComment("entities",
                " Entity and block-entity ray tracing: capacities, glow outlines, name tags and PBR textures.\n"
                        + " 实体与方块实体光追：容量、描边发光、名牌与 PBR 贴图。");
        FILE.setComment("particles",
                " Particle ray tracing: camera-facing billboards that receive direct light.\n"
                        + " 粒子光追：面向相机的公告板，接收直接光照。");
        FILE.setComment("dlss-rr",
                " DLSS Ray Reconstruction: denoises the ray-traced image. quality is the NGX perf-quality mode.\n"
                        + " DLSS 光线重建：对光追图像降噪。quality 是 NGX 的性能/质量档位。");
        FILE.setComment("frame-generation",
                " DLSS Frame Generation. Default off; gated additionally by hardware/driver availability.\n"
                        + " multi-frame-count: frames generated per rendered frame (1 = 2x, 2 = 3x, ...), clamped\n"
                        + " at runtime to the driver's reported DLSSG.MultiFrameCountMax.\n"
                        + " DLSS 帧生成，默认关闭，并且还要求硬件/驱动支持。multi-frame-count 为每个渲染帧生成的\n"
                        + " 帧数（1 = 2 倍，2 = 3 倍……），运行时受驱动报告的 DLSSG.MultiFrameCountMax 限制。");
        FILE.setComment("reflex",
                " NVIDIA Reflex (VK_NV_low_latency2). Default off; gated additionally by device support.\n"
                        + " minimum-interval-us: 0 = no framerate cap (Reflex just paces submission).\n"
                        + " NVIDIA Reflex，默认关闭，并且还要求设备支持。minimum-interval-us 为 0 表示不限制帧率，\n"
                        + " 只让 Reflex 调节提交节奏。");
        FILE.setComment("lights",
                " RIS direct lighting from block emitters (torches, glowstone, lava, ...): per diffuse\n"
                        + " vertex, resample ris-candidates power-weighted proposals and spend one shadow ray on\n"
                        + " the survivor. ris-candidates = 0 disables it entirely (emitters just gather on direct\n"
                        + " hit, same as with no NEE). Power-weighted sampling and the local per-section light\n"
                        + " grid are always active whenever RIS is on. min-fill-ratio drops emissive footprints\n"
                        + " below that fraction of their bounding rectangle (speckle/sparse crossed planes), so\n"
                        + " only reasonably compact glows become lights. stats/dump/dump-radius are debug logging.\n"
                        + " 方块光源（火把、萤石、岩浆等）的 RIS 直接光照：每个漫反射顶点按功率权重重采样\n"
                        + " ris-candidates 个候选，并对存活者发一条阴影射线。ris-candidates = 0 完全关闭（光源只在\n"
                        + " 直接命中时贡献，等同于没有 NEE）。RIS 开启时按功率采样与逐区块光源网格始终有效；\n"
                        + " min-fill-ratio 会丢弃发光面积小于包围矩形该比例的稀疏面片，只有足够紧凑的发光体才会\n"
                        + " 成为光源。stats/dump/dump-radius 是调试日志。");
        FILE.setComment("exposure",
                " Auto exposure: mode auto/manual, manual-ev in stops, key is the target middle grey.\n"
                        + " 自动曝光：mode 为 auto/manual，manual-ev 以档为单位，key 是目标中灰。");
        FILE.setComment("frame-stats",
                " Per-stage GPU timing capture; off keeps the frame free of query overhead.\n"
                        + " 逐阶段 GPU 计时采集；关闭可避免查询开销。");
        FILE.setComment("hdr",
                " HDR display output (ST.2084/PQ). When enabled the swapchain is created in PQ automatically\n"
                        + " (falls back to SDR if the surface doesn't advertise it). paper-white-nits / peak-nits\n"
                        + " drive the scene-HDR -> display mapping.\n"
                        + " HDR 显示输出（ST.2084/PQ）：开启后交换链自动以 PQ 创建（表面不支持时回退到 SDR），\n"
                        + " paper-white-nits / peak-nits 决定场景 HDR 到显示器的映射。");
    }

    private static Path resolveConfigPath() {
        try {
            return FabricLoader.getInstance().getConfigDir().resolve("caustica.toml");
        } catch (Throwable t) {
            return Path.of("config", "caustica.toml");
        }
    }

    private static CommentedFileConfig loadFile(Path path) {
        CommentedFileConfig config = CommentedFileConfig.builder(path, TomlFormat.instance())
                .onFileNotFound(FileNotFoundAction.CREATE_EMPTY)
                .preserveInsertionOrder()
                .sync()
                .build();
        try {
            config.load();
        } catch (Exception e) {
            LOGGER.warn("Failed to read Caustica config {}: {}", path, e.toString());
        }
        return config;
    }

    private static Boolean fileBoolean(String tomlPath) {
        return FILE.contains(tomlPath) ? FILE.<Boolean>get(tomlPath) : null;
    }

    private static Number fileNumber(String tomlPath) {
        return FILE.contains(tomlPath) ? FILE.<Number>get(tomlPath) : null;
    }

    private static String fileString(String tomlPath) {
        return FILE.contains(tomlPath) ? FILE.<String>get(tomlPath) : null;
    }

    public interface RuntimeSetting<T> {
        /** The {@code -Dcaustica.*} system property name that overrides this setting. */
        String key();

        /** The dotted path of this setting inside the nested {@code config/caustica.toml} tables. */
        String tomlPath();

        T defaultValue();

        T get();

        void set(T value);

        void reloadFromSystemProperties();

        /** Writes this setting's current value into the given config at {@link #tomlPath()}. */
        void writeToFile(CommentedConfig config);
    }

    public static final class BooleanSetting implements RuntimeSetting<Boolean> {
        private final String key;
        private final String tomlPath;
        private final boolean defaultValue;
        private volatile boolean value;

        private BooleanSetting(String key, String tomlPath, boolean defaultValue) {
            this.key = key;
            this.tomlPath = tomlPath;
            this.defaultValue = defaultValue;
            this.value = resolveInitial();
            SETTINGS.add(this);
        }

        @Override
        public String key() {
            return key;
        }

        @Override
        public String tomlPath() {
            return tomlPath;
        }

        @Override
        public Boolean defaultValue() {
            return defaultValue;
        }

        @Override
        public Boolean get() {
            return value;
        }

        public boolean value() {
            return value;
        }

        @Override
        public void set(Boolean value) {
            this.value = value != null ? value : defaultValue;
        }

        @Override
        public void reloadFromSystemProperties() {
            set(Boolean.parseBoolean(System.getProperty(key, Boolean.toString(defaultValue))));
        }

        @Override
        public void writeToFile(CommentedConfig config) {
            config.set(tomlPath, value);
        }

        private boolean resolveInitial() {
            String prop = System.getProperty(key);
            if (prop != null) {
                return Boolean.parseBoolean(prop.trim());
            }
            Boolean fromFile = fileBoolean(tomlPath);
            return fromFile != null ? fromFile : defaultValue;
        }
    }

    public static final class IntSetting implements RuntimeSetting<Integer> {
        private final String key;
        private final String tomlPath;
        private final int defaultValue;
        private final IntUnaryOperator sanitize;
        private volatile int value;

        private IntSetting(String key, String tomlPath, int defaultValue, IntUnaryOperator sanitize) {
            this.key = key;
            this.tomlPath = tomlPath;
            this.defaultValue = sanitize.applyAsInt(defaultValue);
            this.sanitize = sanitize;
            this.value = resolveInitial();
            SETTINGS.add(this);
        }

        @Override
        public String key() {
            return key;
        }

        @Override
        public String tomlPath() {
            return tomlPath;
        }

        @Override
        public Integer defaultValue() {
            return defaultValue;
        }

        @Override
        public Integer get() {
            return value;
        }

        public int value() {
            return value;
        }

        @Override
        public void set(Integer value) {
            this.value = sanitize.applyAsInt(value != null ? value : defaultValue);
        }

        @Override
        public void reloadFromSystemProperties() {
            String prop = System.getProperty(key);
            if (prop == null) {
                this.value = defaultValue;
                return;
            }
            try {
                this.value = sanitize.applyAsInt(Integer.parseInt(prop.trim()));
            } catch (NumberFormatException e) {
                this.value = defaultValue;
            }
        }

        @Override
        public void writeToFile(CommentedConfig config) {
            config.set(tomlPath, value);
        }

        private int resolveInitial() {
            String prop = System.getProperty(key);
            if (prop != null) {
                try {
                    return sanitize.applyAsInt(Integer.parseInt(prop.trim()));
                } catch (NumberFormatException e) {
                    return defaultValue;
                }
            }
            Number fromFile = fileNumber(tomlPath);
            return fromFile != null ? sanitize.applyAsInt(fromFile.intValue()) : defaultValue;
        }
    }

    public static final class FloatSetting implements RuntimeSetting<Float> {
        private final String key;
        private final String tomlPath;
        private final float defaultValue;
        // Maps a raw external number (system property, file, or the constructor's raw default) into the
        // stored value domain, e.g. degrees -> radians.
        private final DoubleUnaryOperator inputTransform;
        // Inverse of inputTransform: maps the stored value domain back to the raw external domain (e.g.
        // radians -> degrees) for writeToFile, so a value round-trips through the file unchanged instead
        // of having inputTransform re-applied to an already-transformed number on the next load.
        private final DoubleUnaryOperator outputTransform;
        // Idempotent guard on a value-domain number (clamp / finite check); safe to apply to any source.
        private final DoubleUnaryOperator valueClamp;
        private volatile float value;

        private FloatSetting(String key, String tomlPath, float rawDefault, DoubleUnaryOperator inputTransform,
                             DoubleUnaryOperator outputTransform, DoubleUnaryOperator valueClamp) {
            this.key = key;
            this.tomlPath = tomlPath;
            this.inputTransform = inputTransform;
            this.outputTransform = outputTransform;
            this.valueClamp = valueClamp;
            this.defaultValue = (float) valueClamp.applyAsDouble(inputTransform.applyAsDouble(rawDefault));
            this.value = resolveInitial();
            SETTINGS.add(this);
        }

        @Override
        public String key() {
            return key;
        }

        @Override
        public String tomlPath() {
            return tomlPath;
        }

        @Override
        public Float defaultValue() {
            return defaultValue;
        }

        @Override
        public Float get() {
            return value;
        }

        public float value() {
            return value;
        }

        @Override
        public void set(Float value) {
            if (value == null) {
                this.value = defaultValue;
            } else {
                this.value = (float) valueClamp.applyAsDouble(inputTransform.applyAsDouble(value));
            }
        }

        @Override
        public void reloadFromSystemProperties() {
            String prop = System.getProperty(key);
            if (prop == null) {
                this.value = defaultValue;
                return;
            }
            try {
                this.value = (float) valueClamp.applyAsDouble(inputTransform.applyAsDouble(Double.parseDouble(prop.trim())));
            } catch (NumberFormatException e) {
                this.value = defaultValue;
            }
        }

        @Override
        public void writeToFile(CommentedConfig config) {
            // Round-trip through Float.toString() so the file gets the shortest decimal that reproduces
            // this float (e.g. "0.6"), not outputTransform's raw double with float's binary noise spelled
            // out to 17 digits (e.g. 0.6000000487130328).
            float raw = (float) outputTransform.applyAsDouble(value);
            config.set(tomlPath, Double.parseDouble(Float.toString(raw)));
        }

        private float resolveInitial() {
            String prop = System.getProperty(key);
            if (prop != null) {
                try {
                    return (float) valueClamp.applyAsDouble(inputTransform.applyAsDouble(Double.parseDouble(prop.trim())));
                } catch (NumberFormatException e) {
                    return defaultValue;
                }
            }
            Number fromFile = fileNumber(tomlPath);
            if (fromFile == null) {
                return defaultValue;
            }
            return (float) valueClamp.applyAsDouble(inputTransform.applyAsDouble(fromFile.doubleValue()));
        }
    }

    public static final class StringSetting implements RuntimeSetting<String> {
        private final String key;
        private final String tomlPath;
        private final String defaultValue;
        private final UnaryOperator<String> sanitize;
        private volatile String value;

        private StringSetting(String key, String tomlPath, String defaultValue, UnaryOperator<String> sanitize) {
            this.key = key;
            this.tomlPath = tomlPath;
            this.defaultValue = sanitize.apply(defaultValue);
            this.sanitize = sanitize;
            this.value = resolveInitial();
            SETTINGS.add(this);
        }

        @Override
        public String key() {
            return key;
        }

        @Override
        public String tomlPath() {
            return tomlPath;
        }

        @Override
        public String defaultValue() {
            return defaultValue;
        }

        @Override
        public String get() {
            return value;
        }

        @Override
        public void set(String value) {
            this.value = sanitize.apply(value != null ? value : defaultValue);
        }

        @Override
        public void reloadFromSystemProperties() {
            set(System.getProperty(key, defaultValue));
        }

        @Override
        public void writeToFile(CommentedConfig config) {
            config.set(tomlPath, value);
        }

        private String resolveInitial() {
            String prop = System.getProperty(key);
            if (prop != null) {
                return sanitize.apply(prop);
            }
            String fromFile = fileString(tomlPath);
            return sanitize.apply(fromFile != null ? fromFile : defaultValue);
        }
    }

    public static final class OptionalStringSetting implements RuntimeSetting<String> {
        private final String key;
        private final String tomlPath;
        private volatile String value;

        private OptionalStringSetting(String key, String tomlPath) {
            this.key = key;
            this.tomlPath = tomlPath;
            this.value = resolveInitial();
            SETTINGS.add(this);
        }

        @Override
        public String key() {
            return key;
        }

        @Override
        public String tomlPath() {
            return tomlPath;
        }

        @Override
        public String defaultValue() {
            return null;
        }

        @Override
        public String get() {
            return value;
        }

        @Override
        public void set(String value) {
            this.value = value;
        }

        @Override
        public void reloadFromSystemProperties() {
            this.value = System.getProperty(key);
        }

        @Override
        public void writeToFile(CommentedConfig config) {
            if (value != null) {
                config.set(tomlPath, value);
            } else {
                config.remove(tomlPath);
            }
        }

        private String resolveInitial() {
            String prop = System.getProperty(key);
            return prop != null ? prop : fileString(tomlPath);
        }
    }

    public static final class Rt {
        public static final BooleanSetting ENABLED = bool("caustica.rt", "enabled", true);
        public static final IntSetting WORKER_THREADS =
                intAtLeast("caustica.rt.workerThreads", "worker-threads", defaultWorkerThreads(), 1);

        private Rt() {
        }

        public static final class Composite {
            public static final BooleanSetting DEPTH_OF_FIELD =
                    bool("caustica.rt.depthOfField", "composite.depth-of-field", false);
            public static final FloatSetting DEPTH_OF_FIELD_STRENGTH =
                    clampedFloat("caustica.rt.depthOfFieldStrength", "composite.depth-of-field-strength", 1.0f, 0.0f, 2.0f);
            public static final IntSetting DEPTH_OF_FIELD_QUALITY =
                    clampedInt("caustica.rt.depthOfFieldQuality", "composite.depth-of-field-quality", 1, 0, 5);
            public static final IntSetting DEPTH_OF_FIELD_MODE =
                    clampedInt("caustica.rt.depthOfFieldMode", "composite.depth-of-field-mode", 0, 0, 1);
            public static final IntSetting DEPTH_OF_FIELD_FOCUS_DISTANCE =
                    clampedInt("caustica.rt.depthOfFieldFocusDistance", "composite.depth-of-field-focus-distance", 96, 8, 512);
            public static final IntSetting DEPTH_OF_FIELD_FOREGROUND_QUALITY =
                    clampedInt("caustica.rt.depthOfFieldForegroundQuality", "composite.depth-of-field-foreground-quality", 1, 0, 5);
            public static final FloatSetting ZOOM_FACTOR =
                    clampedFloat("caustica.rt.zoomFactor", "composite.zoom-factor", 3.0f, 1.0f, 8.0f);
            public static final BooleanSetting PARALLAX =
                    bool("caustica.rt.parallax", "composite.parallax", true);
            public static final FloatSetting PARALLAX_DEPTH =
                    clampedFloat("caustica.rt.parallaxDepth", "composite.parallax-depth", 1.0f, 0.0f, 2.0f);
            public static final IntSetting DEBUG_VIEW = intValue("caustica.rt.debugView", "composite.debug-view", 0);
            public static final IntSetting SPP = intAtLeast("caustica.rt.spp", "composite.spp", 1, 1);
            public static final IntSetting MAX_BOUNCES =
                    clampedInt("caustica.rt.maxBounces", "composite.max-bounces", 4, 2, 8);
            public static final BooleanSetting WATER_WAVES =
                    bool("caustica.rt.waterWaves", "composite.water-waves", true);
            public static final FloatSetting WATER_WAVE_STRENGTH =
                    clampedFloat("caustica.rt.waterWaveStrength", "composite.water-wave-strength", 1.0f, 0.0f, 2.0f);
            public static final BooleanSetting WATER_FOG =
                    bool("caustica.rt.waterFog", "composite.water-fog", true);
            public static final FloatSetting WATER_FOG_STRENGTH =
                    clampedFloat("caustica.rt.waterFogStrength", "composite.water-fog-strength", 1.0f, 0.0f, 2.0f);
            public static final FloatSetting WATER_TRANSPARENCY =
                    clampedFloat("caustica.rt.waterTransparency", "composite.water-transparency", 1.0f, 0.0f, 2.0f);
            public static final BooleanSetting AIR_FOG =
                    bool("caustica.rt.airFog", "composite.air-fog", true);
            public static final FloatSetting AIR_FOG_STRENGTH =
                    clampedFloat("caustica.rt.airFogStrength", "composite.air-fog-strength", 1.0f, 0.0f, 2.0f);
            // Fog density = strength x base x weather x time of day. These expose the factors that used
            // to be constants in the shader, so the shape of the haze is tunable in-game rather than by
            // editing and rebuilding.
            public static final FloatSetting AIR_FOG_BASE =
                    clampedFloat("caustica.rt.airFogBase", "composite.air-fog-base", 1.0f, 0.0f, 4.0f);
            public static final FloatSetting AIR_FOG_RAIN =
                    clampedFloat("caustica.rt.airFogRain", "composite.air-fog-rain", 1.5f, 0.0f, 4.0f);
            public static final FloatSetting AIR_FOG_THUNDER =
                    clampedFloat("caustica.rt.airFogThunder", "composite.air-fog-thunder", 1.5f, 0.0f, 4.0f);
            public static final FloatSetting AIR_FOG_MORNING =
                    clampedFloat("caustica.rt.airFogMorning", "composite.air-fog-morning", 1.0f, 0.0f, 3.0f);
            public static final FloatSetting AIR_FOG_NOON =
                    clampedFloat("caustica.rt.airFogNoon", "composite.air-fog-noon", 0.18f, 0.0f, 1.5f);
            public static final BooleanSetting VOLUMETRIC_LIGHT =
                    bool("caustica.rt.volumetricLight", "composite.volumetric-light", true);
            public static final FloatSetting VOLUMETRIC_ABSORPTION =
                    clampedFloat("caustica.rt.volumetricAbsorption", "composite.volumetric-absorption", 1.0f, 0.0f, 2.0f);
            public static final BooleanSetting PLANAR_CLOUDS =
                    bool("caustica.rt.planarClouds", "composite.planar-clouds", true);
            public static final IntSetting CLOUD_QUALITY =
                    clampedInt("caustica.rt.cloudQuality", "composite.cloud-quality", 1, 0, 2);
            public static final IntSetting CLOUD_LAYERS =
                    clampedInt("caustica.rt.cloudLayers", "composite.cloud-layers", 2, 1, 2);
            public static final IntSetting CLOUD_SAMPLES =
                    clampedInt("caustica.rt.cloudSamples", "composite.cloud-samples", 24, 8, 64);
            public static final FloatSetting CLOUD_COVERAGE =
                    clampedFloat("caustica.rt.cloudCoverage", "composite.cloud-coverage", 1.0f, 0.0f, 2.0f);
            public static final FloatSetting CLOUD_DENSITY =
                    clampedFloat("caustica.rt.cloudDensity", "composite.cloud-density", 1.0f, 0.0f, 2.0f);
            public static final FloatSetting CLOUD_SPEED =
                    clampedFloat("caustica.rt.cloudSpeed", "composite.cloud-speed", 1.0f, 0.0f, 2.0f);
            public static final FloatSetting SUN_ANGULAR_RADIUS =
                    radians("caustica.rt.sunAngularRadius", "composite.sun-angular-radius-deg", 0.6f);
            public static final FloatSetting MOON_ANGULAR_RADIUS =
                    radians("caustica.rt.moonAngularRadius", "composite.moon-angular-radius-deg", 1.5f);
            public static final FloatSetting SUN_NOON_SOUTH_TILT =
                    radians("caustica.rt.sunNoonSouthDeg", "composite.sun-noon-south-tilt-deg", 30.0f);
            public static final FloatSetting JITTER_SIGN_X =
                    finiteFloat("caustica.rt.jitterSignX", "composite.jitter-sign-x", 1.0f);
            public static final FloatSetting JITTER_SIGN_Y =
                    finiteFloat("caustica.rt.jitterSignY", "composite.jitter-sign-y", -1.0f);

            private Composite() {
            }
        }

        /**
         * Volumetric cloud layer (clouds.slang). Ported from 0.1.0 together with the shader, so the toml
         * keys, defaults and ranges are the ones that build shipped: a config file written for it keeps
         * meaning the same thing here. The old {@code composite.planar-clouds} / {@code composite.cloud-*}
         * keys are kept below for compatibility but no longer drive anything.
         */
        public static final class Clouds {
            /** Quality presets in cap order. Index 0 is the off switch, and the arrays in RtComposite use
             *  the same index, so the list order is load-bearing. */
            public static final List<String> QUALITY_PRESETS = List.of("off", "low", "medium", "high", "ultra");
            public static final BooleanSetting ENABLED =
                    bool("caustica.rt.clouds", "clouds.enabled", true);
            public static final StringSetting QUALITY =
                    string("caustica.rt.cloudQuality", "clouds.quality", "medium",
                            s -> QUALITY_PRESETS.contains(s) ? s : "medium");
            public static final FloatSetting COVERAGE =
                    clampedFloat("caustica.rt.cloudCoverage", "clouds.coverage", 0.35f, 0.0f, 1.0f);
            public static final FloatSetting DENSITY =
                    clampedFloat("caustica.rt.cloudDensity", "clouds.density", 0.35f, 0.0f, 2.0f);
            public static final IntSetting BASE_ALTITUDE =
                    clampedInt("caustica.rt.cloudBaseAltitude", "clouds.base-altitude", 320, -64, 4096);
            public static final IntSetting THICKNESS =
                    clampedInt("caustica.rt.cloudThickness", "clouds.thickness", 240, 0, 2048);
            public static final FloatSetting DETAIL =
                    clampedFloat("caustica.rt.cloudDetail", "clouds.detail", 0.45f, 0.0f, 1.0f);
            public static final IntSetting STEPS =
                    clampedInt("caustica.rt.cloudSteps", "clouds.steps", 32, 0, 256);
            public static final FloatSetting WIND_SPEED =
                    clampedFloat("caustica.rt.cloudWindSpeed", "clouds.wind-speed", 6.0f, 0.0f, 64.0f);
            public static final FloatSetting WEATHER_RESPONSE =
                    clampedFloat("caustica.rt.cloudWeatherResponse", "clouds.weather-response", 1.0f, 0.0f, 2.0f);
            public static final FloatSetting LIGHTNING =
                    clampedFloat("caustica.rt.cloudLightning", "clouds.lightning", 0.9f, 0.0f, 1.0f);
            public static final FloatSetting JITTER =
                    clampedFloat("caustica.rt.cloudJitter", "clouds.jitter", 0.5f, 0.0f, 1.0f);

            private Clouds() {
            }
        }

        public static final class Terrain {
            // External keys retain their historical "per-tick" names for config compatibility; terrain
            // streaming is render-pass driven and these Java names reflect the actual scheduling unit.
            public static final IntSetting ASYNC_DISPATCH_PER_PASS =
                    intAtLeast("caustica.rt.asyncDispatchPerTick", "terrain.async-dispatch-per-tick", 32, 0);
            public static final IntSetting COMPLETION_RESULTS_PER_PASS =
                    intAtLeast("caustica.rt.sectionResultsPerTick", "terrain.section-results-per-tick", 32, 0);
            public static final IntSetting MAX_INFLIGHT_SECTIONS =
                    intAtLeast("caustica.rt.maxInflightSections", "terrain.max-inflight-sections", 32, 0);
            public static final IntSetting SECTION_TABLE_INITIAL_CAPACITY =
                    intAtLeast("caustica.rt.sectionTableInitialCapacity", "terrain.section-table-initial-capacity", 512, 1);
            public static final IntSetting REBASE_DISTANCE_BLOCKS =
                    intAtLeast("caustica.rt.rebaseDistanceBlocks", "terrain.rebase-distance-blocks", 128, 0);
            public static final BooleanSetting BLAS_COMPACTION =
                    bool("caustica.rt.blasCompaction", "terrain.blas-compaction", true);

            private Terrain() {
            }
        }

        /** RIS block-emitter lights. {@code ris-candidates = 0} disables everything. */
        public static final class Lights {
            public static final IntSetting RIS_CANDIDATES =
                    intAtLeast("caustica.rt.risCandidates", "lights.ris-candidates", 8, 0);
            public static final FloatSetting MIN_FILL_RATIO =
                    finiteFloat("caustica.rt.lightMinFillRatio", "lights.min-fill-ratio", 0.25f);
            public static final BooleanSetting STATS = bool("caustica.rt.lightStats", "lights.stats", false);
            public static final BooleanSetting DUMP = bool("caustica.rt.lightDump", "lights.dump", false);
            public static final IntSetting DUMP_RADIUS =
                    intAtLeast("caustica.rt.lightDumpRadius", "lights.dump-radius", 12, 1);

            private Lights() {
            }
        }

        public static final class Omm {
            public static final BooleanSetting ENABLED = bool("caustica.rt.omm", "omm.enabled", true);
            public static final IntSetting SUBDIVISION =
                    clampedInt("caustica.rt.ommSubdivision", "omm.subdivision", 4, 0, 6);
            public static final BooleanSetting STATS = bool("caustica.rt.ommStats", "omm.stats", false);

            private Omm() {
            }
        }

        public static final class Entities {
            public static final BooleanSetting ENABLED = bool("caustica.rt.entities", "entities.enabled", true);
            public static final BooleanSetting PARTICLES_ENABLED =
                    bool("caustica.rt.particles", "particles.enabled", true);
            public static final BooleanSetting GLOW_ENABLED =
                    bool("caustica.rt.glow", "entities.glow.enabled", true);
            public static final BooleanSetting NAME_TAGS_ENABLED =
                    bool("caustica.rt.nameTags", "entities.name-tags.enabled", true);
            /** Debug-only: render each model submission twice and require bitwise-identical CPU captures. */
            public static final BooleanSetting CAPTURE_PARITY =
                    bool("caustica.rt.entityCaptureParity", "entities.debug.capture-parity", false);
            public static final IntSetting MAX_ORDINARY_ENTITIES =
                    intAtLeast("caustica.rt.maxOrdinaryEntities", "entities.max-ordinary-entities", 1024, 0);
            public static final IntSetting MAX_BLOCK_ENTITIES =
                    intAtLeast("caustica.rt.maxBlockEntities", "entities.block-entities.max-entities", 1024, 0);
            public static final IntSetting MAX_PARTICLES =
                    intAtLeast("caustica.rt.maxParticles", "particles.max-particles", 1024, 0);
            public static final IntSetting BE_VIEW_CHUNKS =
                    intAtLeast("caustica.rt.beViewChunks", "entities.block-entities.view-chunks", 8, 0);
            public static final IntSetting BE_BUILDS_PER_FRAME =
                    intAtLeast("caustica.rt.beBuildsPerFrame", "entities.block-entities.builds-per-frame", 64, 0);
            public static final BooleanSetting REFIT_ENABLED =
                    bool("caustica.rt.entityRefit", "entities.refit.enabled", true);

            private Entities() {
            }

            public static int maxEntities() {
                return Math.addExact(Math.addExact(
                        MAX_ORDINARY_ENTITIES.value(), MAX_BLOCK_ENTITIES.value()), MAX_PARTICLES.value());
            }

            public static int entityListCapacity() {
                return Math.max(16, maxEntities());
            }

            public static int entityMapCapacity() {
                // Fastutil expected-size constructors apply their own load-factor headroom.
                return Math.max(16, MAX_ORDINARY_ENTITIES.value());
            }
        }

        public static final class EntityTextures {
            public static final IntSetting MAX_TEXTURES =
                    intAtLeast("caustica.rt.maxEntityTextures", "entities.textures.max-textures", 256, 1);
            public static final BooleanSetting PBR = bool("caustica.rt.entityPbr", "entities.textures.pbr", true);

            private EntityTextures() {
            }
        }

        public static final class Overlay {
            public static final BooleanSetting BLOCK_OUTLINE_ENABLED =
                    bool("caustica.rt.blockOutline", "overlay.block-outline.enabled", true);

            private Overlay() {
            }
        }

        public static final class DlssRr {
            public static final BooleanSetting ENABLED = bool("caustica.rt.dlssRr", "dlss-rr.enabled", true);
            public static final IntSetting PRESET = intValue("caustica.rt.dlssRr.preset", "dlss-rr.preset", 0);
            public static final IntSetting QUALITY = intValue("caustica.rt.dlssRr.quality", "dlss-rr.quality", 0);

            private DlssRr() {
            }
        }

        /** DLSS Frame Generation. Default off; gated additionally by hardware/driver availability. */
        public static final class Fg {
            public static final BooleanSetting ENABLED = bool("caustica.rt.fg", "frame-generation.enabled", false);
            public static final IntSetting MULTI_FRAME_COUNT =
                    intAtLeast("caustica.rt.fg.multiFrameCount", "frame-generation.multi-frame-count", 1, 1);

            private Fg() {
            }
        }

        /**
         * NVIDIA Reflex ({@code VK_NV_low_latency2}). Default off; gated additionally by device support.
         * Phase 0 (extension + capability probe only, see {@code RtDeviceBringup}/{@code RtReflex}) — the
         * per-frame sleep call + latency markers + the swapchain {@code VkSwapchainLatencyCreateInfoNV} the
         * spec requires for {@code vkSetLatencySleepModeNV} to take effect land in a later phase.
         */
        public static final class Reflex {
            public static final BooleanSetting ENABLED = bool("caustica.rt.reflex", "reflex.enabled", false);
            public static final BooleanSetting LOW_LATENCY_BOOST =
                    bool("caustica.rt.reflex.boost", "reflex.low-latency-boost", false);
            public static final IntSetting MINIMUM_INTERVAL_US =
                    intAtLeast("caustica.rt.reflex.minIntervalUs", "reflex.minimum-interval-us", 0, 0);

            private Reflex() {
            }
        }

        public static final class Exposure {
            public static final StringSetting MODE =
                    string("caustica.rt.exposure.mode", "exposure.mode", "auto", Exposure::sanitizeMode);
            public static final FloatSetting MANUAL_EV =
                    finiteFloat("caustica.rt.exposure.manualEv", "exposure.manual-ev", 0.0f);
            public static final FloatSetting KEY = exposureScale("caustica.rt.exposure.key", "exposure.key", 0.18f);
            public static final FloatSetting MIN_EV =
                    finiteFloat("caustica.rt.exposure.minEv", "exposure.min-ev", -1.5f);
            public static final FloatSetting MAX_EV =
                    finiteFloat("caustica.rt.exposure.maxEv", "exposure.max-ev", 4.0f);
            public static final FloatSetting ADAPT_UP =
                    exposureScale("caustica.rt.exposure.adaptUp", "exposure.adapt-up", 0.12f);
            public static final FloatSetting ADAPT_DOWN =
                    exposureScale("caustica.rt.exposure.adaptDown", "exposure.adapt-down", 0.35f);

            private Exposure() {
            }

            public static float minEv() {
                return Math.min(MIN_EV.value(), MAX_EV.value());
            }

            public static float maxEv() {
                return Math.max(MIN_EV.value(), MAX_EV.value());
            }

            public static float clampScale(float value) {
                return Math.clamp(value, 1.0e-4f, 1.0e4f);
            }

            private static String sanitizeMode(String value) {
                if ("auto".equalsIgnoreCase(value)) {
                    return "auto";
                }
                if ("manual".equalsIgnoreCase(value)) {
                    return "manual";
                }
                return "auto";
            }
        }

        /** Render-frame timing + hitch logging. See {@code RtFrameStats}. */
        public static final class FrameStats {
            public static final BooleanSetting ENABLED = bool("caustica.rt.frameStats", "frame-stats.enabled", false);

            private FrameStats() {
            }
        }

        /** Startup Vulkan inventory + {@code VK_EXT_device_fault} reporting on device loss. See {@code VulkanDiagnostics}. */
        public static final class Diagnostics {
            /** Heavy driver-side crash diagnostics: vendor diagnostics-config extensions (shader debug
             * info, resource tracking, automatic checkpoints, shader error reporting) and the
             * {@code deviceFaultVendorBinary} feature (vendor-format crash dump on device loss). Off by
             * default: measured ~10x BLAS build time / -20% fps when enabled. Plain {@code deviceFault}
             * reporting (fault addresses + vendor records) is always on and unaffected. Turn on only
             * while chasing a live device-loss crash. */
            public static final BooleanSetting HEAVY_CRASH_DIAGNOSTICS =
                    bool("caustica.rt.heavyCrashDiagnostics", "diagnostics.heavy-crash-diagnostics", false);

            private Diagnostics() {
            }
        }

        /**
         * HDR display output. When enabled the swapchain is created in PQ (ST.2084/HDR10 — the display-ready
         * encoding both HDR10 swapchains and DLSS Frame Generation require; whatever pixel format the surface
         * pairs with that color space, commonly a 10-bit UNORM), falling back to SDR if the surface doesn't
         * advertise it. The nit values drive the scene-HDR → display mapping: SDR paper white maps to
         * {@code paperWhiteNits}, and highlights roll off toward {@code peakNits}.
         */
        public static final class Hdr {
            public static final BooleanSetting ENABLED = bool("caustica.rt.hdr", "hdr.enabled", false);
            public static final FloatSetting PAPER_WHITE_NITS =
                    clampedFloat("caustica.rt.hdr.paperWhiteNits", "hdr.paper-white-nits", 200.0f, 80.0f, 500.0f);
            public static final FloatSetting PEAK_NITS =
                    clampedFloat("caustica.rt.hdr.peakNits", "hdr.peak-nits", 1000.0f, 80.0f, 5000.0f);

            // Snapshot of ENABLED as resolved at startup (system property / config file), before any
            // in-session edit from the options screen. The swapchain's pixel format (PQ vs SDR) is fixed
            // at surface-creation time, so flipping ENABLED later cannot change what's actually presented
            // until a restart — every runtime/rendering check reads this frozen value via enabled(),
            // never ENABLED directly, so the live toggle is a no-op for the current session.
            private static final boolean ENABLED_AT_STARTUP = ENABLED.value();

            private Hdr() {
            }

            /** Whether the HDR display path (world HDR + PQ swapchain + UI overlay) is active this session. */
            public static boolean enabled() {
                return ENABLED_AT_STARTUP;
            }

            /** Whether {@link #ENABLED} has been changed since startup and needs a restart to take effect. */
            public static boolean pendingRestart() {
                return ENABLED.value() != ENABLED_AT_STARTUP;
            }

            /** Absolute nits SDR paper white maps to in the PQ encode (ST.2084 is referenced to 10000 nits). */
            public static float paperWhiteNits() {
                return PAPER_WHITE_NITS.value();
            }

            /** Highlight headroom above paper white, in paper-white-referred units ({@code >= 1}). */
            public static float headroom() {
                return Math.max(1.0f, PEAK_NITS.value() / Math.max(1.0f, PAPER_WHITE_NITS.value()));
            }
        }
    }

    public static final class Ngx {
        public static final OptionalStringSetting PATH = optionalString("caustica.ngx.path", "ngx.path");

        private Ngx() {
        }
    }

    private static BooleanSetting bool(String key, String tomlPath, boolean fallback) {
        return new BooleanSetting(key, tomlPath, fallback);
    }

    private static StringSetting string(String key, String tomlPath, String fallback, UnaryOperator<String> sanitize) {
        return new StringSetting(key, tomlPath, fallback, sanitize);
    }

    private static OptionalStringSetting optionalString(String key, String tomlPath) {
        return new OptionalStringSetting(key, tomlPath);
    }

    private static IntSetting intValue(String key, String tomlPath, int fallback) {
        return new IntSetting(key, tomlPath, fallback, v -> v);
    }

    private static IntSetting intAtLeast(String key, String tomlPath, int fallback, int min) {
        return new IntSetting(key, tomlPath, fallback, v -> Math.max(min, v));
    }

    private static IntSetting clampedInt(String key, String tomlPath, int fallback, int min, int max) {
        return new IntSetting(key, tomlPath, fallback, v -> Math.clamp(v, min, max));
    }

    private static FloatSetting finiteFloat(String key, String tomlPath, float fallback) {
        return new FloatSetting(key, tomlPath, fallback, v -> v, v -> v, v -> Double.isFinite(v) ? v : fallback);
    }

    private static FloatSetting exposureScale(String key, String tomlPath, float fallback) {
        return new FloatSetting(key, tomlPath, fallback, v -> v, v -> v, v -> Math.clamp(v, 1.0e-4, 1.0e4));
    }

    private static FloatSetting clampedFloat(String key, String tomlPath, float fallback, float min, float max) {
        return new FloatSetting(key, tomlPath, fallback, v -> v, v -> v, v -> Math.clamp(v, min, max));
    }

    private static FloatSetting radians(String key, String tomlPath, float fallbackDegrees) {
        return new FloatSetting(key, tomlPath, fallbackDegrees, Math::toRadians, Math::toDegrees, v -> Double.isFinite(v) ? v : 0.0);
    }

    private static int defaultWorkerThreads() {
        return Math.clamp(Runtime.getRuntime().availableProcessors() / 2, 1, 4);
    }
}
