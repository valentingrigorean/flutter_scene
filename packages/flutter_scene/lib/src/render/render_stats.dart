/// Steady-state rendering statistics: per-frame counters (draws, instances,
/// vertices, culling, pipeline traffic) broken down by view and by
/// render-graph pass, each pass stopwatched on the CPU.
///
/// Always on. Counting is an integer increment at the draw funnel and each
/// frame allocates a handful of small records, so the cost is negligible next
/// to the rendering it describes. GPU times stay null until the engine
/// exposes timestamp queries.
///
/// TODO(gpu-timing): fill [RenderPassStats.gpuMicros] from pass-level
/// timestamp queries once flutter/flutter#190404 lands.
library;

/// Integer counters accumulated over a frame, a view, or a pass.
/// {@category Debugging and profiling}
class RenderCounters {
  RenderCounters();

  /// Draw calls issued (instanced draws count once).
  int draws = 0;

  /// Instances drawn across all draw calls.
  int instances = 0;

  /// Vertices (or indices, for indexed draws) processed, multiplied by the
  /// instance count.
  int vertices = 0;

  /// Render items the pass considered, including hidden ones and the whole
  /// BVH subtrees the frustum rejected.
  int submitted = 0;

  /// Items a frustum test rejected: a BVH subtree skipped whole, or an
  /// instanced item with no cell in view.
  int culled = 0;

  /// Items rejected by the view's render layer mask.
  int layerMasked = 0;

  /// Items skipped because their pipeline failed to build.
  int pipelineRejected = 0;

  /// Pipeline binds that reached the backend (the encoder skips redundant
  /// binds, so this is the state-change count).
  int pipelineBinds = 0;

  /// Pipelines built this frame. A nonzero steady-state value is a hitch.
  int pipelineBuilds = 0;

  /// Bytes of per-instance world records (transform, color and custom
  /// attributes) instanced items packed again after their instances or their
  /// node changed. A change to some instances packs only their records.
  int instanceBytesPacked = 0;

  /// Bytes of the instance records that changed, written to the device once:
  /// the bytes of the rows a change names, whether or not a frame is still on
  /// the GPU.
  int instanceBytesUploaded = 0;

  /// Bytes of instance records written to the device beyond
  /// [instanceBytesUploaded]: a changed row written again into another buffer
  /// of its ring as that buffer comes free, and the rows a new buffer of a
  /// ring starts with.
  int instanceBytesReplayed = 0;

  /// Nodes the scene pre-pass visited: one per node it ticked and one per
  /// node whose render items it refreshed. Zero on a frame that changes no
  /// node while no node ticks.
  int prePassNodes = 0;

  /// Render items scanned to summarize what the scene's materials ask of a
  /// frame: their scene inputs, the display-referred surfaces and the shadow
  /// catchers. Zero on a frame that adds or removes no item and changes no
  /// material.
  int materialSummaryItems = 0;

  void reset() {
    draws = 0;
    instances = 0;
    vertices = 0;
    submitted = 0;
    culled = 0;
    layerMasked = 0;
    pipelineRejected = 0;
    pipelineBinds = 0;
    pipelineBuilds = 0;
    instanceBytesPacked = 0;
    instanceBytesUploaded = 0;
    instanceBytesReplayed = 0;
    prePassNodes = 0;
    materialSummaryItems = 0;
  }

  void copyFrom(RenderCounters other) {
    draws = other.draws;
    instances = other.instances;
    vertices = other.vertices;
    submitted = other.submitted;
    culled = other.culled;
    layerMasked = other.layerMasked;
    pipelineRejected = other.pipelineRejected;
    pipelineBinds = other.pipelineBinds;
    pipelineBuilds = other.pipelineBuilds;
    instanceBytesPacked = other.instanceBytesPacked;
    instanceBytesUploaded = other.instanceBytesUploaded;
    instanceBytesReplayed = other.instanceBytesReplayed;
    prePassNodes = other.prePassNodes;
    materialSummaryItems = other.materialSummaryItems;
  }

