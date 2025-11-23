{ lib
, stdenv
, zig
, stb
, wayland-scanner
, wayland-protocols
, wayland
, pkg-config
, dbus
, libxkbcommon
, wlroots
, wlr-protocols
, wl-clipboard
, cairo
}:
stdenv.mkDerivation {
  name = "sneemok";
  pname = "sneemok";
  version = "0.1.0";

  src = ../.;

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
    wl-clipboard
    cairo
  ];

  buildPhase = ''
    export HOME=$TMPDIR
    zig build -Doptimize=ReleaseSafe
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp zig-out/bin/sneemok $out/bin/
  '';

  meta = with lib; {
    description = "Wayland screenshot annotation tool";
    homepage = "https://codeberg.org/fn3x/sneemok";
    license = licenses.mit;
    platforms = platforms.linux;
    maintainers = [ fn3x ];
  };
}
