# CAPK's manager, the KubeVirt provider for Cluster API, built from its
# release tag with fixes upstream does not carry yet.
{
  buildGoModule,
  fetchFromGitHub,
}:
buildGoModule (finalAttrs: {
  pname = "cluster-api-provider-kubevirt";
  version = "0.11.2";

  src = fetchFromGitHub {
    owner = "kubernetes-sigs";
    repo = "cluster-api-provider-kubevirt";
    tag = "v${finalAttrs.version}";
    hash = "sha256-A7IJM29HX3U3XdKKeU0FODY+w3SeahZ1RdAE5Daf+x4=";
  };

  vendorHash = "sha256-aQ6zEqAPQRQDn4DAIUjy8HTXIi69YgrEFIJ6ybFqItw=";

  patches = [
    # The SSH bootstrap check cannot dial an IPv6 address.
    ./ipv6-ssh.patch
  ];

  # The module root is the manager; the other packages are tools and tests.
  subPackages = [ "." ];
  env.CGO_ENABLED = 0;

  postInstall = ''
    mv $out/bin/cluster-api-provider-kubevirt $out/bin/manager
  '';

  meta.mainProgram = "manager";
})
