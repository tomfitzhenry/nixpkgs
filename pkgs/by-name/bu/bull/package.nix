{
  lib,
  buildGoModule,
  fetchFromGitHub,
  nix-update-script,
}:

buildGoModule {
  pname = "bull";
  version = "0-unstable-2026-08-27";

  src = fetchFromGitHub {
    owner = "gokrazy";
    repo = "bull";
    rev = "8deb93becfa9e7ce99709a6d9f923d1201e10e5e";
    hash = "sha256-hBerV2vnI6u/mAVAuM83ALzHfpYLZeZrIT2sj0BxyTo=";
  };

  vendorHash = "sha256-dSD/b+M36Lh+V+m3VKuIK+ocBimWyG4cLFq5IXRe0Wk=";

  __structuredAttrs = true;

  passthru.updateScript = nix-update-script { extraArgs = [ "--version=unstable" ]; };

  meta = {
    description = "Minimalist bullet journaling program";
    homepage = "https://github.com/gokrazy/bull";
    license = lib.licenses.bsd0;
    maintainers = with lib.maintainers; [ tomfitzhenry ];
    mainProgram = "bull";
    platforms = lib.platforms.unix;
  };
}