  /// Sets this to `now - start`.
  void setDelta(RenderCounters start, RenderCounters now) {
    draws = now.draws - start.draws;
    instances = now.instances - start.instances;
    vertices = now.vertices - start.vertices;
    submitted = now.submitted - start.submitted;
    culled = now.culled - start.culled;
    layerMasked = now.layerMasked - start.layerMasked;
    pipelineRejected = now.pipelineRejected - start.pipelineRejected;
    pipelineBinds = now.pipelineBinds - start.pipelineBinds;
    pipelineBuilds = now.pipelineBuilds - start.pipelineBuilds;
    instanceBytesPacked = now.instanceBytesPacked - start.instanceBytesPacked;
    instanceBytesUploaded =
        now.instanceBytesUploaded - start.instanceBytesUploaded;
    instanceBytesReplayed =
        now.instanceBytesReplayed - start.instanceBytesReplayed;
    prePassNodes = now.prePassNodes - start.prePassNodes;
    materialSummaryItems =
        now.materialSummaryItems - start.materialSummaryItems;
  }

  Map<String, int> toJson() => {
    'draws': draws,
    'instances': instances,
    'vertices': vertices,
    'submitted': submitted,
    'culled': culled,
    'layerMasked': layerMasked,
    'pipelineRejected': pipelineRejected,
    'pipelineBinds': pipelineBinds,
    'pipelineBuilds': pipelineBuilds,
    'instanceBytesPacked': instanceBytesPacked,
    'instanceBytesUploaded': instanceBytesUploaded,
    'instanceBytesReplayed': instanceBytesReplayed,
    'prePassNodes': prePassNodes,
    'materialSummaryItems': materialSummaryItems,
  };
}

/// The process-wide accumulator every draw funnel increments. Scopes snapshot
/// it at their boundaries and keep the delta, so attribution costs nothing
/// on the draw path.
final RenderCounters activeRenderCounters = RenderCounters();

/// One executed render-graph pass.
/// {@category Debugging and profiling}
class RenderPassStats {
  RenderPassStats({required this.name, required this.indexInGraph});

  final String name;
  final int indexInGraph;

  /// CPU time spent encoding the pass.
  int cpuMicros = 0;

  /// GPU time, or null while the engine has no timestamp queries.
  int? gpuMicros;

  final RenderCounters counters = RenderCounters();

  Map<String, Object?> toJson() => {
    'name': name,
    'index': indexInGraph,
    'cpuMicros': cpuMicros,
    if (gpuMicros != null) 'gpuMicros': gpuMicros,
    'counters': counters.toJson(),
  };
}

/// Why a static shadow tile re-renders in a frame.
/// {@category Debugging and profiling}
enum ShadowTileRefreshReason {
  /// The tile holds no content for the light's shadow parameters: its first
  /// render, or the resolution, caster faces, caster channels or cascade
  /// count changed.
  uncached,

  /// The tile's last render skipped casters whose pipelines were building.
  incomplete,

  /// `DirectionalLight.invalidateStaticShadows` was called.
  invalidated,

  /// `DirectionalLight.invalidateStaticShadowsOf` named a subtree with a
  /// static caster inside the tile's box.
  invalidatedCasters,

  /// The light turned past `DirectionalShadowCache.maxDirectionLagDegrees`.
  turned,

  /// The ideal radius left the tile's radius step.
  radius,

  /// The ideal sphere moved out of the tile's slack box.
  drift,

  /// The static caster set changed (amortized).
  casters,

  /// The light turned by less than
  /// `DirectionalShadowCache.maxDirectionLagDegrees` (amortized).
  lightStep,
}

/// One rendered view: a screen view (by index) or a render texture.
/// {@category Debugging and profiling}
class RenderViewStats {
  RenderViewStats({
    required this.viewIndex,
    required this.width,
    required this.height,
    required this.offscreen,
  });

  /// The screen view index, or -1 for a render-texture view.
  final int viewIndex;
  final int width;
  final int height;

  /// True for a render-texture view (not composited to the canvas).
  final bool offscreen;

  /// CPU time spent building and executing this view's render graph.
  int cpuMicros = 0;

  final List<RenderPassStats> passes = [];
  final RenderCounters counters = RenderCounters();

  /// Why each static shadow tile of the directional light re-rendered in
  /// this view, in cascade order; empty when every tile was reused.
  List<ShadowTileRefreshReason> shadowTileRefreshes = const [];

