/// The numbers opaque draws are sorted by, so two draws fall in one order
/// from run to run and whether they are encoded or kept as render items.
library;

int _last = 0;

/// A number greater than each one given before. A material, a geometry and
/// a render item take one as they are made.
int nextDrawSerial() => ++_last;

final Expando<int> _pipelines = Expando('pipeline serial');
int _lastPipeline = 0;

/// The number of [pipeline] among the pipelines first asked for, which the
/// pipeline cache asks as it builds one.
int pipelineSerialOf(Object pipeline) =>
    _pipelines[pipeline] ??= ++_lastPipeline;

/// Where an opaque draw falls among the opaque draws of one render order:
/// by pipeline, then by the serial of its material. The encoder sorts by the
/// two and a kept draw is kept with this as its order.
int opaqueDrawOrderOf(Object pipeline, int materialSerial) =>
    pipelineSerialOf(pipeline) * 0x100000000 + materialSerial;
