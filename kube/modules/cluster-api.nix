# Cluster API, so a Kubernetes cluster that runs as VMs on this host is a set
# of objects here: the core controllers, the kubeadm bootstrap and control
# plane providers, and CAPK, the KubeVirt infrastructure provider.
#
# The release YAMLs are what `clusterctl init` applies, taken without
# clusterctl. That leaves one clusterctl step to do here: the YAMLs hold
# `${NAME:=default}` placeholders in container arguments, which clusterctl
# fills from its variables. `defaults` fills each one with its default, which
# is what clusterctl does with no variables set.
#
# Every controller's webhook certificate comes from ./cert-manager.nix. The
# Certificate and Issuer objects here need cert-manager's own webhook serving,
# so the first apply against a cluster without cert-manager fails on them and
# the apply after it succeeds.
#
# CAPK 0.11 is built against Cluster API 1.11 and speaks the v1beta2
# contract, which every Cluster API release from 1.11 on serves.
#
# CAPK runs a manager built here (../pkgs/capk) rather than its release
# image, because it carries a fix upstream has not released. nixkube
# mounts the store path into the pod; see ./nixkube.nix.
{ lib, pkgs, ... }:
let
  version = "1.14.2";
  capk = pkgs.callPackage ../pkgs/capk { };
  capkVersion = capk.version;

  runCapkFromStore =
    object:
    if object.kind == "Deployment" && object.metadata.name == "capk-controller-manager" then
      lib.recursiveUpdate object {
        spec.template.spec = {
          containers = map (
            container:
            container
            // {
              image = "ghcr.io/lillecarl/nix-csi/scratch:1.0.1";
              imagePullPolicy = "IfNotPresent";
              command = [ (lib.getExe capk) ];
              volumeMounts = container.volumeMounts ++ [
                {
                  name = "nix";
                  mountPath = "/nix";
                  subPath = "nix";
                }
              ];
            }
          ) object.spec.template.spec.containers;
          volumes = object.spec.template.spec.volumes ++ [
            {
              name = "nix";
              csi = {
                driver = "nixkube";
                readOnly = true;
                volumeAttributes.${pkgs.stdenv.hostPlatform.system} = "${capk}";
              };
            }
          ];
        };
      }
    else
      object;

  release =
    file: hash:
    pkgs.fetchurl {
      inherit hash;
      url = "https://github.com/kubernetes-sigs/cluster-api/releases/download/v${version}/${file}";
    };

  defaults =
    value:
    if lib.isString value then
      lib.concatMapStrings (part: if lib.isList part then lib.head part else part) (
        builtins.split "\\$\\{[A-Za-z0-9_]+:=([^}]*)}" value
      )
    else if lib.isList value then
      map defaults value
    else if lib.isAttrs value then
      lib.mapAttrs (_: defaults) value
    else
      value;

  components = src: {
    inherit src;
    transformers = [ (map defaults) ];
  };
in
{
  importyaml = {
    cluster-api-core = components (release "core-components.yaml" "sha256-sv/0LLXjVEDtljpGPFqxKABEgbWkM26gAFgSvi/34qg=");
    cluster-api-bootstrap-kubeadm = components (release "bootstrap-components.yaml" "sha256-Ki0k+DJEptrmDjXZ5y6Txqw8IJ7txGcYRze7juz9Y7s=");
    cluster-api-control-plane-kubeadm = components (release "control-plane-components.yaml" "sha256-eqgntD7uiY2Fl7s5t9tc91XIcsek2miwXMOp81xFnJM=");
    cluster-api-kubevirt = {
      src = pkgs.fetchurl {
        url = "https://github.com/kubernetes-sigs/cluster-api-provider-kubevirt/releases/download/v${capkVersion}/infrastructure-components.yaml";
        hash = "sha256-PFQIwxjqtOPgxfI5bI35HWFd0McSppLXfnyrNds31xc=";
      };
      transformers = [
        (map defaults)
        (map runCapkFromStore)
      ];
    };
  };
}
