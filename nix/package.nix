{ lib
, stdenv
, callPackage
, zig
, stb
, wayland
, wayland-scanner
, wayland-protocols
, wlr-protocols
, pkg-config
, cairo
, dbus
, libxkbcommon
, wlroots
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "sneemok";
  version = "0.1.0";

  src = ../.;

  # Fetch Zig dependencies from build.zig.zon.nix
  deps = callPackage ../build.zig.zon.nix { name = "sneemok-deps"; };

  nativeBuildInputs = [ zig ];

  buildInputs = [
    stb
    wayland-scanner
    wayland-protocols
    wayland
    pkg-config
    dbus
    libxkbcommon
    wlroots
    wlr-protocols
    cairo
  ];

  dontConfigure = true;

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Doptimize=ReleaseSafe"
  ];

  buildPhase = ''
    runHook preBuild
    export HOME=$TMPDIR
    zig build $zigBuildFlags --prefix $out
    runHook postBuild
  '';

  dontInstall = true;

  meta = with lib; {
    description = "Wayland screenshot annotation tool";
    license = licenses.mit;
    platforms = platforms.linux;
    maintainers = [ fn3x ];
  };
})

