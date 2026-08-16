# vfkit with the memory balloon reachable over its REST API.
#
# Apple's Virtualization.framework offers a memory balloon, and vfkit already
# attaches one with `--device virtio-balloon`. It also already links the vz
# bindings that drive it. What it does not do is expose them: `pkg/rest/rest.go`
# routes only /vm/state and /vm/inspect, so SetTargetVirtualMachineMemorySize is
# linked into the binary and never called. The device is inert.
#
# What this can and cannot buy, measured on the guest rather than assumed. The
# feature bits Apple negotiates are:
#
#   MUST_TELL_HOST=1  STATS_VQ=0  DEFLATE_ON_OOM=1
#   FREE_PAGE_HINT=0  PAGE_POISON=0  PAGE_REPORTING=0
#
# So there is no free page reporting: the guest will never hand memory back on
# its own, and no patch here can add that, because the feature bits come from
# Apple's framework and not from vfkit. Reclaim has to be driven from the host,
# and STATS_VQ=0 means the host cannot read guest memory usage from the device
# either -- a policy has to ask the guest another way, or use fixed targets.
#
# DEFLATE_ON_OOM=1 is what makes fixed targets viable: if the host inflates too
# far, the guest takes memory back rather than invoking the OOM killer.
#
# substituteInPlace rather than a .patch file, so this breaks loudly and
# specifically if upstream moves the lines, instead of failing as a fuzzy hunk.
# Reusing VirtualMachineStateHandler is a downstream shortcut -- an upstream
# change would add its own interface rather than widening that one, and would
# not need the call site in cmd/vfkit/main.go to change.
{ vfkit }:

vfkit.overrideAttrs (old: {
  postPatch = (old.postPatch or "") + ''
    cat > pkg/rest/vf/balloon.go <<'BALLOON_EOF'
    package rest

    import (
    	"net/http"

    	"github.com/Code-Hex/vz/v3"
    	"github.com/gin-gonic/gin"
    )

    type memoryBalloonTarget struct {
    	// Bytes. Apple's API is in bytes; callers that think in MiB must
    	// multiply, and a target above the VM's configured memory is clamped by
    	// the framework rather than rejected here.
    	TargetVirtualMachineMemorySize uint64 `json:"targetVirtualMachineMemorySize"`
    }

    // balloon returns the VM's first traditional memory balloon, if it has one.
    func (vm *VzVirtualMachine) balloon() (*vz.VirtioTraditionalMemoryBalloonDevice, bool) {
    	for _, device := range vm.MemoryBalloonDevices() {
    		if traditional, ok := device.(*vz.VirtioTraditionalMemoryBalloonDevice); ok {
    			return traditional, true
    		}
    	}
    	return nil, false
    }

    // GetMemoryBalloon reports the balloon's current target size in bytes.
    func (vm *VzVirtualMachine) GetMemoryBalloon(c *gin.Context) {
    	device, ok := vm.balloon()
    	if !ok {
    		c.JSON(http.StatusNotFound, gin.H{"error": "no memory balloon device"})
    		return
    	}
    	c.JSON(http.StatusOK, memoryBalloonTarget{
    		TargetVirtualMachineMemorySize: device.GetTargetVirtualMachineMemorySize(),
    	})
    }

    // SetMemoryBalloon inflates or deflates the balloon by setting the memory
    // size the guest is meant to be left with.
    func (vm *VzVirtualMachine) SetMemoryBalloon(c *gin.Context) {
    	var target memoryBalloonTarget
    	if err := c.ShouldBindJSON(&target); err != nil {
    		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
    		return
    	}
    	device, ok := vm.balloon()
    	if !ok {
    		c.JSON(http.StatusNotFound, gin.H{"error": "no memory balloon device"})
    		return
    	}
    	device.SetTargetVirtualMachineMemorySize(target.TargetVirtualMachineMemorySize)
    	c.JSON(http.StatusAccepted, memoryBalloonTarget{
    		TargetVirtualMachineMemorySize: device.GetTargetVirtualMachineMemorySize(),
    	})
    }
    BALLOON_EOF

    # The heredoc above is indented to read as Nix; Go does not care about
    # leading whitespace, but gofmt would, so strip it.
    sed -i 's/^    //' pkg/rest/vf/balloon.go

    substituteInPlace pkg/rest/rest.go \
      --replace-fail \
        'r.GET("/vm/inspect", inspector.Inspect)' \
        'r.GET("/vm/inspect", inspector.Inspect)
    	r.GET("/vm/memory-balloon", stateHandler.GetMemoryBalloon)
    	r.POST("/vm/memory-balloon", stateHandler.SetMemoryBalloon)' \
      --replace-fail \
        'SetVMState(c *gin.Context)' \
        'SetVMState(c *gin.Context)
    	GetMemoryBalloon(c *gin.Context)
    	SetMemoryBalloon(c *gin.Context)'
  '';
})
