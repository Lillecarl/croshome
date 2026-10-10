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
- 25fffc9c: this file.
- 5901a6b7: mesh-wrapper + static-vertex-input patches. Adds MVK_CONFIG_SHADER_DUMP_DIR to the
  run wrapper (full .metal per shader lands in $VENUS_OUT/mvkdump).

Local (NOT in repo, regenerable): UTM SPIRV-Cross 939b40b built in
/tmp/scx-build (static libs) + /tmp/scx-build/driver.cpp replicating
MoltenVK's conversion config (discrete set 0, robust2, mesh, UBO->buffer 1,
sizes->buffer 26). Reproduces host output byte-similar, including the bugs.
`xcrun metal -c` validates candidates (needed one
`xcodebuild -downloadComponent MetalToolchain`).
Reference clone: ~/Dynamist/SPIRV-Cross @ 939b40b (geometry-shaders tip;
nothing newer upstream).

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
- spirv-cross-mesh-wrapper.patch (same pin, 8 hunks, all in
  emit_mesh_wrapper + discrete call sites): the wrapper called the inner
  function with the descriptor ARRAY name while it declares per-element
  `<name>_i` parameters (both object and mesh wrappers) -> undeclared
  identifier; the mesh wrapper copied the per-PRIMITIVE PrimitiveId input
  as if per-vertex (garbage `VARYING_SLOT_PRIMITIVE_ID` lines) and never
  passed gl_PrimitiveID; vertex-index scaling was inverted (strip x3,
  list x1). Fix: forward each element, skip PrimitiveId in the copy loop,
  carry the primitive ID in a new Payload member `spvPrimitiveID`
  (object threadgroup index; MoltenVK MVKCmdDraw dispatches one
  single-thread object group per primitive, threadCount = primitive
  count, so positionInGrid.x IS the primitive index), pass
  `payload.spvPrimitiveID`, scale non-strip triangles x3 / lines x2.
  Verified: VS+GS+FS all compile under `xcrun metal` (0 errors), host
  run shows 0 compile errors and the same wiring in the dumped .metal.
- mesa-zink-venus-static-vertex-input.patch (3 hunks): UTM-mesh bakes
  PIPELINE vertex state at compile time, so dynamic state never reaches
  the object shader. Force fully static on Venus via
  zink_driver_is_venus: have_EXT_vertex_input_dynamic_state=false
  (zink_screen.c), uses_dynamic_stride=false (zink_context.c),
  skip the check_vertex_strides recompute (zink_program_state.hpp).
  Verified: dump shows `vertexIndex * 24` (was `* 0`).
- moltenvk-tmp-vertex-log.patch (TEMPORARY, host MoltenVK fprintf of
  vaCnt/vbCnt/bindings/strides; REMOVE before finishing): proved zink
  sends stride=0 in the pipeline (dynamic-state dummies), which is
  expected and correct on real drivers.

## Causal chain, current end

1. Mesa defaults ProvokingVertex=LAST (_mesa_init_lighting). Venus lacks
   EXT_provoking_vertex (Metal limitation), so zink lowers EVERY draw
   through a generated passthrough GS (lower_pv_mode).
2. That GS compiled to invalid SPIR-V (dedup patch) -> rejected. FIXED.
3. Its UBO access compiled to invalid MSL (robust-size patch) -> Metal
   rejects with pointer-vs-scalar. FIXED.
4. The mesh WRAPPER (UTM geometry-shaders branch, brand-new code) passed
   array names for element params, dropped gl_PrimitiveID, scaled
   vertices backwards. FIXED (mesh-wrapper patch); all three shaders
   compile under Apple's Metal (0 errors) and on the host (0 errors).
5. Vertex fetches used stride 0: zink uses vertex_input_dynamic_state +
   dynamic binding stride (both legal; real drivers consume them at draw
   time), but UTM-mesh bakes pipeline state at compile time. Recorded as
   static-vertex-input patch (3 flags). FIXED: dump shows stride 24.
