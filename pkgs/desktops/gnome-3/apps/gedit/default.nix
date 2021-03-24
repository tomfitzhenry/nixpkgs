{ lib, stdenv
, meson
, fetchurl
, python3
, pkg-config
, gtk3
, glib
, adwaita-icon-theme
, libpeas
, gtksourceview4
, gsettings-desktop-schemas
, wrapGAppsHook
, ninja
, libsoup
, tepl
, gnome3
, gspell
, perl
, itstool
, desktop-file-utils
, vala
}:

stdenv.mkDerivation rec {
  pname = "gedit";
  version = "40.0";

  src = fetchurl {
    url = "mirror://gnome/sources/gedit/${lib.versions.major version}/${pname}-${version}.tar.xz";
    sha256 = "1sc474gf86529vh7hym3bvyw6h6zyxk5rwxa8rrsayc85disr2hf";
  };

  nativeBuildInputs = [
    desktop-file-utils
    itstool
    meson
    ninja
    perl
    pkg-config
    python3
    vala
    wrapGAppsHook
  ];

  buildInputs = [
    adwaita-icon-theme
    glib
    gsettings-desktop-schemas
    gspell
    gtk3
    gtksourceview4
    libpeas
    libsoup
    tepl
  ];

  postPatch = ''
    chmod +x build-aux/meson/post_install.py
    chmod +x plugins/externaltools/scripts/gedit-tool-merge.pl
    patchShebangs build-aux/meson/post_install.py
    patchShebangs plugins/externaltools/scripts/gedit-tool-merge.pl
  '';

  # Reliably fails to generate gedit-file-browser-enum-types.h in time
  enableParallelBuilding = false;

  passthru = {
    updateScript = gnome3.updateScript {
      packageName = "gedit";
      attrPath = "gnome3.gedit";
    };
  };

  meta = with lib; {
    homepage = "https://wiki.gnome.org/Apps/Gedit";
    description = "Official text editor of the GNOME desktop environment";
    maintainers = teams.gnome.members;
    license = licenses.gpl2;
    platforms = platforms.unix;
  };
}