  Map<String, Object?> toJson() => {
    'viewIndex': viewIndex,
    'width': width,
    'height': height,
    'offscreen': offscreen,
    'cpuMicros': cpuMicros,
    'counters': counters.toJson(),
    if (shadowTileRefreshes.isNotEmpty)
      'shadowTileRefreshes': [
        for (final reason in shadowTileRefreshes) reason.name,
      ],
    'passes': [for (final pass in passes) pass.toJson()],
  };
}

/// One rendered frame: every view with its passes, plus frame totals.
/// {@category Debugging and profiling}
class RenderFrameStats {
  RenderFrameStats({required this.frameIndex, required this.timestampMicros});

  /// Frames rendered by this scene so far, counting from zero.
  final int frameIndex;

  /// Wall-clock start of the frame, microseconds since the epoch.
  final int timestampMicros;

  /// CPU time from the start of `renderViews` to its end.
  int cpuMicros = 0;

  /// Pipelines held in the cache at the end of the frame.
  int pipelineCacheSize = 0;

  final List<RenderViewStats> views = [];

  /// Totals over the whole frame, including work outside any view's graph.
  final RenderCounters counters = RenderCounters();

  Map<String, Object?> toJson() => {
    'frameIndex': frameIndex,
    'timestampMicros': timestampMicros,
    'cpuMicros': cpuMicros,
    'pipelineCacheSize': pipelineCacheSize,
    'counters': counters.toJson(),
    'views': [for (final view in views) view.toJson()],
  };
}

/// A scene's rendering statistics: the last frame and a bounded history.
///
/// Read [latest] after a frame renders. Each frame is a fresh record, so a
/// retained one never changes under the caller.
/// {@category Debugging and profiling}
class RenderStats {
  RenderStats({this.historyLength = 120});

  /// Frames to retain in [history]; zero keeps only [latest].
  int historyLength;

  /// Whether the render graph emits `dart:developer` timeline events per
  /// pass (visible in DevTools). On by default; the VM drops them in
  /// release builds.
  static bool timelineEvents = true;

  RenderFrameStats? _latest;
  final List<RenderFrameStats> _history = [];
  int _frameCount = 0;

  /// The most recently completed frame, or null before the first.
  RenderFrameStats? get latest => _latest;

  /// Completed frames, oldest first, at most [historyLength].
  List<RenderFrameStats> get history => List.unmodifiable(_history);

  /// Frames completed so far.
  int get frameCount => _frameCount;

  RenderFrameStats? _active;
  final RenderCounters _frameStart = RenderCounters();
  final Stopwatch _frameWatch = Stopwatch();

  /// The frame being rendered, or null between frames.
  RenderFrameStats? get activeFrame => _active;

  /// Opens a frame. Called by the scene at the start of `renderViews`.
  RenderFrameStats beginFrame() {
    final frame = RenderFrameStats(
      frameIndex: _frameCount,
      timestampMicros: DateTime.now().microsecondsSinceEpoch,
    );
    _active = frame;
    _frameStart.copyFrom(activeRenderCounters);
    _frameWatch
      ..reset()
      ..start();
    return frame;
  }

  /// Closes the frame opened by [beginFrame].
  void endFrame({required int pipelineCacheSize}) {
    final frame = _active;
    if (frame == null) return;
    _frameWatch.stop();
    frame.cpuMicros = _frameWatch.elapsedMicroseconds;
    frame.pipelineCacheSize = pipelineCacheSize;
    frame.counters.setDelta(_frameStart, activeRenderCounters);
    _active = null;
    _latest = frame;
    _frameCount++;
    if (historyLength <= 0) {
      _history.clear();
      return;
    }
    _history.add(frame);
    while (_history.length > historyLength) {
      _history.removeAt(0);
    }
  }

  /// Opens a view scope inside the active frame, or returns null when no
  /// frame is open (a render outside `renderViews`).
  RenderViewStats? beginView({
    required int viewIndex,
    required int width,
    required int height,
    required bool offscreen,
  }) {
    final frame = _active;
    if (frame == null) return null;
    final view = RenderViewStats(
      viewIndex: viewIndex,
      width: width,
      height: height,
      offscreen: offscreen,
    );
    frame.views.add(view);
    return view;
  }
}