6. CURRENT: gears runs 600 frames @ ~120 FPS, pipelines compile, draws
   execute, host validation silent -- but the window is BLACK. virgl
   gears renders fine (same run), so it is zink-pipeline-side, not
   environment. Depth texture still NULL (guard log still fires).
   Prime suspect ranking: (a) depth test with no depth buffer discards
   everything; (b) FS UBO content wrong (FS reads uniforms via buffer(1);
   zeros -> black); (c) mesh rasterizer state (viewport/scissor/cull).
   Ruled OUT by dump inspection: FS<->mesh location linkage matches
   (locn0 both sides), vertex fetch code now correct.

7. Black window = no depth buffer. Probes (since removed) showed every
   window depth create failing in every format: zink got
   memoryTypeBits 0x0 from vkGetImageMemoryRequirements. Cause in
   MoltenVK (UTM pin AND upstream main): MVKPixelFormats offers
   HOST_IMAGE_TRANSFER on depth formats, so zink adds
   VK_IMAGE_USAGE_HOST_TRANSFER (usage 0x400027); MVKImage then limits
   a depth attachment to private types and host transfer removes
   private types -> 0. Fix: moltenvk-depth-no-host-transfer.patch drops
   the feature for depth/stencil formats. Upstream report candidate.

## Rejected hypotheses (do not retry)

- no_gpl (VN_DEBUG=result,no_gpl): identical failure, same object id.
- fb==NULL vs texture==NULL for the discard crash: the texture-NULL log
  fires; fb guard never fired.
- Upstream Mesa already fixed: searched, nothing found.
- "zink sends stride 0 = zink bug": NO. Temporary MoltenVK probe showed
  the PIPELINE carries stride 0 because zink uses EXT_vertex_input_dynamic
  _state + BINDING_STRIDE dynamic state (both advertised by Venus, both
  consumed at draw time on real drivers). The mesh compiler is the only
  consumer that reads pipeline state. Do not "fix" zink's strides; the
  static-vertex-input patch is the correct scope.
- have_EXT_vertex_input_dynamic_state=false ALONE fixes strides: NO.
  Second dynamic mechanism (uses_dynamic_stride, from EDS) keeps
  pipelines dynamic via check_vertex_strides recompute. All three flags
  are needed (screen + context + program_state.hpp).
- R3 (skip generated GS when no flat varyings): MOOT. The mesh path
  works; killing the GS is no longer needed or wanted.

## Device facts (guest vulkaninfo-full.txt)

- Virtio-GPU Venus (Apple M5 Pro), driver 26.2.2. Missing: logicOp,
  customBorderColor, depth_clip_enable (zink warns, continues).
- geometryShader=true BUT maxGeometry*=0 (UTM MoltenVK MVKDevice.mm sets
  zeros; mesh path needs private API, which is off). Consequence, now
  understood: UTM compiles EVERY GS pipeline as mesh (for_mesh_pipeline
  forced for ExecutionModelGeometry; VS as [[object]]). The mesh path is
  prototype-grade but functional after the patches above.
- uniformBufferStandardLayout=true, scalarBlockLayout=true.
- vertexInputDynamicState=true + EDS present: zink uses both dynamic
  mechanisms; static-vertex-input patch opts Venus out (see above).

## Symbolization recipe (aarch64-linux binaries on darwin)

Guest mesa ships a -debug output (copied from builder on rebuild).
`nix shell --file /etc/nixpkgs llvm --command llvm-symbolizer
--obj=<...-debug>/lib/debug/libgallium-26.2.2.so --functions=linkage
--inlining --demangle <offsets>`. Same for libvulkan_virtio.so. Used to
attribute: discard_attachments fbobject.c:5672 block; cache_put_job
zink_screen.c:388; vn_ring_submit_command vn_ring.c:708 (ring==NULL);
vn_get_target_ring NULL return.

## Next steps

R2: confirm the depth fix (step 7) renders gears under zink. If still
black: FS UBO content path (buffer(1) through the vkr descriptor heap),
then mesh raster state.
R5: hand-written patch hygiene: always verify with `patch -p1 --dry-run`
against pristine sources; hand-counted hunk headers bit twice (missing
trailing context line; 9-vs-10-space indent). Generate via diff where
possible.
