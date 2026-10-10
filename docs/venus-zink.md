# Venus zink investigation state

Guest: NixOS aarch64-linux under QEMU on Apple Silicon. Guest Mesa Venus ->
virtio-gpu -> host virglrenderer (UTM fork) -> MoltenVK (UTM fork) -> Metal.
Runner: `hosts/macbook/venus-vm/default.nix`.
Test: `nix build --file hosts/macbook/venus-vm run --no-link --print-out-paths`,
then `VENUS_OUT=<dir> TMPDIR=<dir> <run>/bin/venus-vm`. Writes desktop-test.txt,
vkcube-N.png, es2gears-*.png, vulkaninfo-full.txt, dumpNN.spv, journal.txt.

Prior art: transcript `ca54106b` (claude, ~Oct 10-11). Fixed vkcube
resize deadlock via mesa-wsi-wl-retired-fifo-wait.patch (5/5 vkcube at ~9.1s,
holds across all runs below). Pushed as develop 33c8d34d.

## Commits on develop (all pushed)

- 90c79a3e: two crash guards + zink-run tracing (VN_DEBUG=result,
  ZINK_DEBUG=spirv, dumpNN.spv copied to /out).
- aa75215c: GS/SPIR-V fixes + host validation (VKR_DEBUG=validate,
  VK_LAYER_PATH wired in run wrapper). Test scaffolding kept on purpose:
  zero output when healthy.

Patches in hosts/macbook/venus-vm/ (all against Mesa 26.2.2 / UTM pins):

- mesa-zink-discard-null.patch: kopper invalidates depth/stencil through
  glthread on every swap; on Venus the attachment has a renderbuffer with
  Complete=true but texture==NULL -> SEGV in discard_attachments. Guard +
  log. Log FIRES every zink run: depth resource genuinely missing.
- mesa-venus-getpipelinecachedata-null-ring.patch: zink disk-cache thread
  ("zcq") calls vkGetPipelineCacheData with no TLS ring; vn_get_target_ring
  returns NULL and vn_GetPipelineCacheData passed it to submit (its three
  pipeline-create siblings check). Same check added. Behavior verified:
  SEGV -> ordered path.
- mesa-venus-sync-pipeline-create.patch: force sync graphics-pipeline
  creates. Async create on another ring reached the host after the bind;
  host failed lookup (object 131, type 19 = Pipeline) -> CS wedge -> guest
  ring abort. Now the guest reports the real error instead.
- mesa-zink-pv-primitive-id-dedup.patch: provoking-vertex lowering loaded
  PrimitiveId as sysval although the generated passthrough GS already
  carried it as a varying -> two BuiltIn-PrimitiveId inputs (VUID-09658).
  Reuse the varying. Dumped GS validates clean with current spirv-val.
- spirv-cross-robust-size-index.patch (UTM SPIRV-Cross 939b40b):
  robustness2 path declares pointer-typed per-descriptor size name for an
  arrayed descriptor but get_robust_buffer_array_length used it as scalar.
  zink wraps a lone UBO in struct[1]. Fix indexes [0] for literal
  single-element arrays. Proven locally: unpatched UTM binary emits bare
  `BufferSize / 4u`, patched emits `[0]`.

## Causal chain, current end

1. Mesa defaults ProvokingVertex=LAST (_mesa_init_lighting). Venus lacks
   EXT_provoking_vertex (Metal limitation), so zink lowers EVERY draw
   through a generated passthrough GS (lower_pv_mode).
2. That GS compiled to invalid SPIR-V (above) -> rejected. FIXED, GS valid.
3. Its UBO access compiled to invalid MSL (above) -> Metal rejects with
   `invalid operands ('const constant uint *' and 'unsigned int')` on
   `uniform_0_32_1BufferSize / 4u`. FIXED in fork, verified locally.
4. Host STILL reports `Shader library compile failed / Vertex shader
   function could not be compiled` (qemu9uphn.log pattern; recheck latest).
   Remaining VS suspects: uniform-block layout (needs
   uniformBufferStandardLayout; device reports true, zink never queries it)
   or FloatControls2 / SPIR-V 1.6 handling in pinned SPIRV-Cross.
5. Separately: window depth texture is NULL (guard log fires) although
   eglut asks EGL_DEPTH_SIZE=1. vulkaninfo memory usability lists
   D16/D32F/S8/D32S8 but NO 24-bit depth on Venus. kopper_allocate_textures
   calls resource_create with stvis format and no fallback (zink_get_format
   HAS a D24->D32S8 fallback; the kopper path may not reach it). Even with
   pipelines fixed, gears may draw blank until depth allocates.

## Rejected hypotheses (do not retry)

- no_gpl (VN_DEBUG=result,no_gpl): identical failure, same object id.
- fb==NULL vs texture==NULL for the discard crash: the texture-NULL log
  fires; fb guard never fired.
- Upstream Mesa already fixed: searched, nothing found.

## Device facts (guest vulkaninfo-full.txt)

- Virtio-GPU Venus (Apple M5 Pro), driver 26.2.2. Missing: logicOp,
  customBorderColor, depth_clip_enable (zink warns, continues).
- geometryShader=true BUT maxGeometry*=0 (UTM MoltenVK MVKDevice.mm sets
  zeros; mesh path needs private API, which is off). So no GS can ever
  compile -> the generated GS must go away (skip when no FS inputs are
  flat: then provoking convention is unobservable) or GS limits must be
  plumbed host-side.
- uniformBufferStandardLayout=true, scalarBlockLayout=true.

## Symbolization recipe (aarch64-linux binaries on darwin)

Guest mesa ships a -debug output (copied from builder on rebuild).
`nix shell --file /etc/nixpkgs llvm --command llvm-symbolizer
--obj=<...-debug>/lib/debug/libgallium-26.2.2.so --functions=linkage
--inlining --demangle <offsets>`. Same for libvulkan_virtio.so. Used to
attribute: discard_attachments fbobject.c:5672 block; cache_put_job
zink_screen.c:388; vn_ring_submit_command vn_ring.c:708 (ring==NULL);
vn_get_target_ring NULL return.

## Next steps

R1: read the CURRENT host Metal error (post SPIRV-Cross fix). If uniform
layout: check whether zink enables uniformBufferStandardLayout at device
creation; if not, enable or pad. Then re-run.
R2: log the depth format in kopper_allocate_textures (temporary mesa_loge),
confirm 24-bit, add fallback to D32S8/D16 (mirror zink_get_format).
R3 (if GS still needed): skip generated GS when FS has no flat varyings
(flat_flags==0 in zink_program) or when device reports zero GS limits.
