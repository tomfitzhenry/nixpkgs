{ lib, stdenv, fetchurl, gnome, libxslt }:

stdenv.mkDerivation rec {
  pname = "mobile-broadband-provider-info";
  version = "20210805";

  src = fetchurl {
    url = "mirror://gnome/sources/${pname}/${version}/${pname}-${version}.tar.xz";
    sha256 = "1g384m0qf77gng54w4wvhalmm7ycfig43d7pqvxilm55iras3y3b";
  };

  nativeBuildInputs = [
    # fixes configure: error: xsltproc not found
    libxslt
  ];

  passthru = {
    updateScript = gnome.updateScript {
      packageName = pname;
    };
  };

  meta = with lib; {
    description = "Mobile broadband service provider database";
    homepage = "https://wiki.gnome.org/Projects/NetworkManager/MobileBroadband/ServiceProviders";
    license = licenses.publicDomain;
    maintainers = [ ];
    platforms = platforms.all;
  };
}
